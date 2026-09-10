using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PasswallReceiver.Core;

internal sealed class ClipboardContent
{
    private ClipboardContent(
        string plainText,
        byte[]? rtf,
        string? html,
        ClipboardImageMetadata? image)
    {
        PlainText = plainText;
        Rtf = rtf;
        Html = html;
        Image = image;
        RawByteCount = (long)Encoding.UTF8.GetByteCount(plainText)
            + (rtf?.Length ?? 0)
            + (html is null ? 0 : Encoding.UTF8.GetByteCount(html));
    }

    public string PlainText { get; }
    public byte[]? Rtf { get; }
    public string? Html { get; }
    public ClipboardImageMetadata? Image { get; }
    public long RawByteCount { get; }

    public static ClipboardContent Create(
        string plainText = "",
        byte[]? rtf = null,
        string? html = null,
        ClipboardImageMetadata? image = null)
    {
        if (string.IsNullOrEmpty(plainText) && image is null)
        {
            throw new InvalidDataException("Clipboard requires a plain-text fallback");
        }

        var content = new ClipboardContent(plainText, rtf, html, image);
        if (content.RawByteCount > ProtocolContract.MaximumClipboardRawBytes)
        {
            throw new InvalidDataException(
                $"Clipboard content exceeds {ProtocolContract.MaximumClipboardRawBytes} bytes");
        }
        return content;
    }

    public static ClipboardContent Parse(JsonElement value)
    {
        if (value.ValueKind is not JsonValueKind.Object)
        {
            throw new InvalidDataException("Clipboard content must be an object");
        }

        var plainText = "";
        if (value.TryGetProperty("plainText", out var plainValue))
        {
            if (plainValue.ValueKind is not JsonValueKind.String)
            {
                throw new InvalidDataException("Clipboard plain text must be text");
            }
            plainText = plainValue.GetString()!;
        }

        byte[]? rtf = null;
        if (value.TryGetProperty("rtfBase64", out var rtfValue) &&
            rtfValue.ValueKind is not JsonValueKind.Null)
        {
            if (rtfValue.ValueKind is not JsonValueKind.String)
            {
                throw new InvalidDataException("Clipboard RTF must be Base64 text");
            }
            try
            {
                rtf = Convert.FromBase64String(rtfValue.GetString()!);
            }
            catch (FormatException error)
            {
                throw new InvalidDataException("Clipboard contains invalid RTF Base64", error);
            }
        }

        string? html = null;
        if (value.TryGetProperty("html", out var htmlValue) &&
            htmlValue.ValueKind is not JsonValueKind.Null)
        {
            if (htmlValue.ValueKind is not JsonValueKind.String)
            {
                throw new InvalidDataException("Clipboard HTML must be text");
            }
            html = htmlValue.GetString();
        }

        ClipboardImageMetadata? image = null;
        if (value.TryGetProperty("image", out var imageValue) &&
            imageValue.ValueKind is not JsonValueKind.Null)
        {
            image = ClipboardImageMetadata.Parse(imageValue);
        }

        return Create(plainText, rtf, html, image);
    }

    public object ToWireValue()
    {
        var value = new Dictionary<string, object?>
        {
            ["plainText"] = PlainText
        };
        if (Rtf is not null) value["rtfBase64"] = Convert.ToBase64String(Rtf);
        if (Html is not null) value["html"] = Html;
        if (Image is not null) value["image"] = Image.ToWireValue();
        return value;
    }
}

internal sealed record ClipboardImageMetadata(
    Guid TransferID,
    string MediaType,
    ulong ByteCount,
    string Sha256)
{
    public static ClipboardImageMetadata Create(
        Guid transferID,
        string mediaType,
        ReadOnlySpan<byte> data) =>
        Create(
            transferID,
            mediaType,
            checked((ulong)data.Length),
            Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant());

    public static ClipboardImageMetadata Create(
        Guid transferID,
        string mediaType,
        ulong byteCount,
        string sha256)
    {
        if (!TrustedSessionBinding.TryParseTransferID(transferID.ToString("D"), out _) ||
            mediaType is not ("image/png" or "image/jpeg") ||
            byteCount is 0 || byteCount > ProtocolContract.MaximumImageBytes ||
            sha256.Length != 64 || sha256.Any(character =>
                character is not (>= '0' and <= '9') and not (>= 'a' and <= 'f')))
        {
            throw new InvalidDataException("Clipboard image metadata is invalid");
        }
        return new ClipboardImageMetadata(transferID, mediaType, byteCount, sha256);
    }

    public static ClipboardImageMetadata Parse(JsonElement value)
    {
        if (value.ValueKind is not JsonValueKind.Object ||
            !value.TryGetProperty("transferID", out var transferValue) ||
            transferValue.ValueKind is not JsonValueKind.String ||
            !Guid.TryParse(transferValue.GetString(), out var transferID) ||
            !value.TryGetProperty("mediaType", out var mediaValue) ||
            mediaValue.ValueKind is not JsonValueKind.String ||
            !value.TryGetProperty("byteCount", out var byteCountValue) ||
            !value.TryGetProperty("sha256", out var shaValue) ||
            shaValue.ValueKind is not JsonValueKind.String)
        {
            throw new InvalidDataException("Clipboard image metadata is invalid");
        }
        return Create(
            transferID,
            mediaValue.GetString()!,
            byteCountValue.GetUInt64(),
            shaValue.GetString()!);
    }

    public void Validate(ReadOnlySpan<byte> data)
    {
        if (data.Length > checked((int)ProtocolContract.MaximumImageBytes) ||
            checked((ulong)data.Length) != ByteCount ||
            !HasDeclaredSignature(data) ||
            !CryptographicOperations.FixedTimeEquals(
                SHA256.HashData(data),
                Convert.FromHexString(Sha256)))
        {
            throw new InvalidDataException("Clipboard image failed integrity validation");
        }
    }

    private bool HasDeclaredSignature(ReadOnlySpan<byte> data) => MediaType switch
    {
        "image/png" => data.StartsWith(new byte[]
            { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a }),
        "image/jpeg" => data.StartsWith(new byte[] { 0xff, 0xd8, 0xff }),
        _ => false
    };

    public object ToWireValue() => new
    {
        transferID = TransferID.ToString("D").ToLowerInvariant(),
        mediaType = MediaType,
        byteCount = ByteCount,
        sha256 = Sha256
    };
}

internal static class ClipboardHtml
{
    private const string HeaderFormat =
        "Version:1.0\r\n" +
        "StartHTML:{0:D10}\r\n" +
        "EndHTML:{1:D10}\r\n" +
        "StartFragment:{2:D10}\r\n" +
        "EndFragment:{3:D10}\r\n";
    private const string Prefix = "<html><body><!--StartFragment-->";
    private const string Suffix = "<!--EndFragment--></body></html>";

    public static string ToClipboardFormat(string fragment)
    {
        var emptyHeader = string.Format(CultureInfo.InvariantCulture, HeaderFormat, 0, 0, 0, 0);
        var startHtml = Encoding.UTF8.GetByteCount(emptyHeader);
        var startFragment = startHtml + Encoding.UTF8.GetByteCount(Prefix);
        var endFragment = startFragment + Encoding.UTF8.GetByteCount(fragment);
        var endHtml = endFragment + Encoding.UTF8.GetByteCount(Suffix);
        var header = string.Format(
            CultureInfo.InvariantCulture,
            HeaderFormat,
            startHtml,
            endHtml,
            startFragment,
            endFragment);
        return header + Prefix + fragment + Suffix;
    }

    public static string FromClipboardFormat(string value)
    {
        var start = ReadOffset(value, "StartFragment");
        var end = ReadOffset(value, "EndFragment");
        var bytes = Encoding.UTF8.GetBytes(value);
        if (start < 0 || end < start || end > bytes.Length)
        {
            throw new InvalidDataException("Clipboard HTML has invalid fragment offsets");
        }
        return Encoding.UTF8.GetString(bytes[start..end]);
    }

    private static int ReadOffset(string value, string name)
    {
        var marker = name + ":";
        var start = value.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0)
        {
            throw new InvalidDataException($"Clipboard HTML is missing {name}");
        }
        start += marker.Length;
        var end = value.IndexOfAny(['\r', '\n'], start);
        if (end < 0) end = value.Length;
        if (!int.TryParse(value.AsSpan(start, end - start), out var offset))
        {
            throw new InvalidDataException($"Clipboard HTML has an invalid {name}");
        }
        return offset;
    }
}
