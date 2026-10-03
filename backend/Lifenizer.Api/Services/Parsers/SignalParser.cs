using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for Signal messenger exports (CSV or text formats).
/// </summary>
public sealed partial class SignalParser : IImportParser
{
    public string Source => "signal";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        if (FormatDetector.LooksLikeCsv(text))
        {
            return ParseCsv(request, text);
        }

        return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
    }

    private NormalizedImportResponse ParseCsv(ImportRequest request, string csv)
    {
        var rows = CommonParsing.ParseCsv(csv).ToArray();
        var participants = ParticipantRegistry.FromRequest(request);
        var segments = new List<NormalizedSegment>();
        foreach (var row in rows)
        {
            var sender = CommonParsing.GetCsvField(row, "sender", "from", "author", "name") ?? "Unknown";
            var message = CommonParsing.GetCsvField(row, "message", "body", "text", "content") ?? string.Empty;
            if (message.Length == 0) continue;
            participants.TryAdd(sender);
            segments.Add(new SegmentBuilder()
                .WithText(message)
                .WithSpeaker(sender)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(CommonParsing.GetCsvField(row, "timestamp", "date", "time")))
                .Build());
        }

        if (segments.Count > 0)
        {
            return CommonParsing.Response(Source, $"Normalized {segments.Count} Signal message(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "Signal export", Source, participants.ToList(), segments)]);
        }

        return CommonParsing.ParseTextLines(Source, request, SimpleSpeakerLineRegex());
    }

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();
}
