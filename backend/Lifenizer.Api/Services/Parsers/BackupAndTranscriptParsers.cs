using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Lifenizer backup exports (already normalized JSON format).
/// </summary>
public sealed class LifenizerBackupParser : IImportParser
{
    public string Source => "lifenizer-backup";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (!FormatDetector.IsJson(text))
        {
            return CommonParsing.SingleConversation(Source, request, text, "Lifenizer backup");
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var conversations = new List<NormalizedConversation>();
        var items = CommonParsing.EnumerateArray(root, "conversations", "items", "data");
        foreach (var item in items)
        {
            var title = JsonFieldExtractor.GetString(item, "title") ?? "Backup conversation";
            var convSource = JsonFieldExtractor.GetString(item, "source") ?? "backup";
            var participants = new List<string>();
            foreach (var p in CommonParsing.EnumerateArray(item, "participantNames", "participants"))
            {
                if (p.ValueKind == JsonValueKind.String)
                {
                    var name = p.GetString();
                    if (!string.IsNullOrWhiteSpace(name)) participants.Add(name!);
                }
                else
                {
                    var name = JsonFieldExtractor.GetString(p, "displayName", "name");
                    if (!string.IsNullOrWhiteSpace(name)) participants.Add(name!);
                }
            }

            var segments = new List<NormalizedSegment>();
            foreach (var segment in CommonParsing.EnumerateArray(item, "segments", "messages"))
            {
                if (segment.ValueKind == JsonValueKind.String)
                {
                    var content = segment.GetString();
                    if (!string.IsNullOrWhiteSpace(content))
                    {
                        segments.Add(new SegmentBuilder()
                            .WithText(content!)
                            .WithAutoOffset(segments.Count)
                            .Build());
                    }
                    continue;
                }

                var segmentText = JsonFieldExtractor.GetString(segment, "text", "content", "message") ?? string.Empty;
                if (string.IsNullOrWhiteSpace(segmentText)) continue;
                var offsetMs = 0;
                if (segment.TryGetProperty("offsetMs", out var offsetMsJson) && offsetMsJson.ValueKind == JsonValueKind.Number)
                {
                    offsetMs = offsetMsJson.GetInt32();
                }
                segments.Add(new SegmentBuilder()
                    .WithText(segmentText)
                    .WithSpeaker(JsonFieldExtractor.GetString(segment, "participantName", "speaker"))
                    .WithOffset(offsetMs)
                    .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(segment, "createdAt", "date")))
                    .Build());
            }

            if (segments.Count == 0) continue;

            conversations.Add(new NormalizedConversation(
                title,
                convSource,
                participants,
                segments,
                CommonParsing.EnumerateArray(item, "artifactNames", "artifacts").Where(value => value.ValueKind == JsonValueKind.String).Select(value => value.GetString()!).Where(value => !string.IsNullOrWhiteSpace(value)).ToArray(),
                null));
        }

        if (conversations.Count == 0)
        {
            return CommonParsing.SingleConversation(Source, request, text, "Lifenizer backup");
        }

        return CommonParsing.Response(Source, $"Normalized {conversations.Count} backup conversation(s).", conversations);
    }
}

/// <summary>
/// Parser for video/audio transcripts (JSON and XML formats, e.g. YouTube).
/// </summary>
public sealed partial class TranscriptParser : IImportParser
{
    public string Source => "youtube-transcript";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var trimmed = text.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            return ParseTranscriptJson(request, trimmed);
        }

        if (trimmed.StartsWith('<'))
        {
            return ParseTranscriptXml(request, trimmed);
        }

        return CommonParsing.SingleConversation(Source, request, text, "YouTube transcript");
    }

    private NormalizedImportResponse ParseTranscriptJson(ImportRequest request, string json)
    {
        using var doc = JsonDocument.Parse(json);
        var segments = new List<NormalizedSegment>();
        foreach (var item in CommonParsing.EnumerateArray(doc.RootElement, "segments", "transcript", "items"))
        {
            var text = JsonFieldExtractor.GetString(item, "text", "content", "utterance") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(text)) continue;
            var offsetMs = 0;
            if (item.TryGetProperty("start", out var start) && start.ValueKind == JsonValueKind.Number)
            {
                offsetMs = (int)(start.GetDouble() * 1000);
            }
            else if (item.TryGetProperty("offsetMs", out var offset) && offset.ValueKind == JsonValueKind.Number)
            {
                offsetMs = offset.GetInt32();
            }
            segments.Add(new SegmentBuilder()
                .WithText(text.Trim())
                .WithSpeaker(JsonFieldExtractor.GetString(item, "speaker"))
                .WithOffset(offsetMs)
                .Build());
        }

        if (segments.Count == 0)
        {
            var text = JsonFieldExtractor.GetString(doc.RootElement, "text", "transcript") ?? string.Empty;
            return CommonParsing.SingleConversation(Source, request, text, "YouTube transcript");
        }

        return CommonParsing.Response(Source, $"Normalized {segments.Count} transcript segment(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "YouTube transcript", Source, CommonParsing.ParticipantNames(request), segments)]);
    }

    private NormalizedImportResponse ParseTranscriptXml(ImportRequest request, string xml)
    {
        var segments = new List<NormalizedSegment>();
        foreach (Match match in TranscriptTextRegex().Matches(xml))
        {
            var encoded = match.Groups["text"].Value;
            var start = match.Groups["start"].Success ? match.Groups["start"].Value : "0";
            var text = System.Net.WebUtility.HtmlDecode(encoded).Trim();
            if (text.Length == 0) continue;
            var offsetMs = double.TryParse(start, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) ? (int)(seconds * 1000) : segments.Count * 1000;
            segments.Add(new SegmentBuilder()
                .WithText(text)
                .WithOffset(offsetMs)
                .Build());
        }

        if (segments.Count == 0) return CommonParsing.SingleConversation(Source, request, xml, "YouTube transcript");
        return CommonParsing.Response(Source, $"Normalized {segments.Count} XML transcript segment(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "YouTube transcript", Source, CommonParsing.ParticipantNames(request), segments)]);
    }

    [GeneratedRegex(@"<text(?:[^>]*start=""(?<start>[^""]+)"")?[^>]*>(?<text>.*?)</text>", RegexOptions.Singleline)]
    private static partial Regex TranscriptTextRegex();
}
