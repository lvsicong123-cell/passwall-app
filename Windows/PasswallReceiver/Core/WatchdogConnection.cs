using System.Diagnostics;
using System.IO.Pipes;

namespace PasswallReceiver.Core;

internal sealed class WatchdogConnection : IDisposable
{
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(3);

    private readonly NamedPipeClientStream pipe;
    private readonly Process process;

    private WatchdogConnection(
        NamedPipeClientStream pipe,
        Process process,
        InputStateReporter reporter)
    {
        this.pipe = pipe;
        this.process = process;
        Reporter = reporter;
    }

    public IInputStateReporter Reporter { get; }

    public static async Task<WatchdogConnection> StartAsync(
        string? logPath = null,
        CancellationToken cancellationToken = default)
    {
        var executable = Path.Combine(
            AppContext.BaseDirectory,
            "PasswallReceiver.Watchdog.exe");
        if (!File.Exists(executable))
        {
            throw new FileNotFoundException("Passwall watchdog executable is missing", executable);
        }

        var pipeName = $"PasswallReceiver-{Environment.ProcessId}-{Guid.NewGuid():N}";
        var startInfo = new ProcessStartInfo(executable)
        {
            CreateNoWindow = true,
            UseShellExecute = false
        };
        startInfo.ArgumentList.Add("--pipe");
        startInfo.ArgumentList.Add(pipeName);
        startInfo.ArgumentList.Add("--log");
        startInfo.ArgumentList.Add(logPath ?? Path.Combine(
            AppContext.BaseDirectory,
            "watchdog-release.log"));

        var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Passwall watchdog did not start");
        var pipe = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.Out,
            PipeOptions.Asynchronous);

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(StartupTimeout);
        try
        {
            await pipe.ConnectAsync(deadline.Token);
            var reporter = new InputStateReporter(pipe, leaveOpen: true);
            return new WatchdogConnection(pipe, process, reporter);
        }
        catch
        {
            pipe.Dispose();
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            process.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        (Reporter as IDisposable)?.Dispose();
        pipe.Dispose();
        process.WaitForExit(milliseconds: 2_000);
        process.Dispose();
    }
}
