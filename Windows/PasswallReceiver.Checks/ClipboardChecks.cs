using System.Text;
using System.Text.Json;
using PasswallReceiver.Core;

internal static class ClipboardChecks
{
    public static int Run()
    {
        var checks = 0;
        var parsed = ClipboardContent.Parse(JsonDocument.Parse("""
            {"plainText":"Passwall 链接","rtfBase64":"e1xydGYxIFxiIFBhc3N3YWxsfQ==","html":"<b>Passwall</b> 链接"}
            """).RootElement);

        Check(parsed.PlainText == "Passwall 链接", "Plain fallback changed");
        Check(
            Encoding.UTF8.GetString(parsed.Rtf!) == "{\\rtf1 \\b Passwall}",
            "RTF Base64 changed");
        Check(parsed.Html == "<b>Passwall</b> 链接", "HTML changed");

        var wire = JsonSerializer.SerializeToElement(parsed.ToWireValue());
        Check(wire.GetProperty("plainText").GetString() == parsed.PlainText, "Wire text changed");
        Check(wire.GetProperty("rtfBase64").GetString() == "e1xydGYxIFxiIFBhc3N3YWxsfQ==", "Wire RTF changed");
        Check(wire.GetProperty("html").GetString() == parsed.Html, "Wire HTML changed");

        var fragment = "<p><b>粗体</b> and <a href=\"https://example.com\">link</a></p>";
        var windowsHtml = ClipboardHtml.ToClipboardFormat(fragment);
        Check(
            ClipboardHtml.FromClipboardFormat(windowsHtml) == fragment,
            "CF_HTML offsets changed the Unicode fragment");

        CheckThrows<InvalidDataException>(
            () => ClipboardContent.Parse(JsonDocument.Parse("{\"plainText\":\"x\",\"rtfBase64\":\"%%%\"}").RootElement),
            "Invalid RTF Base64 was accepted");
        CheckThrows<InvalidDataException>(
            () => ClipboardContent.Parse(JsonDocument.Parse("{\"plainText\":\"\"}").RootElement),
            "Empty plain fallback was accepted");
        CheckThrows<InvalidDataException>(
            () => ClipboardContent.Parse(JsonDocument.Parse("{}").RootElement),
            "Missing plain fallback was accepted");
        CheckThrows<InvalidDataException>(
            () => ClipboardContent.Parse(JsonSerializer.SerializeToElement(new
            {
                plainText = new string('x', ProtocolContract.MaximumClipboardRawBytes + 1)
            })),
            "Oversized clipboard content was accepted");
        CheckThrows<InvalidDataException>(
            () => ClipboardHtml.FromClipboardFormat("StartFragment:0000000100\r\nEndFragment:0000000001\r\nx"),
            "Malformed CF_HTML offsets were accepted");

        var imageBytes = Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
        var image = ClipboardImageMetadata.Create(Guid.NewGuid(), "image/png", imageBytes);
        var imageContent = ClipboardContent.Create(image: image);
        var imageWire = JsonSerializer.SerializeToElement(imageContent.ToWireValue());
        var parsedImage = ClipboardContent.Parse(imageWire);
        Check(parsedImage.PlainText.Length == 0, "Image clipboard required a text fallback");
        Check(parsedImage.Image == image, "Image metadata changed on the wire");
        image.Validate(imageBytes);
        CheckThrows<InvalidDataException>(
            () => image.Validate(Encoding.UTF8.GetBytes("changed")),
            "Image digest mismatch was accepted");
        CheckThrows<InvalidDataException>(
            () => ClipboardImageMetadata.Create(
                Guid.NewGuid(),
                "image/jpeg",
                imageBytes).Validate(imageBytes),
            "Image bytes that disagreed with their declared media type were accepted");
        CheckThrows<InvalidDataException>(
            () => ClipboardImageMetadata.Create(
                Guid.NewGuid(),
                "image/jpeg",
                new byte[checked((int)ProtocolContract.MaximumImageBytes + 1)]),
            "Oversized clipboard image was accepted");

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
    }
}
