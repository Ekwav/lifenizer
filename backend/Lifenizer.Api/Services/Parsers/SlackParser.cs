using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Slack message exports (JSON or text format).
/// </summary>
public sealed partial class SlackParser : IImportParser
{
    public string Source => "slack";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = CommonParsing.EnumerateArray(doc.RootElement, "messages", "items");
        var participants = ParticipantRegistry.FromRequest(request);
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonFieldExtractor.GetString(message, "text", "content", "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = JsonFieldExtractor.GetAuthorName(message)
                ?? JsonFieldExtractor.GetNestedString(message, "user_profile", "display_name", "real_name")
                ?? JsonFieldExtractor.GetString(message, "user")
                ?? "Unknown";
            participants.TryAdd(speaker);

            var createdAt = CommonParsing.TryParseDate(JsonFieldExtractor.GetString(message, "timestamp", "date"))
                ?? CommonParsing.ParseUnixEpoch(JsonFieldExtractor.GetString(message, "ts"));

            segments.Add(new SegmentBuilder()
                .WithText(content.Trim())
                .WithSpeaker(speaker)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(createdAt)
                .Build());
        }

        var title = CommonParsing.Clean(request.Title) ?? CommonParsing.Metadata(request, "channel") ?? CommonParsing.Clean(request.OriginalFileName) ?? "Slack export";
        return CommonParsing.Response(Source, $"Normalized {segments.Count} Slack message(s).", [new NormalizedConversation(title, Source, participants.ToList(), segments)]);
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}
