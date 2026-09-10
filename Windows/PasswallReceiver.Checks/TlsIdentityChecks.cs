using System.Buffers.Binary;
using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using PasswallReceiver.Core;

internal static class TlsIdentityChecks
{
    public static async Task<int> RunAsync()
    {
        var checks = 0;
        using var certificate = WindowsDeviceIdentity.CreateCertificate(
            "passwall-receiver",
            DateTimeOffset.UtcNow);
        var fingerprint = WindowsDeviceIdentity.Fingerprint(certificate);

        Check(certificate.HasPrivateKey, "Device certificate has no private key");
        Check(fingerprint.Length == 64, "Device certificate fingerprint is not SHA-256");

        var displayedCode = "";
        var displayedCodeCount = 0;
        var trustedPeers = new Dictionary<string, byte[]>();
        var inputSink = new RecordingInputSink();
        var clipboard = new RecordingClipboardBridge();
        var bulkTransfers = new BulkTransferRegistry();
        using var listener = TlsPairingListener.Start(
            0,
            certificate,
            code =>
            {
                displayedCode = code;
                displayedCodeCount++;
            },
            (controllerID, secret) => trustedPeers[controllerID] = secret,
            controllerID => trustedPeers.GetValueOrDefault(controllerID),
            async (binding, stream, token) =>
            {
                if (binding.Role == TrustedSessionRole.Input)
                {
                    await ReceiverSession.RunAsync(
                        stream,
                        inputSink,
                        clipboard,
                        clipboardAllowed: true,
                        bulkTransfers,
                        cancellationToken: token);
                    return;
                }
                using var claim = bulkTransfers.Claim(binding);
                using var transferCancellation =
                    CancellationTokenSource.CreateLinkedTokenSource(
                        token,
                        claim.CancellationToken);
                await BulkSession.DrainAsync(
                    stream,
                    claim.TransferID,
                    claim.TotalBytes,
                    transferCancellation.Token);
            });
        using var client = new TcpClient();
        await client.ConnectAsync("127.0.0.1", listener.Port);
        using var tls = new SslStream(
            client.GetStream(),
            leaveInnerStreamOpen: false,
            (_, peer, _, _) =>
                peer is not null &&
                WindowsDeviceIdentity.Fingerprint(peer) == fingerprint);
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "passwall-receiver",
            EnabledSslProtocols = SslProtocols.Tls13,
            CertificateRevocationCheckMode =
                System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck
        });

        Check(tls.SslProtocol == SslProtocols.Tls13, "Pairing listener negotiated a non-TLS-1.3 protocol");
        var commitmentLine = await ReadLineAsync(tls);
        Check(
            commitmentLine.StartsWith("PASSWALL_PAIRING_V1 COMMIT "),
            "Pairing listener exposed an unexpected protocol");
        var commitment = commitmentLine["PASSWALL_PAIRING_V1 COMMIT ".Length..];
        const string clientNonce = "101112131415161718191a1b1c1d1e1f";
        await WriteLineAsync(tls, $"NONCE {clientNonce} PAIR");
        var revealLine = await ReadLineAsync(tls);
        Check(
            revealLine.StartsWith("REVEAL "),
            "Pairing listener did not reveal its committed nonce");

        var challenge = new PairingChallenge(
            fingerprint,
            Convert.FromHexString(revealLine["REVEAL ".Length..]));
        Check(
            challenge.CommitmentHex == commitment,
            "Pairing listener revealed a nonce that did not match its commitment");
        Check(
            challenge.Complete(clientNonce) == displayedCode,
            "Displayed pairing code did not match the TLS transcript");
        const string controllerID =
            "11111111-2222-3333-4444-555555555555";
        var secret = Enumerable.Range(0x20, 32)
            .Select(value => (byte)value)
            .ToArray();
        var confirmationProof = challenge.ConfirmationProof(
            displayedCode,
            clientNonce,
            controllerID,
            secret);
        await WriteLineAsync(
            tls,
            $"CONFIRM {commitment} {controllerID} " +
            $"{Convert.ToHexString(secret).ToLowerInvariant()} {confirmationProof}");
        Check(
            await ReadLineAsync(tls) == "PAIRED",
            "Pairing listener did not confirm the matching code");
        await WriteLineAsync(tls, "SESSION input");
        Check(
            await ReadLineAsync(tls) == "SESSION_OK",
            "Pairing listener did not bind the input role");
        Check(
            trustedPeers[controllerID].SequenceEqual(secret),
            "Pairing listener did not persist the trusted peer");
        tls.Dispose();
        client.Dispose();

        using var resumeClient = new TcpClient();
        await resumeClient.ConnectAsync("127.0.0.1", listener.Port);
        using var resumeTls = CreateTlsClient(
            resumeClient,
            fingerprint);
        await AuthenticateAsync(resumeTls);
        var resumeCommitmentLine = await ReadLineAsync(resumeTls);
        var resumeCommitment = resumeCommitmentLine[
            "PASSWALL_PAIRING_V1 COMMIT ".Length..];
        await WriteLineAsync(
            resumeTls,
            $"NONCE {clientNonce} RESUME {controllerID}");
        var resumeReveal = await ReadLineAsync(resumeTls);
        var resumeChallenge = new PairingChallenge(
            fingerprint,
            Convert.FromHexString(resumeReveal["REVEAL ".Length..]));
        Check(
            resumeChallenge.CommitmentHex == resumeCommitment,
            "Trusted resume reveal did not match its commitment");
        var resumeProof = resumeChallenge.ResumeProof(
            clientNonce,
            controllerID,
            secret);
        await WriteLineAsync(
            resumeTls,
            $"RESUME {controllerID} {resumeProof}");
        Check(
            await ReadLineAsync(resumeTls) == "PAIRED",
            "Stored trusted peer did not resume");
        await WriteLineAsync(resumeTls, "SESSION input");
        Check(
            await ReadLineAsync(resumeTls) == "SESSION_OK",
            "Trusted resume did not bind the input role");
        Check(
            displayedCodeCount == 1,
            "Trusted resume displayed a new pairing code");
        await WriteFrameAsync(resumeTls, new
        {
            version = ProtocolContract.Version,
            sessionID = "tls-input-session",
            sequence = 1,
            sentAtMicros = 100,
            payload = new { type = "heartbeat" }
        });
        using (var heartbeat = JsonDocument.Parse(
            await ReadFrameAsync(resumeTls)))
        {
            Check(
                heartbeat.RootElement
                    .GetProperty("payload")
                    .GetProperty("type")
                    .GetString() == "heartbeat",
                "Trusted TLS session did not carry input protocol frames");
        }

        var transferID = Guid.Parse("11111111-2222-4333-8444-555555555555");
        const int bulkChunkCount = 256;
        var bulkTotalBytes = checked(
            (ulong)ProtocolContract.MaximumBulkChunkSize * bulkChunkCount);
        await WriteFrameAsync(resumeTls, new
        {
            version = ProtocolContract.Version,
            sessionID = "tls-input-session",
            sequence = 2,
            sentAtMicros = 101,
            payload = new
            {
                type = "transfer_offer",
                data = new
                {
                    transferID = transferID.ToString("D"),
                    kind = "files",
                    direction = "upload",
                    totalBytes = bulkTotalBytes,
                    manifest = new
                    {
                        entries = new[]
                        {
                            new
                            {
                                path = "bulk.bin",
                                kind = "file",
                                byteCount = bulkTotalBytes,
                                sha256 = new string('a', 64)
                            }
                        }
                    }
                }
            }
        });
        await WriteFrameAsync(resumeTls, new
        {
            version = ProtocolContract.Version,
            sessionID = "tls-input-session",
            sequence = 3,
            sentAtMicros = 102,
            payload = new { type = "heartbeat" }
        });
        _ = await ReadFrameAsync(resumeTls);
        bulkTransfers.Accept(transferID);

        using var bulkClient = new TcpClient();
        await bulkClient.ConnectAsync("127.0.0.1", listener.Port);
        using var bulkTls = CreateTlsClient(bulkClient, fingerprint);
        await AuthenticateAsync(bulkTls);
        var bulkCommitmentLine = await ReadLineAsync(bulkTls);
        var bulkCommitment = bulkCommitmentLine[
            "PASSWALL_PAIRING_V1 COMMIT ".Length..];
        await WriteLineAsync(
            bulkTls,
            $"NONCE {clientNonce} RESUME {controllerID}");
        var bulkReveal = await ReadLineAsync(bulkTls);
        var bulkChallenge = new PairingChallenge(
            fingerprint,
            Convert.FromHexString(bulkReveal["REVEAL ".Length..]));
        Check(
            bulkChallenge.CommitmentHex == bulkCommitment,
            "Bulk trusted-resume reveal did not match its commitment");
        await WriteLineAsync(
            bulkTls,
            $"RESUME {controllerID} " +
            bulkChallenge.ResumeProof(clientNonce, controllerID, secret));
        Check(
            await ReadLineAsync(bulkTls) == "PAIRED",
            "Bulk connection did not complete trusted resume");
        await WriteLineAsync(
            bulkTls,
            $"SESSION bulk {transferID:D} upload");
        Check(
            await ReadLineAsync(bulkTls) == "SESSION_OK",
            "Bulk connection did not bind its transfer ID");
        var bulkPayload = new byte[ProtocolContract.MaximumBulkChunkSize];
        var bulkWrite = Task.Run(async () =>
        {
            for (var index = 0; index < bulkChunkCount; index++)
            {
                await BulkFrameCodec.WriteAsync(
                    bulkTls,
                    new BulkFrame(
                        BulkFrameKind.Chunk,
                        transferID,
                        checked((ulong)index + 1),
                        bulkPayload));
                await Task.Delay(1);
            }
            await BulkFrameCodec.WriteAsync(
                bulkTls,
                new BulkFrame(
                    BulkFrameKind.Complete,
                    transferID,
                    bulkChunkCount + 1UL,
                    []));
        });
        await Task.Delay(10);
        Check(!bulkWrite.IsCompleted, "Bulk transfer finished before input concurrency was exercised");
        var releasesBefore = inputSink.ReleaseCount;
        await WriteFrameAsync(resumeTls, new
        {
            version = ProtocolContract.Version,
            sessionID = "tls-input-session",
            sequence = 4,
            sentAtMicros = 103,
            payload = new { type = "release_all" }
        });
        var maximumInputLatency = TimeSpan.Zero;
        var allHeartbeatsReturned = true;
        var heartbeatCount = 0;
        do
        {
            var watch = Stopwatch.StartNew();
            await WriteFrameAsync(resumeTls, new
            {
                version = ProtocolContract.Version,
                sessionID = "tls-input-session",
                sequence = checked((ulong)heartbeatCount + 5),
                sentAtMicros = 104 + heartbeatCount,
                payload = new { type = "heartbeat" }
            });
            using var heartbeatDuringBulk = JsonDocument.Parse(
                await ReadFrameAsync(resumeTls).WaitAsync(TimeSpan.FromSeconds(1)));
            watch.Stop();
            maximumInputLatency = TimeSpan.FromTicks(Math.Max(
                maximumInputLatency.Ticks,
                watch.Elapsed.Ticks));
            allHeartbeatsReturned &= heartbeatDuringBulk.RootElement
                .GetProperty("payload")
                .GetProperty("type")
                .GetString() == "heartbeat";
            heartbeatCount++;
            if (!bulkWrite.IsCompleted) await Task.Delay(100);
        }
        while (heartbeatCount < 10 || !bulkWrite.IsCompleted);
        Check(allHeartbeatsReturned && maximumInputLatency < TimeSpan.FromSeconds(1),
            "Sustained bulk traffic blocked the input heartbeat");
        Check(
            inputSink.ReleaseCount == releasesBefore + 1,
            "Bulk traffic blocked release-all processing");
        await bulkWrite;
        resumeTls.Dispose();
        resumeClient.Dispose();

        using var cancelClient = new TcpClient();
        await cancelClient.ConnectAsync("127.0.0.1", listener.Port);
        using var cancelTls = new SslStream(
            cancelClient.GetStream(),
            leaveInnerStreamOpen: false,
            (_, peer, _, _) =>
                peer is not null &&
                WindowsDeviceIdentity.Fingerprint(peer) == fingerprint);
        await cancelTls.AuthenticateAsClientAsync(
            new SslClientAuthenticationOptions
            {
                TargetHost = "passwall-receiver",
                EnabledSslProtocols = SslProtocols.Tls13,
                CertificateRevocationCheckMode =
                    System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck
            });
        _ = await ReadLineAsync(cancelTls);
        await WriteLineAsync(cancelTls, $"NONCE {clientNonce} PAIR");
        _ = await ReadLineAsync(cancelTls);
        await WriteLineAsync(cancelTls, "CANCEL");
        Check(
            await ReadLineAsync(cancelTls) == "CANCELLED",
            "Pairing listener did not acknowledge cancellation");

        var vector = new PairingChallenge(
            string.Concat(Enumerable.Repeat("a1", 32)),
            Enumerable.Range(0, 16).Select(value => (byte)value).ToArray());
        Check(
            vector.CommitmentHex ==
                "be45cb2605bf36bebde684841a28f0fd43c69850a3dce5fedba69928ee3a8991",
            "Pairing commitment changed across platforms");
        Check(
            vector.Complete("101112131415161718191a1b1c1d1e1f") == "697655",
            "Pairing code changed across platforms");
        Check(
            vector.ConfirmationProof(
                "697655",
                clientNonce,
                "controller-test",
                secret) ==
                "3cab00bcfdcabb6fdd0e6ba1ff8c9858ddeeb6979ba5e9f3412fc55ce7b8b66c",
            "Pairing confirmation proof changed across platforms");
        Check(
            vector.ResumeProof(clientNonce, "controller-test", secret) ==
                "d384427038c29bac5785dda022472d859c0d9e871e3621576f10089598538a2f",
            "Trusted resume proof changed across platforms");
        var vectorProof = vector.ConfirmationProof(
            "697655",
            clientNonce,
            "controller-test",
            secret);
        vector.Confirm(
            vector.CommitmentHex,
            clientNonce,
            "controller-test",
            secret,
            vectorProof);
        try
        {
            vector.Confirm(
                vector.CommitmentHex,
                clientNonce,
                "controller-test",
                secret,
                vectorProof);
            throw new InvalidOperationException(
                "Pairing challenge accepted a replay");
        }
        catch (InvalidDataException)
        {
            checks++;
        }

        var credentialTestID = $"checks-{Guid.NewGuid():N}";
        try
        {
            WindowsTrustedPeerStore.Save(credentialTestID, secret);
            Check(
                WindowsTrustedPeerStore.Load(credentialTestID)!
                    .SequenceEqual(secret),
                "Windows Credential Manager did not round trip the peer secret");
        }
        finally
        {
            WindowsTrustedPeerStore.Delete(credentialTestID);
        }

        return checks;

        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
            checks++;
        }
    }

    private static async Task<string> ReadLineAsync(Stream stream)
    {
        var bytes = new List<byte>();
        var one = new byte[1];
        while (true)
        {
            await stream.ReadExactlyAsync(one);
            if (one[0] == (byte)'\n')
            {
                return Encoding.ASCII.GetString(bytes.ToArray());
            }
            bytes.Add(one[0]);
        }
    }

    private static async Task WriteLineAsync(Stream stream, string line)
    {
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"{line}\n"));
        await stream.FlushAsync();
    }

    private static async Task WriteFrameAsync(Stream stream, object message)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message);
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)payload.Length);
        await stream.WriteAsync(header);
        await stream.WriteAsync(payload);
        await stream.FlushAsync();
    }

    private static async Task<byte[]> ReadFrameAsync(Stream stream)
    {
        var header = new byte[4];
        await stream.ReadExactlyAsync(header);
        var payload = new byte[checked((int)
            BinaryPrimitives.ReadUInt32BigEndian(header))];
        await stream.ReadExactlyAsync(payload);
        return payload;
    }

    private static SslStream CreateTlsClient(
        TcpClient client,
        string fingerprint) =>
        new(
            client.GetStream(),
            leaveInnerStreamOpen: false,
            (_, peer, _, _) =>
                peer is not null &&
                WindowsDeviceIdentity.Fingerprint(peer) == fingerprint);

    private static Task AuthenticateAsync(SslStream tls) =>
        tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "passwall-receiver",
            EnabledSslProtocols = SslProtocols.Tls13,
            CertificateRevocationCheckMode =
                System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck
        });

    private sealed class RecordingInputSink : IInputSink
    {
        public int ReleaseCount { get; private set; }
        public double? Move(double dx, double dy, double gain) => null;
        public void EnterRemote(
            string remotePosition,
            double entryFraction,
            double activationDistance)
        {
        }
        public void Warp(double x, double y) { }
        public void Scroll(double horizontal, double vertical, string phase, bool navigationEnabled, double gain) { }
        public void Button(string button, bool isDown) { }
        public void Key(ushort usbHidUsage, bool isDown) { }
        public void ReleaseAll() => ReleaseCount++;
    }

    private sealed class RecordingClipboardBridge : IClipboardBridge
    {
        public Task EnableAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public Task DisableAsync() => Task.CompletedTask;
        public Task<ClipboardState?> ApplyAsync(
            ClipboardContent content,
            CancellationToken cancellationToken) => Task.FromResult<ClipboardState?>(null);
        public Task<ClipboardState?> ApplyImageAsync(
            ClipboardContent content,
            byte[] imageData,
            CancellationToken cancellationToken) => Task.FromResult<ClipboardState?>(null);
        public ClipboardState? StateAfter(ulong revision) => null;
    }
}
