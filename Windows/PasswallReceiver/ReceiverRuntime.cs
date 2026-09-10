using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using PasswallReceiver.Core;

namespace PasswallReceiver;

internal static class ReceiverRuntime
{
    public const ushort DefaultPort = 24870;
    private const ushort PairingPort = 24871;

    public static async Task RunAsync(
        ushort port,
        string dataDirectory,
        Action<string> displayPairingCode,
        Action onStarted,
        IClipboardBridge clipboard,
        BulkTransferRegistry bulkTransfers,
        Action<bool> trustedInputConnectionChanged,
        CancellationToken cancellationToken)
    {
        var listener = new TcpListener(IPAddress.Loopback, port);
        using var watchdog = await WatchdogConnection.StartAsync(
            Path.Combine(dataDirectory, "watchdog.log"),
            cancellationToken);
        var injector = new InputInjector(watchdog.Reporter);
        using var inputSessionGate = new SemaphoreSlim(1, 1);
        using var bulkSessionGate = new SemaphoreSlim(1, 1);
        Console.WriteLine("Input watchdog connected");

        listener.Start();
        using var stopListener = cancellationToken.Register(listener.Stop);
        using var deviceIdentity = WindowsDeviceIdentity.LoadOrCreate();
        using var pairingListener = TlsPairingListener.Start(
            PairingPort,
            deviceIdentity.Certificate,
            displayCode: displayPairingCode,
            runTrustedSession: RunTrustedSessionAsync);
        using var bonjourPublisher = StartBonjour(
            PairingPort,
            deviceIdentity.FingerprintHex);
        Console.WriteLine($"PasswallReceiver listening on 127.0.0.1:{port}");
        Console.WriteLine($"TLS 1.3 pairing listener on 0.0.0.0:{PairingPort}");
        Console.WriteLine($"Device certificate SHA-256: {deviceIdentity.FingerprintHex}");
        Console.WriteLine($"Desktop session: {Process.GetCurrentProcess().SessionId}; interactive: {Environment.UserInteractive}");
        onStarted();

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    using var client = await listener.AcceptTcpClientAsync(cancellationToken);
                    client.NoDelay = true;
                    Console.WriteLine("Mac connected");
                    await RunInputSessionAsync(
                        client.GetStream(),
                        clipboardAllowed: false,
                        trustedSession: false,
                        cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (SocketException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine(ReceiverLog.Describe("Input session failed", error));
                }
                finally
                {
                    injector.ReleaseAll();
                    Console.WriteLine("Input released");
                }
            }
        }
        finally
        {
            injector.ReleaseAll();
            listener.Stop();
        }

        async Task RunInputSessionAsync(
            Stream stream,
            bool clipboardAllowed,
            bool trustedSession,
            CancellationToken sessionCancellationToken)
        {
            if (!await inputSessionGate.WaitAsync(0, sessionCancellationToken))
            {
                throw new InvalidOperationException(
                    "Another authenticated input session is active");
            }
            try
            {
                if (trustedSession) trustedInputConnectionChanged(true);
                await ReceiverSession.RunAsync(
                    stream,
                    injector,
                    clipboard,
                    clipboardAllowed,
                    bulkTransfers,
                    cancellationToken: sessionCancellationToken);
            }
            finally
            {
                if (trustedSession) trustedInputConnectionChanged(false);
                inputSessionGate.Release();
            }
        }

        async Task RunTrustedSessionAsync(
            TrustedSessionBinding binding,
            Stream stream,
            CancellationToken sessionCancellationToken)
        {
            if (binding.Role == TrustedSessionRole.Input)
            {
                await RunInputSessionAsync(
                    stream,
                    clipboardAllowed: true,
                    trustedSession: true,
                    sessionCancellationToken);
                return;
            }
            if (!await bulkSessionGate.WaitAsync(0, sessionCancellationToken))
            {
                throw new InvalidOperationException(
                    "Another authenticated bulk session is active");
            }
            try
            {
                using var claim = bulkTransfers.Claim(binding);
                using var transferCancellation =
                    CancellationTokenSource.CreateLinkedTokenSource(
                        sessionCancellationToken,
                        claim.CancellationToken);
                try
                {
                    if (claim.Direction == TransferDirection.Upload)
                    {
                        if (claim.Destination is { } destination)
                        {
                            var completed = await BulkSession.ReceiveAsync(
                                stream,
                                destination,
                                claim.TransferID,
                                claim.TotalBytes,
                                transferCancellation.Token,
                                onProgress: bytes => bulkTransfers.ReportFileProgress(
                                    claim.TransferID,
                                    bytes));
                            if (completed)
                            {
                                bulkTransfers.MarkFileVerifying(claim.TransferID);
                                await claim.CompleteAsync(transferCancellation.Token);
                            }
                            else if (claim.IsFileTransfer)
                            {
                                bulkTransfers.ResolveFileTransfer(
                                    claim.TransferID,
                                    FileTransferStatus.Canceled);
                            }
                        }
                        else
                        {
                            await BulkSession.DrainAsync(
                                stream,
                                claim.TransferID,
                                claim.TotalBytes,
                                transferCancellation.Token);
                        }
                    }
                    else
                    {
                        await BulkSession.SendAsync(
                            stream,
                            claim.TransferID,
                            claim.Source ?? throw new InvalidDataException(
                                "Download transfer has no approved source"),
                            claim.TotalBytes,
                            transferCancellation.Token,
                            onProgress: bytes => bulkTransfers.ReportFileProgress(
                                claim.TransferID,
                                bytes));
                        bulkTransfers.MarkFileVerifying(claim.TransferID);
                    }
                }
                catch (OperationCanceledException)
                    when (claim.CancellationToken.IsCancellationRequested)
                {
                }
                catch (Exception)
                {
                    bulkTransfers.FailFileTransfer(
                        claim.TransferID,
                        "file_transfer_failed",
                        notifyPeer: claim.IsFileTransfer);
                    throw;
                }
            }
            finally
            {
                bulkSessionGate.Release();
            }
        }
    }

    private static WindowsBonjourPublisher? StartBonjour(
        ushort port,
        string certificateFingerprint)
    {
        try
        {
            return WindowsBonjourPublisher.Start(port, certificateFingerprint);
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(ReceiverLog.Describe("Bonjour unavailable", error));
            return null;
        }
    }
}
