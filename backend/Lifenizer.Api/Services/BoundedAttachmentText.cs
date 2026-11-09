using System.Text;
using System.Xml;
using Lifenizer.Api.Services.Parsers;

namespace Lifenizer.Api.Services;

public static class BoundedAttachmentText
{
    public const int MaxTextChars = 4 * 1024 * 1024;

    public static string? Kind(string name, string mimeType) => Path.GetExtension(name).ToLowerInvariant() switch
    {
        ".pdf" => "pdf",
        ".txt" => "text",
        ".csv" => "text",
        ".htm" or ".html" => "html",
        ".docx" => "docx",
        ".odt" => "odt",
        _ => mimeType.ToLowerInvariant() switch
        {
            "application/pdf" => "pdf",
            "text/plain" or "text/csv" => "text",
            "text/html" => "html",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
            "application/vnd.oasis.opendocument.text" => "odt",
            _ => null
        }
    };

    public static string Extract(byte[] bytes, string kind, string? charset = null, TimeSpan? timeout = null)
    {
        if (bytes.Length is 0 or > BoundedImportArchive.MaxBytes) throw new InvalidDataException("Attachment must be between 1 byte and 25 MiB.");
        string text;
        if (kind == "pdf") text = PdfTextExtractor.Extract(bytes, timeout: timeout);
        else if (kind is "docx" or "odt")
        {
            using var archive = BoundedImportArchive.Open(bytes);
            var entry = archive.GetEntry(kind == "docx" ? "word/document.xml" : "content.xml")
                ?? throw new InvalidDataException("Office attachment is missing its document text.");
            using var stream = new MemoryStream(BoundedImportArchive.Read(entry, MaxTextChars));
            using var reader = XmlReader.Create(stream, new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxTextChars
            });
            var result = new StringBuilder();
            while (reader.Read())
            {
                if (reader.NodeType is XmlNodeType.Text or XmlNodeType.CDATA) result.Append(reader.Value);
                else if (reader.NodeType == XmlNodeType.EndElement && reader.LocalName is "p" or "h") result.AppendLine();
                else if (reader.NodeType == XmlNodeType.Element && reader.LocalName is "tab" or "br" or "line-break") result.Append(' ');
                if (result.Length > MaxTextChars) throw new InvalidDataException("Extracted attachment text exceeds 4 MiB characters.");
            }
            text = result.ToString();
        }
        else
        {
            var encoding = Encoding.GetEncoding(charset ?? "utf-8", EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
            if (encoding.GetCharCount(bytes) > MaxTextChars) throw new InvalidDataException("Extracted attachment text exceeds 4 MiB characters.");
            text = encoding.GetString(bytes);
            if (kind == "html") text = CommonParsing.StripHtml(text);
        }
        if (text.Length > MaxTextChars) throw new InvalidDataException("Extracted attachment text exceeds 4 MiB characters.");
        text = text.Trim('\uFEFF', ' ', '\t', '\r', '\n');
        if (text.Length == 0) throw new InvalidDataException("Attachment contains no readable text.");
        return text;
    }
}
