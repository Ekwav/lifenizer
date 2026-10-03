using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Discord message exports (JSON or text format).
/// </summary>
public sealed partial class DiscordParser : IImportParser
{
    public string Source => "discord";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = CommonParsing.EnumerateArray(doc.RootElement, "messages");
        var participants = ParticipantRegistry.FromRequest(request);
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonFieldExtractor.GetString(message, "content", "message", "text") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = JsonFieldExtractor.GetAuthorName(message) ?? "Unknown";
            participants.TryAdd(speaker);
            segments.Add(new SegmentBuilder()
                .WithText(content.Trim())
                .WithSpeaker(speaker)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(message, "timestamp", "date")))
                .Build());
        }

        var title = CommonParsing.Clean(request.Title) ?? JsonFieldExtractor.GetString(doc.RootElement, "channelName") ?? "Discord export";
        return CommonParsing.Response(Source, $"Normalized {segments.Count} Discord message(s).", [new NormalizedConversation(title, Source, participants.ToList(), segments)]);
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}
