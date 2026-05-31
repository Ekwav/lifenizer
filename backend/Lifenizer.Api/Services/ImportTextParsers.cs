using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

public static partial class ImportTextParsers
{
    public static NormalizedImportResponse NormalizeLocal(string source, ImportRequest request)
    {
        return source.ToLowerInvariant() switch
        {
            "manual-text" => SingleConversation(source, request, request.Text ?? string.Empty, "Manual text import"),
            "scanned-pdf" => SingleConversation(source, request, request.Text ?? Metadata(request, "ocrText") ?? string.Empty, "OCR text import"),
            "live-recording" => SingleConversation(source, request, request.Text ?? string.Empty, "Recording transcript import"),
            "whatsapp" => ParseChatLines(source, request, WhatsAppLineRegex()),
            "signal" => ParseSignal(source, request),
            "telegram" => ParseTelegram(request),
            "discord" => ParseDiscord(request, source),
            "browser-history" => ParseBrowserHistory(request),
            "youtube-transcript" => ParseTranscript(source, request, request.Text ?? string.Empty, "YouTube transcript"),
            _ => SingleConversation(source, request, request.Text ?? string.Empty, "Imported data")
        };
    }

    public static NormalizedImportResponse SingleConversation(
        string source,
        ImportRequest request,
        string text,
        string fallbackTitle,
        IReadOnlyList<string>? artifactNames = null,
        IReadOnlyDictionary<string, string>? metadata = null)
    {
        var participants = ParticipantNames(request).ToArray();
        var title = Clean(request.Title) ?? Clean(request.OriginalFileName) ?? fallbackTitle;
        var body = Clean(text) ?? $"Imported {source} item without textual body.";
        var segment = new NormalizedSegment(body, participants.FirstOrDefault(), 0, DateTimeOffset.UtcNow);
        var conversation = new NormalizedConversation(
            title,
            source,
            participants,
            [segment],
            artifactNames ?? ArtifactNames(request),
            metadata);
        return Response(source, $"Normalized 1 {source} conversation.", [conversation]);
    }

    public static NormalizedImportResponse ParseTranscript(string source, ImportRequest request, string text, string fallbackTitle)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            return ParseTranscriptJson(source, request, trimmed, fallbackTitle);
        }

        if (trimmed.StartsWith('<'))
        {
            return ParseTranscriptXml(source, request, trimmed, fallbackTitle);
        }

        return SingleConversation(source, request, text, fallbackTitle);
    }

    public static NormalizedImportResponse ParseDiscordMessages(string source, ImportRequest request, string json)
    {
        return ParseDiscord(request with { Text = json }, source);
    }

    public static IReadOnlyList<string> ParticipantNames(ImportRequest request)
    {
        var names = new List<string>();
        if (request.ParticipantNames is not null)
        {
            names.AddRange(request.ParticipantNames);
        }

        if (request.Metadata is not null && request.Metadata.TryGetValue("participants", out var metadataNames))
        {
            names.AddRange(metadataNames.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));
        }

        return names
            .Select(name => name.Trim())
            .Where(name => name.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static NormalizedImportResponse Response(string source, string message, IReadOnlyList<NormalizedConversation> conversations, IReadOnlyDictionary<string, string>? diagnostics = null)
    {
        var participants = conversations
            .SelectMany(conversation => conversation.ParticipantNames)
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(name => new NormalizedParticipant(name))
            .ToArray();

        return new NormalizedImportResponse(
            source,
            true,
            message,
            conversations,
            participants,
            diagnostics);
    }

    public static string? Metadata(ImportRequest request, string key)
    {
        if (request.Metadata is null) return null;
        return request.Metadata.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value : null;
    }

    private static NormalizedImportResponse ParseChatLines(string source, ImportRequest request, Regex lineRegex)
    {
        var title = Clean(request.Title) ?? $"{CultureInfo.InvariantCulture.TextInfo.ToTitleCase(source)} export";
        var conversations = new List<NormalizedSegment>();
        var participants = ParticipantNames(request).ToList();
        NormalizedSegment? current = null;

        foreach (var rawLine in (request.Text ?? string.Empty).Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;

            var match = lineRegex.Match(line);
            if (match.Success)
            {
                if (current is not null) conversations.Add(current);
                var speaker = match.Groups["speaker"].Value.Trim();
                if (speaker.Length > 0 && !participants.Contains(speaker, StringComparer.OrdinalIgnoreCase))
                {
                    participants.Add(speaker);
                }

                var text = match.Groups["text"].Value.Trim();
                current = new NormalizedSegment(text, speaker, conversations.Count * 1000, TryParseDate(match.Groups["date"].Value));
                continue;
            }

            if (current is null)
            {
                current = new NormalizedSegment(line, participants.FirstOrDefault(), conversations.Count * 1000, DateTimeOffset.UtcNow);
            }
            else
            {
                current = current with { Text = current.Text + "\n" + line };
            }
        }

        if (current is not null) conversations.Add(current);
        if (conversations.Count == 0)
        {
            return SingleConversation(source, request, request.Text ?? string.Empty, title);
        }

        var conversation = new NormalizedConversation(title, source, participants, conversations);
        return Response(source, $"Normalized {conversations.Count} {source} message(s).", [conversation]);
    }

    private static NormalizedImportResponse ParseSignal(string source, ImportRequest request)
    {
        var text = request.Text ?? string.Empty;
        if (text.Contains(',') && text.Split('\n').FirstOrDefault()?.Contains("message", StringComparison.OrdinalIgnoreCase) == true)
        {
            var rows = ParseCsv(text).ToArray();
            var participants = ParticipantNames(request).ToList();
            var segments = new List<NormalizedSegment>();
            foreach (var row in rows)
            {
                var sender = FirstValue(row, "sender", "from", "author", "name") ?? "Unknown";
                var message = FirstValue(row, "message", "body", "text", "content") ?? string.Empty;
                if (message.Length == 0) continue;
                if (!participants.Contains(sender, StringComparer.OrdinalIgnoreCase)) participants.Add(sender);
                segments.Add(new NormalizedSegment(message, sender, segments.Count * 1000, TryParseDate(FirstValue(row, "timestamp", "date", "time"))));
            }

            if (segments.Count > 0)
            {
                return Response(source, $"Normalized {segments.Count} Signal message(s).", [new NormalizedConversation(Clean(request.Title) ?? "Signal export", source, participants, segments)]);
            }
        }

        return ParseChatLines(source, request, SimpleSpeakerLineRegex());
    }

    private static NormalizedImportResponse ParseTelegram(ImportRequest request)
    {
        var text = request.Text ?? string.Empty;
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines("telegram", request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var messages = root.ValueKind == JsonValueKind.Array
            ? root.EnumerateArray()
            : root.TryGetProperty("messages", out var array) && array.ValueKind == JsonValueKind.Array
                ? array.EnumerateArray()
                : Enumerable.Empty<JsonElement>();

        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = TelegramText(message);
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = JsonString(message, "from") ?? JsonString(message, "actor") ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);
            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, TryParseDate(JsonString(message, "date"))));
        }

        var title = Clean(request.Title) ?? JsonString(root, "name") ?? "Telegram export";
        return Response("telegram", $"Normalized {segments.Count} Telegram message(s).", [new NormalizedConversation(title, "telegram", participants, segments)]);
    }

    private static NormalizedImportResponse ParseDiscord(ImportRequest request, string source)
    {
        var text = request.Text ?? string.Empty;
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines(source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = EnumerateArray(doc.RootElement, "messages");
        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonString(message, "content") ?? JsonString(message, "message") ?? JsonString(message, "text") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = AuthorName(message) ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);
            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, TryParseDate(JsonString(message, "timestamp") ?? JsonString(message, "date"))));
        }

        var title = Clean(request.Title) ?? JsonString(doc.RootElement, "channelName") ?? "Discord export";
        return Response(source, $"Normalized {segments.Count} Discord message(s).", [new NormalizedConversation(title, source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseBrowserHistory(ImportRequest request)
    {
        var text = request.Text ?? string.Empty;
        var segments = new List<NormalizedSegment>();
        if (text.TrimStart().StartsWith('[') || text.TrimStart().StartsWith('{'))
        {
            using var doc = JsonDocument.Parse(text);
            foreach (var item in EnumerateArray(doc.RootElement, "history", "visits", "items"))
            {
                var title = JsonString(item, "title") ?? JsonString(item, "name") ?? "Visited page";
                var url = JsonString(item, "url") ?? JsonString(item, "href") ?? string.Empty;
                if (url.Length == 0 && title == "Visited page") continue;
                segments.Add(new NormalizedSegment($"Visited {title}: {url}".Trim(), null, segments.Count * 1000, TryParseDate(JsonString(item, "time") ?? JsonString(item, "lastVisitTime") ?? JsonString(item, "date"))));
            }
        }
        else
        {
            foreach (var row in ParseCsv(text))
            {
                var title = FirstValue(row, "title", "name") ?? "Visited page";
                var url = FirstValue(row, "url", "href") ?? string.Empty;
                if (url.Length == 0 && title == "Visited page") continue;
                segments.Add(new NormalizedSegment($"Visited {title}: {url}".Trim(), null, segments.Count * 1000, TryParseDate(FirstValue(row, "time", "lastVisitTime", "date"))));
            }
        }

        if (segments.Count == 0) return SingleConversation("browser-history", request, text, "Browser history");
        return Response("browser-history", $"Normalized {segments.Count} browser history visit(s).", [new NormalizedConversation(Clean(request.Title) ?? "Browser history", "browser-history", ParticipantNames(request), segments)]);
    }

    private static NormalizedImportResponse ParseTranscriptJson(string source, ImportRequest request, string json, string fallbackTitle)
    {
        using var doc = JsonDocument.Parse(json);
        var segments = new List<NormalizedSegment>();
        foreach (var item in EnumerateArray(doc.RootElement, "segments", "transcript", "items"))
        {
            var text = JsonString(item, "text") ?? JsonString(item, "content") ?? JsonString(item, "utterance") ?? string.Empty;
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
            segments.Add(new NormalizedSegment(text.Trim(), JsonString(item, "speaker"), offsetMs, null));
        }

        if (segments.Count == 0)
        {
            var text = JsonString(doc.RootElement, "text") ?? JsonString(doc.RootElement, "transcript") ?? string.Empty;
            return SingleConversation(source, request, text, fallbackTitle);
        }

        return Response(source, $"Normalized {segments.Count} transcript segment(s).", [new NormalizedConversation(Clean(request.Title) ?? fallbackTitle, source, ParticipantNames(request), segments)]);
    }

    private static NormalizedImportResponse ParseTranscriptXml(string source, ImportRequest request, string xml, string fallbackTitle)
    {
        var segments = new List<NormalizedSegment>();
        foreach (Match match in TranscriptTextRegex().Matches(xml))
        {
            var encoded = match.Groups["text"].Value;
            var start = match.Groups["start"].Success ? match.Groups["start"].Value : "0";
            var text = System.Net.WebUtility.HtmlDecode(encoded).Trim();
            if (text.Length == 0) continue;
            var offsetMs = double.TryParse(start, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) ? (int)(seconds * 1000) : segments.Count * 1000;
            segments.Add(new NormalizedSegment(text, null, offsetMs, null));
        }

        if (segments.Count == 0) return SingleConversation(source, request, xml, fallbackTitle);
        return Response(source, $"Normalized {segments.Count} XML transcript segment(s).", [new NormalizedConversation(Clean(request.Title) ?? fallbackTitle, source, ParticipantNames(request), segments)]);
    }

    private static IEnumerable<Dictionary<string, string>> ParseCsv(string csv)
    {
        var lines = csv.Split('\n').Select(line => line.TrimEnd('\r')).Where(line => line.Length > 0).ToArray();
        if (lines.Length < 2) yield break;
        var headers = SplitCsvLine(lines[0]).Select(header => header.Trim()).ToArray();
        for (var i = 1; i < lines.Length; i++)
        {
            var values = SplitCsvLine(lines[i]).ToArray();
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var j = 0; j < headers.Length && j < values.Length; j++)
            {
                row[headers[j]] = values[j];
            }
            yield return row;
        }
    }

    private static IEnumerable<string> SplitCsvLine(string line)
    {
        var value = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (c == '"')
            {
                if (quoted && i + 1 < line.Length && line[i + 1] == '"')
                {
                    value.Append('"');
                    i++;
                }
                else
                {
                    quoted = !quoted;
                }
                continue;
            }

            if (c == ',' && !quoted)
            {
                yield return value.ToString();
                value.Clear();
                continue;
            }

            value.Append(c);
        }
        yield return value.ToString();
    }

    private static IEnumerable<JsonElement> EnumerateArray(JsonElement root, params string[] propertyNames)
    {
        if (root.ValueKind == JsonValueKind.Array) return root.EnumerateArray().ToArray();
        foreach (var propertyName in propertyNames)
        {
            if (root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.Array)
            {
                return property.EnumerateArray().ToArray();
            }
        }
        return [];
    }

    private static string? TelegramText(JsonElement message)
    {
        if (!message.TryGetProperty("text", out var text)) return JsonString(message, "content");
        if (text.ValueKind == JsonValueKind.String) return text.GetString();
        if (text.ValueKind != JsonValueKind.Array) return null;

        var builder = new StringBuilder();
        foreach (var item in text.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                builder.Append(item.GetString());
            }
            else if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("text", out var nested))
            {
                builder.Append(nested.GetString());
            }
        }
        return builder.ToString();
    }

    private static string? AuthorName(JsonElement message)
    {
        if (message.TryGetProperty("author", out var author))
        {
            if (author.ValueKind == JsonValueKind.String) return author.GetString();
            if (author.ValueKind == JsonValueKind.Object)
            {
                return JsonString(author, "username") ?? JsonString(author, "name") ?? JsonString(author, "global_name");
            }
        }
        return JsonString(message, "from") ?? JsonString(message, "sender") ?? JsonString(message, "username");
    }

    private static string? JsonString(JsonElement element, string property)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(property, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.ToString(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null
        };
    }

    private static string? FirstValue(Dictionary<string, string> row, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (row.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)) return value.Trim();
        }
        return null;
    }

    private static IReadOnlyList<string> ArtifactNames(ImportRequest request)
    {
        var originalFileName = Clean(request.OriginalFileName);
        return originalFileName is null ? [] : [originalFileName];
    }

    private static string? Clean(string? value)
    {
        var cleaned = value?.Trim();
        return string.IsNullOrWhiteSpace(cleaned) ? null : cleaned;
    }

    private static DateTimeOffset? TryParseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : null;
    }

    [GeneratedRegex(@"^\[?(?<date>\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}[^\]]*)\]?\s*-?\s*(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex WhatsAppLineRegex();

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();

    [GeneratedRegex(@"<text(?:[^>]*start=""(?<start>[^""]+)"")?[^>]*>(?<text>.*?)</text>", RegexOptions.Singleline)]
    private static partial Regex TranscriptTextRegex();
}
