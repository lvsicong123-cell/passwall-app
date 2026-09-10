using System.Security.Cryptography;

namespace PasswallReceiver.Core;

internal sealed class FileTransferStaging : IDisposable
{
    private readonly string destinationRoot;
    private readonly List<FileManifestEntry> files;
    private int fileIndex;
    private ulong byteCount;
    private FileStream? stream;
    private IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private bool committed;

    public static void RemoveAbandonedPartials(string destinationRoot)
    {
        if (!Directory.Exists(destinationRoot)) return;
        foreach (var path in Directory.EnumerateDirectories(destinationRoot, ".passwall-*.partial")
            .Where(path => PartialTransferID(Path.GetFileName(path)) is not null))
        {
            Directory.Delete(path, recursive: true);
        }
    }

    public FileTransferStaging(string destinationRoot, Guid transferID, FileTransferManifest manifest)
    {
        this.destinationRoot = destinationRoot;
        files = manifest.Entries.Where(entry => entry.Kind == "file").ToList();
        Directory.CreateDirectory(destinationRoot);
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(destinationRoot))!);
        if (!HasEnoughSpace(drive.AvailableFreeSpace, manifest.TotalBytes))
        {
            throw new IOException("Destination has insufficient free space");
        }
        PartialDirectory = Path.Combine(destinationRoot, $".passwall-{transferID:D}.partial");
        if (Directory.Exists(PartialDirectory))
        {
            throw new InvalidDataException("Transfer staging already exists");
        }
        Directory.CreateDirectory(PartialDirectory);
        try
        {
            foreach (var entry in manifest.Entries.Where(entry => entry.Kind == "directory"))
            {
                Directory.CreateDirectory(PathFor(entry));
            }
            PrepareNextFile();
        }
        catch
        {
            Cleanup();
            throw;
        }
    }

    public string PartialDirectory { get; }

    internal static bool HasEnoughSpace(long availableBytes, ulong requiredBytes) =>
        availableBytes >= 0 && (ulong)availableBytes >= requiredBytes;

    public void Append(ReadOnlySpan<byte> bytes)
    {
        try
        {
            while (!bytes.IsEmpty)
            {
                if (fileIndex == files.Count || stream is null)
                {
                    throw new InvalidDataException("File body exceeds its manifest");
                }
                var remaining = files[fileIndex].ByteCount - byteCount;
                var count = (int)Math.Min(remaining, (ulong)bytes.Length);
                var chunk = bytes[..count];
                stream.Write(chunk);
                hash.AppendData(chunk);
                byteCount += (ulong)count;
                bytes = bytes[count..];
                if (byteCount == files[fileIndex].ByteCount) FinishFile();
            }
        }
        catch
        {
            Cleanup();
            throw;
        }
    }

    public string Finish()
    {
        try
        {
            PrepareNextFile();
            if (fileIndex != files.Count) throw new InvalidDataException("File body ended early");
            var destination = Path.Combine(destinationRoot, $"Passwall-{Guid.NewGuid():D}");
            while (Directory.Exists(destination))
            {
                destination = Path.Combine(destinationRoot, $"Passwall-{Guid.NewGuid():D}");
            }
            Directory.Move(PartialDirectory, destination);
            committed = true;
            return destination;
        }
        catch
        {
            Cleanup();
            throw;
        }
    }

    public void Dispose()
    {
        Cleanup();
        hash.Dispose();
    }

    private void PrepareNextFile()
    {
        while (fileIndex < files.Count)
        {
            var path = PathFor(files[fileIndex]);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            byteCount = 0;
            hash.Dispose();
            hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            if (files[fileIndex].ByteCount != 0) return;
            FinishFile();
        }
    }

    private void FinishFile()
    {
        var entry = files[fileIndex];
        stream!.Dispose();
        stream = null;
        var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        if (digest != entry.Sha256)
        {
            throw new InvalidDataException($"File digest did not match: {entry.Path}");
        }
        fileIndex++;
        PrepareNextFile();
    }

    private string PathFor(FileManifestEntry entry) =>
        Path.Combine(PartialDirectory, entry.LocalPath.Replace('/', Path.DirectorySeparatorChar));

    private static Guid? PartialTransferID(string name)
    {
        const string prefix = ".passwall-";
        const string suffix = ".partial";
        if (!name.StartsWith(prefix, StringComparison.Ordinal) ||
            !name.EndsWith(suffix, StringComparison.Ordinal)) return null;
        return Guid.TryParse(name[prefix.Length..^suffix.Length], out var transferID)
            ? transferID : null;
    }

    private void Cleanup()
    {
        stream?.Dispose();
        stream = null;
        try
        {
            if (!committed && Directory.Exists(PartialDirectory))
            {
                Directory.Delete(PartialDirectory, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }
}

internal sealed class FileTransferStagingStream(FileTransferStaging staging) : Stream
{
    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

    public string Finish() => staging.Finish();
    public override void Flush() { }
    public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) =>
        staging.Append(buffer.AsSpan(offset, count));
    public override void Write(ReadOnlySpan<byte> buffer) => staging.Append(buffer);
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        staging.Append(buffer.Span);
        return ValueTask.CompletedTask;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) staging.Dispose();
        base.Dispose(disposing);
    }
}
