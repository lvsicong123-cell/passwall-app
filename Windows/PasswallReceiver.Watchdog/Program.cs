using System.IO.Pipes;
using System.Text;
using PasswallReceiver.Core;
using PasswallReceiver.Watchdog;

var pipeIndex = Array.IndexOf(args, "--pipe");
var logIndex = Array.IndexOf(args, "--log");
if (pipeIndex < 0 || pipeIndex + 1 >= args.Length ||
    logIndex < 0 || logIndex + 1 >= args.Length)
{
    Console.Error.WriteLine("usage: PasswallReceiver.Watchdog --pipe <name> --log <path>");
    return 2;
}

var logPath = args[logIndex + 1];

void Log(string message) => File.AppendAllText(
    logPath,
    $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}");

try
{
    using var pipe = new NamedPipeServerStream(
        args[pipeIndex + 1],
        PipeDirection.In,
        maxNumberOfServerInstances: 1,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous);
    await pipe.WaitForConnectionAsync();
    using var reader = new StreamReader(
        pipe,
        new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        detectEncodingFromByteOrderMarks: false);
    var releaser = new EmergencyInputReleaser();
    await WatchdogSession.RunAsync(reader, releaser);
    Log($"Released {releaser.ReleasedButtonCount} button(s) and {releaser.ReleasedKeyCount} key(s)");
    return 0;
}
catch (Exception error)
{
    Log(ReceiverLog.Describe("FAILED", error));
    Console.Error.WriteLine(ReceiverLog.Describe("Watchdog", error));
    return 1;
}
