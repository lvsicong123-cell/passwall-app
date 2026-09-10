namespace PasswallReceiver.Core;

internal interface IEmergencyInputReleaser
{
    void Release(HeldInputSnapshot snapshot);
}

internal static class WatchdogSession
{
    public static async Task RunAsync(
        TextReader reader,
        IEmergencyInputReleaser releaser,
        CancellationToken cancellationToken = default)
    {
        var state = new InputStateAccumulator();
        try
        {
            while (await reader.ReadLineAsync(cancellationToken) is { } record)
            {
                state.Apply(record);
            }
        }
        finally
        {
            releaser.Release(state.Snapshot());
        }
    }
}
