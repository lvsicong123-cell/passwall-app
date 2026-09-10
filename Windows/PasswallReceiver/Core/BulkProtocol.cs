using System.Buffers.Binary;

namespace PasswallReceiver.Core;

internal enum TransferDirection
{
    Upload,
    Download
}

internal enum TrustedSessionRole
{
    Input,
    Bulk
}

internal sealed record TrustedSessionBinding(
    TrustedSessionRole Role,
    Guid? TransferID = null,
    TransferDirection? Direction = null)
{
    public static TrustedSessionBinding Parse(string line)
    {
        var parts = line.Split(' ', StringSplitOptions.None);
        if (parts is ["SESSION", "input"])
        {
            return new(TrustedSessionRole.Input);
        }
        if (parts.Length != 4 || parts[0] != "SESSION" || parts[1] != "bulk" ||
            !TryParseTransferID(parts[2], out var transferID))
        {
            throw new InvalidDataException("Invalid session declaration");
        }
        var direction = parts[3] switch
        {
            "upload" => TransferDirection.Upload,
            "download" => TransferDirection.Download,
            _ => throw new InvalidDataException("Invalid bulk direction")
        };
        return new(TrustedSessionRole.Bulk, transferID, direction);
    }

    internal static bool TryParseTransferID(string value, out Guid transferID) =>
        Guid.TryParseExact(value, "D", out transferID) &&
        value.Length == 36 && value[14] == '4' &&
        "89abAB".Contains(value[19]);
}

internal enum BulkFrameKind : byte
{
    Chunk = 1,
    Cancel = 2,
    Complete = 3
}

internal sealed record BulkFrame(
    BulkFrameKind Kind,
    Guid TransferID,
    ulong Sequence,
    byte[] Payload);

internal static class BulkFrameCodec
{
    public const int HeaderSize = 29;
    public const int MaximumEncodedSize = HeaderSize + ProtocolContract.MaximumBulkChunkSize;

    public static async Task WriteAsync(
        Stream stream,
        BulkFrame frame,
        CancellationToken cancellationToken = default)
    {
        Validate(frame);
        var header = new byte[HeaderSize];
        header[0] = (byte)frame.Kind;
        Convert.FromHexString(frame.TransferID.ToString("N")).CopyTo(header, 1);
        BinaryPrimitives.WriteUInt64BigEndian(header.AsSpan(17, 8), frame.Sequence);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(25, 4), (uint)frame.Payload.Length);
        await stream.WriteAsync(header, cancellationToken);
        if (frame.Payload.Length > 0)
        {
            await stream.WriteAsync(frame.Payload, cancellationToken);
        }
    }

    public static async Task<BulkFrame?> ReadAsync(
        Stream stream,
        CancellationToken cancellationToken = default)
    {
        var header = new byte[HeaderSize];
        if (!await ReadExactlyOrEndAsync(stream, header, cancellationToken))
        {
            return null;
        }

        var kind = (BulkFrameKind)header[0];
        var transferID = Guid.ParseExact(Convert.ToHexString(header.AsSpan(1, 16)), "N");
        var sequence = BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(17, 8));
        var length = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(25, 4));
        if (length > ProtocolContract.MaximumBulkChunkSize)
        {
            throw new InvalidDataException(
                $"Bulk chunk exceeds {ProtocolContract.MaximumBulkChunkSize} bytes");
        }
        var payload = new byte[checked((int)length)];
        if (!await ReadExactlyOrEndAsync(stream, payload, cancellationToken))
        {
            throw new EndOfStreamException("Connection ended inside a bulk frame");
        }
        var frame = new BulkFrame(kind, transferID, sequence, payload);
        Validate(frame);
        return frame;
    }

    private static void Validate(BulkFrame frame)
    {
        if (frame.Kind is not (BulkFrameKind.Chunk or BulkFrameKind.Cancel or BulkFrameKind.Complete))
        {
            throw new InvalidDataException("Unknown bulk frame kind");
        }
        if (!TrustedSessionBinding.TryParseTransferID(
                frame.TransferID.ToString("D"), out _))
        {
            throw new InvalidDataException("Invalid transfer ID");
        }
        if (frame.Sequence == 0)
        {
            throw new InvalidDataException("Bulk sequence must be positive");
        }
        if (frame.Payload.Length > ProtocolContract.MaximumBulkChunkSize)
        {
            throw new InvalidDataException(
                $"Bulk chunk exceeds {ProtocolContract.MaximumBulkChunkSize} bytes");
        }
        if (frame.Kind is not BulkFrameKind.Chunk && frame.Payload.Length != 0)
        {
            throw new InvalidDataException("Bulk control frame cannot contain payload");
        }
    }

    private static async Task<bool> ReadExactlyOrEndAsync(
        Stream stream,
        Memory<byte> buffer,
        CancellationToken cancellationToken)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer[total..], cancellationToken);
            if (read == 0)
            {
                if (total == 0) return false;
                throw new EndOfStreamException("Connection ended inside a bulk frame segment");
            }
            total += read;
        }
        return true;
    }
}

internal sealed class BulkFrameSequenceGuard(Guid expectedTransferID)
{
    public ulong LastAcceptedSequence { get; private set; }
    public bool IsFinished { get; private set; }

    public void Accept(BulkFrame frame)
    {
        if (IsFinished) throw new InvalidDataException("Bulk transfer is already finished");
        if (frame.TransferID != expectedTransferID)
        {
            throw new InvalidDataException("Bulk frame used the wrong transfer ID");
        }
        if (frame.Sequence <= LastAcceptedSequence)
        {
            throw new InvalidDataException("Bulk frame sequence was replayed or stale");
        }
        LastAcceptedSequence = frame.Sequence;
        IsFinished = frame.Kind is BulkFrameKind.Cancel or BulkFrameKind.Complete;
    }
}
