namespace PasswallReceiver.Core;

internal static class ReceiverLog
{
    public static string Describe(string context, Exception error) =>
        $"{context}: {error.GetType().Name}";
}
