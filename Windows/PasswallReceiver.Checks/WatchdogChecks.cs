using PasswallReceiver.Core;

internal static class WatchdogChecks
{
    public static async Task<int> RunAsync()
    {
        var checks = 0;

        using var reportBytes = new MemoryStream();
        using (var reporter = new InputStateReporter(reportBytes, leaveOpen: true))
        {
            reporter.Button("left", true);
            reporter.Key(0x1E, true);
            reporter.Button("left", false);
        }

        reportBytes.Position = 0;
        using var reader = new StreamReader(reportBytes, leaveOpen: true);
        var releaser = new RecordingEmergencyReleaser();
        await WatchdogSession.RunAsync(reader, releaser);

        Check(releaser.ReleaseCount == 1, "Watchdog did not release input at reporter EOF");
        Check(releaser.Snapshot.Buttons.Count == 0, "Watchdog retained a released mouse button");
        Check(releaser.Snapshot.ScanCodes.SetEquals([0x1E]), "Watchdog lost the held keyboard scan code");

        using var invalidReader = new StringReader("button right down\ninvalid record\n");
        var invalidReleaser = new RecordingEmergencyReleaser();
        await CheckThrowsAsync<InvalidDataException>(
            () => WatchdogSession.RunAsync(invalidReader, invalidReleaser),
            "Watchdog accepted an invalid state record");
        Check(invalidReleaser.ReleaseCount == 1, "Watchdog did not release tracked input after a protocol error");
        Check(invalidReleaser.Snapshot.Buttons.SetEquals(["right"]), "Watchdog lost state before a protocol error");

        return checks;

        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
            checks++;
        }

        async Task CheckThrowsAsync<TError>(Func<Task> action, string message) where TError : Exception
        {
            try
            {
                await action();
            }
            catch (TError)
            {
                checks++;
                return;
            }
            throw new InvalidOperationException(message);
        }
    }

    private sealed class RecordingEmergencyReleaser : IEmergencyInputReleaser
    {
        public int ReleaseCount { get; private set; }
        public HeldInputSnapshot Snapshot { get; private set; } = HeldInputSnapshot.Empty;

        public void Release(HeldInputSnapshot snapshot)
        {
            ReleaseCount++;
            Snapshot = snapshot;
        }
    }
}
