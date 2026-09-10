namespace PasswallReceiver.Core;

internal sealed class BulkTransferRegistry(TimeProvider? timeProvider = null)
{
    private const int MaximumOutstandingTransfers = 100;
    private const int MaximumRememberedTransfers = 10_000;
    private static readonly TimeSpan OfferLifetime = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan ReplayLifetime = TimeSpan.FromMinutes(10);

    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly object sync = new();
    private readonly Dictionary<Guid, Registration> offered = [];
    private readonly Dictionary<Guid, Registration> accepted = [];
    private readonly Dictionary<Guid, DateTimeOffset> used = [];
    private readonly Queue<UsedTransfer> usedOrder = [];
    private readonly Queue<FileTransferControl> outgoingControls = [];
    private readonly Dictionary<Guid, FileTransferActivity> fileTransfers = [];
    private readonly Queue<Guid> fileTransferOrder = [];
    private BulkTransferClaim? active;

    public void Register(
        Guid transferID,
        TransferDirection direction,
        ulong totalBytes,
        FileTransferManifest? manifest = null)
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            if (offered.Count + accepted.Count >= MaximumOutstandingTransfers)
            {
                throw new InvalidDataException("Too many outstanding transfer offers");
            }
            if (offered.ContainsKey(transferID) || accepted.ContainsKey(transferID) ||
                used.ContainsKey(transferID) || active?.TransferID == transferID)
            {
                throw new InvalidDataException("Transfer ID was already registered");
            }
            offered.Add(
                transferID,
                new Registration(direction, totalBytes, now + OfferLifetime, Manifest: manifest));
            if (manifest is not null)
            {
                fileTransfers[transferID] = new FileTransferActivity(
                    transferID,
                    direction,
                    manifest,
                    totalBytes,
                    0,
                    now,
                    FileTransferStatus.AwaitingApproval);
                fileTransferOrder.Enqueue(transferID);
                while (fileTransferOrder.Count > FileTransferHistoryStore.MaximumCount)
                {
                    fileTransfers.Remove(fileTransferOrder.Dequeue());
                }
            }
        }
    }

    public void Accept(Guid transferID, Stream? source = null)
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            if (!offered.TryGetValue(transferID, out var registration) ||
                accepted.ContainsKey(transferID) || used.ContainsKey(transferID))
            {
                throw new InvalidDataException("Transfer offer is unknown or already used");
            }
            if (registration.Direction == TransferDirection.Download &&
                source?.CanRead != true)
            {
                throw new InvalidDataException("Download approval requires a readable source");
            }
            if (registration.Direction == TransferDirection.Upload && source is not null)
            {
                throw new InvalidDataException("Upload approval cannot include a source");
            }
            offered.Remove(transferID);
            accepted.Add(
                transferID,
                registration with { ExpiresAt = now + OfferLifetime, Source = source });
        }
    }

    public void AcceptUpload(
        Guid transferID,
        ulong expectedBytes,
        Stream destination,
        Func<Stream, CancellationToken, Task> completion)
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            if (!offered.TryGetValue(transferID, out var registration) ||
                registration.Direction != TransferDirection.Upload ||
                registration.TotalBytes != expectedBytes ||
                destination.CanWrite is false)
            {
                destination.Dispose();
                throw new InvalidDataException("Upload approval did not match its offer");
            }
            offered.Remove(transferID);
            accepted.Add(
                transferID,
                registration with
                {
                    ExpiresAt = now + OfferLifetime,
                    Destination = destination,
                    Completion = completion
                });
        }
    }

    public void AcceptFileUpload(Guid transferID, string destinationRoot)
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            if (!offered.TryGetValue(transferID, out var registration) ||
                registration.Direction != TransferDirection.Upload || registration.Manifest is null)
            {
                throw new InvalidDataException("File transfer offer is unknown or invalid");
            }
            var staging = new FileTransferStaging(destinationRoot, transferID, registration.Manifest);
            var destination = new FileTransferStagingStream(staging);
            offered.Remove(transferID);
            accepted.Add(
                transferID,
                registration with
                {
                    ExpiresAt = now + OfferLifetime,
                    Destination = destination,
                    Completion = (stream, _) =>
                    {
                        var resultPath = ((FileTransferStagingStream)stream).Finish();
                        if (ResolveFileTransfer(
                            transferID,
                            FileTransferStatus.Completed,
                            resultPath: resultPath))
                        {
                            QueueControl(new FileTransferControl("transfer_complete", transferID));
                        }
                        return Task.CompletedTask;
                    }
                });
            UpdateFileTransferLocked(transferID, FileTransferStatus.Transferring);
            outgoingControls.Enqueue(new FileTransferControl("transfer_accept", transferID));
        }
    }

    public IReadOnlyList<FileTransferOffer> PendingFileUploads()
    {
        lock (sync)
        {
            PruneLocked(clock.GetUtcNow());
            return offered
                .Where(pair => pair.Value is { Direction: TransferDirection.Upload, Manifest: not null })
                .Select(pair => new FileTransferOffer(
                    pair.Key,
                    pair.Value.Manifest!,
                    pair.Value.TotalBytes,
                    pair.Value.ExpiresAt))
                .ToArray();
        }
    }

    public IReadOnlyList<FileTransferActivity> FileTransfers()
    {
        lock (sync)
        {
            PruneLocked(clock.GetUtcNow());
            return fileTransferOrder
                .Reverse()
                .Where(fileTransfers.ContainsKey)
                .Select(transferID => fileTransfers[transferID])
                .ToArray();
        }
    }

    public bool HasActiveFileTransfers()
    {
        lock (sync)
        {
            PruneLocked(clock.GetUtcNow());
            return fileTransfers.Values.Any(transfer => transfer.Status is
                FileTransferStatus.Queued or FileTransferStatus.AwaitingApproval or
                FileTransferStatus.Transferring or FileTransferStatus.Verifying);
        }
    }

    public void ClearFinishedFileTransfers()
    {
        lock (sync)
        {
            foreach (var pair in fileTransfers.Where(pair => pair.Value.Status is
                FileTransferStatus.Completed or FileTransferStatus.Rejected or
                FileTransferStatus.Canceled or FileTransferStatus.Failed).ToArray())
            {
                fileTransfers.Remove(pair.Key);
            }
        }
    }

    public void PeerAcceptedFileTransfer(Guid transferID)
    {
        lock (sync) UpdateFileTransferLocked(transferID, FileTransferStatus.Transferring);
    }

    public void ReportFileProgress(Guid transferID, ulong transferredBytes)
    {
        lock (sync)
        {
            UpdateFileTransferLocked(transferID, transfer => transfer with
            {
                Status = FileTransferStatus.Transferring,
                TransferredBytes = Math.Min(transferredBytes, transfer.TotalBytes)
            });
        }
    }

    public bool ResolveFileTransfer(
        Guid transferID,
        FileTransferStatus status,
        string? errorCode = null,
        string? resultPath = null)
    {
        lock (sync)
        {
            return UpdateFileTransferLocked(transferID, transfer => transfer with
            {
                Status = status,
                TransferredBytes = status == FileTransferStatus.Completed
                    ? transfer.TotalBytes : transfer.TransferredBytes,
                ErrorCode = errorCode,
                ResultPath = resultPath ?? transfer.ResultPath
            });
        }
    }

    public void MarkFileVerifying(Guid transferID)
    {
        lock (sync) UpdateFileTransferLocked(transferID, FileTransferStatus.Verifying);
    }

    public void FailFileTransfer(Guid transferID, string code, bool notifyPeer)
    {
        if (ResolveFileTransfer(transferID, FileTransferStatus.Failed, code) && notifyPeer)
        {
            QueueControl(new FileTransferControl("transfer_error", transferID, Code: code));
        }
    }

    public void RejectFileUpload(
        Guid transferID,
        string code = "user_rejected",
        FileTransferStatus status = FileTransferStatus.Rejected)
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            if (!offered.TryGetValue(transferID, out var registration) ||
                registration is not { Direction: TransferDirection.Upload, Manifest: not null })
            {
                throw new InvalidDataException("File transfer offer is unknown or invalid");
            }
            offered.Remove(transferID);
            MarkUsedLocked(transferID, now);
            UpdateFileTransferLocked(transferID, status, code);
            outgoingControls.Enqueue(new FileTransferControl(
                "transfer_reject", transferID, Code: code));
        }
    }

    public void RegisterFileDownload(Guid transferID, FileTransferBatch batch)
    {
        var source = batch.OpenRead();
        try
        {
            Register(
                transferID,
                TransferDirection.Download,
                batch.Manifest.TotalBytes,
                batch.Manifest);
            Accept(transferID, source);
            lock (sync)
            {
                outgoingControls.Enqueue(new FileTransferControl(
                    "transfer_offer",
                    transferID,
                    batch.Manifest,
                    batch.Manifest.TotalBytes));
            }
        }
        catch
        {
            source.Dispose();
            throw;
        }
    }

    public IReadOnlyList<FileTransferControl> DrainOutgoingControls()
    {
        lock (sync)
        {
            PruneLocked(clock.GetUtcNow());
            var controls = outgoingControls.ToArray();
            outgoingControls.Clear();
            return controls;
        }
    }

    public BulkTransferClaim Claim(TrustedSessionBinding binding)
    {
        if (binding is not { Role: TrustedSessionRole.Bulk, TransferID: { } transferID,
                Direction: { } direction })
        {
            throw new InvalidDataException("Bulk session binding is incomplete");
        }
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            if (active is not null)
            {
                throw new InvalidDataException("Another bulk session is active");
            }
            if (!accepted.Remove(transferID, out var registration) ||
                used.ContainsKey(transferID))
            {
                throw new InvalidDataException("Unknown, replayed, or mismatched transfer ID");
            }
            MarkUsedLocked(transferID, now);
            if (registration.Direction != direction)
            {
                registration.Source?.Dispose();
                registration.Destination?.Dispose();
                throw new InvalidDataException("Unknown, replayed, or mismatched transfer ID");
            }
            active = new BulkTransferClaim(
                this,
                transferID,
                direction,
                registration.TotalBytes,
                registration.Source,
                registration.Destination,
                registration.Completion,
                registration.Manifest is not null);
            if (registration.Manifest is not null)
            {
                UpdateFileTransferLocked(transferID, FileTransferStatus.Transferring);
            }
            return active;
        }
    }

    public bool Cancel(Guid transferID)
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            PruneLocked(now);
            var removed = offered.Remove(transferID);
            if (accepted.Remove(transferID, out var registration))
            {
                registration.Source?.Dispose();
                registration.Destination?.Dispose();
                removed = true;
            }
            if (removed)
            {
                MarkUsedLocked(transferID, now);
            }
            var activeMatch = active?.TransferID == transferID;
            if (activeMatch) active!.Cancel();
            if (removed || activeMatch)
            {
                UpdateFileTransferLocked(transferID, FileTransferStatus.Canceled);
            }
            return removed || activeMatch;
        }
    }

    public void CancelFileTransfer(Guid transferID)
    {
        if (Cancel(transferID))
        {
            QueueControl(new FileTransferControl("transfer_cancel", transferID));
        }
    }

    public void CancelImages()
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            foreach (var pair in offered.Where(pair => pair.Value.Manifest is null).ToArray())
            {
                offered.Remove(pair.Key);
                MarkUsedLocked(pair.Key, now);
            }
            foreach (var pair in accepted.Where(pair => pair.Value.Manifest is null).ToArray())
            {
                accepted.Remove(pair.Key);
                pair.Value.Source?.Dispose();
                pair.Value.Destination?.Dispose();
                MarkUsedLocked(pair.Key, now);
            }
            if (active?.IsFileTransfer == false) active.Cancel();
        }
    }

    public void CancelAll()
    {
        lock (sync)
        {
            var now = clock.GetUtcNow();
            foreach (var pair in offered)
            {
                MarkUsedLocked(pair.Key, now);
                UpdateFileTransferLocked(pair.Key, FileTransferStatus.Failed, "disconnected");
            }
            foreach (var pair in accepted)
            {
                pair.Value.Source?.Dispose();
                pair.Value.Destination?.Dispose();
                MarkUsedLocked(pair.Key, now);
                UpdateFileTransferLocked(pair.Key, FileTransferStatus.Failed, "disconnected");
            }
            offered.Clear();
            accepted.Clear();
            outgoingControls.Clear();
            if (active is not null)
            {
                UpdateFileTransferLocked(active.TransferID, FileTransferStatus.Failed, "disconnected");
            }
            active?.Cancel();
        }
    }

    internal void Release(Guid transferID)
    {
        lock (sync)
        {
            if (active?.TransferID != transferID) return;
            active = null;
            MarkUsedLocked(transferID, clock.GetUtcNow());
        }
    }

    private void PruneLocked(DateTimeOffset now)
    {
        foreach (var pair in offered.Where(pair => pair.Value.ExpiresAt <= now).ToArray())
        {
            offered.Remove(pair.Key);
            MarkUsedLocked(pair.Key, now);
            if (pair.Value.Manifest is not null)
            {
                UpdateFileTransferLocked(pair.Key, FileTransferStatus.Rejected, "approval_timeout");
                outgoingControls.Enqueue(new FileTransferControl(
                    "transfer_reject", pair.Key, Code: "approval_timeout"));
            }
        }
        foreach (var pair in accepted.Where(pair => pair.Value.ExpiresAt <= now).ToArray())
        {
            accepted.Remove(pair.Key);
            pair.Value.Source?.Dispose();
            pair.Value.Destination?.Dispose();
            MarkUsedLocked(pair.Key, now);
            if (pair.Value.Manifest is not null)
            {
                UpdateFileTransferLocked(pair.Key, FileTransferStatus.Failed, "transfer_timeout");
                outgoingControls.Enqueue(new FileTransferControl(
                    "transfer_error", pair.Key, Code: "transfer_timeout"));
            }
        }
        while (usedOrder.TryPeek(out var entry) &&
            (entry.ExpiresAt <= now || used.Count > MaximumRememberedTransfers))
        {
            usedOrder.Dequeue();
            if (used.GetValueOrDefault(entry.TransferID) == entry.ExpiresAt)
            {
                used.Remove(entry.TransferID);
            }
        }
    }

    private void MarkUsedLocked(Guid transferID, DateTimeOffset now)
    {
        var expiresAt = now + ReplayLifetime;
        used[transferID] = expiresAt;
        usedOrder.Enqueue(new UsedTransfer(transferID, expiresAt));
        // ponytail: process-local 10,000-ID replay window; persist IDs if
        // replay protection must survive restarts or a larger authenticated flood.
        while (used.Count > MaximumRememberedTransfers)
        {
            var entry = usedOrder.Dequeue();
            if (used.GetValueOrDefault(entry.TransferID) == entry.ExpiresAt)
            {
                used.Remove(entry.TransferID);
            }
        }
    }

    private void QueueControl(FileTransferControl control)
    {
        lock (sync) outgoingControls.Enqueue(control);
    }

    private bool UpdateFileTransferLocked(
        Guid transferID,
        FileTransferStatus status,
        string? errorCode = null)
    {
        return UpdateFileTransferLocked(
            transferID,
            transfer => transfer with { Status = status, ErrorCode = errorCode });
    }

    private bool UpdateFileTransferLocked(
        Guid transferID,
        Func<FileTransferActivity, FileTransferActivity> update)
    {
        if (!fileTransfers.TryGetValue(transferID, out var transfer) ||
            transfer.Status is FileTransferStatus.Completed or FileTransferStatus.Rejected or
                FileTransferStatus.Canceled or FileTransferStatus.Failed)
        {
            return false;
        }
        fileTransfers[transferID] = update(transfer);
        return true;
    }

    private sealed record Registration(
        TransferDirection Direction,
        ulong TotalBytes,
        DateTimeOffset ExpiresAt,
        Stream? Source = null,
        Stream? Destination = null,
        Func<Stream, CancellationToken, Task>? Completion = null,
        FileTransferManifest? Manifest = null);

    private sealed record UsedTransfer(Guid TransferID, DateTimeOffset ExpiresAt);
}

internal sealed record FileTransferControl(
    string Type,
    Guid TransferID,
    FileTransferManifest? Manifest = null,
    ulong TotalBytes = 0,
    string? Code = null);

internal sealed record FileTransferOffer(
    Guid TransferID,
    FileTransferManifest Manifest,
    ulong TotalBytes,
    DateTimeOffset ExpiresAt);

internal sealed record FileTransferActivity(
    Guid TransferID,
    TransferDirection Direction,
    FileTransferManifest Manifest,
    ulong TotalBytes,
    ulong TransferredBytes,
    DateTimeOffset StartedAt,
    FileTransferStatus Status,
    string? ErrorCode = null,
    string? ResultPath = null);

internal sealed class BulkTransferClaim : IDisposable
{
    private readonly BulkTransferRegistry registry;
    private readonly CancellationTokenSource cancellation = new();
    private bool disposed;

    public BulkTransferClaim(
        BulkTransferRegistry registry,
        Guid transferID,
        TransferDirection direction,
        ulong totalBytes,
        Stream? source,
        Stream? destination,
        Func<Stream, CancellationToken, Task>? completion,
        bool isFileTransfer)
    {
        this.registry = registry;
        TransferID = transferID;
        Direction = direction;
        TotalBytes = totalBytes;
        Source = source;
        Destination = destination;
        Completion = completion;
        IsFileTransfer = isFileTransfer;
    }

    public Guid TransferID { get; }
    public TransferDirection Direction { get; }
    public ulong TotalBytes { get; }
    public Stream? Source { get; }
    public Stream? Destination { get; }
    public CancellationToken CancellationToken => cancellation.Token;
    public bool IsFileTransfer { get; }
    private Func<Stream, CancellationToken, Task>? Completion { get; }

    internal void Cancel() => cancellation.Cancel();

    public Task CompleteAsync(CancellationToken cancellationToken) =>
        Completion is not null && Destination is not null
            ? Completion(Destination, cancellationToken)
            : Task.CompletedTask;

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        registry.Release(TransferID);
        Source?.Dispose();
        Destination?.Dispose();
        cancellation.Dispose();
    }
}
