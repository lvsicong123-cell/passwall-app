using System.Diagnostics;
using System.Runtime.InteropServices;
using PasswallReceiver.Core;

namespace PasswallReceiver;

internal sealed class ReceiverApplicationContext : ApplicationContext
{
    private readonly ushort port;
    private readonly string dataDirectory;
    private readonly string logPath;
    private readonly Control dispatcher = new();
    private readonly ClipboardBridge clipboardBridge;
    private readonly BulkTransferRegistry bulkTransfers = new();
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem openItem;
    private readonly ToolStripMenuItem restartItem;
    private readonly ToolStripMenuItem logItem;
    private readonly ToolStripMenuItem exitItem;
    private readonly NotifyIcon notifyIcon;
    private readonly Icon trayIcon;
    private readonly System.Windows.Forms.Timer offerTimer = new() { Interval = 500 };
    private readonly HashSet<Guid> announcedOffers = [];
    private CancellationTokenSource? receiverStop;
    private Task? receiverTask;
    private ReceiverWindow? receiverWindow;
    private ReceiverStrings strings;
    private string status = "Starting";
    private bool trustedInputConnected;
    private bool exiting;

    public ReceiverApplicationContext(
        ushort port,
        string dataDirectory,
        string logPath,
        bool openAtLaunch = false)
    {
        this.port = port;
        this.dataDirectory = dataDirectory;
        this.logPath = logPath;
        var preferences = ReceiverPreferences.Load(
            Path.Combine(dataDirectory, "receiver-settings.json"));
        strings = new ReceiverStrings(preferences.Language);
        try
        {
            FileTransferStaging.RemoveAbandonedPartials(preferences.ReceiveDirectory);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine(ReceiverLog.Describe("File transfer cleanup failed", error));
        }
        dispatcher.CreateControl();
        clipboardBridge = new ClipboardBridge(dispatcher);

        var menu = new ContextMenuStrip();
        menu.Opened += (_, _) => SetForegroundWindow(menu.Handle);
        menu.Closed += (_, _) => PostMessage(menu.Handle, 0, IntPtr.Zero, IntPtr.Zero);
        statusItem = new ToolStripMenuItem(strings["Starting"]);
        statusItem.Enabled = false;
        menu.Items.Add(statusItem);
        openItem = new ToolStripMenuItem(strings["Open Transfer Center"]);
        openItem.Click += (_, _) => OpenTransferCenter();
        menu.Items.Add(openItem);
        restartItem = new ToolStripMenuItem(strings["Restart Receiver"]);
        restartItem.Click += async (_, _) => await RestartReceiverAsync();
        menu.Items.Add(restartItem);
        logItem = new ToolStripMenuItem(strings["Open Logs"]);
        logItem.Click += (_, _) => OpenLogs();
        menu.Items.Add(logItem);
        menu.Items.Add(new ToolStripSeparator());
        exitItem = new ToolStripMenuItem(strings["Exit Passwall Receiver"]);
        exitItem.Click += async (_, _) => await ExitAsync();
        menu.Items.Add(exitItem);

        trayIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)
            ?? (Icon)SystemIcons.Application.Clone();
        notifyIcon = new NotifyIcon
        {
            ContextMenuStrip = menu,
            Icon = trayIcon,
            Text = $"Passwall Receiver - {strings["Starting"]}",
            Visible = true
        };
        notifyIcon.DoubleClick += (_, _) => OpenTransferCenter();
        notifyIcon.BalloonTipClicked += (_, _) => OpenTransferCenter();
        offerTimer.Tick += (_, _) => CheckIncomingOffers();
        offerTimer.Start();

        StartReceiver();
        if (openAtLaunch) OpenTransferCenter();
    }

    private void StartReceiver()
    {
        if (receiverTask is { IsCompleted: false }) return;

        SetStatus("Starting");
        receiverStop = new CancellationTokenSource();
        var task = Task.Run(() => ReceiverRuntime.RunAsync(
            port,
            dataDirectory,
            code => Post(() => ShowPairingCode(code)),
            () => Post(() => SetStatus("Running")),
            clipboardBridge,
            bulkTransfers,
            connected => Post(() => SetTrustedInputConnected(connected)),
            receiverStop.Token));
        receiverTask = task;
        _ = ObserveReceiverAsync(task);
    }

    private async Task ObserveReceiverAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
            Post(() =>
            {
                if (ReferenceEquals(receiverTask, task) && !exiting)
                {
                    SetStatus("Stopped");
                }
            });
        }
        catch (OperationCanceledException)
        {
            Post(() =>
            {
                if (ReferenceEquals(receiverTask, task) && !exiting)
                {
                    SetStatus("Stopped");
                }
            });
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(ReceiverLog.Describe("Receiver stopped", error));
            Post(() =>
            {
                if (!ReferenceEquals(receiverTask, task) || exiting) return;
                SetStatus("Failed");
                MessageBox.Show(
                    $"Passwall Receiver stopped.\n\n{error.Message}\n\nSee the log for details.",
                    "Passwall Receiver",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            });
        }
    }

    private async Task StopReceiverAsync()
    {
        var task = receiverTask;
        var stop = receiverStop;
        if (task is null || stop is null) return;

        stop.Cancel();
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(ReceiverLog.Describe("Receiver shutdown failed", error));
        }
        finally
        {
            if (ReferenceEquals(receiverTask, task))
            {
                receiverTask = null;
                receiverStop = null;
            }
            stop.Dispose();
        }
    }

    private async Task RestartReceiverAsync()
    {
        restartItem.Enabled = false;
        SetStatus("Restarting");
        await StopReceiverAsync();
        StartReceiver();
        restartItem.Enabled = true;
    }

    private async Task ExitAsync()
    {
        if (exiting) return;
        if ((receiverWindow?.HasActiveTransfers == true || bulkTransfers.HasActiveFileTransfers()) &&
            MessageBox.Show(
            receiverWindow,
            strings["Active transfers will be canceled. Exit Passwall Receiver?"],
            strings["Passwall Receiver"],
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            return;
        }
        exiting = true;
        restartItem.Enabled = false;
        SetStatus("Stopping");
        await StopReceiverAsync();
        receiverWindow?.CloseForExit();
        notifyIcon.Visible = false;
        ExitThread();
    }

    private void ShowPairingCode(string code)
    {
        notifyIcon.BalloonTipTitle = "Passwall Pairing Code";
        notifyIcon.BalloonTipText = code;
        notifyIcon.ShowBalloonTip(120_000);
        MessageBox.Show(
            $"Enter this code on your Mac:\n\n{code}",
            "Passwall Pairing",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void OpenLogs()
    {
        if (!File.Exists(logPath)) File.WriteAllText(logPath, string.Empty);
        Process.Start(new ProcessStartInfo
        {
            FileName = "notepad.exe",
            Arguments = $"\"{logPath}\"",
            UseShellExecute = true
        });
    }

    private void OpenTransferCenter()
    {
        if (receiverWindow is null || receiverWindow.IsDisposed)
        {
            receiverWindow = new ReceiverWindow(
                bulkTransfers,
                dataDirectory,
                logPath,
                () => trustedInputConnected);
            receiverWindow.LanguageChanged += ApplyLanguage;
        }
        receiverWindow.ShowTransferCenter();
    }

    private void CheckIncomingOffers()
    {
        if (exiting) return;
        var offer = bulkTransfers.PendingFileUploads()
            .FirstOrDefault(item => !announcedOffers.Contains(item.TransferID));
        if (offer is null) return;
        announcedOffers.Add(offer.TransferID);
        notifyIcon.BalloonTipTitle = strings["Incoming files"];
        notifyIcon.BalloonTipText = strings["Files are waiting for your approval."];
        notifyIcon.ShowBalloonTip(10_000);
        OpenTransferCenter();
        receiverWindow!.PromptIncoming(offer);
    }

    private void SetTrustedInputConnected(bool connected)
    {
        trustedInputConnected = connected;
        receiverWindow?.RefreshConnection();
    }

    private void ApplyLanguage()
    {
        var language = receiverWindow?.Language ?? ReceiverLanguage.System;
        strings = new ReceiverStrings(language);
        openItem.Text = strings["Open Transfer Center"];
        restartItem.Text = strings["Restart Receiver"];
        logItem.Text = strings["Open Logs"];
        exitItem.Text = strings["Exit Passwall Receiver"];
        SetStatus(status);
    }

    private void SetStatus(string status)
    {
        this.status = status;
        statusItem.Text = strings[status];
        notifyIcon.Text = $"Passwall Receiver - {strings[status]}";
    }

    private void Post(Action action)
    {
        if (dispatcher.IsDisposed || dispatcher.Disposing) return;
        try
        {
            dispatcher.BeginInvoke(action);
        }
        catch (InvalidOperationException) when (dispatcher.IsDisposed || dispatcher.Disposing)
        {
        }
    }

    protected override void ExitThreadCore()
    {
        receiverStop?.Cancel();
        offerTimer.Stop();
        offerTimer.Dispose();
        receiverWindow?.CloseForExit();
        receiverWindow?.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        trayIcon.Dispose();
        clipboardBridge.Dispose();
        dispatcher.Dispose();
        base.ExitThreadCore();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(
        IntPtr windowHandle,
        uint message,
        IntPtr wordParameter,
        IntPtr longParameter);
}
