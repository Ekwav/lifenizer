using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

/// <summary>Typed failure of the built-in YouTube caption fetcher; mapped to an HTTP status by the import endpoint.</summary>
public sealed class YouTubeCaptionException(string code, int statusCode, string message, TimeSpan? retryAfter = null) : Exception(message)
{
    public string Code { get; } = code;
    public int StatusCode { get; } = statusCode;
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>
/// Best-effort built-in caption fetcher (public captions only, no login). Approach, as used by
/// youtube-transcript-api style tools: GET the watch page, read <c>captionTracks</c> from the embedded
/// <c>ytInitialPlayerResponse</c>, then GET the chosen track's <c>baseUrl</c> with <c>fmt=json3</c>. If the
/// page carries no tracks (or the timedtext response is empty, as happens when the web client needs a PO
/// token) it falls back once to the innertube <c>player</c> endpoint using the ANDROID client, which returns
/// tokenless track URLs. Both paths depend on undocumented YouTube behaviour and may break at any time.
/// </summary>
public sealed partial class YouTubeCaptionFetcher(IHttpClientFactory httpClientFactory, TimeProvider? timeProvider = null)
{
    public const string HttpClientName = "youtube-captions";
    public const string ConfigKeyBuiltIn = "Imports:YouTube:BuiltInCaptions";
    public const int MaxWatchPageBytes = 4 * 1024 * 1024;
    public const int MaxTranscriptBytes = 2 * 1024 * 1024;
    public const int MaxFetchesPerWindow = 30;
    public static readonly TimeSpan Window = TimeSpan.FromMinutes(10);
    private const string UserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
    private const string AndroidUserAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip";

    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly ConcurrentDictionary<Guid, UserState> users = new();

    private sealed class UserState
    {
        public readonly SemaphoreSlim Gate = new(1, 1);
        public readonly Queue<DateTimeOffset> Stamps = new();
    }

    public static bool IsBuiltInEnabled(IConfiguration configuration)
        => !bool.TryParse(configuration[ConfigKeyBuiltIn], out var enabled) || enabled;

    public static bool IsValidVideoId(string? id) => id is not null && VideoIdRegex().IsMatch(id);

    [GeneratedRegex("^[A-Za-z0-9_-]{11}$")]
    private static partial Regex VideoIdRegex();

    public async Task<NormalizedImportResponse> FetchAsync(Guid userId, ImportRequest request, string? videoId, CancellationToken cancellationToken)
    {
        if (!IsValidVideoId(videoId))
            throw new InvalidOperationException("YouTube videoId must be exactly 11 characters of A-Z, a-z, 0-9, '_' or '-'.");
        var language = ImportTextParsers.Metadata(request, "language");
        if (language is not null && !LanguageRegex().IsMatch(language)) language = null;

        var state = users.GetOrAdd(userId, _ => new UserState());
        if (!state.Gate.Wait(0, CancellationToken.None))
            throw new YouTubeCaptionException("rate_limited", 429, "Another YouTube caption fetch is already running for this vault.", TimeSpan.FromSeconds(5));
        try
        {
            ConsumeToken(state);
            return await FetchCoreAsync(request, videoId!, language, cancellationToken);
        }
        finally { state.Gate.Release(); }
    }

    private void ConsumeToken(UserState state)
    {
        var now = clock.GetUtcNow();
        lock (state.Stamps)
        {
            while (state.Stamps.Count > 0 && now - state.Stamps.Peek() >= Window) state.Stamps.Dequeue();
            if (state.Stamps.Count >= MaxFetchesPerWindow)
            {
                var wait = Window - (now - state.Stamps.Peek());
                throw new YouTubeCaptionException("rate_limited", 429, "Too many YouTube caption fetches; retry later.", wait < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : wait);
            }
            state.Stamps.Enqueue(now);
        }
        if (users.Count > 1000)
            foreach (var (key, s) in users)
                if (s.Gate.CurrentCount == 1 && Idle(s, now)) users.TryRemove(key, out _);
    }

    private static bool Idle(UserState s, DateTimeOffset now)
    {
        lock (s.Stamps) return s.Stamps.Count == 0 || now - s.Stamps.Peek() >= Window && now - s.Stamps.Last() >= Window;
    }

    private async Task<NormalizedImportResponse> FetchCoreAsync(ImportRequest request, string videoId, string? language, CancellationToken ct)
    {
        var page = await LoadWatchPageAsync(videoId, ct);
        using var player = ExtractPlayerResponse(page);
        CheckPlayability(player?.RootElement);

        var tracks = ReadTracks(player?.RootElement);
        string? json3 = null;
        var title = player is null ? null : TitleOf(player.RootElement);
        if (tracks.Count > 0) json3 = await TryFetchTrackAsync(Pick(tracks, language), ct);
        if (string.IsNullOrWhiteSpace(json3))
        {
            // Fallback: innertube ANDROID player (tokenless caption URLs).
            using var android = await TryAndroidPlayerAsync(videoId, page, ct);
            if (android is not null)
            {
                CheckPlayability(android.RootElement);
                title ??= TitleOf(android.RootElement);
                var androidTracks = ReadTracks(android.RootElement);
                if (androidTracks.Count > 0)
                {
                    tracks = androidTracks;
                    json3 = await TryFetchTrackAsync(Pick(tracks, language), ct);
                }
            }
        }
        if (tracks.Count == 0 || string.IsNullOrWhiteSpace(json3))
            throw new YouTubeCaptionException("transcript_unavailable", 404, "This video has no public captions available.");

        var chosen = Pick(tracks, language);
        var segments = MapJson3(json3);
        if (segments.Count == 0)
            throw new YouTubeCaptionException("transcript_unavailable", 404, "The caption track contained no text.");

        var kind = chosen.IsAsr ? "asr" : "manual";
        var metadata = new Dictionary<string, string>
        {
            ["videoId"] = videoId,
            ["videoUrl"] = $"https://www.youtube.com/watch?v={videoId}",
            ["language"] = chosen.Language,
            ["kind"] = kind,
            ["transcriptSource"] = "youtube-captions"
        };
        var conversation = new NormalizedConversation(
            CommonParsing.Clean(request.Title) ?? CommonParsing.Clean(title) ?? "YouTube transcript",
            "youtube-transcript", CommonParsing.ParticipantNames(request), segments, Metadata: metadata,
            SourceUrl: metadata["videoUrl"]);
        return ImportTextParsers.Response("youtube-transcript", $"Fetched and normalized {segments.Count} YouTube caption segment(s) ({kind}, {chosen.Language}).", [conversation]);
    }

    // ---- watch page -------------------------------------------------------------------------

    private async Task<string> LoadWatchPageAsync(string videoId, CancellationToken ct)
    {
        var url = new Uri($"https://www.youtube.com/watch?v={videoId}&hl=en&has_verified=1");
        var cookies = new[] { "CONSENT=YES+cb", "CONSENT=YES+cb; SOCS=CAI" };
        string body = "";
        for (var attempt = 0; attempt < cookies.Length; attempt++)
        {
            using var message = new HttpRequestMessage(HttpMethod.Get, url);
            message.Headers.TryAddWithoutValidation("Cookie", cookies[attempt]);
            message.Headers.TryAddWithoutValidation("Accept-Language", "en-US,en;q=0.9");
            var (status, text, redirectedToConsent) = await SendCappedAsync(message, MaxWatchPageBytes, ct);
            if (redirectedToConsent || IsConsentPage(text, status)) { body = text; continue; }
            ThrowForStatus(status, text);
            return text;
        }
        throw new YouTubeCaptionException("provider_blocked", 429, "YouTube kept returning a consent page.", TimeSpan.FromMinutes(5));
    }

    private static bool IsConsentPage(string body, int status)
        => status == 200 && !body.Contains("ytInitialPlayerResponse", StringComparison.Ordinal)
           && (body.Contains("consent.youtube.com", StringComparison.OrdinalIgnoreCase) || body.Contains("consent.google.com", StringComparison.OrdinalIgnoreCase));

    private static void ThrowForStatus(int status, string body)
    {
        if (status == 429 || status == 403 || body.Contains("/sorry/", StringComparison.Ordinal) || body.Contains("unusual traffic", StringComparison.OrdinalIgnoreCase))
            throw new YouTubeCaptionException("provider_blocked", 429, "YouTube is rate limiting or blocking this server; retry later.", TimeSpan.FromMinutes(5));
        if (status == 404 || status == 410)
            throw new YouTubeCaptionException("video_unavailable", 404, "The YouTube video does not exist or is unavailable.");
        if (status < 200 || status > 299)
            throw new YouTubeCaptionException("provider_error", 502, $"YouTube answered with HTTP {status}.");
    }

    private static JsonDocument? ExtractPlayerResponse(string html)
    {
        foreach (var marker in new[] { "var ytInitialPlayerResponse = ", "ytInitialPlayerResponse = ", "ytInitialPlayerResponse\":" })
        {
            var at = html.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) continue;
            var start = html.IndexOf('{', at + marker.Length - 1);
            if (start < 0 || start > at + marker.Length + 4) continue;
            var end = FindObjectEnd(html, start);
            if (end < 0) continue;
            try { return JsonDocument.Parse(html.AsMemory(start, end - start + 1)); }
            catch (JsonException) { }
        }
        return null;
    }

    private static int FindObjectEnd(string s, int start)
    {
        var depth = 0; var inString = false;
        for (var i = start; i < s.Length; i++)
        {
            var c = s[i];
            if (inString) { if (c == '\\') i++; else if (c == '"') inString = false; continue; }
            if (c == '"') inString = true;
            else if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return i;
        }
        return -1;
    }

    private static void CheckPlayability(JsonElement? root)
    {
        if (root is not { ValueKind: JsonValueKind.Object } r || !r.TryGetProperty("playabilityStatus", out var ps)) return;
        var status = ps.TryGetProperty("status", out var s) ? s.GetString() : null;
        var reason = ps.TryGetProperty("reason", out var rs) && rs.ValueKind == JsonValueKind.String ? rs.GetString() : "";
        if (status is null or "OK") return;
        if (reason!.Contains("not a bot", StringComparison.OrdinalIgnoreCase) || reason.Contains("unusual traffic", StringComparison.OrdinalIgnoreCase))
            throw new YouTubeCaptionException("provider_blocked", 429, "YouTube asked this server to prove it is not a bot; retry later.", TimeSpan.FromMinutes(5));
        // LOGIN_REQUIRED (private/age-restricted), UNPLAYABLE, ERROR (removed/unknown), LIVE_STREAM_OFFLINE ...
        throw new YouTubeCaptionException("video_unavailable", 404, $"The YouTube video is not available ({status}).");
    }

    private static string? TitleOf(JsonElement root)
        => root.TryGetProperty("videoDetails", out var d) && d.TryGetProperty("title", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;

    // ---- tracks -----------------------------------------------------------------------------

    private sealed record Track(string BaseUrl, string Language, bool IsAsr);

    private static List<Track> ReadTracks(JsonElement? root)
    {
        var list = new List<Track>();
        if (root is not { ValueKind: JsonValueKind.Object } r
            || !r.TryGetProperty("captions", out var caps)
            || !caps.TryGetProperty("playerCaptionsTracklistRenderer", out var renderer)
            || !renderer.TryGetProperty("captionTracks", out var tracks)
            || tracks.ValueKind != JsonValueKind.Array) return list;
        foreach (var t in tracks.EnumerateArray())
        {
            var url = t.TryGetProperty("baseUrl", out var b) ? b.GetString() : null;
            if (string.IsNullOrWhiteSpace(url)) continue;
            var lang = t.TryGetProperty("languageCode", out var l) ? l.GetString() ?? "" : "";
            var asr = t.TryGetProperty("kind", out var k) && k.GetString() == "asr";
            list.Add(new Track(url, lang, asr));
        }
        return list;
    }

    private static bool LangMatches(string code, string wanted)
        => code.Equals(wanted, StringComparison.OrdinalIgnoreCase)
           || code.StartsWith(wanted + "-", StringComparison.OrdinalIgnoreCase)
           || wanted.StartsWith(code + "-", StringComparison.OrdinalIgnoreCase);

    private static Track Pick(List<Track> tracks, string? language)
    {
        if (language is not null)
        {
            var wanted = tracks.Where(t => LangMatches(t.Language, language)).ToList();
            if (wanted.Count > 0) return wanted.OrderBy(t => t.IsAsr).First();
        }
        var manual = tracks.Where(t => !t.IsAsr).ToList();
        foreach (var preferred in new[] { "de", "en" })
            if (manual.FirstOrDefault(t => LangMatches(t.Language, preferred)) is { } hit) return hit;
        return manual.FirstOrDefault() ?? tracks.First();
    }

    private async Task<string?> TryFetchTrackAsync(Track track, CancellationToken ct)
    {
        if (!Uri.TryCreate(track.BaseUrl, UriKind.Absolute, out var uri) || !IsAllowedHost(uri))
            return null;
        var builder = new UriBuilder(uri);
        var query = Regex.Replace(builder.Query.TrimStart('?'), "(^|&)fmt=[^&]*", "").TrimStart('&');
        builder.Query = (query.Length > 0 ? query + "&" : "") + "fmt=json3";
        using var message = new HttpRequestMessage(HttpMethod.Get, builder.Uri);
        message.Headers.TryAddWithoutValidation("Cookie", "CONSENT=YES+cb");
        var (status, text, _) = await SendCappedAsync(message, MaxTranscriptBytes, ct);
        if (status == 429) throw new YouTubeCaptionException("provider_blocked", 429, "YouTube rate limited the caption download; retry later.", TimeSpan.FromMinutes(5));
        return status is >= 200 and <= 299 ? text : null;
    }

    private async Task<JsonDocument?> TryAndroidPlayerAsync(string videoId, string page, CancellationToken ct)
    {
        var key = InnertubeKeyRegex().Match(page) is { Success: true } m ? m.Groups[1].Value : null;
        if (key is null) return null;
        var payload = JsonSerializer.Serialize(new
        {
            context = new { client = new { clientName = "ANDROID", clientVersion = "20.10.38", androidSdkVersion = 34, hl = "en" } },
            videoId
        });
        using var message = new HttpRequestMessage(HttpMethod.Post, $"https://www.youtube.com/youtubei/v1/player?key={Uri.EscapeDataString(key)}&prettyPrint=false")
        {
            Content = new StringContent(payload, Encoding.UTF8, "application/json")
        };
        message.Headers.TryAddWithoutValidation("User-Agent", AndroidUserAgent);
        var (status, text, _) = await SendCappedAsync(message, MaxWatchPageBytes, ct);
        if (status is < 200 or > 299) return null;
        try { return JsonDocument.Parse(text); } catch (JsonException) { return null; }
    }

    [GeneratedRegex("\"INNERTUBE_API_KEY\"\\s*:\\s*\"([A-Za-z0-9_-]{20,60})\"")]
    private static partial Regex InnertubeKeyRegex();

    [GeneratedRegex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")]
    private static partial Regex LanguageRegex();

    // ---- transcript mapping -----------------------------------------------------------------

    internal static List<NormalizedSegment> MapJson3(string json)
    {
        var segments = new List<NormalizedSegment>();
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json); }
        catch (JsonException) { return segments; }
        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("events", out var events) || events.ValueKind != JsonValueKind.Array) return segments;
            foreach (var e in events.EnumerateArray())
            {
                if (!e.TryGetProperty("segs", out var segs) || segs.ValueKind != JsonValueKind.Array) continue;
                var sb = new StringBuilder();
                foreach (var s in segs.EnumerateArray())
                    if (s.TryGetProperty("utf8", out var u) && u.ValueKind == JsonValueKind.String) sb.Append(u.GetString());
                var text = System.Net.WebUtility.HtmlDecode(sb.ToString().Replace('\n', ' ')).Trim();
                if (text.Length == 0) continue;
                var start = e.TryGetProperty("tStartMs", out var ts) && ts.TryGetInt64(out var tsv) ? tsv : 0;
                var dur = e.TryGetProperty("dDurationMs", out var d) && d.TryGetInt64(out var dv) ? dv : -1;
                if (start < 0 || start > int.MaxValue) continue;
                int? end = dur >= 0 && start + dur <= int.MaxValue ? (int)(start + dur) : null;
                segments.Add(new NormalizedSegment(text, null, (int)start, null, EndMs: end));
            }
        }
        return segments;
    }

    // ---- HTTP -------------------------------------------------------------------------------

    internal static bool IsAllowedHost(Uri uri)
        => uri.Scheme == Uri.UriSchemeHttps && uri.UserInfo.Length == 0
           && (HostIs(uri.Host, "youtube.com") || HostIs(uri.Host, "googlevideo.com"));

    private static bool HostIs(string host, string domain)
        => host.Equals(domain, StringComparison.OrdinalIgnoreCase) || host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase);

    /// <summary>Sends the request, follows up to 3 redirects within youtube.com/googlevideo.com only and reads at most <paramref name="cap"/> bytes.</summary>
    private async Task<(int Status, string Body, bool ConsentRedirect)> SendCappedAsync(HttpRequestMessage first, int cap, CancellationToken ct)
    {
        var client = httpClientFactory.CreateClient(HttpClientName);
        var request = first;
        for (var hop = 0; ; hop++)
        {
            if (!IsAllowedHost(request.RequestUri!))
                throw new YouTubeCaptionException("provider_error", 502, "Refusing to contact a non-YouTube host.");
            if (!request.Headers.Contains("User-Agent")) request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            HttpResponseMessage response;
            try { response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct); }
            catch (HttpRequestException) { throw new YouTubeCaptionException("provider_error", 502, "Could not reach YouTube."); }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new YouTubeCaptionException("provider_error", 504, "YouTube did not answer in time."); }
            using (response)
            {
                var code = (int)response.StatusCode;
                if (code is >= 300 and < 400 && response.Headers.Location is { } location)
                {
                    var target = location.IsAbsoluteUri ? location : new Uri(request.RequestUri!, location);
                    if (target.Host.StartsWith("consent.", StringComparison.OrdinalIgnoreCase)) return (code, "", true);
                    if (hop >= 3 || !IsAllowedHost(target))
                        throw new YouTubeCaptionException("provider_error", 502, "YouTube redirected outside youtube.com; refusing to follow.");
                    var next = new HttpRequestMessage(HttpMethod.Get, target);
                    foreach (var h in request.Headers) next.Headers.TryAddWithoutValidation(h.Key, h.Value);
                    request = next;
                    continue;
                }
                if (response.Content.Headers.ContentLength > cap)
                    throw new YouTubeCaptionException("response_too_large", 502, $"YouTube response exceeds {cap / 1024 / 1024} MiB.");
                await using var stream = await response.Content.ReadAsStreamAsync(ct);
                using var buffer = new MemoryStream();
                var chunk = new byte[81920];
                int read;
                while ((read = await stream.ReadAsync(chunk, ct)) != 0)
                {
                    if (buffer.Length + read > cap)
                        throw new YouTubeCaptionException("response_too_large", 502, $"YouTube response exceeds {cap / 1024 / 1024} MiB.");
                    buffer.Write(chunk, 0, read);
                }
                return (code, Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length), false);
            }
        }
    }
}
