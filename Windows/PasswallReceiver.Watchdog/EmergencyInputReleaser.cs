using System.ComponentModel;
using System.Runtime.InteropServices;
using PasswallReceiver.Core;
using static PasswallReceiver.Interop.NativeInput;

namespace PasswallReceiver.Watchdog;

internal sealed class EmergencyInputReleaser : IEmergencyInputReleaser
{
    public int ReleasedButtonCount { get; private set; }
    public int ReleasedKeyCount { get; private set; }

    public void Release(HeldInputSnapshot snapshot)
    {
        Exception? firstError = null;
        foreach (var button in snapshot.Buttons)
        {
            try
            {
                var (data, flag) = button switch
                {
                    "left" => (0u, MouseLeftUp),
                    "right" => (0u, MouseRightUp),
                    "middle" => (0u, MouseMiddleUp),
                    "back" => (1u, MouseXUp),
                    "forward" => (2u, MouseXUp),
                    _ => throw new InvalidDataException($"Unsupported watchdog button: {button}")
                };
                Send(new Input
                {
                    type = InputMouse,
                    data = new InputUnion
                    {
                        mouse = new MouseInput { mouseData = data, flags = flag }
                    }
                });
                ReleasedButtonCount++;
            }
            catch (Exception error)
            {
                firstError ??= error;
            }
        }

        foreach (var scanCode in snapshot.ScanCodes)
        {
            try
            {
                Send(new Input
                {
                    type = InputKeyboard,
                    data = new InputUnion
                    {
                        keyboard = new KeyboardInput
                        {
                            scanCode = KeyboardScanCode.Value(scanCode),
                            flags = KeyScanCode
                                | (KeyboardScanCode.IsExtended(scanCode) ? KeyExtended : 0)
                                | KeyUp
                        }
                    }
                });
                ReleasedKeyCount++;
            }
            catch (Exception error)
            {
                firstError ??= error;
            }
        }

        if (firstError is not null) throw firstError;
    }

    private static void Send(Input input)
    {
        if (SendInput(1, [input], Marshal.SizeOf<Input>()) != 1)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Emergency input release failed");
        }
    }
}
