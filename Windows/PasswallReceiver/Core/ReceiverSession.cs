using System.Buffers.Binary;
using System.Text.Json;

namespace PasswallReceiver.Core;

internal static class ReceiverSession
{
    private static readonly TimeSpan DefaultInactivityTimeout = TimeSpan.FromSeconds(2);

    public static async Task RunAsync(
        Stream stream,
        IInputSink injector,
        IClipboardBridge clipboard,
        bool clipboardAllowed,
        BulkTransferRegistry? bulkTransfers = null,
        TimeSpan? inactivityTimeout = null,
        CancellationToken cancellationToken = default)
    {
        var header = new byte[4];
        ulong responseSequence = 0;
        var messageGuard = new SessionMessageGuard();
        var timeout = inactivityTimeout ?? DefaultInactivityTimeout;
        var clipboardEnabled = false;
        ulong lastClipboardRevisionSent = 0;

        try
        {
            while (true)
            {
                using var readDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                readDeadline.CancelAfter(timeout);

                try
                {
                    if (!await ReadExactlyOrEndAsync(stream, header, readDeadline.Token))
                    {
                        return;
                    }

                    var length = BinaryPrimitives.ReadUInt32BigEndian(header);
                    if (length > ProtocolContract.MaximumPayloadSize)
                    {
                        throw new InvalidDataException(
                            $"Frame exceeds {ProtocolContract.MaximumPayloadSize} bytes");
                    }

                    var payload = new byte[length];
                    if (!await ReadExactlyOrEndAsync(stream, payload, readDeadline.Token))
                    {
                        throw new EndOfStreamException("Connection ended inside a frame");
                    }

                    using var document = JsonDocument.Parse(payload);
                    var root = document.RootElement;
                    var sessionID = root.GetProperty("sessionID").GetString()
                        ?? throw new InvalidDataException("Missing session ID");
                    messageGuard.Accept(
                        root.GetProperty("version").GetInt32(),
                        sessionID,
                        root.GetProperty("sequence").GetUInt64());

                    var messagePayload = root.GetProperty("payload");
                    var type = messagePayload.GetProperty("type").GetString();
                    if (type is "heartbeat")
                    {
                        if (bulkTransfers is not null)
                        {
                            foreach (var control in bulkTransfers.DrainOutgoingControls())
                            {
                                if (control is { Type: "transfer_offer", Manifest: { } manifest })
                                {
                                    await WriteFileTransferOfferAsync(
                                        stream,
                                        sessionID,
                                        ++responseSequence,
                                        control.TransferID,
                                        control.TotalBytes,
                                        manifest,
                                        readDeadline.Token);
                                }
                                else if (control.Code is { } code)
                                {
                                    await WriteTransferFailureAsync(
                                        stream,
                                        sessionID,
                                        ++responseSequence,
                                        control.Type,
                                        control.TransferID,
                                        code,
                                        readDeadline.Token);
                                }
                                else
                                {
                                    await WriteTransferReferenceAsync(
                                        stream,
                                        sessionID,
                                        ++responseSequence,
                                        control.Type,
                                        control.TransferID,
                                        readDeadline.Token);
                                }
                            }
                        }
                        if (clipboardEnabled &&
                            clipboard.StateAfter(lastClipboardRevisionSent) is { } state)
                        {
                            if (state is { OutgoingImage: { } outgoing, Content.Image: { } image })
                            {
                                var registry = bulkTransfers ?? throw new InvalidDataException(
                                    "Bulk transfers are unavailable");
                                registry.Register(
                                    image.TransferID,
                                    TransferDirection.Download,
                                    image.ByteCount);
                                registry.Accept(
                                    image.TransferID,
                                    new MemoryStream(outgoing.Data, writable: false));
                                await WriteTransferOfferAsync(
                                    stream,
                                    sessionID,
                                    ++responseSequence,
                                    image,
                                    readDeadline.Token);
                            }
                            await WriteClipboardStateAsync(
                                stream,
                                sessionID,
                                ++responseSequence,
                                state,
                                readDeadline.Token);
                            lastClipboardRevisionSent = state.Revision;
                        }
                        await WriteHeartbeatAsync(
                            stream,
                            sessionID,
                            ++responseSequence,
                            readDeadline.Token);
                        continue;
                    }

                    if (type is "clipboard_control")
                    {
                        EnsureTrustedSession(clipboardAllowed);
                        var enabled = messagePayload
                            .GetProperty("data")
                            .GetProperty("enabled")
                            .GetBoolean();
                        if (enabled != clipboardEnabled)
                        {
                            if (enabled)
                            {
                                await clipboard.EnableAsync(readDeadline.Token);
                            }
                            else
                            {
                                await clipboard.DisableAsync();
                                bulkTransfers?.CancelImages();
                            }
                            clipboardEnabled = enabled;
                        }
                        continue;
                    }

                    if (type is "clipboard_set")
                    {
                        EnsureTrustedSession(clipboardAllowed);
                        if (!clipboardEnabled)
                        {
                            throw new InvalidDataException("Clipboard sharing is disabled");
                        }
                        var content = ClipboardContent.Parse(
                            messagePayload
                                .GetProperty("data")
                                .GetProperty("content"));
                        if (content.Image is { } image)
                        {
                            var registry = bulkTransfers ?? throw new InvalidDataException(
                                "Bulk transfers are unavailable");
                            var destination = new MemoryStream(checked((int)image.ByteCount));
                            registry.AcceptUpload(
                                image.TransferID,
                                image.ByteCount,
                                destination,
                                async (received, transferCancellation) =>
                                {
                                    if (received is not MemoryStream memory ||
                                        !memory.TryGetBuffer(out var segment))
                                    {
                                        throw new InvalidDataException(
                                            "Clipboard image buffer is unavailable");
                                    }
                                    var imageData = segment.AsSpan().ToArray();
                                    image.Validate(imageData);
                                    if (await clipboard.ApplyImageAsync(
                                        content,
                                        imageData,
                                        transferCancellation) is null)
                                    {
                                        throw new InvalidDataException(
                                            "Clipboard image could not be applied");
                                    }
                                });
                            await WriteTransferReferenceAsync(
                                stream,
                                sessionID,
                                ++responseSequence,
                                "transfer_accept",
                                image.TransferID,
                                readDeadline.Token);
                        }
                        else
                        {
                            await clipboard.ApplyAsync(content, readDeadline.Token);
                        }
                        continue;
                    }

                    if (type is "clipboard_state")
                    {
                        throw new InvalidDataException(
                            "clipboard_state is receiver-to-controller only");
                    }

                    if (type is not null && type.StartsWith("transfer_", StringComparison.Ordinal))
                    {
                        EnsureTrustedSession(clipboardAllowed);
                        HandleTransferControl(type, messagePayload, bulkTransfers);
                        continue;
                    }

                    var returnFraction = Dispatch(root, injector);
                    if (returnFraction is { } fraction)
                    {
                        injector.ReleaseAll();
                        await WriteRemoteExitAsync(
                            stream,
                            sessionID,
                            ++responseSequence,
                            fraction,
                            readDeadline.Token);
                        Console.WriteLine($"Returned control to Mac at edge fraction {fraction:F3}");
                    }
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    throw new TimeoutException($"No valid input received for {timeout.TotalSeconds:F1} seconds");
                }
            }
        }
        finally
        {
            bulkTransfers?.CancelAll();
            try
            {
                await clipboard.DisableAsync();
            }
            finally
            {
                injector.ReleaseAll();
            }
        }
    }

    private static void HandleTransferControl(
        string type,
        JsonElement payload,
        BulkTransferRegistry? bulkTransfers)
    {
        var data = payload.GetProperty("data");
        var transferIDText = data.GetProperty("transferID").GetString()
            ?? throw new InvalidDataException("Missing transfer ID");
        if (!TrustedSessionBinding.TryParseTransferID(transferIDText, out var transferID))
        {
            throw new InvalidDataException("Invalid transfer ID");
        }
        if (type == "transfer_offer")
        {
            var kind = data.GetProperty("kind").GetString();
            var direction = data.GetProperty("direction").GetString() switch
            {
                "upload" => TransferDirection.Upload,
                "download" => TransferDirection.Download,
                _ => throw new InvalidDataException("Invalid transfer direction")
            };
            var totalBytes = data.GetProperty("totalBytes").GetUInt64();
            var maximumBytes = kind switch
            {
                "image" => ProtocolContract.MaximumImageBytes,
                "files" => ProtocolContract.MaximumBatchBytes,
                _ => throw new InvalidDataException("Invalid transfer kind")
            };
            if (totalBytes > maximumBytes)
            {
                throw new InvalidDataException("Transfer offer exceeds its size limit");
            }
            FileTransferManifest? manifest = null;
            if (kind is "files")
            {
                manifest = FileTransferManifest.Parse(data.GetProperty("manifest"));
                if (manifest.TotalBytes != totalBytes)
                {
                    throw new InvalidDataException("File manifest size does not match its offer");
                }
            }
            else if (data.TryGetProperty("manifest", out _))
            {
                throw new InvalidDataException("Only file offers may include a manifest");
            }
            (bulkTransfers ?? throw new InvalidDataException(
                "Bulk transfers are unavailable")).Register(
                    transferID,
                    direction,
                    totalBytes,
                    manifest);
            return;
        }
        var registry = bulkTransfers ?? throw new InvalidDataException(
            "Bulk transfers are unavailable");
        if (type == "transfer_accept")
        {
            registry.PeerAcceptedFileTransfer(transferID);
            return;
        }
        if (type == "transfer_progress")
        {
            registry.ReportFileProgress(
                transferID,
                data.GetProperty("transferredBytes").GetUInt64());
            return;
        }
        if (type == "transfer_complete")
        {
            registry.ResolveFileTransfer(transferID, FileTransferStatus.Completed);
            return;
        }
        if (type is "transfer_cancel" or "transfer_reject" or "transfer_error")
        {
            var status = type switch
            {
                "transfer_reject" => FileTransferStatus.Rejected,
                "transfer_error" => FileTransferStatus.Failed,
                _ => FileTransferStatus.Canceled
            };
            var code = data.TryGetProperty("code", out var codeValue)
                ? codeValue.GetString() : null;
            registry.ResolveFileTransfer(transferID, status, code);
            registry.Cancel(transferID);
            return;
        }
        throw new InvalidDataException("Unknown transfer control message");
    }

    private static void EnsureTrustedSession(bool trustedSession)
    {
        if (!trustedSession)
        {
            throw new InvalidDataException(
                "Operation requires an authenticated TLS session");
        }
    }

    private static double? Dispatch(JsonElement root, IInputSink injector)
    {
        var payload = root.GetProperty("payload");
        var type = payload.GetProperty("type").GetString();
        if (type is "release_all")
        {
            injector.ReleaseAll();
            return null;
        }

        var data = payload.GetProperty("data");
        switch (type)
        {
            case "pointer_move":
                return injector.Move(
                    data.GetProperty("dx").GetDouble(),
                    data.GetProperty("dy").GetDouble(),
                    data.TryGetProperty("gain", out var pointerGain)
                        ? pointerGain.GetDouble()
                        : 1);
            case "remote_enter":
                var remotePosition = data.GetProperty("remotePosition").GetString()
                    ?? throw new InvalidDataException("Missing remote position");
                injector.EnterRemote(
                    remotePosition,
                    data.GetProperty("entryFraction").GetDouble(),
                    data.GetProperty("activationDistance").GetDouble());
                Console.WriteLine($"Remote control entered from Mac {remotePosition} edge");
                break;
            case "pointer_warp":
                injector.Warp(
                    data.GetProperty("x").GetDouble(),
                    data.GetProperty("y").GetDouble());
                break;
            case "scroll":
                injector.Scroll(
                    data.GetProperty("horizontal").GetDouble(),
                    data.GetProperty("vertical").GetDouble(),
                    data.TryGetProperty("phase", out var phase)
                        ? phase.GetString() ?? "changed"
                        : "changed",
                    data.TryGetProperty("navigationEnabled", out var navigationEnabled)
                        && navigationEnabled.GetBoolean(),
                    data.TryGetProperty("gain", out var scrollGain)
                        ? scrollGain.GetDouble()
                        : 1);
                break;
            case "button":
                injector.Button(
                    data.GetProperty("button").GetString() ?? "left",
                    data.GetProperty("isDown").GetBoolean());
                break;
            case "key":
                injector.Key(
                    data.GetProperty("usbHIDUsage").GetUInt16(),
                    data.GetProperty("isDown").GetBoolean());
                break;
            default:
                throw new InvalidDataException($"Unknown input type: {type}");
        }
        return null;
    }

    private static async Task WriteRemoteExitAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        double entryFraction,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new
            {
                type = "remote_exit",
                data = new { entryFraction }
            }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteHeartbeatAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new { type = "heartbeat" }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteClipboardStateAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        ClipboardState state,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new
            {
                type = "clipboard_state",
                data = new
                {
                    revision = state.Revision,
                    content = state.Content.ToWireValue()
                }
            }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteTransferOfferAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        ClipboardImageMetadata image,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new
            {
                type = "transfer_offer",
                data = new
                {
                    transferID = image.TransferID.ToString("D").ToLowerInvariant(),
                    kind = "image",
                    direction = "download",
                    totalBytes = image.ByteCount
                }
            }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteTransferReferenceAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        string type,
        Guid transferID,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new
            {
                type,
                data = new { transferID = transferID.ToString("D").ToLowerInvariant() }
            }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteTransferFailureAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        string type,
        Guid transferID,
        string code,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new
            {
                type,
                data = new
                {
                    transferID = transferID.ToString("D").ToLowerInvariant(),
                    code
                }
            }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteFileTransferOfferAsync(
        Stream stream,
        string sessionID,
        ulong sequence,
        Guid transferID,
        ulong totalBytes,
        FileTransferManifest manifest,
        CancellationToken cancellationToken)
    {
        var message = new
        {
            version = ProtocolContract.Version,
            sessionID,
            sequence,
            sentAtMicros = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000,
            payload = new
            {
                type = "transfer_offer",
                data = new
                {
                    transferID = transferID.ToString("D").ToLowerInvariant(),
                    kind = "files",
                    direction = "download",
                    totalBytes,
                    manifest = new
                    {
                        entries = manifest.Entries.Select(entry => new
                        {
                            path = entry.Path,
                            kind = entry.Kind,
                            byteCount = entry.ByteCount,
                            sha256 = entry.Sha256
                        })
                    }
                }
            }
        };
        await WriteMessageAsync(stream, message, cancellationToken);
    }

    private static async Task WriteMessageAsync(
        Stream stream,
        object message,
        CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message);
        if (payload.Length > ProtocolContract.MaximumPayloadSize)
        {
            throw new InvalidDataException(
                $"Frame exceeds {ProtocolContract.MaximumPayloadSize} bytes");
        }

        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)payload.Length);
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
    }

    private static async Task<bool> ReadExactlyOrEndAsync(
        Stream stream,
        Memory<byte> buffer,
        CancellationToken cancellationToken)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer[total..], cancellationToken);
            if (read == 0)
            {
                if (total == 0) return false;
                throw new EndOfStreamException("Connection ended inside a frame segment");
            }
            total += read;
        }
        return true;
    }
}
