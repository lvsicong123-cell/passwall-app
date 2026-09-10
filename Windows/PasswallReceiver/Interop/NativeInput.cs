using System.Runtime.InteropServices;

namespace PasswallReceiver.Interop;

internal static partial class NativeInput
{
    internal const uint InputMouse = 0;
    internal const uint InputKeyboard = 1;
    internal const uint MouseMove = 0x0001;
    internal const uint MouseLeftDown = 0x0002;
    internal const uint MouseLeftUp = 0x0004;
    internal const uint MouseRightDown = 0x0008;
    internal const uint MouseRightUp = 0x0010;
    internal const uint MouseMiddleDown = 0x0020;
    internal const uint MouseMiddleUp = 0x0040;
    internal const uint MouseXDown = 0x0080;
    internal const uint MouseXUp = 0x0100;
    internal const uint MouseWheel = 0x0800;
    internal const uint MouseHorizontalWheel = 0x01000;
    internal const uint MouseAbsolute = 0x8000;
    internal const uint MouseVirtualDesk = 0x4000;
    internal const uint KeyUp = 0x0002;
    internal const uint KeyExtended = 0x0001;
    internal const uint KeyScanCode = 0x0008;
    internal const int VirtualScreenLeft = 76;
    internal const int VirtualScreenTop = 77;
    internal const int VirtualScreenWidth = 78;
    internal const int VirtualScreenHeight = 79;

    [StructLayout(LayoutKind.Sequential)]
    internal struct Input
    {
        internal uint type;
        internal InputUnion data;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] internal MouseInput mouse;
        [FieldOffset(0)] internal KeyboardInput keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInput
    {
        internal int dx;
        internal int dy;
        internal uint mouseData;
        internal uint flags;
        internal uint time;
        internal UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput
    {
        internal ushort virtualKey;
        internal ushort scanCode;
        internal uint flags;
        internal uint time;
        internal UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Point
    {
        internal int x;
        internal int y;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial uint SendInput(uint count, Input[] inputs, int size);

    [LibraryImport("user32.dll")]
    internal static partial int GetSystemMetrics(int index);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out Point point);

    [LibraryImport("user32.dll")]
    internal static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll")]
    internal static partial uint GetWindowThreadProcessId(
        nint window,
        out uint processID);
}
