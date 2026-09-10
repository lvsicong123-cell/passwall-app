using System.Globalization;
using System.Text;

namespace PasswallReceiver.Core;

internal interface IInputStateReporter
{
    void Button(string button, bool isDown);
    void Key(ushort scanCode, bool isDown);
}

internal sealed class InputStateReporter : IInputStateReporter, IDisposable
{
    private readonly object gate = new();
    private readonly StreamWriter writer;

    public InputStateReporter(Stream stream, bool leaveOpen = false)
    {
        writer = new StreamWriter(
            stream,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            bufferSize: 1_024,
            leaveOpen: leaveOpen)
        {
            AutoFlush = true
        };
    }

    public void Button(string button, bool isDown) =>
        Write($"button {button} {(isDown ? "down" : "up")}");

    public void Key(ushort scanCode, bool isDown) =>
        Write($"key {scanCode:X4} {(isDown ? "down" : "up")}");

    public void Dispose() => writer.Dispose();

    private void Write(string record)
    {
        lock (gate)
        {
            writer.WriteLine(record);
        }
    }
}

internal sealed class InputStateAccumulator
{
    private static readonly HashSet<string> SupportedButtons =
        ["left", "right", "middle", "back", "forward"];

    private readonly HashSet<string> buttons = [];
    private readonly HashSet<ushort> scanCodes = [];

    public void Apply(string record)
    {
        var fields = record.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 3 || (fields[2] != "down" && fields[2] != "up"))
        {
            throw new InvalidDataException($"Invalid watchdog input record: {record}");
        }

        var isDown = fields[2] == "down";
        switch (fields[0])
        {
            case "button" when SupportedButtons.Contains(fields[1]):
                Update(buttons, fields[1], isDown);
                break;
            case "key" when ushort.TryParse(
                fields[1],
                NumberStyles.HexNumber,
                CultureInfo.InvariantCulture,
                out var scanCode):
                Update(scanCodes, scanCode, isDown);
                break;
            default:
                throw new InvalidDataException($"Invalid watchdog input record: {record}");
        }
    }

    public HeldInputSnapshot Snapshot() => new(
        new HashSet<string>(buttons),
        new HashSet<ushort>(scanCodes));

    private static void Update<T>(HashSet<T> values, T value, bool isDown)
    {
        if (isDown) values.Add(value); else values.Remove(value);
    }
}

internal readonly record struct HeldInputSnapshot(
    IReadOnlySet<string> Buttons,
    IReadOnlySet<ushort> ScanCodes)
{
    public static HeldInputSnapshot Empty { get; } = new(
        new HashSet<string>(),
        new HashSet<ushort>());
}
