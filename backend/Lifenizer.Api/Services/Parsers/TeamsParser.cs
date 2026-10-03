using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Microsoft Teams chat exports (JSON or text format).
/// </summary>
public sealed partial class TeamsParser : IImportParser
{
    public string Source => "teams";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = CommonParsing.EnumerateArray(doc.RootElement, "messages", "value", "conversations", "items");
        var participants = ParticipantRegistry.FromRequest(request);
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var rawContent = JsonFieldExtractor.GetString(message, "content", "body", "text") ?? string.Empty;
            var content = CommonParsing.StripHtml(rawContent).Trim();
            if (content.Length == 0) continue;

            var speaker = JsonFieldExtractor.GetString(message, "fromDisplayName", "sender")
                ?? JsonFieldExtractor.GetNestedString(message, "from", "displayName", "name")
                ?? "Unknown";
            participants.TryAdd(speaker);

            var createdAt = CommonParsing.TryParseDate(
                JsonFieldExtractor.GetString(message, "createdDateTime", "timestamp", "time", "date"));

            segments.Add(new SegmentBuilder()
                .WithText(content)
                .WithSpeaker(speaker)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(createdAt)
                .Build());
        }

        var title = CommonParsing.Clean(request.Title) ?? CommonParsing.Metadata(request, "thread") ?? CommonParsing.Clean(request.OriginalFileName) ?? "Teams export";
        return CommonParsing.Response(Source, $"Normalized {segments.Count} Teams message(s).", [new NormalizedConversation(title, Source, participants.ToList(), segments)]);
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}
