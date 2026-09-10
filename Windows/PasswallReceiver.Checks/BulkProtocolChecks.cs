using System.Buffers.Binary;
using PasswallReceiver.Core;

internal static class BulkProtocolChecks
{
    public static async Task<int> RunAsync()
    {
        var checks = 0;
        var transferID = Guid.Parse("11111111-2222-4333-8444-555555555555");
        var otherID = Guid.Parse("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");

        var input = TrustedSessionBinding.Parse("SESSION input");
        Check(input.Role == TrustedSessionRole.Input, "Input session role was not parsed");
        var bulk = TrustedSessionBinding.Parse(
            $"SESSION bulk {transferID:D} upload");
        Check(
            bulk == new TrustedSessionBinding(
                TrustedSessionRole.Bulk,
                transferID,
                TransferDirection.Upload),
            "Bulk session binding changed");
        CheckThrows<InvalidDataException>(
            () => TrustedSessionBinding.Parse("SESSION bulk"),
            "Incomplete bulk role was accepted");

        var payload = Enumerable.Repeat((byte)0xa5, ProtocolContract.MaximumBulkChunkSize)
            .ToArray();
        var chunk = new BulkFrame(BulkFrameKind.Chunk, transferID, 1, payload);
        using var stream = new MemoryStream();
        await BulkFrameCodec.WriteAsync(stream, chunk);
        Check(
            stream.Length == BulkFrameCodec.MaximumEncodedSize,
            "Maximum bulk frame used the wrong encoded size");
        stream.Position = 0;
        var decoded = await BulkFrameCodec.ReadAsync(stream);
        Check(
            decoded is not null && decoded.Kind == chunk.Kind &&
            decoded.TransferID == transferID && decoded.Sequence == 1 &&
            decoded.Payload.SequenceEqual(payload),
            "Bulk frame did not round trip");

        using var vectorStream = new MemoryStream();
        await BulkFrameCodec.WriteAsync(
            vectorStream,
            new BulkFrame(BulkFrameKind.Chunk, transferID, 1, [0xaa]));
        Check(
            Convert.ToHexString(vectorStream.ToArray()).ToLowerInvariant() ==
                "0111111111222243338444555555555555000000000000000100000001aa",
            "Bulk framing changed across platforms");

        var oversizedHeader = new byte[BulkFrameCodec.HeaderSize];
        oversizedHeader[0] = (byte)BulkFrameKind.Chunk;
        Convert.FromHexString(transferID.ToString("N")).CopyTo(oversizedHeader, 1);
        BinaryPrimitives.WriteUInt64BigEndian(oversizedHeader.AsSpan(17, 8), 1);
        BinaryPrimitives.WriteUInt32BigEndian(
            oversizedHeader.AsSpan(25, 4),
            (uint)(ProtocolContract.MaximumBulkChunkSize + 1));
        await CheckThrowsAsync<InvalidDataException>(
            () => BulkFrameCodec.ReadAsync(new MemoryStream(oversizedHeader)),
            "Oversized bulk length was accepted");

        var guard = new BulkFrameSequenceGuard(transferID);
        guard.Accept(chunk);
        CheckThrows<InvalidDataException>(
            () => guard.Accept(chunk),
            "Bulk sequence guard accepted a replay");
        CheckThrows<InvalidDataException>(
            () => guard.Accept(new BulkFrame(BulkFrameKind.Chunk, otherID, 2, [1])),
            "Bulk sequence guard accepted another transfer ID");
        guard.Accept(new BulkFrame(BulkFrameKind.Cancel, transferID, 2, []));
        CheckThrows<InvalidDataException>(
            () => guard.Accept(new BulkFrame(BulkFrameKind.Complete, transferID, 3, [])),
            "Bulk sequence guard accepted data after cancellation");

        var registry = new BulkTransferRegistry();
        registry.Register(transferID, TransferDirection.Upload, 3);
        CheckThrows<InvalidDataException>(
            () => registry.Claim(bulk),
            "Registry accepted an offer before receiver approval");
        registry.Accept(transferID);
        using (var claim = registry.Claim(bulk))
        {
            Check(
                claim.Direction == TransferDirection.Upload && claim.TotalBytes == 3,
                "Registry discarded accepted transfer metadata");
            CheckThrows<InvalidDataException>(
                () => registry.Claim(bulk),
                "Registry accepted a duplicate active bulk session");
            registry.Cancel(transferID);
            Check(
                claim.CancellationToken.IsCancellationRequested,
                "Input control cancellation did not stop the active bulk claim");
        }
        CheckThrows<InvalidDataException>(
            () => registry.Claim(bulk),
            "Registry accepted a replayed transfer ID");

        using var rejectedSource = new MemoryStream([1, 2, 3]);
        registry.Register(otherID, TransferDirection.Download, 3);
        registry.Accept(otherID, rejectedSource);
        CheckThrows<InvalidDataException>(
            () => registry.Claim(new TrustedSessionBinding(
                TrustedSessionRole.Bulk,
                otherID,
                TransferDirection.Upload)),
            "Registry accepted a direction mismatch");
        CheckThrows<InvalidDataException>(
            () => registry.Register(otherID, TransferDirection.Download, 3),
            "Registry allowed a mismatched transfer ID to be reused");
        Check(!rejectedSource.CanRead, "Rejected download source was not disposed");

        var downloadID = Guid.Parse("12345678-1234-4abc-8abc-123456789abc");
        using var downloadSource = new MemoryStream([4, 5, 6]);
        registry.Register(downloadID, TransferDirection.Download, 3);
        registry.Accept(downloadID, downloadSource);
        using (var claim = registry.Claim(new TrustedSessionBinding(
            TrustedSessionRole.Bulk,
            downloadID,
            TransferDirection.Download)))
        {
            using var output = new MemoryStream();
            await BulkSession.SendAsync(
                output,
                claim.TransferID,
                claim.Source!,
                claim.TotalBytes,
                CancellationToken.None);
            output.Position = 0;
            var sentChunk = await BulkFrameCodec.ReadAsync(output);
            var sentComplete = await BulkFrameCodec.ReadAsync(output);
            Check(
                sentChunk is { Kind: BulkFrameKind.Chunk } &&
                sentChunk.Payload.SequenceEqual(new byte[] { 4, 5, 6 }) &&
                sentComplete is { Kind: BulkFrameKind.Complete },
                "Download session did not send chunk and completion frames");
        }

        var largeBytes = new byte[ProtocolContract.MaximumBulkChunkSize * 2 + 1];
        using var largeSource = new MemoryStream(largeBytes);
        using var largeOutput = new MemoryStream();
        ulong sentProgress = 0;
        await BulkSession.SendAsync(
            largeOutput,
            transferID,
            largeSource,
            (ulong)largeBytes.Length,
            CancellationToken.None,
            onProgress: bytes => sentProgress = bytes);
        largeOutput.Position = 0;
        var firstLargeChunk = await BulkFrameCodec.ReadAsync(largeOutput);
        var secondLargeChunk = await BulkFrameCodec.ReadAsync(largeOutput);
        var finalLargeChunk = await BulkFrameCodec.ReadAsync(largeOutput);
        var largeComplete = await BulkFrameCodec.ReadAsync(largeOutput);
        Check(firstLargeChunk?.Payload.Length == ProtocolContract.MaximumBulkChunkSize &&
            secondLargeChunk?.Payload.Length == ProtocolContract.MaximumBulkChunkSize &&
            finalLargeChunk?.Payload.Length == 1 &&
            largeComplete?.Kind == BulkFrameKind.Complete &&
            sentProgress == (ulong)largeBytes.Length,
            "Large file stream was not bounded or did not report final progress");

        using var incomplete = new MemoryStream();
        await BulkFrameCodec.WriteAsync(
            incomplete,
            new BulkFrame(BulkFrameKind.Chunk, transferID, 1, [1]));
        incomplete.Position = 0;
        await CheckThrowsAsync<EndOfStreamException>(
            () => BulkSession.DrainAsync(
                incomplete,
                transferID,
                1,
                CancellationToken.None),
            "Bulk session accepted EOF before completion");

        using var wrongSize = new MemoryStream();
        await BulkFrameCodec.WriteAsync(
            wrongSize,
            new BulkFrame(BulkFrameKind.Chunk, transferID, 1, [1, 2]));
        await BulkFrameCodec.WriteAsync(
            wrongSize,
            new BulkFrame(BulkFrameKind.Complete, transferID, 2, []));
        wrongSize.Position = 0;
        await CheckThrowsAsync<InvalidDataException>(
            () => BulkSession.DrainAsync(
                wrongSize,
                transferID,
                1,
                CancellationToken.None),
            "Bulk session accepted more bytes than declared");

        await CheckThrowsAsync<TimeoutException>(
            () => BulkSession.DrainAsync(
                new BlockingReadStream(),
                transferID,
                1,
                CancellationToken.None,
                TimeSpan.FromMilliseconds(10)),
            "Silent bulk session held the active path indefinitely");
        await CheckThrowsAsync<TimeoutException>(
            () => BulkSession.SendAsync(
                new MemoryStream(),
                transferID,
                new BlockingReadStream(),
                1,
                CancellationToken.None,
                TimeSpan.FromMilliseconds(10)),
            "Blocking download source held the active path indefinitely");

        using var receivedFrames = new MemoryStream();
        await BulkFrameCodec.WriteAsync(
            receivedFrames,
            new BulkFrame(BulkFrameKind.Chunk, transferID, 1, [7, 8, 9]));
        await BulkFrameCodec.WriteAsync(
            receivedFrames,
            new BulkFrame(BulkFrameKind.Complete, transferID, 2, []));
        receivedFrames.Position = 0;
        using var receivedContent = new MemoryStream();
        ulong receivedProgress = 0;
        Check(
            await BulkSession.ReceiveAsync(
                receivedFrames,
                receivedContent,
                transferID,
                3,
                CancellationToken.None,
                onProgress: bytes => receivedProgress = bytes),
            "Completed upload was reported as canceled");
        Check(
            receivedContent.ToArray().SequenceEqual(new byte[] { 7, 8, 9 }),
            "Upload bytes were not retained for clipboard application");
        Check(receivedProgress == 3, "Bulk receive progress did not reach its declared size");

        var retainedUploadID = Guid.NewGuid();
        var retainedUploadCompleted = false;
        var retainedRegistry = new BulkTransferRegistry();
        using var retainedDestination = new MemoryStream(3);
        retainedRegistry.Register(retainedUploadID, TransferDirection.Upload, 3);
        retainedRegistry.AcceptUpload(
            retainedUploadID,
            3,
            retainedDestination,
            (destination, _) =>
            {
                retainedUploadCompleted = destination.Length == 3;
                return Task.CompletedTask;
            });
        using (var retainedClaim = retainedRegistry.Claim(new TrustedSessionBinding(
            TrustedSessionRole.Bulk,
            retainedUploadID,
            TransferDirection.Upload)))
        {
            using var retainedFrames = new MemoryStream();
            await BulkFrameCodec.WriteAsync(
                retainedFrames,
                new BulkFrame(BulkFrameKind.Chunk, retainedUploadID, 1, [1, 2, 3]));
            await BulkFrameCodec.WriteAsync(
                retainedFrames,
                new BulkFrame(BulkFrameKind.Complete, retainedUploadID, 2, []));
            retainedFrames.Position = 0;
            Check(
                await BulkSession.ReceiveAsync(
                    retainedFrames,
                    retainedClaim.Destination!,
                    retainedClaim.TransferID,
                    retainedClaim.TotalBytes,
                    retainedClaim.CancellationToken),
                "Accepted upload did not complete");
            await retainedClaim.CompleteAsync(CancellationToken.None);
        }
        Check(retainedUploadCompleted, "Accepted upload completion was not applied");

        var clock = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var expiringRegistry = new BulkTransferRegistry(clock);
        expiringRegistry.Register(transferID, TransferDirection.Upload, 1);
        expiringRegistry.Accept(transferID);
        clock.Advance(TimeSpan.FromMinutes(3));
        CheckThrows<InvalidDataException>(
            () => expiringRegistry.Claim(bulk),
            "Expired transfer approval remained claimable");
        clock.Advance(TimeSpan.FromMinutes(11));
        expiringRegistry.Register(transferID, TransferDirection.Upload, 1);
        Check(true, "Expired replay ID was not pruned");

        using var expiringManifestDocument = System.Text.Json.JsonDocument.Parse("""
            {"entries":[{"path":"offer.txt","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
            """);
        var expiringFileID = Guid.NewGuid();
        var expiringFileRegistry = new BulkTransferRegistry(clock);
        expiringFileRegistry.Register(
            expiringFileID,
            TransferDirection.Upload,
            0,
            FileTransferManifest.Parse(expiringManifestDocument.RootElement));
        clock.Advance(TimeSpan.FromMinutes(3));
        Check(expiringFileRegistry.DrainOutgoingControls() is
            [{ Type: "transfer_reject", TransferID: var rejectedID, Code: "approval_timeout" }] &&
            rejectedID == expiringFileID &&
            expiringFileRegistry.FileTransfers() is [{ Status: FileTransferStatus.Rejected }],
            "Expired file offer did not auto-reject with a visible terminal state");

        var boundedRegistry = new BulkTransferRegistry();
        var oldestID = Guid.NewGuid();
        boundedRegistry.Register(oldestID, TransferDirection.Upload, 0);
        boundedRegistry.Cancel(oldestID);
        for (var index = 0; index < 10_000; index++)
        {
            var id = Guid.NewGuid();
            boundedRegistry.Register(id, TransferDirection.Upload, 0);
            boundedRegistry.Cancel(id);
        }
        boundedRegistry.Register(oldestID, TransferDirection.Upload, 0);
        Check(true, "Replay registry did not evict its oldest bounded entry");

        var activeClock = new ManualTimeProvider(DateTimeOffset.UtcNow);
        var activeRegistry = new BulkTransferRegistry(activeClock);
        activeRegistry.Register(transferID, TransferDirection.Upload, 1);
        activeRegistry.Accept(transferID);
        using (activeRegistry.Claim(bulk))
        {
            activeClock.Advance(TimeSpan.FromMinutes(11));
            CheckThrows<InvalidDataException>(
                () => activeRegistry.Register(transferID, TransferDirection.Upload, 1),
                "Active transfer ID was accepted after replay expiry");
        }
        activeClock.Advance(TimeSpan.FromMinutes(11));
        activeRegistry.Register(transferID, TransferDirection.Upload, 1);
        Check(true, "Released transfer replay timestamp was not refreshed");

        return checks;

        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
            checks++;
        }

        void CheckThrows<TError>(Action action, string message) where TError : Exception
        {
            try
            {
                action();
            }
            catch (TError)
            {
                checks++;
                return;
            }
            throw new InvalidOperationException(message);
        }

        async Task CheckThrowsAsync<TError>(Func<Task> action, string message)
            where TError : Exception
        {
            try
            {
                await action();
            }
            catch (TError)
            {
                checks++;
                return;
            }
            throw new InvalidOperationException(message);
        }
    }

    private sealed class BlockingReadStream : MemoryStream
    {
        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return 0;
        }
    }

    private sealed class ManualTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;

        public void Advance(TimeSpan duration) => now += duration;
    }
}
