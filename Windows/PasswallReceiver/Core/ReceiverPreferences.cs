using System.Text.Json;

namespace PasswallReceiver.Core;

internal enum ReceiverLanguage
{
    System,
    English,
    SimplifiedChinese
}

internal sealed record ReceiverPreferences(
    string ReceiveDirectory,
    ReceiverLanguage Language,
    IReadOnlyList<FileTransferHistoryEntry> History)
{
    public static ReceiverPreferences Default => new(
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads",
            "Passwall"),
        ReceiverLanguage.System,
        []);

    public static ReceiverPreferences Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return Default;
            var stored = JsonSerializer.Deserialize<StoredPreferences>(File.ReadAllText(path));
            if (stored is null) return Default;
            var language = Enum.IsDefined(stored.Language)
                ? stored.Language : ReceiverLanguage.System;
            var directory = string.IsNullOrWhiteSpace(stored.ReceiveDirectory)
                ? Default.ReceiveDirectory : Path.GetFullPath(stored.ReceiveDirectory);
            var history = (stored.History ?? [])
                .Where(entry => entry.TransferID != Guid.Empty && !string.IsNullOrWhiteSpace(entry.Name))
                .Take(FileTransferHistoryStore.MaximumCount)
                .Select(entry => entry with
                {
                    Status = entry.Status is FileTransferStatus.Queued or
                        FileTransferStatus.AwaitingApproval or FileTransferStatus.Transferring or
                        FileTransferStatus.Verifying ? FileTransferStatus.Failed : entry.Status
                })
                .ToArray();
            return new ReceiverPreferences(directory, language, history);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            JsonException or ArgumentException or NotSupportedException)
        {
            return Default;
        }
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var stored = new StoredPreferences(
            ReceiveDirectory,
            Language,
            History.Take(FileTransferHistoryStore.MaximumCount)
                .ToArray());
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(stored));
        File.Move(temporary, path, overwrite: true);
    }

    private sealed record StoredPreferences(
        string ReceiveDirectory,
        ReceiverLanguage Language,
        IReadOnlyList<FileTransferHistoryEntry>? History);
}
