using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Common parsing utilities shared across multiple parsers: text extraction, CSV parsing, JSON handling, date parsing.
/// Consolidates parsing logic previously scattered across ImportTextParsers.cs.
/// </summary>
public static partial class CommonParsing
{
    /// <summary>
    /// Creates a single-conversation response from request data.
    /// </summary>
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

    /// <summary>
    /// Creates a normalized import response from conversations.
    /// </summary>
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

    /// <summary>
    /// Extracts participant names from request (combined from request.ParticipantNames and metadata).
    /// </summary>
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

    /// <summary>
    /// Gets metadata value by key, or null if not found or empty.
    /// </summary>
    public static string? Metadata(ImportRequest request, string key)
    {
        if (request.Metadata is null) return null;
        return request.Metadata.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value : null;
    }

    /// <summary>
    /// Parses text lines using a regex pattern, consolidating line-based chat format handling.
    /// </summary>
    public static NormalizedImportResponse ParseTextLines(string source, ImportRequest request, Regex lineRegex, string? titleOverride = null)
    {
        var title = titleOverride ?? Clean(request.Title) ?? $"{CultureInfo.InvariantCulture.TextInfo.ToTitleCase(source)} export";
        var conversations = new List<NormalizedSegment>();
        var participants = ParticipantRegistry.FromRequest(request);
        NormalizedSegment? current = null;
        var text = EffectiveText(request);

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;

            var match = lineRegex.Match(line);
            if (match.Success)
            {
                if (current is not null) conversations.Add(current);
                var speaker = match.Groups["speaker"].Value.Trim();
                participants.TryAdd(speaker);

                var messageText = match.Groups["text"].Value.Trim();
                current = new SegmentBuilder()
                    .WithText(messageText)
                    .WithSpeaker(speaker)
                    .WithOffset(conversations.Count * 1000)
                    .WithTimestamp(TryParseDate(match.Groups["date"].Value))
                    .Build();
                continue;
            }

            if (current is null)
            {
                current = new SegmentBuilder()
                    .WithText(line)
                    .WithSpeaker(participants.ToUnsortedList().FirstOrDefault())
                    .WithOffset(conversations.Count * 1000)
                    .Build();
            }
            else
            {
                current = current with { Text = current.Text + "\n" + line };
            }
        }

        if (current is not null) conversations.Add(current);
        if (conversations.Count == 0)
        {
            return SingleConversation(source, request, text, title);
        }

        var conversation = new NormalizedConversation(title, source, participants.ToList(), conversations);
        return Response(source, $"Normalized {conversations.Count} {source} message(s).", [conversation]);
    }

    /// <summary>
    /// Gets text content from import request (handles base64 zip extraction).
    /// </summary>
    public static string EffectiveText(ImportRequest request, string fallback = "")
    {
        if (!string.IsNullOrWhiteSpace(request.Text))
        {
            return request.Text;
        }

        if (string.IsNullOrWhiteSpace(request.PayloadBase64))
        {
            return fallback;
        }

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(request.PayloadBase64);
        }
        catch (FormatException)
        {
            return fallback;
        }

        var mimeType = request.MimeType?.Trim().ToLowerInvariant();
        var fileName = request.OriginalFileName?.Trim().ToLowerInvariant();
        var isZip = mimeType == "application/zip" || fileName?.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) == true;
        if (isZip)
        {
            return ExtractTextFromZip(bytes) ?? fallback;
        }

        var decoded = Encoding.UTF8.GetString(bytes).Trim();
        return decoded.Length == 0 ? fallback : decoded;
    }

    /// <summary>
    /// Parses CSV data into rows of field dictionaries.
    /// </summary>
    public static IEnumerable<Dictionary<string, string>> ParseCsv(string csv)
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

    /// <summary>
    /// Gets a CSV field value by key, checking multiple possible field names.
    /// </summary>
    public static string? GetCsvField(Dictionary<string, string> row, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (row.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)) return value.Trim();
        }
        return null;
    }

    /// <summary>
    /// Enumerates JSON array, checking multiple possible property names for the array.
    /// </summary>
    public static IEnumerable<JsonElement> EnumerateArray(JsonElement root, params string[] propertyNames)
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

    /// <summary>
    /// Parses Unix epoch timestamp (in seconds) to DateTimeOffset.
    /// </summary>
    public static DateTimeOffset? ParseUnixEpoch(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)) return null;
        try
        {
            var milliseconds = (long)Math.Round(seconds * 1000);
            return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>
    /// Parses Unix epoch timestamp (in milliseconds) to DateTimeOffset.
    /// </summary>
    public static DateTimeOffset? ParseUnixEpochMilliseconds(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var milliseconds)) return null;
        try
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>
    /// Tries to parse date string with standard date formats.
    /// </summary>
    public static DateTimeOffset? TryParseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : null;
    }

    /// <summary>
    /// Strips HTML tags and decodes HTML entities.
    /// </summary>
    public static string StripHtml(string value)
    {
        if (value.IndexOf('<') < 0 || value.IndexOf('>') < 0)
        {
            return value;
        }

        var stripped = HtmlTagRegex().Replace(value, " ");
        var decoded = System.Net.WebUtility.HtmlDecode(stripped);
        return WhitespaceRegex().Replace(decoded, " ").Trim();
    }

    /// <summary>
    /// Cleans whitespace from string, returns null if empty after cleaning.
    /// </summary>
    public static string? Clean(string? value)
    {
        var cleaned = value?.Trim();
        return string.IsNullOrWhiteSpace(cleaned) ? null : cleaned;
    }

    /// <summary>
    /// Gets artifact names from import request original filename.
    /// </summary>
    public static IReadOnlyList<string> ArtifactNames(ImportRequest request)
    {
        var originalFileName = Clean(request.OriginalFileName);
        return originalFileName is null ? [] : [originalFileName];
    }

    private static string? ExtractTextFromZip(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes, writable: false);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
        var preferredEntries = archive.Entries
            .Where(entry => entry.Length > 0)
            .OrderBy(entry => RankEntry(entry.FullName))
            .ThenBy(entry => entry.FullName, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (preferredEntries.Length == 0)
        {
            return null;
        }

        foreach (var entry in preferredEntries)
        {
            using var entryStream = entry.Open();
            using var reader = new StreamReader(entryStream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: false);
            var content = reader.ReadToEnd().Trim();
            if (content.Length == 0)
            {
                continue;
            }

            return content;
        }

        return null;
    }

    private static int RankEntry(string fileName)
    {
        var lower = fileName.ToLowerInvariant();
        if (lower.EndsWith(".txt", StringComparison.Ordinal)) return 0;
        if (lower.EndsWith(".md", StringComparison.Ordinal)) return 1;
        if (lower.EndsWith(".csv", StringComparison.Ordinal)) return 2;
        if (lower.EndsWith(".json", StringComparison.Ordinal) || lower.EndsWith(".jsonl", StringComparison.Ordinal)) return 3;
        if (lower.EndsWith(".html", StringComparison.Ordinal) || lower.EndsWith(".htm", StringComparison.Ordinal)) return 4;
        if (lower.EndsWith(".xml", StringComparison.Ordinal)) return 5;
        return 10;
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

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex HtmlTagRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();
}
