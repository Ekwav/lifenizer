using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>One watch of one video as read from an export.</summary>
internal sealed record WatchEntry(string VideoId, string Title, string VideoUrl, string? Channel, string? ChannelUrl, DateTimeOffset? WatchedAt);

/// <summary>
/// Groups watch entries per video: ONE conversation per video, one segment per watch (segment time = watch time,
/// segment id = platform:videoId@unixSeconds) so repeated watches and re-imports of overlapping exports merge on the client.
/// </summary>
internal static class WatchHistoryBuilder
{
    public static NormalizedImportResponse Build(string source, string platform, IReadOnlyList<WatchEntry> entries, Dictionary<string, string> diagnostics)
    {
        var conversations = new List<NormalizedConversation>();
        var participants = new Dictionary<string, NormalizedParticipant>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in entries.GroupBy(entry => entry.VideoId, StringComparer.Ordinal))
        {
            var watches = group.OrderBy(e => e.WatchedAt ?? DateTimeOffset.MinValue).ToArray();
            var first = watches[0];
            var last = watches[^1];
            var best = watches.FirstOrDefault(e => !string.IsNullOrEmpty(e.Channel)) ?? last;
            var title = watches.Select(e => e.Title).LastOrDefault(t => !string.IsNullOrWhiteSpace(t)) ?? $"{PlatformName(platform)} video {group.Key}";
            var channel = best.Channel;
            var channelUrl = best.ChannelUrl;

            var segments = new List<NormalizedSegment>();
            var seen = new HashSet<string>();
            foreach (var watch in watches)
            {
                var id = $"{platform}:{group.Key}@" + (watch.WatchedAt is { } t ? t.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture) : "unknown");
                if (!seen.Add(id)) continue; // identical timestamp listed twice in the export
                var text = channel is null ? title : $"{title}\nChannel: {channel}";
                segments.Add(new NormalizedSegment(text, channel, 0, watch.WatchedAt, channelUrl is null && channel is null ? null : $"{platform}:{channelUrl ?? channel}", id));
            }

            string[] names = channel is null ? [] : [channel];
            string[]? identifiers = channel is null ? null : [$"{platform}:{channelUrl ?? channel}"];
            if (channel is not null)
                participants.TryAdd(channel!, new NormalizedParticipant(channel!, identifiers));

            var metadata = new Dictionary<string, string>
            {
                ["platform"] = platform,
                ["videoId"] = group.Key,
                ["videoUrl"] = first.VideoUrl,
                ["watchCount"] = segments.Count.ToString(CultureInfo.InvariantCulture),
                ["transcript"] = "none",
            };
            if (channel is not null) metadata["channel"] = channel;
            if (channelUrl is not null) metadata["channelUrl"] = channelUrl;
            if (last.WatchedAt is { } lastAt)
            {
                metadata["watchedAt"] = lastAt.ToString("o", CultureInfo.InvariantCulture);
                metadata["lastWatchedAt"] = lastAt.ToString("o", CultureInfo.InvariantCulture);
            }
            if (watches.FirstOrDefault(e => e.WatchedAt is not null)?.WatchedAt is { } firstAt)
                metadata["firstWatchedAt"] = firstAt.ToString("o", CultureInfo.InvariantCulture);

            conversations.Add(new NormalizedConversation(title, source, names, segments, null, metadata, identifiers, $"{platform}:{group.Key}", first.VideoUrl));
        }

        diagnostics["entries"] = entries.Count.ToString(CultureInfo.InvariantCulture);
        diagnostics["videos"] = conversations.Count.ToString(CultureInfo.InvariantCulture);
        return new NormalizedImportResponse(source, true,
            $"Normalized {conversations.Count} {source} video(s) from {entries.Count} watch(es).", conversations, participants.Values.ToArray(), diagnostics);
    }

    private static string PlatformName(string platform) => platform == "tiktok" ? "TikTok" : "YouTube";
}

/// <summary>Google Takeout YouTube watch-history.json / watch-history.html (any locale).</summary>
public sealed partial class YouTubeWatchHistoryParser : IImportParser
{
    public string Source => "youtube-watch-history";

    private static readonly string[] WatchedPrefixes =
        ["Watched ", "Angesehen: ", "Angesehen ", "Gekeken: ", "Visualizzato: ", "Visto: ", "Vu : ", "Vu: ", "Regardé : ", "Regardé: "];

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request).TrimStart('﻿').Trim();
        if (text.Length == 0) throw new InvalidOperationException("YouTube watch history import requires watch-history.json or watch-history.html content.");
        var diagnostics = new Dictionary<string, string>();
        var entries = new List<WatchEntry>();
        var skipped = 0;
        if (text.StartsWith('[') || text.StartsWith('{'))
        {
            using var doc = JsonDocument.Parse(text);
            foreach (var item in CommonParsing.EnumerateArray(doc.RootElement, "items", "history", "watchHistory"))
            {
                if (item.ValueKind != JsonValueKind.Object) { skipped++; continue; }
                var url = Str(item, "titleUrl");
                var rawTitle = Str(item, "title") ?? "";
                var id = url is null ? null : VideoId(url);
                if (id is null) { skipped++; continue; } // removed video, community post, ad ...
                string? channel = null, channelUrl = null;
                if (item.TryGetProperty("subtitles", out var subs) && subs.ValueKind == JsonValueKind.Array && subs.GetArrayLength() > 0 && subs[0].ValueKind == JsonValueKind.Object)
                {
                    channel = Str(subs[0], "name");
                    channelUrl = Str(subs[0], "url");
                }
                var time = Str(item, "time") is { } t && DateTimeOffset.TryParse(t, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed.ToUniversalTime() : (DateTimeOffset?)null;
                entries.Add(new WatchEntry(id, CleanTitle(rawTitle, id, url!), CanonicalUrl(id), channel, channelUrl, time));
            }
        }
        else
        {
            var unknownZones = 0;
            foreach (Match cell in CellRegex().Matches(text))
            {
                var html = cell.Groups[1].Value;
                var anchors = AnchorRegex().Matches(html);
                if (anchors.Count == 0) continue;
                var id = VideoId(System.Net.WebUtility.HtmlDecode(anchors[0].Groups[1].Value));
                if (id is null) { if (html.Contains("youtube.com", StringComparison.OrdinalIgnoreCase)) skipped++; continue; }
                var rawTitle = Plain(anchors[0].Groups[2].Value);
                var channel = anchors.Count > 1 ? Plain(anchors[1].Groups[2].Value) : null;
                var channelUrl = anchors.Count > 1 ? System.Net.WebUtility.HtmlDecode(anchors[1].Groups[1].Value) : null;
                var lastBr = html.LastIndexOf("<br", StringComparison.OrdinalIgnoreCase);
                DateTimeOffset? time = null;
                if (lastBr >= 0)
                {
                    var tail = Plain(html[(html.IndexOf('>', lastBr) + 1)..]);
                    time = ParseTakeoutDate(tail, out var known);
                    if (time is not null && !known) unknownZones++;
                }
                entries.Add(new WatchEntry(id, CleanTitle(rawTitle, id, anchors[0].Groups[1].Value), CanonicalUrl(id), channel is { Length: > 0 } ? channel : null, channelUrl, time));
            }
            if (unknownZones > 0) diagnostics["assumedUtcTimes"] = unknownZones.ToString(CultureInfo.InvariantCulture);
        }
        diagnostics["skippedWithoutVideoUrl"] = skipped.ToString(CultureInfo.InvariantCulture);
        return WatchHistoryBuilder.Build(Source, "youtube", entries, diagnostics);
    }

    private static string? Str(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()) ? value.GetString()!.Trim() : null;

    private static string CanonicalUrl(string id) => $"https://www.youtube.com/watch?v={id}";

    internal static string? VideoId(string url)
    {
        var match = VideoIdRegex().Match(url);
        return match.Success ? match.Groups["id"].Value : null;
    }

    private static string CleanTitle(string raw, string id, string url)
    {
        var title = raw.Trim();
        foreach (var prefix in WatchedPrefixes)
        {
            if (title.StartsWith(prefix, StringComparison.Ordinal)) { title = title[prefix.Length..].Trim(); break; }
        }
        // Removed videos carry the URL as their title.
        if (title.Length == 0 || title.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || title.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || title == url)
            return $"YouTube video {id}";
        return title;
    }

    private static string Plain(string html) => Regex.Replace(System.Net.WebUtility.HtmlDecode(Regex.Replace(html, "<[^>]+>", " ")), @"[\s  ]+", " ").Trim();

    private static readonly Dictionary<string, int> ZoneMinutes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["UTC"] = 0, ["GMT"] = 0, ["Z"] = 0, ["BST"] = 60, ["WET"] = 0, ["WEST"] = 60, ["CET"] = 60, ["MEZ"] = 60, ["CEST"] = 120, ["MESZ"] = 120,
        ["EET"] = 120, ["EEST"] = 180, ["MSK"] = 180, ["JST"] = 540, ["KST"] = 540, ["AEST"] = 600, ["AEDT"] = 660, ["NZST"] = 720, ["NZDT"] = 780,
        ["EST"] = -300, ["EDT"] = -240, ["CST"] = -360, ["CDT"] = -300, ["MST"] = -420, ["MDT"] = -360, ["PST"] = -480, ["PDT"] = -420,
    };

    private static readonly string[] DateFormats =
    [
        "MMM d, yyyy, h:mm:ss tt", "MMMM d, yyyy, h:mm:ss tt", "d MMM yyyy, HH:mm:ss", "d MMMM yyyy, HH:mm:ss", "dd.MM.yyyy, HH:mm:ss", "d.M.yyyy, HH:mm:ss",
        "yyyy-MM-dd, HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "d MMM yyyy, h:mm:ss tt", "MMM d, yyyy, HH:mm:ss", "d. MMM yyyy, HH:mm:ss", "d. MMMM yyyy, HH:mm:ss",
    ];

    /// <summary>Parses "Jan 2, 2024, 3:04:05 PM CET" style values; <paramref name="knownZone"/> is false when UTC had to be assumed.</summary>
    public static DateTimeOffset? ParseTakeoutDate(string value, out bool knownZone)
    {
        knownZone = false;
        var text = Regex.Replace(value, @"[\s  ]+", " ").Trim();
        if (text.Length == 0) return null;
        var offset = TimeSpan.Zero;
        var zone = Regex.Match(text, @"\s(?<z>(?:UTC|GMT)\s?[+-]\d{1,2}(?::?\d{2})?|[A-Z]{1,5})$");
        if (zone.Success)
        {
            var z = zone.Groups["z"].Value.Replace(" ", "");
            var numeric = Regex.Match(z, @"^(?:UTC|GMT)([+-])(\d{1,2})(?::?(\d{2}))?$");
            if (numeric.Success)
            {
                var minutes = int.Parse(numeric.Groups[2].Value, CultureInfo.InvariantCulture) * 60 + (numeric.Groups[3].Success ? int.Parse(numeric.Groups[3].Value, CultureInfo.InvariantCulture) : 0);
                offset = TimeSpan.FromMinutes(numeric.Groups[1].Value == "-" ? -minutes : minutes);
                knownZone = true;
                text = text[..zone.Index].Trim();
            }
            else if (ZoneMinutes.TryGetValue(z, out var zoneMinutes))
            {
                offset = TimeSpan.FromMinutes(zoneMinutes);
                knownZone = true;
                text = text[..zone.Index].Trim();
            }
        }
        foreach (var culture in new[] { CultureInfo.InvariantCulture, CultureInfo.GetCultureInfo("de-DE") })
        {
            if (DateTime.TryParseExact(text, DateFormats, culture, DateTimeStyles.None, out var local))
                return new DateTimeOffset(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), offset).ToUniversalTime();
        }
        return null;
    }

    [GeneratedRegex(@"<div[^>]*class=""[^""]*content-cell[^""]*""[^>]*>(.*?)</div>", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex CellRegex();

    [GeneratedRegex(@"<a\s[^>]*href=""([^""]*)""[^>]*>(.*?)</a>", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex AnchorRegex();

    [GeneratedRegex(@"(?:youtube\.com/(?:watch\?(?:[^#]*&)?v=|shorts/|embed/|live/)|youtu\.be/)(?<id>[A-Za-z0-9_-]{6,20})", RegexOptions.IgnoreCase)]
    private static partial Regex VideoIdRegex();
}

/// <summary>TikTok data export: user_data*.json (Activity > Video Browsing History > VideoList) or the .txt variant.</summary>
public sealed partial class TikTokWatchHistoryParser : IImportParser
{
    public string Source => "tiktok-watch-history";

    public NormalizedImportResponse Parse(ImportRequest request)
    {
        var text = CommonParsing.EffectiveText(request).TrimStart('﻿').Trim();
        if (text.Length == 0) throw new InvalidOperationException("TikTok watch history import requires user_data.json or Video Browsing History.txt content.");
        var raw = new List<(string? Date, string? Link)>();
        if (text.StartsWith('{') || text.StartsWith('['))
        {
            using var doc = JsonDocument.Parse(text);
            var list = FindVideoList(doc.RootElement, underBrowsing: false) ?? (doc.RootElement.ValueKind == JsonValueKind.Array ? doc.RootElement : (JsonElement?)null);
            if (list is { ValueKind: JsonValueKind.Array } array)
            {
                foreach (var item in array.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;
                    raw.Add((Prop(item, "Date"), Prop(item, "Link") ?? Prop(item, "VideoLink")));
                }
            }
        }
        else
        {
            string? date = null, link = null;
            foreach (var line in text.Split('\n'))
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith("Date:", StringComparison.OrdinalIgnoreCase))
                {
                    if (date is not null || link is not null) { raw.Add((date, link)); link = null; }
                    date = trimmed[5..].Trim();
                }
                else if (trimmed.StartsWith("Link:", StringComparison.OrdinalIgnoreCase))
                {
                    if (link is not null) { raw.Add((date, link)); date = null; }
                    link = trimmed[5..].Trim();
                }
            }
            if (date is not null || link is not null) raw.Add((date, link));
        }

        var entries = new List<WatchEntry>();
        var skipped = 0;
        foreach (var (date, link) in raw)
        {
            var match = link is null ? Match.Empty : VideoIdRegex().Match(link);
            if (!match.Success) { skipped++; continue; }
            var id = match.Groups["id"].Value;
            DateTimeOffset? time = date is not null && DateTimeOffset.TryParse(date, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed.ToUniversalTime() : null;
            entries.Add(new WatchEntry(id, $"TikTok video {id}", link!, null, null, time));
        }
        return WatchHistoryBuilder.Build(Source, "tiktok", entries, new Dictionary<string, string> { ["skippedWithoutVideoLink"] = skipped.ToString(CultureInfo.InvariantCulture) });
    }

    private static string? Prop(JsonElement item, string name)
    {
        foreach (var property in item.EnumerateObject())
            if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase) && property.Value.ValueKind == JsonValueKind.String) return property.Value.GetString();
        return null;
    }

    private static JsonElement? FindVideoList(JsonElement element, bool underBrowsing)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Name.Equals("VideoList", StringComparison.OrdinalIgnoreCase) && property.Value.ValueKind == JsonValueKind.Array && underBrowsing) return property.Value;
                var browsing = underBrowsing || property.Name.Contains("Browsing History", StringComparison.OrdinalIgnoreCase);
                if (FindVideoList(property.Value, browsing) is { } found) return found;
            }
        }
        return null;
    }

    [GeneratedRegex(@"/(?:video|v)/(?<id>\d{8,})|/(?<id>\d{15,})(?:[/?#]|$)", RegexOptions.IgnoreCase)]
    private static partial Regex VideoIdRegex();
}
