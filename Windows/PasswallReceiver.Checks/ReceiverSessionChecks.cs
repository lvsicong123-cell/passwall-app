using System.Buffers.Binary;
using System.Text.Json;
using PasswallReceiver.Core;

internal static class ReceiverSessionChecks
{
    public static async Task<int> RunAsync()
    {
        var checks = 0;

        var heartbeatStream = new ScriptedDuplexStream(Frame(Message(sequence: 1, type: "heartbeat")));
        var heartbeatSink = new RecordingInputSink();
        var heartbeatClipboard = new RecordingClipboardBridge();
        await ReceiverSession.RunAsync(
            heartbeatStream,
            heartbeatSink,
            heartbeatClipboard,
            clipboardAllowed: false,
            inactivityTimeout: TimeSpan.FromSeconds(1));
        using (var response = JsonDocument.Parse(Unframe(heartbeatStream.Written)))
        {
            Check(response.RootElement.GetProperty("sessionID").GetString() == "session-a", "Heartbeat reply changed the session ID");
            Check(response.RootElement.GetProperty("version").GetInt32() == 3, "Heartbeat reply used the wrong protocol version");
            Check(response.RootElement.GetProperty("sequence").GetUInt64() == 1, "Heartbeat reply used the wrong sequence");
            Check(response.RootElement.GetProperty("payload").GetProperty("type").GetString() == "heartbeat", "Receiver did not echo a heartbeat");
        }
        Check(heartbeatSink.ReleaseCount == 1, "Clean connection close did not release input");
        Check(heartbeatClipboard.DisableCount == 1, "Clean connection close did not disable clipboard sharing");

        var orderedEvents = new List<string>();
        var orderedInput = Frame(Message(1, "clipboard_control", new { enabled = true }))
            .Concat(Frame(Message(2, "clipboard_set", new
            {
                content = new
                {
                    plainText = "copy then paste",
                    html = "<b>copy then paste</b>"
                }
            })))
            .Concat(Frame(Message(3, "key", new { usbHIDUsage = 0x19, isDown = true })))
            .Concat(Frame(Message(4, "heartbeat")))
            .ToArray();
        var orderedStream = new ScriptedDuplexStream(orderedInput);
        var orderedClipboard = new RecordingClipboardBridge(orderedEvents);
        await ReceiverSession.RunAsync(
            orderedStream,
            new RecordingInputSink(orderedEvents),
            orderedClipboard,
            clipboardAllowed: true,
            inactivityTimeout: TimeSpan.FromSeconds(1));

        Check(
            orderedEvents.IndexOf("clipboard:copy then paste") <
                orderedEvents.IndexOf("key:25:true"),
            "Paste input was dispatched before the awaited clipboard write");
        var orderedResponses = UnframeAll(orderedStream.Written);
        using (var clipboardState = JsonDocument.Parse(orderedResponses[0]))
        using (var heartbeat = JsonDocument.Parse(orderedResponses[1]))
        {
            Check(
                clipboardState.RootElement.GetProperty("payload").GetProperty("type").GetString() == "clipboard_state",
                "Receiver did not send clipboard state before heartbeat");
            Check(
                clipboardState.RootElement.GetProperty("payload").GetProperty("data").GetProperty("revision").GetUInt64() == 1,
                "Receiver sent the wrong clipboard revision");
            Check(
                heartbeat.RootElement.GetProperty("payload").GetProperty("type").GetString() == "heartbeat",
                "Receiver did not send heartbeat after clipboard state");
        }

        var imageBytes = System.Text.Encoding.UTF8.GetBytes("png-image");
        var image = ClipboardImageMetadata.Create(
            Guid.Parse("12345678-1234-4abc-8abc-123456789abc"),
            "image/png",
            imageBytes);
        var imageInput = Frame(Message(1, "clipboard_control", new { enabled = true }))
            .Concat(Frame(Message(2, "transfer_offer", new
            {
                transferID = image.TransferID.ToString("D"),
                kind = "image",
                direction = "upload",
                totalBytes = image.ByteCount
            })))
            .Concat(Frame(Message(3, "clipboard_set", new
            {
                content = ClipboardContent.Create(image: image).ToWireValue()
            })))
            .ToArray();
        var imageStream = new ScriptedDuplexStream(imageInput);
        var imageClipboard = new RecordingClipboardBridge();
        await ReceiverSession.RunAsync(
            imageStream,
            new RecordingInputSink(),
            imageClipboard,
            clipboardAllowed: true,
            bulkTransfers: new BulkTransferRegistry(),
            inactivityTimeout: TimeSpan.FromSeconds(1));
        using (var imageAccept = JsonDocument.Parse(Unframe(imageStream.Written)))
        {
            Check(
                imageAccept.RootElement.GetProperty("payload").GetProperty("type").GetString() ==
                    "transfer_accept",
                "Receiver did not accept a bounded image upload after metadata registration");
        }
        Check(imageClipboard.ImageApplyCount == 0, "Image clipboard changed before bulk completion");

        var canceledImageID = Guid.NewGuid();
        var canceledImageRegistry = new BulkTransferRegistry();
        canceledImageRegistry.Register(canceledImageID, TransferDirection.Upload, 1);
        canceledImageRegistry.Accept(canceledImageID);
        var canceledImageStream = new ScriptedDuplexStream(
            Frame(Message(1, "transfer_cancel", new
            {
                transferID = canceledImageID.ToString("D")
            })),
            blockAtEnd: true);
        using (var canceledImageSession = new CancellationTokenSource())
        {
            var canceledImageTask = ReceiverSession.RunAsync(
                canceledImageStream,
                new RecordingInputSink(),
                new RecordingClipboardBridge(),
                clipboardAllowed: true,
                bulkTransfers: canceledImageRegistry,
                inactivityTimeout: TimeSpan.FromSeconds(1),
                cancellationToken: canceledImageSession.Token);
            await canceledImageStream.InputConsumed.WaitAsync(TimeSpan.FromSeconds(1));
            var imageWasCanceled = false;
            try
            {
                using var claim = canceledImageRegistry.Claim(new TrustedSessionBinding(
                    TrustedSessionRole.Bulk,
                    canceledImageID,
                    TransferDirection.Upload));
            }
            catch (InvalidDataException)
            {
                imageWasCanceled = true;
            }
            canceledImageSession.Cancel();
            try
            {
                await canceledImageTask;
            }
            catch (OperationCanceledException)
            {
            }
            Check(imageWasCanceled, "Peer transfer_cancel did not cancel an image transfer");
        }

        var rejectedFileID = Guid.NewGuid();
        using var rejectedManifestDocument = JsonDocument.Parse("""
            {"entries":[{"path":"offer.txt","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
            """);
        var rejectedRegistry = new BulkTransferRegistry();
        rejectedRegistry.Register(
            rejectedFileID,
            TransferDirection.Download,
            0,
            FileTransferManifest.Parse(rejectedManifestDocument.RootElement));
        rejectedRegistry.Accept(rejectedFileID, new MemoryStream());
        await ReceiverSession.RunAsync(
            new ScriptedDuplexStream(Frame(Message(1, "transfer_reject", new
            {
                transferID = rejectedFileID.ToString("D"),
                code = "user_rejected"
            }))),
            new RecordingInputSink(),
            new RecordingClipboardBridge(),
            clipboardAllowed: true,
            bulkTransfers: rejectedRegistry,
            inactivityTimeout: TimeSpan.FromSeconds(1));
        Check(rejectedRegistry.FileTransfers() is
            [{ Status: FileTransferStatus.Rejected, ErrorCode: "user_rejected" }],
            "Peer file rejection was not retained as the terminal result");

        var disconnectedRoot = Path.Combine(
            Path.GetTempPath(), $"PasswallDisconnectedTransfer-{Guid.NewGuid():D}");
        try
        {
            Directory.CreateDirectory(disconnectedRoot);
            var disconnectedID = Guid.NewGuid();
            var disconnectedRegistry = new BulkTransferRegistry();
            disconnectedRegistry.Register(
                disconnectedID,
                TransferDirection.Upload,
                0,
                FileTransferManifest.Parse(rejectedManifestDocument.RootElement));
            disconnectedRegistry.AcceptFileUpload(disconnectedID, disconnectedRoot);
            var partial = Path.Combine(disconnectedRoot, $".passwall-{disconnectedID:D}.partial");
            await ReceiverSession.RunAsync(
                new ScriptedDuplexStream(Frame(Message(1, "heartbeat"))),
                new RecordingInputSink(),
                new RecordingClipboardBridge(),
                clipboardAllowed: true,
                bulkTransfers: disconnectedRegistry,
                inactivityTimeout: TimeSpan.FromSeconds(1));
            Check(!Directory.Exists(partial) && disconnectedRegistry.FileTransfers() is
                [{ Status: FileTransferStatus.Failed, ErrorCode: "disconnected" }],
                "Input disconnect retained file staging or a nonterminal result");
        }
        finally
        {
            if (Directory.Exists(disconnectedRoot))
            {
                Directory.Delete(disconnectedRoot, recursive: true);
            }
        }

        var outgoingClipboard = new RecordingClipboardBridge();
        outgoingClipboard.SetState(new ClipboardState(
            1,
            ClipboardContent.Create(image: image),
            new ClipboardImagePayload(imageBytes)));
        var outgoingStream = new ScriptedDuplexStream(
            Frame(Message(1, "clipboard_control", new { enabled = true }))
                .Concat(Frame(Message(2, "heartbeat")))
                .ToArray());
        await ReceiverSession.RunAsync(
            outgoingStream,
            new RecordingInputSink(),
            outgoingClipboard,
            clipboardAllowed: true,
            bulkTransfers: new BulkTransferRegistry(),
            inactivityTimeout: TimeSpan.FromSeconds(1));
        var outgoingResponses = UnframeAll(outgoingStream.Written);
        using (var offerResponse = JsonDocument.Parse(outgoingResponses[0]))
        using (var stateResponse = JsonDocument.Parse(outgoingResponses[1]))
        {
            Check(
                offerResponse.RootElement.GetProperty("payload").GetProperty("type").GetString() ==
                    "transfer_offer",
                "Windows image state did not register a download offer first");
            Check(
                stateResponse.RootElement.GetProperty("payload").GetProperty("type").GetString() ==
                    "clipboard_state",
                "Windows image metadata did not follow its download offer");
        }

        var disabledClipboard = new RecordingClipboardBridge();
        await CheckThrowsAsync<InvalidDataException>(
            () => ReceiverSession.RunAsync(
                new ScriptedDuplexStream(Frame(Message(1, "clipboard_set", new
                {
                    content = new { plainText = "not enabled" }
                }))),
                new RecordingInputSink(),
                disabledClipboard,
                clipboardAllowed: true,
                inactivityTimeout: TimeSpan.FromSeconds(1)),
            "Receiver accepted clipboard content before opt-in");
        Check(disabledClipboard.DisableCount == 1, "Rejected clipboard content did not clean up sharing");

        await CheckThrowsAsync<InvalidDataException>(
            () => ReceiverSession.RunAsync(
                new ScriptedDuplexStream(Frame(Message(1, "clipboard_state", new
                {
                    revision = 1,
                    content = new { plainText = "wrong direction" }
                }))),
                new RecordingInputSink(),
                new RecordingClipboardBridge(),
                clipboardAllowed: true,
                inactivityTimeout: TimeSpan.FromSeconds(1)),
            "Receiver accepted controller-originated clipboard state");

        await CheckThrowsAsync<InvalidDataException>(
            () => ReceiverSession.RunAsync(
                new ScriptedDuplexStream(Frame(Message(1, "transfer_offer", new
                {
                    transferID = "11111111-2222-4333-8444-555555555555",
                    kind = "image",
                    direction = "upload",
                    totalBytes = ProtocolContract.MaximumImageBytes + 1
                }))),
                new RecordingInputSink(),
                new RecordingClipboardBridge(),
                clipboardAllowed: true,
                bulkTransfers: new BulkTransferRegistry(),
                inactivityTimeout: TimeSpan.FromSeconds(1)),
            "Receiver accepted an oversized image offer");

        await CheckThrowsAsync<InvalidDataException>(
            () => ReceiverSession.RunAsync(
                new ScriptedDuplexStream(Frame(Message(1, "clipboard_control", new
                {
                    enabled = true
                }))),
                new RecordingInputSink(),
                new RecordingClipboardBridge(),
                clipboardAllowed: false,
                inactivityTimeout: TimeSpan.FromSeconds(1)),
            "Unauthenticated loopback session enabled clipboard sharing");

        var duplicate = Frame(Message(sequence: 1, type: "heartbeat"))
            .Concat(Frame(Message(sequence: 1, type: "heartbeat")))
            .ToArray();
        var duplicateSink = new RecordingInputSink();
        var duplicateClipboard = new RecordingClipboardBridge();
        await CheckThrowsAsync<InvalidDataException>(
            () => ReceiverSession.RunAsync(
                new ScriptedDuplexStream(duplicate),
                duplicateSink,
                duplicateClipboard,
                clipboardAllowed: false,
                inactivityTimeout: TimeSpan.FromSeconds(1)),
            "Receiver accepted a duplicate sequence");
        Check(duplicateSink.ReleaseCount == 1, "Sequence rejection did not release input");

        var timeoutSink = new RecordingInputSink();
        var timeoutClipboard = new RecordingClipboardBridge();
        await CheckThrowsAsync<TimeoutException>(
            () => ReceiverSession.RunAsync(
                new BlockingReadStream(),
                timeoutSink,
                timeoutClipboard,
                clipboardAllowed: false,
                inactivityTimeout: TimeSpan.FromMilliseconds(30)),
            "Receiver did not time out an inactive connection");
        Check(timeoutSink.ReleaseCount == 1, "Heartbeat timeout did not release input");

        return checks;

        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
            checks++;
        }

        async Task CheckThrowsAsync<TError>(Func<Task> action, string message) where TError : Exception
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

    private static object Message(ulong sequence, string type, object? data = null) => new
    {
        version = 3,
        sessionID = "session-a",
        sequence,
        sentAtMicros = 100,
        payload = new { type, data }
    };

    private static byte[] Frame(object message)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message);
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        return frame;
    }

    private static byte[] Unframe(byte[] frame)
    {
        var length = BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(0, 4));
        return frame.AsSpan(4, checked((int)length)).ToArray();
    }

    private static List<byte[]> UnframeAll(byte[] frames)
    {
        var payloads = new List<byte[]>();
        var offset = 0;
        while (offset < frames.Length)
        {
            var length = checked((int)BinaryPrimitives.ReadUInt32BigEndian(
                frames.AsSpan(offset, 4)));
            offset += 4;
            payloads.Add(frames.AsSpan(offset, length).ToArray());
            offset += length;
        }
        return payloads;
    }

    private sealed class RecordingInputSink(List<string>? events = null) : IInputSink
    {
        public int ReleaseCount { get; private set; }
        public double? Move(double dx, double dy, double gain) => null;
        public void EnterRemote(string remotePosition, double entryFraction, double activationDistance) { }
        public void Warp(double x, double y) { }
        public void Scroll(double horizontal, double vertical, string phase, bool navigationEnabled, double gain) { }
        public void Button(string button, bool isDown) { }
        public void Key(ushort usbHidUsage, bool isDown) =>
            events?.Add($"key:{usbHidUsage}:{isDown.ToString().ToLowerInvariant()}");
        public void ReleaseAll() => ReleaseCount++;
    }

    private sealed class RecordingClipboardBridge(List<string>? events = null) : IClipboardBridge
    {
        private ClipboardState? state;
        public int DisableCount { get; private set; }
        public int ImageApplyCount { get; private set; }

        public Task EnableAsync(CancellationToken cancellationToken)
        {
            events?.Add("clipboard:enabled");
            return Task.CompletedTask;
        }

        public Task DisableAsync()
        {
            DisableCount++;
            return Task.CompletedTask;
        }

        public Task<ClipboardState?> ApplyAsync(
            ClipboardContent content,
            CancellationToken cancellationToken)
        {
            events?.Add($"clipboard:{content.PlainText}");
            state = new ClipboardState((state?.Revision ?? 0) + 1, content);
            return Task.FromResult<ClipboardState?>(state);
        }

        public Task<ClipboardState?> ApplyImageAsync(
            ClipboardContent content,
            byte[] imageData,
            CancellationToken cancellationToken)
        {
            content.Image?.Validate(imageData);
            ImageApplyCount++;
            events?.Add($"clipboard:image:{imageData.Length}");
            state = new ClipboardState((state?.Revision ?? 0) + 1, content);
            return Task.FromResult<ClipboardState?>(state);
        }

        public ClipboardState? StateAfter(ulong revision) =>
            state is { } current && current.Revision > revision ? current : null;

        public void SetState(ClipboardState value) => state = value;
    }

    private sealed class ScriptedDuplexStream : Stream
    {
        private readonly MemoryStream input;
        private readonly MemoryStream output = new();
        private readonly bool blockAtEnd;
        private readonly TaskCompletionSource inputConsumed = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public ScriptedDuplexStream(byte[] inputBytes, bool blockAtEnd = false)
        {
            input = new MemoryStream(inputBytes);
            this.blockAtEnd = blockAtEnd;
        }

        public byte[] Written => output.ToArray();
        public Task InputConsumed => inputConsumed.Task;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => output.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => output.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => input.Read(buffer, offset, count);
        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var count = await input.ReadAsync(buffer, cancellationToken);
            if (count > 0 || !blockAtEnd) return count;
            inputConsumed.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return 0;
        }
        public override void Write(byte[] buffer, int offset, int count) => output.Write(buffer, offset, count);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) =>
            output.WriteAsync(buffer, cancellationToken);
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class BlockingReadStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return 0;
        }
        public override void Write(byte[] buffer, int offset, int count) { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
