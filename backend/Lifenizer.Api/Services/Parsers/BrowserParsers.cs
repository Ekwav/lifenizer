using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Parser for browser history exports (JSON or CSV format).
/// </summary>
public sealed class BrowserHistoryParser : IImportParser
{
    public string Source => "browser-history";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var segments = new List<NormalizedSegment>();
        if (FormatDetector.IsJson(text))
        {
            ParseJson(text, segments);
        }
        else
        {
            ParseCsv(text, segments);
        }

        if (segments.Count == 0) return CommonParsing.SingleConversation(Source, request, text, "Browser history");
        return CommonParsing.Response(Source, $"Normalized {segments.Count} browser history visit(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "Browser history", Source, CommonParsing.ParticipantNames(request), segments)]);
    }

    private static void ParseJson(string json, List<NormalizedSegment> segments)
    {
        using var doc = JsonDocument.Parse(json);
        foreach (var item in CommonParsing.EnumerateArray(doc.RootElement, "history", "visits", "items"))
        {
            var title = JsonFieldExtractor.GetString(item, "title", "name") ?? "Visited page";
            var url = JsonFieldExtractor.GetString(item, "url", "href") ?? string.Empty;
            if (url.Length == 0 && title == "Visited page") continue;
            segments.Add(new SegmentBuilder()
                .WithText($"Visited {title}: {url}".Trim())
                .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(item, "time", "lastVisitTime", "date")))
                .WithAutoOffset(segments.Count)
                .Build());
        }
    }

    private static void ParseCsv(string csv, List<NormalizedSegment> segments)
    {
        foreach (var row in CommonParsing.ParseCsv(csv))
        {
            var title = CommonParsing.GetCsvField(row, "title", "name") ?? "Visited page";
            var url = CommonParsing.GetCsvField(row, "url", "href") ?? string.Empty;
            if (url.Length == 0 && title == "Visited page") continue;
            segments.Add(new SegmentBuilder()
                .WithText($"Visited {title}: {url}".Trim())
                .WithTimestamp(CommonParsing.TryParseDate(CommonParsing.GetCsvField(row, "time", "lastVisitTime", "date")))
                .WithAutoOffset(segments.Count)
                .Build());
        }
    }
}

/// <summary>
/// Parser for browser-captured web content (JSON or text format).
/// </summary>
public sealed class BrowserCaptureParser : IImportParser
{
    public string Source => "browser-capture";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var participants = CommonParsing.ParticipantNames(request);
        if (!FormatDetector.IsJson(text))
        {
            var url = CommonParsing.Metadata(request, "url");
            var title = CommonParsing.Metadata(request, "title") ?? request.Title ?? "Browser capture";
            var body = url is null ? text : $"{title}\nURL: {url}\n\n{text}";
            return CommonParsing.SingleConversation(Source, request, body, title);
        }

        using var doc = JsonDocument.Parse(text);
        var items = CommonParsing.EnumerateArray(doc.RootElement, "events", "captures", "items", "history");
        var segments = new List<NormalizedSegment>();
        foreach (var item in items)
        {
            var url = JsonFieldExtractor.GetString(item, "url", "href") ?? string.Empty;
            var title = JsonFieldExtractor.GetString(item, "title", "name") ?? "Consumed content";
            var content = JsonFieldExtractor.GetString(item, "content", "text", "summary") ?? string.Empty;
            if (url.Length == 0 && content.Length == 0) continue;
            var body = content.Length == 0
                ? $"{title}\nURL: {url}".Trim()
                : $"{title}\nURL: {url}\n\n{content}".Trim();
            segments.Add(new SegmentBuilder()
                .WithText(body)
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(item, "timestamp", "time", "date")))
                .Build());
        }

        if (segments.Count == 0)
        {
            return CommonParsing.SingleConversation(Source, request, text, "Browser capture");
        }

        return CommonParsing.Response(Source, $"Normalized {segments.Count} browser capture item(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "Browser capture", Source, participants, segments)]);
    }
}

/// <summary>
/// Parser for bookmarks exports (JSON from browser or HTML format).
/// </summary>
public sealed partial class BookmarksParser : IImportParser
{
    public string Source => "bookmarks";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var segments = new List<NormalizedSegment>();

        if (FormatDetector.IsJson(text))
        {
            ParseJson(text, segments);
        }
        else
        {
            ParseHtml(text, segments);
        }

        if (segments.Count == 0)
        {
            return CommonParsing.SingleConversation(Source, request, text, "Bookmarks");
        }

        return CommonParsing.Response(Source, $"Normalized {segments.Count} bookmark(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "Bookmarks", Source, CommonParsing.ParticipantNames(request), segments)]);
    }

    private static void ParseJson(string json, List<NormalizedSegment> segments)
    {
        using var doc = JsonDocument.Parse(json);
        var roots = new List<JsonElement>();
        if (doc.RootElement.TryGetProperty("roots", out var rootsObject) && rootsObject.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in rootsObject.EnumerateObject())
            {
                roots.Add(property.Value);
            }
        }
        else
        {
            roots.Add(doc.RootElement);
        }

        foreach (var root in roots)
        {
            foreach (var node in EnumerateBookmarkNodes(root))
            {
                var title = JsonFieldExtractor.GetString(node, "name", "title") ?? "Bookmark";
                var url = JsonFieldExtractor.GetString(node, "url", "href") ?? string.Empty;
                if (url.Length == 0) continue;
                segments.Add(new SegmentBuilder()
                    .WithText($"Bookmarked {title}: {url}")
                    .WithAutoOffset(segments.Count)
                    .WithTimestamp(CommonParsing.ParseUnixEpochMilliseconds(JsonFieldExtractor.GetString(node, "date_added")) ?? CommonParsing.ParseUnixEpoch(JsonFieldExtractor.GetString(node, "date_added")))
                    .Build());
            }
        }
    }

    private static void ParseHtml(string html, List<NormalizedSegment> segments)
    {
        foreach (Match match in BookmarkHtmlRegex().Matches(html))
        {
            var url = match.Groups["url"].Value.Trim();
            var title = System.Net.WebUtility.HtmlDecode(match.Groups["title"].Value).Trim();
            if (url.Length == 0) continue;
            segments.Add(new SegmentBuilder()
                .WithText($"Bookmarked {title}: {url}".Trim())
                .WithAutoOffset(segments.Count)
                .Build());
        }
    }

    private static IEnumerable<JsonElement> EnumerateBookmarkNodes(JsonElement node)
    {
        if (node.ValueKind != JsonValueKind.Object) yield break;
        var type = JsonFieldExtractor.GetString(node, "type");
        if (string.Equals(type, "url", StringComparison.OrdinalIgnoreCase)
            || node.TryGetProperty("url", out var urlProperty) && urlProperty.ValueKind == JsonValueKind.String)
        {
            yield return node;
            yield break;
        }

        if (node.TryGetProperty("children", out var children) && children.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in children.EnumerateArray())
            {
                foreach (var nested in EnumerateBookmarkNodes(child))
                {
                    yield return nested;
                }
            }
        }
    }

    [GeneratedRegex(@"<A[^>]*HREF=""(?<url>[^""]+)""[^>]*>(?<title>.*?)</A>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex BookmarkHtmlRegex();
}

/// <summary>
/// Parser for Google Search history exports (JSON or CSV format).
/// </summary>
public sealed class GoogleSearchHistoryParser : IImportParser
{
    public string Source => "google-search-history";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request);
        var segments = new List<NormalizedSegment>();

        if (FormatDetector.IsJson(text))
        {
            ParseJson(text, segments);
        }
        else if (text.Contains(','))
        {
            ParseCsv(text, segments);
        }

        if (segments.Count == 0)
        {
            return CommonParsing.SingleConversation(Source, request, text, "Google search history");
        }

        return CommonParsing.Response(Source, $"Normalized {segments.Count} Google search event(s).", [new NormalizedConversation(CommonParsing.Clean(request.Title) ?? "Google search history", Source, CommonParsing.ParticipantNames(request), segments)]);
    }

    private static void ParseJson(string json, List<NormalizedSegment> segments)
    {
        using var doc = JsonDocument.Parse(json);
        var items = CommonParsing.EnumerateArray(doc.RootElement, "events", "items", "history");
        foreach (var item in items)
        {
            var title = JsonFieldExtractor.GetString(item, "title", "query") ?? string.Empty;
            var url = JsonFieldExtractor.GetString(item, "titleUrl", "url") ?? string.Empty;
            var query = JsonFieldExtractor.GetString(item, "query") ?? ExtractGoogleQuery(url) ?? ExtractSearchedFor(title) ?? title;
            if (string.IsNullOrWhiteSpace(query) && string.IsNullOrWhiteSpace(url)) continue;
            segments.Add(new SegmentBuilder()
                .WithText($"Searched: {query}" + (url.Length > 0 ? $"\nURL: {url}" : string.Empty))
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(JsonFieldExtractor.GetString(item, "time", "time_usec", "date")))
                .Build());
        }
    }

    private static void ParseCsv(string csv, List<NormalizedSegment> segments)
    {
        foreach (var row in CommonParsing.ParseCsv(csv))
        {
            var url = CommonParsing.GetCsvField(row, "url", "titleUrl", "link") ?? string.Empty;
            var query = CommonParsing.GetCsvField(row, "query", "search_term", "term", "title") ?? ExtractGoogleQuery(url) ?? string.Empty;
            if (query.Length == 0 && url.Length == 0) continue;
            segments.Add(new SegmentBuilder()
                .WithText($"Searched: {query}" + (url.Length > 0 ? $"\nURL: {url}" : string.Empty))
                .WithAutoOffset(segments.Count)
                .WithTimestamp(CommonParsing.TryParseDate(CommonParsing.GetCsvField(row, "time", "date", "timestamp")))
                .Build());
        }
    }

    private static string? ExtractGoogleQuery(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return null;
        if (!uri.Host.Contains("google.", StringComparison.OrdinalIgnoreCase)) return null;
        var queryPart = uri.Query.TrimStart('?');
        foreach (var kvp in queryPart.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var equalsIndex = kvp.IndexOf('=');
            if (equalsIndex <= 0) continue;
            var key = kvp[..equalsIndex];
            if (!key.Equals("q", StringComparison.OrdinalIgnoreCase)) continue;
            return Uri.UnescapeDataString(kvp[(equalsIndex + 1)..]).Replace('+', ' ');
        }
        return null;
    }

    private static string? ExtractSearchedFor(string title)
    {
        var marker = "searched for";
        var index = title.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (index < 0) return null;
        return title[(index + marker.Length)..].Trim(' ', ':', '-', '"');
    }
}
