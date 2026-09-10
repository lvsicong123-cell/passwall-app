using System.Security.Cryptography;
using System.Text.Json;

namespace PasswallReceiver.Core;

internal sealed record FileTransferBatch(FileTransferManifest Manifest, IReadOnlyList<string> Files)
{
    public static FileTransferBatch Build(
        IEnumerable<string> selectedPaths,
        ulong maximumBatchBytes = ProtocolContract.MaximumBatchBytes)
    {
        maximumBatchBytes = Math.Min(maximumBatchBytes, ProtocolContract.MaximumBatchBytes);
        var wireEntries = new List<Dictionary<string, object?>>();
        var files = new List<string>();
        ulong totalBytes = 0;
        var discoveredEntries = 0;
        foreach (var path in selectedPaths)
        {
            Append(
                Path.GetFullPath(path),
                Path.GetFileName(path),
                wireEntries,
                files,
                ref totalBytes,
                ref discoveredEntries,
                maximumBatchBytes);
        }
        var document = JsonSerializer.SerializeToElement(new { entries = wireEntries });
        return new FileTransferBatch(FileTransferManifest.Parse(document), files);
    }

    public Stream OpenRead() => new FileTransferSourceStream(this);

    private static void Append(
        string path,
        string relativePath,
        List<Dictionary<string, object?>> entries,
        List<string> files,
        ref ulong totalBytes,
        ref int discoveredEntries,
        ulong maximumBatchBytes,
        bool alreadyDiscovered = false)
    {
        if (!alreadyDiscovered)
        {
            if (discoveredEntries == ProtocolContract.MaximumBatchEntries)
            {
                throw new InvalidDataException("File batch exceeds the entry limit");
            }
            discoveredEntries++;
        }
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException($"Symbolic links are unsupported: {relativePath}");
        }
        if ((attributes & FileAttributes.Directory) != 0)
        {
            entries.Add(new() { ["path"] = relativePath, ["kind"] = "directory", ["byteCount"] = 0UL });
            var remainingEntries = ProtocolContract.MaximumBatchEntries - discoveredEntries;
            var children = Directory.EnumerateFileSystemEntries(path)
                .Take(remainingEntries + 1)
                .ToArray();
            if (children.Length > remainingEntries)
            {
                throw new InvalidDataException("File batch exceeds the entry limit");
            }
            discoveredEntries += children.Length;
            foreach (var child in children.OrderBy(
                child => Path.GetFileName(child),
                StringComparer.Ordinal))
            {
                Append(
                    child,
                    $"{relativePath}/{Path.GetFileName(child)}",
                    entries,
                    files,
                    ref totalBytes,
                    ref discoveredEntries,
                    maximumBatchBytes,
                    alreadyDiscovered: true);
            }
            return;
        }
        if ((attributes & (FileAttributes.Device | FileAttributes.Offline)) != 0)
        {
            throw new InvalidDataException($"Unsupported file: {relativePath}");
        }
        var size = checked((ulong)new FileInfo(path).Length);
        try { totalBytes = checked(totalBytes + size); }
        catch (OverflowException error)
        {
            throw new InvalidDataException("File batch size overflowed", error);
        }
        if (totalBytes > maximumBatchBytes)
        {
            throw new InvalidDataException("File batch exceeds the byte limit");
        }
        using var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var digest = Convert.ToHexString(SHA256.HashData(source)).ToLowerInvariant();
        entries.Add(new()
        {
            ["path"] = relativePath,
            ["kind"] = "file",
            ["byteCount"] = size,
            ["sha256"] = digest
        });
        files.Add(path);
    }
}

internal sealed class FileTransferSourceStream(FileTransferBatch batch) : Stream
{
    private readonly List<FileManifestEntry> files = batch.Manifest.Entries
        .Where(entry => entry.Kind == "file").ToList();
    private int index;
    private FileStream? source;
    private ulong byteCount;
    private IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => checked((long)batch.Manifest.TotalBytes);
    public override long Position { get; set; }

    public override int Read(byte[] buffer, int offset, int count)
    {
        while (index < files.Count)
        {
            Prepare();
            var read = source!.Read(buffer, offset, count);
            if (read > 0)
            {
                Accept(buffer.AsSpan(offset, read));
                Position += read;
                return read;
            }
            FinishFile();
        }
        return 0;
    }

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        while (index < files.Count)
        {
            Prepare();
            var read = await source!.ReadAsync(buffer, cancellationToken);
            if (read > 0)
            {
                Accept(buffer.Span[..read]);
                Position += read;
                return read;
            }
            FinishFile();
        }
        return 0;
    }

    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            source?.Dispose();
            hash.Dispose();
        }
        base.Dispose(disposing);
    }

    private void Prepare()
    {
        if (source is not null) return;
        source = new FileStream(batch.Files[index], FileMode.Open, FileAccess.Read, FileShare.Read);
        byteCount = 0;
        hash.Dispose();
        hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    }

    private void Accept(ReadOnlySpan<byte> data)
    {
        byteCount += checked((ulong)data.Length);
        if (byteCount > files[index].ByteCount)
        {
            throw new InvalidDataException($"File changed after offer: {files[index].Path}");
        }
        hash.AppendData(data);
    }

    private void FinishFile()
    {
        source!.Dispose();
        source = null;
        var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        if (byteCount != files[index].ByteCount || digest != files[index].Sha256)
        {
            throw new InvalidDataException($"File changed after offer: {files[index].Path}");
        }
        index++;
    }
}

internal enum FileTransferStatus
{
    Queued,
    AwaitingApproval,
    Transferring,
    Verifying,
    Completed,
    Rejected,
    Canceled,
    Failed
}

internal sealed record FileTransferNameMapping(string Original, string Local);

internal sealed record FileTransferHistoryEntry(
    Guid TransferID,
    string Name,
    TransferDirection Direction,
    ulong TotalBytes,
    string DeviceName,
    DateTimeOffset StartedAt,
    FileTransferStatus Status,
    IReadOnlyList<FileTransferNameMapping>? NameMappings = null);

internal sealed class FileTransferHistoryStore
{
    public const int MaximumCount = 100;
    private readonly List<FileTransferHistoryEntry> entries = [];
    public IReadOnlyList<FileTransferHistoryEntry> Entries => entries;

    public void Record(FileTransferHistoryEntry entry)
    {
        entries.RemoveAll(existing => existing.TransferID == entry.TransferID);
        entries.Insert(0, entry);
        if (entries.Count > MaximumCount) entries.RemoveAt(entries.Count - 1);
    }

    public void Update(Guid transferID, FileTransferStatus status)
    {
        var index = entries.FindIndex(entry => entry.TransferID == transferID);
        if (index >= 0) entries[index] = entries[index] with { Status = status };
    }

    public void Clear() => entries.Clear();
}
