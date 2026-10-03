using System.Text.RegularExpressions;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for mbox (mailbox) email exports with RFC-compliant header parsing.
/// </summary>
public sealed partial class MboxParser : IImportParser
{
    public string Source => "mbox";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var blocks = SplitMboxBlocks(text);
        var conversations = new List<NormalizedConversation>();
        foreach (var block in blocks)
        {
            var split = HeaderBodySeparatorRegex().Split(block, 2);
            var headers = ParseHeaders(split[0]);
            var body = split.Length > 1 ? DecodeQuotedPrintable(split[1]) : string.Empty;
            var from = Header(headers, "From") ?? "Unknown sender";
            var to = Header(headers, "To");
            var subject = Header(headers, "Subject") ?? "Email message";
            var participants = CommonParsing.ParticipantNames(request).ToList();
            foreach (var name in EmailNames(from).Concat(EmailNames(to)))
            {
                if (!participants.Contains(name, StringComparer.OrdinalIgnoreCase)) participants.Add(name);
            }

            var metadata = new Dictionary<string, string>();
            foreach (var key in new[] { "Message-Id", "Date", "From", "To" })
            {
                if (Header(headers, key) is { } value) metadata[key.ToLowerInvariant()] = value;
            }

            var sender = EmailNames(from).FirstOrDefault() ?? from;
            conversations.Add(new NormalizedConversation(
                subject,
                Source,
                participants,
                [new NormalizedSegment(body.Trim(), sender, 0, CommonParsing.TryParseDate(Header(headers, "Date")) ?? DateTimeOffset.UtcNow)],
                null,
                metadata));
        }

        if (conversations.Count == 0)
        {
            return CommonParsing.SingleConversation(Source, request, text, "Email export");
        }

        return CommonParsing.Response(Source, $"Normalized {conversations.Count} mbox email(s).", conversations);
    }

    private static string[] SplitMboxBlocks(string text)
    {
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal);
        var parts = MboxSeparatorRegex().Split(normalized)
            .Select(part => part.Trim())
            .Where(part => part.Length > 0)
            .ToArray();
        return parts;
    }

    private static Dictionary<string, string> ParseHeaders(string headerText)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? currentKey = null;
        foreach (var rawLine in headerText.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if ((line.StartsWith(' ') || line.StartsWith('\t')) && currentKey is not null)
            {
                headers[currentKey] += " " + line.Trim();
                continue;
            }

            var index = line.IndexOf(':');
            if (index <= 0) continue;
            currentKey = line[..index];
            headers[currentKey] = line[(index + 1)..].Trim();
        }
        return headers;
    }

    private static string? Header(Dictionary<string, string> headers, string key)
    {
        return headers.TryGetValue(key, out var value) ? value : null;
    }

    private static IEnumerable<string> EmailNames(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) yield break;
        foreach (var part in value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var display = part;
            var lt = part.IndexOf('<');
            if (lt > 0)
            {
                display = part[..lt].Trim();
            }
            var gt = part.IndexOf('>');
            if (lt >= 0 && gt > lt)
            {
                var address = part[(lt + 1)..gt].Trim();
                if (display.Length == 0) display = address;
            }

            display = display.Trim('"', ' ');
            if (display.Length > 0) yield return display;
        }
    }

    private static string DecodeQuotedPrintable(string value)
    {
        return value
            .Replace("=\r\n", string.Empty, StringComparison.Ordinal)
            .Replace("=\n", string.Empty, StringComparison.Ordinal)
            .Replace("=20", " ", StringComparison.Ordinal)
            .Trim();
    }

    [GeneratedRegex(@"(?:^|\n)From\s.+\n")]
    private static partial Regex MboxSeparatorRegex();

    [GeneratedRegex(@"\r?\n\r?\n")]
    private static partial Regex HeaderBodySeparatorRegex();
}
