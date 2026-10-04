using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for manual text imports and other simple text-based formats.
/// Wraps text in a single conversation.
/// </summary>
public sealed class ManualTextParser : IImportParser
{
    public string Source => "manual-text";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        return CommonParsing.SingleConversation(Source, request, CommonParsing.EffectiveText(request), "Manual text import");
    }
}

/// <summary>
/// Parser for scanned PDF/OCR text imports.
/// </summary>
public sealed class ScannedPdfParser : IImportParser
{
    public string Source => "scanned-pdf";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var ocrText = CommonParsing.Metadata(request, "ocrText") ?? string.Empty;
        var fullText = CommonParsing.Clean(request.Text) ?? CommonParsing.Clean(ocrText);
        if (fullText is null)
        {
            if (string.IsNullOrWhiteSpace(request.PayloadBase64)) throw new InvalidOperationException("Document import requires a PDF/image payload or extracted text.");
            if (request.PayloadBase64.Length > (PdfTextExtractor.MaxBytes + 2L) / 3 * 4) throw new InvalidOperationException("Document exceeds 25 MiB.");
            byte[] bytes;
            try { bytes = Convert.FromBase64String(request.PayloadBase64); }
            catch (FormatException) { throw new InvalidOperationException("Document payloadBase64 is invalid."); }
            var pdf = bytes.AsSpan(0, Math.Min(bytes.Length, 1024)).IndexOf("%PDF-"u8) >= 0;
            var image = !pdf && (bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) ||
                bytes.Length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8 ||
                request.MimeType is "image/png" or "image/jpeg" ||
                new[] { ".png", ".jpg", ".jpeg" }.Contains(Path.GetExtension(request.OriginalFileName ?? "").ToLowerInvariant()));
            fullText = PdfTextExtractor.Extract(bytes, image);
        }
        var response = CommonParsing.SingleConversation(Source, request, fullText, "Document import");
        if (CommonParsing.Metadata(request, "documentId") is not { } id) return response;
        return response with { Conversations = response.Conversations.Select(conversation => conversation with
        {
            SourceThreadId = id, Segments = conversation.Segments.Select(segment => segment with { SourceMessageId = id }).ToArray()
        }).ToArray() };
    }
}

/// <summary>
/// Parser for recording transcripts (audio/video).
/// </summary>
public sealed class RecordingTranscriptParser : IImportParser
{
    public string Source => "live-recording";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        return CommonParsing.SingleConversation(Source, request, CommonParsing.EffectiveText(request), "Recording transcript import");
    }
}
