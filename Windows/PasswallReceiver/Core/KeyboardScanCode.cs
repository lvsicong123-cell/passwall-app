namespace PasswallReceiver.Core;

internal static class KeyboardScanCode
{
    private const ushort ExtendedMask = 0x8000;

    public static ushort Encode(ushort scanCode, bool isExtended) =>
        isExtended ? (ushort)(scanCode | ExtendedMask) : scanCode;

    public static ushort Value(ushort encoded) => (ushort)(encoded & ~ExtendedMask);

    public static bool IsExtended(ushort encoded) => (encoded & ExtendedMask) != 0;
}
