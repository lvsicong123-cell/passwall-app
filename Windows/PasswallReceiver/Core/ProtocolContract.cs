namespace PasswallReceiver.Core;

internal static class ProtocolContract
{
    public const int Version = 3;
    public const int MaximumPayloadSize = 1_048_576;
    public const int MaximumClipboardRawBytes = 524_288;
    public const int MaximumBulkChunkSize = 256 * 1024;
    public const ulong MaximumImageBytes = 32UL * 1024 * 1024;
    public const ulong MaximumBatchBytes = 100UL * 1024 * 1024 * 1024;
    public const int MaximumBatchEntries = 10_000;
}
