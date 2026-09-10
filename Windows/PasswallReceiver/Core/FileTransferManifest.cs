using System.Text.Json;

namespace PasswallReceiver.Core;

internal sealed record FileManifestEntry(
    string Path,
    string LocalPath,
    string Kind,
    ulong ByteCount,
    string? Sha256);

internal sealed record FileTransferManifest(IReadOnlyList<FileManifestEntry> Entries, ulong TotalBytes)
{
    public static FileTransferManifest Parse(JsonElement value)
    {
        if (value.ValueKind is not JsonValueKind.Object ||
            !value.TryGetProperty("entries", out var entriesValue) ||
            entriesValue.ValueKind is not JsonValueKind.Array)
        {
            throw new InvalidDataException("File manifest must contain entries");
        }

        var entries = new List<FileManifestEntry>();
        var paths = new HashSet<string>(StringComparer.Ordinal);
        var filePaths = new HashSet<string>(StringComparer.Ordinal);
        var parentPaths = new HashSet<string>(StringComparer.Ordinal);
        var portablePaths = new PortableWindowsPaths();
        ulong totalBytes = 0;
        foreach (var item in entriesValue.EnumerateArray())
        {
            if (entries.Count == ProtocolContract.MaximumBatchEntries ||
                item.ValueKind is not JsonValueKind.Object)
            {
                throw new InvalidDataException("File manifest has too many or invalid entries");
            }
            var path = item.GetProperty("path").GetString()
                ?? throw new InvalidDataException("File manifest path is missing");
            var kind = item.GetProperty("kind").GetString();
            var byteCount = item.GetProperty("byteCount").GetUInt64();
            var sha256 = item.TryGetProperty("sha256", out var digestValue) &&
                digestValue.ValueKind is not JsonValueKind.Null ? digestValue.GetString() : null;

            if (!IsRelativePath(path) || !paths.Add(path))
            {
                throw new InvalidDataException("File manifest path is unsafe or duplicated");
            }
            var parents = ParentPaths(path).ToArray();
            if (parents.Any(filePaths.Contains) || kind is "file" && parentPaths.Contains(path))
            {
                throw new InvalidDataException("File manifest path conflicts with a file entry");
            }
            parentPaths.UnionWith(parents);
            if (kind is "file") filePaths.Add(path);
            if (kind is "directory")
            {
                if (byteCount != 0 || sha256 is not null)
                {
                    throw new InvalidDataException("Directory manifest entry has content metadata");
                }
            }
            else if (kind is "file")
            {
                if (!IsSha256(sha256))
                {
                    throw new InvalidDataException("File manifest digest is invalid");
                }
            }
            else
            {
                throw new InvalidDataException("File manifest entry kind is invalid");
            }

            try { totalBytes = checked(totalBytes + byteCount); }
            catch (OverflowException error)
            {
                throw new InvalidDataException("File manifest size overflowed", error);
            }
            if (totalBytes > ProtocolContract.MaximumBatchBytes)
            {
                throw new InvalidDataException("File manifest exceeds the batch limit");
            }
            var localPath = portablePaths.Map(path);
            entries.Add(new FileManifestEntry(path, localPath, kind!, byteCount, sha256));
        }

        if (entries.Count == 0) throw new InvalidDataException("File manifest is empty");
        return new FileTransferManifest(entries, totalBytes);
    }

    private static bool IsRelativePath(string path) =>
        !string.IsNullOrEmpty(path) && !path.StartsWith('/') && !path.EndsWith('/') &&
        !path.Contains('\\') && !path.Contains('\0') &&
        path.Split('/').All(part => part.Length > 0 && part is not "." and not "..");

    private static bool IsSha256(string? value) =>
        value is { Length: 64 } && value.All(character =>
            character is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    private static IEnumerable<string> ParentPaths(string path)
    {
        for (var slash = path.IndexOf('/'); slash >= 0; slash = path.IndexOf('/', slash + 1))
        {
            yield return path[..slash];
        }
    }
}

internal sealed class PortableWindowsPaths
{
    private static readonly char[] Invalid = ['<', '>', ':', '"', '|', '?', '*'];
    private static readonly HashSet<string> Reserved = new(
        ["CON", "PRN", "AUX", "NUL", .. Enumerable.Range(1, 9).SelectMany(
            number => new[] { $"COM{number}", $"LPT{number}" })],
        StringComparer.OrdinalIgnoreCase);

    private readonly Dictionary<string, string> mappedPaths = new(StringComparer.Ordinal);
    private readonly Dictionary<string, HashSet<string>> usedNames = new(StringComparer.OrdinalIgnoreCase);

    public string Map(string path)
    {
        var wirePath = "";
        var localPath = "";
        foreach (var component in path.Split('/'))
        {
            wirePath = wirePath.Length == 0 ? component : $"{wirePath}/{component}";
            if (mappedPaths.TryGetValue(wirePath, out var mapped))
            {
                localPath = mapped;
                continue;
            }
            var used = usedNames.GetValueOrDefault(localPath);
            if (used is null)
            {
                used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                usedNames.Add(localPath, used);
            }
            var localName = Unique(MapComponent(component), used);
            localPath = localPath.Length == 0 ? localName : $"{localPath}/{localName}";
            mappedPaths.Add(wirePath, localPath);
        }
        return localPath;
    }

    private static string Unique(string name, HashSet<string> used)
    {
        if (used.Add(name)) return name;
        var extension = Path.GetExtension(name);
        var stem = name[..^extension.Length];
        for (var suffix = 2; ; suffix++)
        {
            var candidate = $"{stem} ({suffix}){extension}";
            if (used.Add(candidate)) return candidate;
        }
    }

    private static string MapComponent(string component)
    {
        var mapped = new string(component.Select(character =>
            character < 32 || Invalid.Contains(character) ? '_' : character).ToArray());
        while (mapped.EndsWith('.') || mapped.EndsWith(' ')) mapped = mapped[..^1] + '_';
        var stem = Path.GetFileNameWithoutExtension(mapped);
        return Reserved.Contains(stem) ? mapped + "_" : mapped;
    }
}
