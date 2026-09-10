using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace PasswallReceiver.Core;

internal sealed class TlsPairingListener : IDisposable
{
    private readonly TcpListener listener;
    private readonly X509Certificate2 certificate;
    private readonly Action<string> displayCode;
    private readonly Action<string, byte[]> saveTrustedPeer;
    private readonly Func<string, byte[]?> loadTrustedPeer;
    private readonly Func<TrustedSessionBinding, Stream, CancellationToken, Task>?
        runTrustedSession;
    private readonly CancellationTokenSource stop = new();
    private readonly SemaphoreSlim connectionSlots = new(4, 4);
    private readonly object sessionsSync = new();
    private readonly List<Task> sessions = [];
    private readonly Task runTask;

    private TlsPairingListener(
        int port,
        X509Certificate2 certificate,
        Action<string> displayCode,
        Action<string, byte[]> saveTrustedPeer,
        Func<string, byte[]?> loadTrustedPeer,
        Func<TrustedSessionBinding, Stream, CancellationToken, Task>? runTrustedSession)
    {
        this.certificate = certificate;
        this.displayCode = displayCode;
        this.saveTrustedPeer = saveTrustedPeer;
        this.loadTrustedPeer = loadTrustedPeer;
        this.runTrustedSession = runTrustedSession;
        listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        runTask = RunAsync();
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    public static TlsPairingListener Start(
        int port,
        X509Certificate2 certificate,
        Action<string> displayCode,
        Action<string, byte[]>? saveTrustedPeer = null,
        Func<string, byte[]?>? loadTrustedPeer = null,
        Func<TrustedSessionBinding, Stream, CancellationToken, Task>?
            runTrustedSession = null) =>
        new(
            port,
            certificate,
            displayCode,
            saveTrustedPeer ?? WindowsTrustedPeerStore.Save,
            loadTrustedPeer ?? WindowsTrustedPeerStore.Load,
            runTrustedSession);

    private async Task RunAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            await connectionSlots.WaitAsync(stop.Token);
            try
            {
                var client = await listener.AcceptTcpClientAsync(stop.Token);
                var session = HandleClientWithLoggingAsync(client, stop.Token);
                lock (sessionsSync)
                {
                    sessions.RemoveAll(task => task.IsCompleted);
                    sessions.Add(session);
                }
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested)
            {
                connectionSlots.Release();
                return;
            }
            catch (SocketException) when (stop.IsCancellationRequested)
            {
                connectionSlots.Release();
                return;
            }
            catch (Exception error)
            {
                connectionSlots.Release();
                Console.Error.WriteLine(ReceiverLog.Describe("TLS peer session failed", error));
            }
        }
    }

    private async Task HandleClientWithLoggingAsync(
        TcpClient client,
        CancellationToken cancellationToken)
    {
        using (client)
        {
            try
            {
                await HandleClientAsync(client, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(ReceiverLog.Describe("TLS peer session failed", error));
            }
            finally
            {
                connectionSlots.Release();
            }
        }
    }

    private async Task HandleClientAsync(
        TcpClient client,
        CancellationToken cancellationToken)
    {
        client.NoDelay = true;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(120));
        using var tls = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
        await tls.AuthenticateAsServerAsync(
            new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                ClientCertificateRequired = false,
                EnabledSslProtocols = SslProtocols.Tls13,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            },
            deadline.Token);

        var challenge = new PairingChallenge(
            WindowsDeviceIdentity.Fingerprint(certificate));
        await WriteLineAsync(
            tls,
            $"PASSWALL_PAIRING_V1 COMMIT {challenge.CommitmentHex}",
            deadline.Token);
        var nonceLine = await ReadLineAsync(tls, deadline.Token);
        var nonceParts = nonceLine.Split(
            ' ',
            StringSplitOptions.RemoveEmptyEntries);
        if (nonceParts.Length < 2 || nonceParts[0] != "NONCE")
        {
            throw new InvalidDataException("Expected client pairing nonce");
        }
        var clientNonce = nonceParts[1];
        var resumeControllerID =
            nonceParts.Length == 4 && nonceParts[2] == "RESUME"
                ? nonceParts[3]
                : null;
        if (resumeControllerID is not null &&
            !Guid.TryParseExact(resumeControllerID, "D", out _))
        {
            throw new InvalidDataException("Trusted peer ID is invalid");
        }
        if (resumeControllerID is null &&
            !(nonceParts.Length == 2 ||
              (nonceParts.Length == 3 && nonceParts[2] == "PAIR")))
        {
            throw new InvalidDataException("Invalid pairing mode");
        }
        var code = challenge.Complete(clientNonce);
        if (resumeControllerID is null)
        {
            displayCode(code);
        }
        await WriteLineAsync(
            tls,
            $"REVEAL {challenge.ServerNonceHex}",
            deadline.Token);

        var confirmation = await ReadLineAsync(tls, deadline.Token);
        if (confirmation == "CANCEL")
        {
            await WriteLineAsync(tls, "CANCELLED", deadline.Token);
            return;
        }
        var parts = confirmation.Split(
            ' ',
            StringSplitOptions.RemoveEmptyEntries);
        var resumed = resumeControllerID is not null;
        if (resumed)
        {
            if (parts.Length != 3 ||
                parts[0] != "RESUME" ||
                parts[1] != resumeControllerID)
            {
                throw new InvalidDataException("Expected trusted-peer proof");
            }
            var secret = loadTrustedPeer(resumeControllerID)
                ?? throw new InvalidDataException("Trusted peer was not found");
            challenge.Resume(
                clientNonce,
                resumeControllerID,
                secret,
                parts[2]);
            Console.WriteLine(
                $"TLS 1.3 trusted peer resumed from {client.Client.RemoteEndPoint}");
        }
        else
        {
            if (parts.Length != 5 || parts[0] != "CONFIRM")
            {
                throw new InvalidDataException("Expected pairing confirmation");
            }
            if (!Guid.TryParseExact(parts[2], "D", out _))
            {
                throw new InvalidDataException("Trusted peer ID is invalid");
            }
            var trustedSecret = Convert.FromHexString(parts[3]);
            challenge.Confirm(
                parts[1],
                clientNonce,
                parts[2],
                trustedSecret,
                parts[4]);
            saveTrustedPeer(parts[2], trustedSecret);
            Console.WriteLine(
                $"TLS 1.3 pairing confirmed from {client.Client.RemoteEndPoint}");
        }
        await WriteLineAsync(tls, "PAIRED", deadline.Token);
        var binding = TrustedSessionBinding.Parse(
            await ReadLineAsync(tls, deadline.Token));
        if (binding.Role == TrustedSessionRole.Bulk && !resumed)
        {
            throw new InvalidDataException("Bulk sessions require trusted resume");
        }
        await WriteLineAsync(tls, "SESSION_OK", deadline.Token);
        if (runTrustedSession is not null)
        {
            deadline.CancelAfter(Timeout.InfiniteTimeSpan);
            await runTrustedSession(binding, tls, cancellationToken);
        }
    }

    private static async Task<string> ReadLineAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var bytes = new List<byte>(128);
        var one = new byte[1];
        while (bytes.Count <= 256)
        {
            if (await stream.ReadAsync(one, cancellationToken) == 0)
            {
                throw new EndOfStreamException(
                    "Pairing connection ended before a complete line");
            }
            if (one[0] == (byte)'\n')
            {
                return Encoding.ASCII.GetString(bytes.ToArray());
            }
            if (one[0] == (byte)'\r' || one[0] > 0x7f)
            {
                throw new InvalidDataException(
                    "Pairing protocol requires printable ASCII lines");
            }
            bytes.Add(one[0]);
        }
        throw new InvalidDataException("Pairing protocol line is too long");
    }

    private static async Task WriteLineAsync(
        Stream stream,
        string line,
        CancellationToken cancellationToken)
    {
        await stream.WriteAsync(
            Encoding.ASCII.GetBytes($"{line}\n"),
            cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        try
        {
            runTask.GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
        }
        Task[] activeSessions;
        lock (sessionsSync)
        {
            activeSessions = sessions.ToArray();
        }
        try
        {
            Task.WhenAll(activeSessions).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
        }
        connectionSlots.Dispose();
        stop.Dispose();
    }
}
