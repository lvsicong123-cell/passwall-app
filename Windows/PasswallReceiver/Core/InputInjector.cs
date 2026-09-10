using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using PasswallReceiver.Interop;
using static PasswallReceiver.Interop.NativeInput;

namespace PasswallReceiver.Core;

internal sealed class InputInjector : IInputSink
{
    private readonly IInputStateReporter? stateReporter;
    private readonly Func<Input, bool> sendInput;
    private readonly HashSet<string> downButtons = [];
    private readonly HashSet<ushort> downKeys = [];
    private readonly RemoteReturnDetector returnDetector = new();
    private readonly HorizontalNavigationTracker navigationTracker = new();
    private static readonly HashSet<string> NavigationProcesses = new(
        ["chrome", "msedge", "firefox", "brave", "opera"],
        StringComparer.OrdinalIgnoreCase);
    private double verticalResidual;
    private double horizontalResidual;
    private double pointerXResidual;
    private double pointerYResidual;
    private nint cachedForegroundWindow;
    private bool cachedForegroundSupportsNavigation;
    private bool inputBlocked;

    public InputInjector(
        IInputStateReporter? stateReporter = null,
        Func<Input, bool>? sendInput = null)
    {
        this.stateReporter = stateReporter;
        this.sendInput = sendInput ?? SendNativeInput;
    }

    public double? Move(double dx, double dy, double gain)
    {
        if (!EnsureInputAvailable()) return null;
        if (!SendMouse(
            Quantize(Scale(dx, gain), ref pointerXResidual),
            Quantize(Scale(dy, gain), ref pointerYResidual),
            0,
            MouseMove))
        {
            return null;
        }

        if (!returnDetector.IsActive)
        {
            return null;
        }
        if (!GetCursorPos(out var cursor))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetCursorPos failed");
        }
        return returnDetector.Update(cursor.x, cursor.y, DesktopBounds(), dx, dy);
    }

    public void EnterRemote(string remotePosition, double entryFraction, double activationDistance)
    {
        ReleaseAll();
        var bounds = DesktopBounds();
        var returnEdge = RemoteReturnDetector.ReturnEdgeFor(remotePosition);
        var fraction = Math.Clamp(entryFraction, 0, 1);
        const int inset = 2;
        var x = returnEdge switch
        {
            DesktopEdge.Left => bounds.Left + inset,
            DesktopEdge.Right => bounds.Right - inset,
            _ => bounds.Left + (int)Math.Round((bounds.Width - 1) * fraction)
        };
        var y = returnEdge switch
        {
            DesktopEdge.Top => bounds.Top + inset,
            DesktopEdge.Bottom => bounds.Bottom - inset,
            _ => bounds.Top + (int)Math.Round((bounds.Height - 1) * fraction)
        };

        Warp(x, y);
        returnDetector.Activate(returnEdge, activationDistance);
    }

    public void Warp(double x, double y)
    {
        if (!EnsureInputAvailable()) return;
        var left = GetSystemMetrics(VirtualScreenLeft);
        var top = GetSystemMetrics(VirtualScreenTop);
        var width = Math.Max(GetSystemMetrics(VirtualScreenWidth), 1);
        var height = Math.Max(GetSystemMetrics(VirtualScreenHeight), 1);
        var normalizedX = NormalizeAbsolute(x, left, width);
        var normalizedY = NormalizeAbsolute(y, top, height);
        SendMouse(normalizedX, normalizedY, 0, MouseMove | MouseAbsolute | MouseVirtualDesk);
    }

    public void Scroll(
        double horizontal,
        double vertical,
        string phase,
        bool navigationEnabled,
        double gain)
    {
        if (!EnsureInputAvailable()) return;
        if (navigationEnabled && ForegroundSupportsNavigation())
        {
            var navigation = navigationTracker.Update(horizontal, vertical, phase);
            if (navigation.Action is { } action)
            {
                var button = action == HorizontalNavigationAction.Back
                    ? "back"
                    : "forward";
                Button(button, true);
                Button(button, false);
            }
            if (navigation.Consumed) return;
        }
        else
        {
            navigationTracker.Reset();
        }

        var verticalUnits = Quantize(Scale(vertical, gain) * 1.5, ref verticalResidual);
        var horizontalUnits = Quantize(Scale(horizontal, gain) * 1.5, ref horizontalResidual);
        if (verticalUnits != 0)
        {
            SendMouse(0, 0, unchecked((uint)verticalUnits), MouseWheel);
        }
        if (horizontalUnits != 0)
        {
            SendMouse(0, 0, unchecked((uint)horizontalUnits), MouseHorizontalWheel);
        }
    }

    public void Button(string button, bool isDown)
    {
        if (!EnsureInputAvailable()) return;
        var wasDown = downButtons.Contains(button);
        if (isDown && !wasDown) stateReporter?.Button(button, true);
        if (!SendButton(button, isDown))
        {
            if (isDown && !wasDown) stateReporter?.Button(button, false);
            return;
        }
        if (!isDown && wasDown) stateReporter?.Button(button, false);
        if (isDown) downButtons.Add(button); else downButtons.Remove(button);
    }

    public void Key(ushort usbHidUsage, bool isDown)
    {
        if (!EnsureInputAvailable()) return;
        var encodedScanCode = KeyboardScanCode.Encode(
            HidUsageToScanCode(usbHidUsage),
            IsExtendedHidUsage(usbHidUsage));
        var wasDown = downKeys.Contains(encodedScanCode);
        if (isDown && !wasDown) stateReporter?.Key(encodedScanCode, true);
        if (!SendKeyboard(encodedScanCode, isDown))
        {
            if (isDown && !wasDown) stateReporter?.Key(encodedScanCode, false);
            return;
        }
        if (!isDown && wasDown) stateReporter?.Key(encodedScanCode, false);
        if (isDown) downKeys.Add(encodedScanCode); else downKeys.Remove(encodedScanCode);
    }

    private void ReleaseHeldInputs()
    {
        foreach (var button in downButtons.ToArray())
        {
            if (!SendButton(button, false)) continue;
            stateReporter?.Button(button, false);
            downButtons.Remove(button);
        }
        foreach (var scanCode in downKeys.ToArray())
        {
            if (!SendKeyboard(scanCode, false)) continue;
            stateReporter?.Key(scanCode, false);
            downKeys.Remove(scanCode);
        }
        if (downButtons.Count > 0 || downKeys.Count > 0) MarkInputBlocked();
    }

    public void ReleaseAll()
    {
        ReleaseHeldInputs();
        verticalResidual = 0;
        horizontalResidual = 0;
        pointerXResidual = 0;
        pointerYResidual = 0;
        returnDetector.Reset();
        navigationTracker.Reset();
    }

    internal static int Quantize(double units, ref double residual)
    {
        if (units != 0 && residual != 0 && Math.Sign(units) != Math.Sign(residual))
        {
            residual = 0;
        }
        residual += units;
        var whole = (int)Math.Truncate(residual);
        residual -= whole;
        return whole;
    }

    internal static double Scale(double value, double gain)
    {
        var safeGain = double.IsFinite(gain) ? Math.Clamp(gain, 0.5, 2) : 1;
        var scaled = value * safeGain;
        return double.IsFinite(scaled) ? scaled : 0;
    }

    private static int NormalizeAbsolute(double value, int origin, int length)
    {
        var normalized = Math.Round((value - origin) * 65_535 / Math.Max(length - 1, 1));
        return (int)Math.Clamp(normalized, 0, 65_535);
    }

    private static VirtualDesktopBounds DesktopBounds() => new(
        GetSystemMetrics(VirtualScreenLeft),
        GetSystemMetrics(VirtualScreenTop),
        Math.Max(GetSystemMetrics(VirtualScreenWidth), 1),
        Math.Max(GetSystemMetrics(VirtualScreenHeight), 1));

    private bool ForegroundSupportsNavigation()
    {
        var window = GetForegroundWindow();
        if (window == 0) return false;
        if (window == cachedForegroundWindow) return cachedForegroundSupportsNavigation;

        cachedForegroundWindow = window;
        _ = GetWindowThreadProcessId(window, out var processID);
        try
        {
            using var process = Process.GetProcessById(checked((int)processID));
            cachedForegroundSupportsNavigation =
                NavigationProcesses.Contains(process.ProcessName);
        }
        catch (ArgumentException)
        {
            cachedForegroundSupportsNavigation = false;
        }
        return cachedForegroundSupportsNavigation;
    }

    internal static ushort HidUsageToScanCode(ushort usage) => usage switch
    {
        0x04 => 0x1E, // A
        0x05 => 0x30, // B
        0x06 => 0x2E, // C
        0x07 => 0x20, // D
        0x08 => 0x12, // E
        0x09 => 0x21, // F
        0x0A => 0x22, // G
        0x0B => 0x23, // H
        0x0C => 0x17, // I
        0x0D => 0x24, // J
        0x0E => 0x25, // K
        0x0F => 0x26, // L
        0x10 => 0x32, // M
        0x11 => 0x31, // N
        0x12 => 0x18, // O
        0x13 => 0x19, // P
        0x14 => 0x10, // Q
        0x15 => 0x13, // R
        0x16 => 0x1F, // S
        0x17 => 0x14, // T
        0x18 => 0x16, // U
        0x19 => 0x2F, // V
        0x1A => 0x11, // W
        0x1B => 0x2D, // X
        0x1C => 0x15, // Y
        0x1D => 0x2C, // Z
        0x1E => 0x02, // 1
        0x1F => 0x03, // 2
        0x20 => 0x04, // 3
        0x21 => 0x05, // 4
        0x22 => 0x06, // 5
        0x23 => 0x07, // 6
        0x24 => 0x08, // 7
        0x25 => 0x09, // 8
        0x26 => 0x0A, // 9
        0x27 => 0x0B, // 0
        0x28 => 0x1C, // Enter
        0x29 => 0x01, // Escape
        0x2A => 0x0E, // Backspace
        0x2B => 0x0F, // Tab
        0x2C => 0x39, // Space
        0x2D => 0x0C, // Minus
        0x2E => 0x0D, // Equals
        0x2F => 0x1A, // Left bracket
        0x30 => 0x1B, // Right bracket
        0x31 => 0x2B, // Backslash
        0x33 => 0x27, // Semicolon
        0x34 => 0x28, // Apostrophe
        0x35 => 0x29, // Grave
        0x36 => 0x33, // Comma
        0x37 => 0x34, // Period
        0x38 => 0x35, // Slash
        0x39 => 0x3A, // Caps Lock
        >= 0x3A and <= 0x43 => (ushort)(0x3B + usage - 0x3A), // F1-F10
        0x44 => 0x57, // F11
        0x45 => 0x58, // F12
        0x47 => 0x46, // Scroll Lock
        0x49 => 0x52, // Insert
        0x4A => 0x47, // Home
        0x4B => 0x49, // Page Up
        0x4C => 0x53, // Delete
        0x4D => 0x4F, // End
        0x4E => 0x51, // Page Down
        0x4F => 0x4D, // Right
        0x50 => 0x4B, // Left
        0x51 => 0x50, // Down
        0x52 => 0x48, // Up
        0x53 => 0x45, // Num Lock
        0x54 => 0x35, // Keypad divide
        0x55 => 0x37, // Keypad multiply
        0x56 => 0x4A, // Keypad minus
        0x57 => 0x4E, // Keypad plus
        0x58 => 0x1C, // Keypad enter
        0x59 => 0x4F, // Keypad 1
        0x5A => 0x50, // Keypad 2
        0x5B => 0x51, // Keypad 3
        0x5C => 0x4B, // Keypad 4
        0x5D => 0x4C, // Keypad 5
        0x5E => 0x4D, // Keypad 6
        0x5F => 0x47, // Keypad 7
        0x60 => 0x48, // Keypad 8
        0x61 => 0x49, // Keypad 9
        0x62 => 0x52, // Keypad 0
        0x63 => 0x53, // Keypad decimal
        0x65 => 0x5D, // Application
        0xE0 => 0x1D, // Left Control
        0xE1 => 0x2A, // Left Shift
        0xE2 => 0x38, // Left Alt
        0xE3 => 0x5B, // Left Windows
        0xE4 => 0x1D, // Right Control
        0xE5 => 0x36, // Right Shift
        0xE6 => 0x38, // Right Alt
        0xE7 => 0x5C, // Right Windows
        _ => throw new NotSupportedException($"Unsupported HID usage: 0x{usage:X}")
    };

    internal static bool IsExtendedHidUsage(ushort usage) =>
        usage is 0x49 or 0x4A or 0x4B or 0x4C or 0x4D or 0x4E
            or 0x4F or 0x50 or 0x51 or 0x52 or 0x54 or 0x58 or 0x65
            or 0xE3 or 0xE4 or 0xE6 or 0xE7;

    private bool SendMouse(int dx, int dy, uint data, uint flags) => Send(
        new Input
        {
            type = InputMouse,
            data = new InputUnion
            {
                mouse = new MouseInput { dx = dx, dy = dy, mouseData = data, flags = flags }
            }
        });

    private bool SendButton(string button, bool isDown)
    {
        var flag = (button, isDown) switch
        {
            ("left", true) => MouseLeftDown,
            ("left", false) => MouseLeftUp,
            ("right", true) => MouseRightDown,
            ("right", false) => MouseRightUp,
            ("middle", true) => MouseMiddleDown,
            ("middle", false) => MouseMiddleUp,
            ("back", true) => MouseXDown,
            ("back", false) => MouseXUp,
            ("forward", true) => MouseXDown,
            ("forward", false) => MouseXUp,
            _ => throw new NotSupportedException($"Unsupported button: {button}")
        };
        var data = button switch
        {
            "back" => 1u,
            "forward" => 2u,
            _ => 0u
        };
        return SendMouse(0, 0, data, flag);
    }

    private bool SendKeyboard(ushort encodedScanCode, bool isDown) => Send(
        new Input
        {
            type = InputKeyboard,
            data = new InputUnion
            {
                keyboard = new KeyboardInput
                {
                    scanCode = KeyboardScanCode.Value(encodedScanCode),
                    flags = KeyScanCode
                        | (KeyboardScanCode.IsExtended(encodedScanCode) ? KeyExtended : 0)
                        | (isDown ? 0 : KeyUp)
                }
            }
        });

    private bool Send(Input input)
    {
        if (sendInput(input))
        {
            MarkInputAvailable();
            return true;
        }

        MarkInputBlocked();
        return false;
    }

    private bool EnsureInputAvailable()
    {
        if (!inputBlocked) return true;
        ReleaseHeldInputs();
        return downButtons.Count == 0 && downKeys.Count == 0;
    }

    private void MarkInputBlocked()
    {
        if (!inputBlocked)
        {
            Console.WriteLine("Input injection blocked; keeping the trusted session connected");
        }
        inputBlocked = true;
    }

    private void MarkInputAvailable()
    {
        if (inputBlocked) Console.WriteLine("Input injection resumed");
        inputBlocked = false;
    }

    private static bool SendNativeInput(Input input) =>
        SendInput(1, [input], Marshal.SizeOf<Input>()) == 1;
}
