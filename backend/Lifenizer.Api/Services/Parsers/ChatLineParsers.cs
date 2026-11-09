using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for WhatsApp text exports with timestamp and speaker format.
/// </summary>
public sealed partial class WhatsAppParser : IImportParser
{
    public string Source => "whatsapp";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        return CommonParsing.ParseTextLines(Source, request, WhatsAppLineRegex());
    }

    [GeneratedRegex(@"^\[?(?<date>\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}[^\]]*)\]?\s*-?\s*(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex WhatsAppLineRegex();
}

/// <summary>
/// Parser for iMessage/SMS exports with Apple-specific timestamp format.
/// </summary>
public sealed partial class IMessageParser : IImportParser
{
    public string Source => "imessage";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (FormatDetector.IsJson(text))
        {
            return ParseJson(request, text);
        }

        return CommonParsing.ParseTextLines(Source, request, AppleMessageLineRegex());
    }

    private static NormalizedImportResponse ParseJson(ImportRequest request, string json)
    {
        const string source = "imessage";
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var messages = CommonParsing.EnumerateArray(doc.RootElement, "messages", "items", "chat");
        var participants = ParticipantRegistry.FromRequest(request);
        var segments = new List<NormalizedSegment>();

        foreach (var message in messages)
        {
            var content = JsonFieldExtractor.GetString(message, "text", "body", "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = JsonFieldExtractor.GetString(message, "from", "sender", "author") ?? "Unknown";
            participants.TryAdd(speaker);
            segments.Add(new SegmentBuilder()
                .WithText(content.Trim())
                .WithSpeaker(speaker)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(message, "date", "timestamp")))
                .Build());
        }

        return CommonParsing.Response(source, $"Normalized {segments.Count} iMessage/SMS message(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "iMessage export", source, participants.ToList(), segments)]);
    }

    [GeneratedRegex(@"^(?<date>\d{1,2}/\d{1,2}/\d{2,4},\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?)[\s-]+(?<speaker>[^:]+):\s*(?<text>.*)$", RegexOptions.IgnoreCase)]
    private static partial Regex AppleMessageLineRegex();
}
