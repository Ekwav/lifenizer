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
        var fullText = CommonParsing.EffectiveText(request, ocrText);
        return CommonParsing.SingleConversation(Source, request, fullText, "OCR text import");
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
