namespace PasswallReceiver.Core;

internal sealed record ClipboardImagePayload(byte[] Data);

internal sealed record ClipboardState(
    ulong Revision,
    ClipboardContent Content,
    ClipboardImagePayload? OutgoingImage = null);

internal interface IClipboardBridge
{
    Task EnableAsync(CancellationToken cancellationToken);
    Task DisableAsync();
    Task<ClipboardState?> ApplyAsync(
        ClipboardContent content,
        CancellationToken cancellationToken);
    Task<ClipboardState?> ApplyImageAsync(
        ClipboardContent content,
        byte[] imageData,
        CancellationToken cancellationToken);
    ClipboardState? StateAfter(ulong revision);
}
