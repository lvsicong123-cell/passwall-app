namespace PasswallReceiver.Core;

internal static class BulkSession
{
    private static readonly TimeSpan DefaultInactivityTimeout = TimeSpan.FromSeconds(30);

    public static async Task DrainAsync(
        Stream stream,
        Guid transferID,
        ulong expectedBytes,
        CancellationToken cancellationToken,
        TimeSpan? inactivityTimeout = null)
    {
        _ = await ReceiveAsync(
            stream,
            Stream.Null,
            transferID,
            expectedBytes,
            cancellationToken,
            inactivityTimeout);
    }

    public static async Task<bool> ReceiveAsync(
        Stream stream,
        Stream destination,
        Guid transferID,
        ulong expectedBytes,
        CancellationToken cancellationToken,
        TimeSpan? inactivityTimeout = null,
        Action<ulong>? onProgress = null)
    {
        if (!destination.CanWrite)
        {
            throw new InvalidDataException("Bulk destination is not writable");
        }
        var guard = new BulkFrameSequenceGuard(transferID);
        ulong transferredBytes = 0;
        while (!guard.IsFinished)
        {
            var frame = await ReadWithDeadlineAsync(
                    stream,
                    cancellationToken,
                    inactivityTimeout ?? DefaultInactivityTimeout)
                ?? throw new EndOfStreamException("Bulk session ended before completion");
            guard.Accept(frame);
            if (frame.Kind == BulkFrameKind.Chunk)
            {
                transferredBytes = checked(transferredBytes + (ulong)frame.Payload.Length);
                if (transferredBytes > expectedBytes)
                {
                    throw new InvalidDataException("Bulk content exceeded its declared size");
                }
                await destination.WriteAsync(frame.Payload, cancellationToken);
                onProgress?.Invoke(transferredBytes);
            }
            else if (frame.Kind == BulkFrameKind.Complete &&
                transferredBytes != expectedBytes)
            {
                throw new InvalidDataException("Bulk content did not match its declared size");
            }
            if (frame.Kind == BulkFrameKind.Cancel) return false;
        }
        return true;
    }

    public static async Task SendAsync(
        Stream stream,
        Guid transferID,
        Stream source,
        ulong expectedBytes,
        CancellationToken cancellationToken,
        TimeSpan? inactivityTimeout = null,
        Action<ulong>? onProgress = null)
    {
        var buffer = new byte[ProtocolContract.MaximumBulkChunkSize];
        ulong transferredBytes = 0;
        ulong sequence = 0;
        while (true)
        {
            var count = await ReadSourceWithDeadlineAsync(
                source,
                buffer,
                cancellationToken,
                inactivityTimeout ?? DefaultInactivityTimeout);
            if (count == 0) break;
            transferredBytes = checked(transferredBytes + (ulong)count);
            if (transferredBytes > expectedBytes)
            {
                throw new InvalidDataException("Bulk content exceeded its declared size");
            }
            await WriteWithDeadlineAsync(
                stream,
                new BulkFrame(
                    BulkFrameKind.Chunk,
                    transferID,
                    ++sequence,
                    buffer[..count]),
                cancellationToken,
                inactivityTimeout ?? DefaultInactivityTimeout);
            onProgress?.Invoke(transferredBytes);
        }
        if (transferredBytes != expectedBytes)
        {
            throw new InvalidDataException("Bulk content did not match its declared size");
        }
        await WriteWithDeadlineAsync(
            stream,
            new BulkFrame(BulkFrameKind.Complete, transferID, ++sequence, []),
            cancellationToken,
            inactivityTimeout ?? DefaultInactivityTimeout);
    }

    private static async Task<BulkFrame?> ReadWithDeadlineAsync(
        Stream stream,
        CancellationToken cancellationToken,
        TimeSpan timeout)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            return await BulkFrameCodec.ReadAsync(stream, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"No bulk content received for {timeout.TotalSeconds:F1} seconds");
        }
    }

    private static async Task WriteWithDeadlineAsync(
        Stream stream,
        BulkFrame frame,
        CancellationToken cancellationToken,
        TimeSpan timeout)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            await BulkFrameCodec.WriteAsync(stream, frame, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"Bulk peer stopped reading for {timeout.TotalSeconds:F1} seconds");
        }
    }

    private static async Task<int> ReadSourceWithDeadlineAsync(
        Stream source,
        Memory<byte> buffer,
        CancellationToken cancellationToken,
        TimeSpan timeout)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            return await source.ReadAsync(buffer, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"Bulk source stopped reading for {timeout.TotalSeconds:F1} seconds");
        }
    }
}
