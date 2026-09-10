using System.Runtime.InteropServices;
using System.Drawing.Imaging;
using System.Text;
using PasswallReceiver.Core;

namespace PasswallReceiver;

internal sealed class ClipboardBridge : IClipboardBridge, IDisposable
{
    private readonly Control dispatcher;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 500 };
    private readonly object stateLock = new();
    private bool enabled;
    private uint lastClipboardSequence;
    private ulong revision;
    private ClipboardState? state;

    public ClipboardBridge(Control dispatcher)
    {
        this.dispatcher = dispatcher;
        timer.Tick += (_, _) => ObserveLocalClipboard();
    }

    public Task EnableAsync(CancellationToken cancellationToken) =>
        InvokeAsync(() =>
        {
            enabled = true;
            lastClipboardSequence = GetClipboardSequenceNumber();
            lock (stateLock) state = null;
            timer.Start();
        }, cancellationToken);

    public Task DisableAsync()
    {
        if (dispatcher.IsDisposed || dispatcher.Disposing || !dispatcher.IsHandleCreated)
        {
            return Task.CompletedTask;
        }
        return InvokeAsync(() =>
        {
            enabled = false;
            timer.Stop();
            lock (stateLock) state = null;
        }, CancellationToken.None);
    }

    public Task<ClipboardState?> ApplyAsync(
        ClipboardContent content,
        CancellationToken cancellationToken) =>
        InvokeAsync(() =>
        {
            if (!enabled) return null;
            if (content.Image is not null)
            {
                throw new InvalidDataException("Image clipboard requires bulk content");
            }
            try
            {
                var data = new DataObject();
                AddTextFormats(data, content);
                Clipboard.SetDataObject(data, true, 3, 50);
                lastClipboardSequence = GetClipboardSequenceNumber();
                return Publish(content);
            }
            catch (Exception error) when (IsClipboardFailure(error))
            {
                LogFailure("apply", content.RawByteCount, error);
                return null;
            }
        }, cancellationToken);

    public Task<ClipboardState?> ApplyImageAsync(
        ClipboardContent content,
        byte[] imageData,
        CancellationToken cancellationToken) =>
        InvokeAsync(() =>
        {
            if (!enabled) return null;
            try
            {
                var image = content.Image
                    ?? throw new InvalidDataException("Clipboard image metadata is missing");
                image.Validate(imageData);
                using var stream = new MemoryStream(imageData, writable: false);
                using var decoded = Image.FromStream(stream, useEmbeddedColorManagement: false);
                var expectedFormat = image.MediaType == "image/png"
                    ? ImageFormat.Png
                    : ImageFormat.Jpeg;
                if (decoded.RawFormat.Guid != expectedFormat.Guid)
                {
                    throw new InvalidDataException(
                        "Clipboard image encoding does not match its declared media type");
                }
                using var bitmap = new Bitmap(decoded);
                var data = new DataObject();
                data.SetData(DataFormats.Bitmap, true, bitmap);
                AddTextFormats(data, content);
                Clipboard.SetDataObject(data, true, 3, 50);
                lastClipboardSequence = GetClipboardSequenceNumber();
                return Publish(content);
            }
            catch (Exception error) when (IsClipboardFailure(error))
            {
                LogFailure("apply image", imageData.LongLength, error);
                return null;
            }
        }, cancellationToken);

    public ClipboardState? StateAfter(ulong previousRevision)
    {
        lock (stateLock)
        {
            return state is { } current && current.Revision > previousRevision
                ? current
                : null;
        }
    }

    public void Dispose()
    {
        enabled = false;
        timer.Stop();
        timer.Dispose();
    }

    private void ObserveLocalClipboard()
    {
        if (!enabled) return;
        var sequence = GetClipboardSequenceNumber();
        if (sequence == lastClipboardSequence) return;
        lastClipboardSequence = sequence;

        try
        {
            var data = Clipboard.GetDataObject();
            if (data is null) return;
            var plainText = data.GetData(DataFormats.UnicodeText) as string ?? "";

            byte[]? rtf = null;
            if (data.GetDataPresent(DataFormats.Rtf, false) &&
                data.GetData(DataFormats.Rtf, false) is string rtfText)
            {
                rtf = Encoding.UTF8.GetBytes(rtfText);
            }

            string? html = null;
            if (data.GetDataPresent(DataFormats.Html, false) &&
                data.GetData(DataFormats.Html, false) is string clipboardHtml)
            {
                html = ClipboardHtml.FromClipboardFormat(clipboardHtml);
            }

            byte[]? imageData;
            try
            {
                imageData = ReadImage(data);
            }
            catch (Exception error) when (
                !string.IsNullOrEmpty(plainText) && IsClipboardFailure(error))
            {
                Publish(ClipboardContent.Create(plainText, rtf, html));
                return;
            }
            if (imageData is not null)
            {
                var image = ClipboardImageMetadata.Create(
                    Guid.NewGuid(),
                    "image/png",
                    imageData);
                Publish(
                    ClipboardContent.Create(plainText, rtf, html, image),
                    new ClipboardImagePayload(imageData));
            }
            else if (!string.IsNullOrEmpty(plainText))
            {
                Publish(ClipboardContent.Create(plainText, rtf, html));
            }
        }
        catch (Exception error) when (IsClipboardFailure(error))
        {
            LogFailure("read", 0, error);
        }
    }

    private ClipboardState Publish(
        ClipboardContent content,
        ClipboardImagePayload? outgoingImage = null)
    {
        lock (stateLock)
        {
            state = new ClipboardState(++revision, content, outgoingImage);
            return state;
        }
    }

    private Task InvokeAsync(Action action, CancellationToken cancellationToken) =>
        InvokeAsync(() =>
        {
            action();
            return true;
        }, cancellationToken);

    private Task<T> InvokeAsync<T>(Func<T> action, CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return Task.FromCanceled<T>(cancellationToken);
        }

        var completion = new TaskCompletionSource<T>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            dispatcher.BeginInvoke(() =>
            {
                try
                {
                    completion.TrySetResult(action());
                }
                catch (Exception error)
                {
                    completion.TrySetException(error);
                }
            });
        }
        catch (Exception error)
        {
            completion.TrySetException(error);
        }
        return completion.Task.WaitAsync(cancellationToken);
    }

    private static bool IsClipboardFailure(Exception error) =>
        error is ExternalException or InvalidDataException or InvalidOperationException or
            ArgumentException;

    private static void AddTextFormats(DataObject data, ClipboardContent content)
    {
        if (!string.IsNullOrEmpty(content.PlainText))
        {
            data.SetData(DataFormats.UnicodeText, content.PlainText);
        }
        if (content.Rtf is not null)
        {
            data.SetData(DataFormats.Rtf, Encoding.UTF8.GetString(content.Rtf));
        }
        if (content.Html is not null)
        {
            data.SetData(DataFormats.Html, ClipboardHtml.ToClipboardFormat(content.Html));
        }
    }

    private static byte[]? ReadImage(IDataObject data)
    {
        if (data.GetDataPresent("PNG", false) && data.GetData("PNG", false) is Stream png)
        {
            return ReadBounded(png);
        }
        if (!data.GetDataPresent(DataFormats.Bitmap, false) ||
            data.GetData(DataFormats.Bitmap, false) is not Image image)
        {
            return null;
        }
        using var output = new BoundedMemoryStream(ProtocolContract.MaximumImageBytes);
        image.Save(output, ImageFormat.Png);
        return output.ToArray();
    }

    private static byte[] ReadBounded(Stream source)
    {
        if (source.CanSeek && (ulong)source.Length > ProtocolContract.MaximumImageBytes)
        {
            throw new InvalidDataException("Clipboard image exceeds 32 MiB");
        }
        if (source.CanSeek) source.Position = 0;
        using var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = source.Read(buffer, 0, buffer.Length);
            if (count == 0) break;
            if ((ulong)(output.Length + count) > ProtocolContract.MaximumImageBytes)
            {
                throw new InvalidDataException("Clipboard image exceeds 32 MiB");
            }
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }

    private static void LogFailure(string operation, long byteCount, Exception error) =>
        Console.Error.WriteLine(
            $"Clipboard {operation} failed: {error.GetType().Name}; bytes={byteCount}");

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    private sealed class BoundedMemoryStream(ulong maximumBytes) : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count)
        {
            EnsureWriteFits(count);
            base.Write(buffer, offset, count);
        }

        public override void Write(ReadOnlySpan<byte> buffer)
        {
            EnsureWriteFits(buffer.Length);
            base.Write(buffer);
        }

        public override void WriteByte(byte value)
        {
            EnsureWriteFits(1);
            base.WriteByte(value);
        }

        public override void SetLength(long value)
        {
            if (value < 0 || checked((ulong)value) > maximumBytes)
            {
                throw new InvalidDataException("Clipboard image exceeds 32 MiB");
            }
            base.SetLength(value);
        }

        private void EnsureWriteFits(int count)
        {
            if (count < 0 || checked((ulong)Position + (ulong)count) > maximumBytes)
            {
                throw new InvalidDataException("Clipboard image exceeds 32 MiB");
            }
        }
    }
}
