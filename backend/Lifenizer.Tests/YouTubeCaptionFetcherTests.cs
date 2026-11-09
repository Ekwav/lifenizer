using System.Net;
using System.Net.Http.Json;
using System.Text;
using Lifenizer.Api.Services;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class YouTubeCaptionFetcherTests
{
    private const string VideoId = "dQw4w9WgXcQ";
    private static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "MockData", "youtube", name));

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Task.FromResult(respond(request));
        }
    }

    private sealed class StubFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private sealed class FakeClock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static HttpResponseMessage Text(string body, HttpStatusCode status = HttpStatusCode.OK)
        => new(status) { Content = new StringContent(body, Encoding.UTF8, "text/html") };

    private static HttpResponseMessage Happy(HttpRequestMessage r)
        => r.RequestUri!.AbsolutePath == "/watch" ? Text(Fixture("watch-page.html")) : Text(Fixture("transcript.json3"));

    private static (YouTubeCaptionFetcher Fetcher, StubHandler Handler) Create(Func<HttpRequestMessage, HttpResponseMessage>? respond = null, TimeProvider? clock = null)
    {
        var handler = new StubHandler(respond ?? Happy);
        return (new YouTubeCaptionFetcher(new StubFactory(handler), clock), handler);
    }

    private static ImportRequest Req(string? language = null, string? title = null)
        => new(Title: title, Metadata: language is null ? null : new Dictionary<string, string> { ["language"] = language });

    [Test]
    public async Task PrefersManualGermanOverAsrEnglishAndMapsSegments()
    {
        var (fetcher, handler) = Create();
        var result = await fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default);

        var conversation = result.Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(result.Source, Is.EqualTo("youtube-transcript"));
            Assert.That(conversation.Metadata!["language"], Is.EqualTo("de"));
            Assert.That(conversation.Metadata["kind"], Is.EqualTo("manual"));
            Assert.That(conversation.Metadata["transcriptSource"], Is.EqualTo("youtube-captions"));
            Assert.That(conversation.Metadata["videoId"], Is.EqualTo(VideoId));
            Assert.That(conversation.Metadata["videoUrl"], Is.EqualTo($"https://www.youtube.com/watch?v={VideoId}"));
            Assert.That(conversation.Title, Is.EqualTo("Brace } test \" title"));
            Assert.That(conversation.Segments.Select(s => (s.OffsetMs, s.EndMs, s.Text)), Is.EqualTo(new (int, int?, string)[]
            {
                (500, 2500, "Tom & Jerry 'quoted'"),
                (3000, 5500, "second line")
            }));
            var track = handler.Requests.Last().RequestUri!;
            Assert.That(track.Query, Does.Contain("lang=de").And.Contain("fmt=json3").And.Not.Contain("srv3"));
            Assert.That(string.Join(" ", handler.Requests[0].Headers.GetValues("User-Agent")), Does.Contain("Mozilla"));
            Assert.That(handler.Requests[0].Headers.GetValues("Cookie").Single(), Does.Contain("CONSENT=YES+"));
        });
    }

    [Test]
    public async Task RequestedLanguageWinsAndRequestTitleIsKept()
    {
        var (fetcher, handler) = Create();
        var result = await fetcher.FetchAsync(Guid.NewGuid(), Req("en", "My title"), VideoId, default);
        var conversation = result.Conversations.Single();
        Assert.That(conversation.Metadata!["language"], Is.EqualTo("en"));
        Assert.That(conversation.Metadata["kind"], Is.EqualTo("asr"));
        Assert.That(conversation.Title, Is.EqualTo("My title"));
        Assert.That(handler.Requests.Last().RequestUri!.Query, Does.Contain("lang=en"));
    }

    [Test]
    public async Task FallsBackToAsrWhenOnlyAsrExists()
    {
        var page = Fixture("watch-page.html").Replace("{\"baseUrl\":\"https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=de&fmt=srv3\",\"name\":{\"simpleText\":\"German\"},\"languageCode\":\"de\"}", "");
        page = page.Replace("\"kind\":\"asr\"},]", "\"kind\":\"asr\"}]");
        var (fetcher, _) = Create(r => r.RequestUri!.AbsolutePath == "/watch" ? Text(page) : Text(Fixture("transcript.json3")));
        var result = await fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default);
        Assert.That(result.Conversations.Single().Metadata!["kind"], Is.EqualTo("asr"));
    }

    [Test]
    public void NoCaptionsReportsTranscriptUnavailable()
    {
        var page = "<html><script>var ytInitialPlayerResponse = {\"playabilityStatus\":{\"status\":\"OK\"},\"videoDetails\":{\"title\":\"x\"}};</script></html>";
        var (fetcher, _) = Create(_ => Text(page));
        var ex = Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default));
        Assert.That(ex!.Code, Is.EqualTo("transcript_unavailable"));
        Assert.That(ex.StatusCode, Is.EqualTo(404));
    }

    [Test]
    public void PrivateVideoReportsVideoUnavailable()
    {
        var page = "<script>var ytInitialPlayerResponse = {\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"This video is private\"}};</script>";
        var (fetcher, _) = Create(_ => Text(page));
        var ex = Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default));
        Assert.That(ex!.Code, Is.EqualTo("video_unavailable"));
    }

    [Test]
    public void BotCheckOrHttp429ReportsProviderBlocked()
    {
        var (blockedPage, _) = Create(_ => Text("<script>var ytInitialPlayerResponse = {\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"Sign in to confirm you're not a bot\"}};</script>"));
        Assert.That(Assert.ThrowsAsync<YouTubeCaptionException>(() => blockedPage.FetchAsync(Guid.NewGuid(), Req(), VideoId, default))!.Code, Is.EqualTo("provider_blocked"));
        var (tooMany, _) = Create(_ => Text("slow down", HttpStatusCode.TooManyRequests));
        var ex = Assert.ThrowsAsync<YouTubeCaptionException>(() => tooMany.FetchAsync(Guid.NewGuid(), Req(), VideoId, default))!;
        Assert.That(ex.Code, Is.EqualTo("provider_blocked"));
        Assert.That(ex.StatusCode, Is.EqualTo(429));
    }

    [Test]
    public async Task ConsentInterstitialIsRetriedWithConsentCookies()
    {
        var calls = 0;
        var (fetcher, handler) = Create(r =>
        {
            if (r.RequestUri!.AbsolutePath != "/watch") return Text(Fixture("transcript.json3"));
            return ++calls == 1
                ? Text("<html><form action=\"https://consent.youtube.com/save\"></form></html>")
                : Text(Fixture("watch-page.html"));
        });
        var result = await fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default);
        var watchRequests = handler.Requests.Where(r => r.RequestUri!.AbsolutePath == "/watch").ToList();
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations, Has.Count.EqualTo(1));
            Assert.That(watchRequests, Has.Count.EqualTo(2));
            Assert.That(watchRequests[1].Headers.GetValues("Cookie").Single(), Does.Contain("SOCS=").And.Contain("CONSENT=YES+"));
        });
    }

    [Test]
    public void ConsentRedirectThatNeverClearsIsReportedAsBlocked()
    {
        var (fetcher, _) = Create(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.Found);
            response.Headers.Location = new Uri("https://consent.youtube.com/m?continue=x");
            return response;
        });
        Assert.That(Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default))!.Code, Is.EqualTo("provider_blocked"));
    }

    [Test]
    public void RedirectOutsideYouTubeIsRefused()
    {
        var (fetcher, handler) = Create(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.Found);
            response.Headers.Location = new Uri("https://evil.example/steal");
            return response;
        });
        var ex = Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default))!;
        Assert.That(ex.Code, Is.EqualTo("provider_error"));
        Assert.That(handler.Requests, Has.Count.EqualTo(1));
    }

    [Test]
    public void OversizeWatchPageIsRejectedWhileStreaming()
    {
        var (fetcher, _) = Create(_ => Text(new string('a', YouTubeCaptionFetcher.MaxWatchPageBytes + 10)));
        Assert.That(Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default))!.Code, Is.EqualTo("response_too_large"));
    }

    [Test]
    public void OversizeTranscriptIsRejected()
    {
        var (fetcher, _) = Create(r => r.RequestUri!.AbsolutePath == "/watch" ? Text(Fixture("watch-page.html")) : Text(new string('a', YouTubeCaptionFetcher.MaxTranscriptBytes + 10)));
        Assert.That(Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default))!.Code, Is.EqualTo("response_too_large"));
    }

    [TestCase(null)]
    [TestCase("")]
    [TestCase("short")]
    [TestCase("dQw4w9WgXcQx")]
    [TestCase("dQw4w9WgX/Q")]
    [TestCase("dQw4w9WgX?Q")]
    public void InvalidVideoIdIsRejectedWithoutNetwork(string? id)
    {
        var (fetcher, handler) = Create();
        Assert.ThrowsAsync<InvalidOperationException>(() => fetcher.FetchAsync(Guid.NewGuid(), Req(), id, default));
        Assert.That(handler.Requests, Is.Empty);
    }

    [Test]
    public async Task RateLimitsPerUserWithRetryAfterAndRecovers()
    {
        var clock = new FakeClock(DateTimeOffset.UtcNow);
        var (fetcher, _) = Create(clock: clock);
        var user = Guid.NewGuid();
        for (var i = 0; i < YouTubeCaptionFetcher.MaxFetchesPerWindow; i++)
            await fetcher.FetchAsync(user, Req(), VideoId, default);

        var ex = Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(user, Req(), VideoId, default))!;
        Assert.Multiple(() =>
        {
            Assert.That(ex.StatusCode, Is.EqualTo(429));
            Assert.That(ex.Code, Is.EqualTo("rate_limited"));
            Assert.That(ex.RetryAfter, Is.Not.Null.And.GreaterThan(TimeSpan.Zero));
        });
        await fetcher.FetchAsync(Guid.NewGuid(), Req(), VideoId, default); // other vault unaffected
        clock.Now += YouTubeCaptionFetcher.Window + TimeSpan.FromSeconds(1);
        await fetcher.FetchAsync(user, Req(), VideoId, default);
    }

    [Test]
    public async Task OnlyOneFetchAtATimePerUser()
    {
        var release = new TaskCompletionSource();
        var entered = new TaskCompletionSource();
        var handler = new SlowHandler(entered, release.Task);
        var fetcher = new YouTubeCaptionFetcher(new StubFactory(handler));
        var user = Guid.NewGuid();
        var first = fetcher.FetchAsync(user, Req(), VideoId, default);
        await entered.Task;
        var ex = Assert.ThrowsAsync<YouTubeCaptionException>(() => fetcher.FetchAsync(user, Req(), VideoId, default))!;
        Assert.That(ex.StatusCode, Is.EqualTo(429));
        release.SetResult();
        await first;
    }

    private sealed class SlowHandler(TaskCompletionSource entered, Task gate) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            entered.TrySetResult();
            await gate;
            return Happy(request);
        }
    }

    [Test]
    public async Task ConfiguredBaseUrlTakesPrecedenceOverBuiltInFetcher()
    {
        await using var mockApi = new MockHttpServer(request => request.Url!.AbsolutePath == $"/api/transcripts/{VideoId}"
            ? new MockHttpResponse("application/json", "{\"segments\":[{\"text\":\"from service\",\"start\":1.0}]}")
            : new MockHttpResponse("text/plain", "nf", 404));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Imports:YouTube:BaseUrl"] = mockApi.Url,
            ["Imports:YouTube:BuiltInCaptions"] = "true"
        });
        using var client = await ImportIntegrationTests.AuthenticatedClientForTestsAsync(factory, "alice@example.test");
        var response = await client.PostAsJsonAsync("/api/imports/youtube-transcript", new ImportRequest(Title: "t", Metadata: new Dictionary<string, string> { ["videoId"] = VideoId }));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK), body);
        Assert.That(body, Does.Contain("from service"));
        Assert.That(mockApi.RequestCount, Is.EqualTo(1));
    }

    [Test]
    public async Task EndpointRejectsInvalidIdAndCapabilitiesReflectProviderState()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await ImportIntegrationTests.AuthenticatedClientForTestsAsync(factory, "alice@example.test");
        var response = await client.PostAsJsonAsync("/api/imports/youtube-transcript", new ImportRequest(Metadata: new Dictionary<string, string> { ["videoId"] = "../etc/passwd" }));
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));

        var caps = await client.GetFromJsonAsync<ImportCapability[]>("/api/imports/capabilities");
        Assert.That(caps!.Single(c => c.Source == "youtube-transcript").Status, Does.Contain("Remote mode: available (built-in"));

        await using var disabled = new LifenizerApiFactory(new Dictionary<string, string?> { ["Imports:YouTube:BuiltInCaptions"] = "false" });
        using var c2 = disabled.CreateClient();
        var caps2 = await c2.GetFromJsonAsync<ImportCapability[]>("/api/imports/capabilities");
        Assert.That(caps2!.Single(c => c.Source == "youtube-transcript").Status, Does.Contain("Remote mode: unavailable"));
    }
}
