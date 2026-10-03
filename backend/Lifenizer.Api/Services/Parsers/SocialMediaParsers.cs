using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Facebook Messenger exports (JSON or text format).
/// </summary>
public sealed partial class FacebookMessengerParser : IImportParser
{
    public string Source => "facebook-messenger";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var messages = CommonParsing.EnumerateArray(root, "messages", "items");
        var participants = ParticipantRegistry.FromRequest(request);
        foreach (var participant in CommonParsing.EnumerateArray(root, "participants"))
        {
            var name = JsonFieldExtractor.GetString(participant, "name");
            participants.TryAdd(name);
        }

        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonFieldExtractor.GetString(message, "content", "text", "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;

            var speaker = JsonFieldExtractor.GetString(message, "sender_name", "sender") ?? JsonFieldExtractor.GetAuthorName(message) ?? "Unknown";
            participants.TryAdd(speaker);

            var createdAt = CommonParsing.ParseUnixEpochMilliseconds(JsonFieldExtractor.GetString(message, "timestamp_ms"))
                ?? CommonParsing.ParseUnixEpoch(JsonFieldExtractor.GetString(message, "timestamp"))
                ?? CommonParsing.TryParseDate(JsonFieldExtractor.GetString(message, "date"));

            segments.Add(new SegmentBuilder()
                .WithText(content.Trim())
                .WithSpeaker(speaker)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(createdAt)
                .Build());
        }

        var title = CommonParsing.Clean(request.Title) ?? JsonFieldExtractor.GetString(root, "title") ?? CommonParsing.Metadata(request, "thread") ?? "Messenger export";
        return CommonParsing.Response(Source, $"Normalized {segments.Count} Messenger message(s).", [new NormalizedConversation(title, Source, participants.ToList(), segments)]);
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}

/// <summary>
/// Parser for Instagram message exports (JSON or text format).
/// </summary>
public sealed partial class InstagramParser : IImportParser
{
    public string Source => "instagram";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var messages = CommonParsing.EnumerateArray(root, "messages", "conversation", "items");
        var participants = ParticipantRegistry.FromRequest(request);
        foreach (var participant in CommonParsing.EnumerateArray(root, "participants"))
        {
            var name = JsonFieldExtractor.GetString(participant, "name", "username");
            participants.TryAdd(name);
        }

        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonFieldExtractor.GetString(message, "content", "text", "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;

            var speaker = JsonFieldExtractor.GetString(message, "sender_name", "sender") ?? JsonFieldExtractor.GetAuthorName(message) ?? "Unknown";
            participants.TryAdd(speaker);

            var createdAt = CommonParsing.ParseUnixEpochMilliseconds(JsonFieldExtractor.GetString(message, "timestamp_ms"))
                ?? CommonParsing.ParseUnixEpoch(JsonFieldExtractor.GetString(message, "timestamp"))
                ?? CommonParsing.TryParseDate(JsonFieldExtractor.GetString(message, "created_at", "date"));

            segments.Add(new SegmentBuilder()
                .WithText(content.Trim())
                .WithSpeaker(speaker)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(createdAt)
                .Build());
        }

        var title = CommonParsing.Clean(request.Title) ?? JsonFieldExtractor.GetString(root, "title") ?? CommonParsing.Metadata(request, "thread") ?? "Instagram export";
        return CommonParsing.Response(Source, $"Normalized {segments.Count} Instagram message(s).", [new NormalizedConversation(title, Source, participants.ToList(), segments)]);
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}
