using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;
using Microsoft.AspNetCore.WebUtilities;

namespace Lifenizer.Tests;

/// <summary>
/// Covers the audio import path against the self-hosted whisper-trained service
/// (onerahmet/openai-whisper-asr-webservice). All HTTP is stubbed via an in-process
/// loopback listener (MockHttpServer) -- never the real network.
/// </summary>
public sealed class WhisperTranscriptionTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task AudioImport_SendsMultipartRequestToAsrWithoutLanguage()
    {
        CapturedRequest? captured = null;
        var audioBytes = Encoding.UTF8.GetBytes("fake wav bytes for request-shape assertions");

        await using var mockApi = new MockHttpServer(request =>
        {
            captured = CapturedRequest.Capture(request);
            return Json(new { text = "hello world", segments = Array.Empty<object>() });
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-shape@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            OriginalFileName: "note.wav",
            MimeType: "audio/wav",
            PayloadBase64: Convert.ToBase64String(audioBytes)), JsonOptions);
        response.EnsureSuccessStatusCode();

        Assert.That(captured, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(captured!.Path, Is.EqualTo("/asr"));
            Assert.That(captured.Query["task"], Is.EqualTo("transcribe"));
            Assert.That(captured.Query["output"], Is.EqualTo("json"));
            Assert.That(captured.Query["encode"], Is.EqualTo("true"));
            Assert.That(captured.Query["language"], Is.Null, "language must be omitted entirely for auto-detect");
            Assert.That(captured.PartName, Is.EqualTo("audio_file"));
            Assert.That(captured.PartBytes, Is.EqualTo(audioBytes));
        });
    }

    [Test]
    public async Task AudioImport_RequestLanguage_IsSentAsQueryParameter()
    {
        CapturedRequest? captured = null;
        await using var mockApi = new MockHttpServer(request =>
        {
            captured = CapturedRequest.Capture(request);
            return Json(new { text = "bonjour", segments = Array.Empty<object>() });
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-lang@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("fr audio")),
            Metadata: new Dictionary<string, string> { ["language"] = "fr" }), JsonOptions);
        response.EnsureSuccessStatusCode();

        Assert.That(captured!.Query["language"], Is.EqualTo("fr"));
    }

    [Test]
    public async Task AudioImport_LanguageAuto_IsTreatedAsUnset()
    {
        CapturedRequest? captured = null;
        await using var mockApi = new MockHttpServer(request =>
        {
            captured = CapturedRequest.Capture(request);
            return Json(new { text = "auto detected", segments = Array.Empty<object>() });
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-auto@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("auto audio")),
            Metadata: new Dictionary<string, string> { ["language"] = "auto" }), JsonOptions);
        response.EnsureSuccessStatusCode();

        Assert.That(captured!.Query["language"], Is.Null);
    }

    [Test]
    public async Task AudioImport_ObjectShapedSegments_MapToOffsetsAndTrimmedText()
    {
        await using var mockApi = new MockHttpServer(_ => Json(new
        {
            text = "Hello there. Second part.",
            language = "en",
            segments = new[]
            {
                new { start = 0.0, end = 1.2, text = "  Hello there.  " },
                new { start = 2.5, end = 3.7, text = "Second part." },
                new { start = 4.0, end = 4.1, text = "   " } // whitespace-only segment must be skipped
            }
        }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-object-segments@example.test");

        var result = await ImportAsync(client, new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("object segment audio"))));

        Assert.That(result.Conversations, Has.Count.EqualTo(1));
        var segments = result.Conversations[0].Segments;
        Assert.Multiple(() =>
        {
            Assert.That(segments, Has.Count.EqualTo(2));
            Assert.That(segments[0].Text, Is.EqualTo("Hello there."));
            Assert.That(segments[0].OffsetMs, Is.EqualTo(0));
            Assert.That(segments[1].Text, Is.EqualTo("Second part."));
            Assert.That(segments[1].OffsetMs, Is.EqualTo(2500));
            Assert.That(result.Conversations[0].Metadata!["language"], Is.EqualTo("en"));
        });
    }

    [Test]
    public async Task AudioImport_ArrayShapedSegments_MapPositionalFasterWhisperFields()
    {
        // faster-whisper positional order: [id, seek, start, end, text, tokens, ...]
        await using var mockApi = new MockHttpServer(_ => Json(new
        {
            text = "positional segment text",
            segments = new object[]
            {
                new object[] { 0, 0, 0.0, 1.5, "positional segment text", new[] { 1, 2, 3 } },
                new object[] { 1, 100, 1.5, 3.0, "second positional segment", new[] { 4, 5 } }
            }
        }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-array-segments@example.test");

        var result = await ImportAsync(client, new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("array segment audio"))));

        var segments = result.Conversations[0].Segments;
        Assert.Multiple(() =>
        {
            Assert.That(segments, Has.Count.EqualTo(2));
            Assert.That(segments[0].Text, Is.EqualTo("positional segment text"));
            Assert.That(segments[0].OffsetMs, Is.EqualTo(0));
            Assert.That(segments[1].Text, Is.EqualTo("second positional segment"));
            Assert.That(segments[1].OffsetMs, Is.EqualTo(1500));
        });
    }

    [Test]
    public async Task AudioImport_MissingSegments_FallsBackToTopLevelText()
    {
        await using var mockApi = new MockHttpServer(_ => Json(new
        {
            text = "  Only a top-level transcript, no segments.  ",
            language = "de"
        }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-fallback@example.test");

        var result = await ImportAsync(client, new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("no segments audio"))));

        Assert.That(result.Conversations[0].Segments, Has.Count.EqualTo(1));
        Assert.That(result.Conversations[0].Segments[0].Text, Is.EqualTo("Only a top-level transcript, no segments."));
    }

    [Test]
    public async Task AudioImport_RecordedAt_MapsToSegmentCreatedAtPlusOffset()
    {
        await using var mockApi = new MockHttpServer(_ => Json(new
        {
            text = "Hello there. Second part.",
            segments = new[]
            {
                new { start = 0.0, end = 1.2, text = "Hello there." },
                new { start = 2.5, end = 3.7, text = "Second part." }
            }
        }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-recordedat@example.test");

        var recordedAt = DateTimeOffset.Parse("2025-10-14T18:05:00Z", CultureInfo.InvariantCulture);
        var result = await ImportAsync(client, new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("recorded at audio")),
            Metadata: new Dictionary<string, string> { ["recordedAt"] = "2025-10-14T18:05:00Z" }));

        var segments = result.Conversations[0].Segments;
        Assert.Multiple(() =>
        {
            Assert.That(segments, Has.Count.EqualTo(2));
            Assert.That(segments[0].CreatedAt, Is.EqualTo(recordedAt));
            Assert.That(segments[1].CreatedAt, Is.EqualTo(recordedAt + TimeSpan.FromMilliseconds(2500)));
        });
    }

    [Test]
    public async Task AudioImport_AbsentRecordedAt_LeavesCreatedAtNull()
    {
        await using var mockApi = new MockHttpServer(_ => Json(new
        {
            text = "no recorded at metadata",
            segments = new[] { new { start = 0.0, end = 1.0, text = "no recorded at metadata" } }
        }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-norecordedat@example.test");

        var result = await ImportAsync(client, new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("no recorded at audio"))));

        Assert.That(result.Conversations[0].Segments[0].CreatedAt, Is.Null);
    }

    [Test]
    public async Task AudioImport_InvalidRecordedAt_ReturnsBadRequestNamingMetadataKey()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "whisper-badrecordedat@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("bad recorded at audio")),
            Metadata: new Dictionary<string, string> { ["recordedAt"] = "not-a-date" }), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("metadata.recordedAt"));
    }

    [Test]
    public async Task AudioImport_FutureRecordedAt_ReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "whisper-futurerecordedat@example.test");

        var future = DateTimeOffset.UtcNow.AddDays(5).ToString("O", CultureInfo.InvariantCulture);
        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("future recorded at audio")),
            Metadata: new Dictionary<string, string> { ["recordedAt"] = future }), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("metadata.recordedAt"));
    }

    [Test]
    public async Task AudioImport_MetadataBaseUrlOverrides_AreIgnored_SsrfRegression()
    {
        // Regression test for the SSRF fix: an attacker-controlled metadata.tapBaseUrl /
        // metadata.whisperBaseUrl must never redirect the server's outbound request. Only the
        // configured Whisper:BaseUrl may be contacted.
        var attackerHit = false;
        await using var attacker = new MockHttpServer(_ =>
        {
            attackerHit = true;
            return Json(new { text = "should never be used" });
        });
        await using var configured = new MockHttpServer(_ => Json(new { text = "legit transcript", segments = Array.Empty<object>() }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = configured.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-ssrf@example.test");

        var result = await ImportAsync(client, new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("ssrf regression audio")),
            Metadata: new Dictionary<string, string>
            {
                ["tapBaseUrl"] = attacker.Url,
                ["whisperBaseUrl"] = attacker.Url,
                ["tapPath"] = "/asr",
                ["tapApiKey"] = "attacker-supplied-key"
            }));

        Assert.Multiple(() =>
        {
            Assert.That(attackerHit, Is.False, "the attacker-controlled base URL must never be contacted");
            Assert.That(configured.RequestCount, Is.EqualTo(1));
            Assert.That(result.Conversations[0].Segments[0].Text, Is.EqualTo("legit transcript"));
        });
    }

    [Test]
    public async Task AudioImport_InvalidBase64Payload_ReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "whisper-badbase64@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: "not-valid-base64!!!"), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task AudioImport_MissingPayload_ReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "whisper-missingpayload@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task AudioImport_UnreachableWhisperService_ReturnsBadRequestNamingConfiguredUrl()
    {
        const string unreachableBaseUrl = "http://127.0.0.1:1/";
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = unreachableBaseUrl
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-unreachable@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("unreachable"))), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain(unreachableBaseUrl));
    }

    [Test]
    public async Task AudioImport_WhisperServiceReturnsError_SurfacesTruncatedExcerptWithoutFullBody()
    {
        var longErrorBody = new string('x', 5000);
        await using var mockApi = new MockHttpServer(_ => new MockHttpResponse("text/plain", longErrorBody, 500));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "whisper-error-body@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/audio", new ImportRequest(
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("error body audio"))), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body.Length, Is.LessThan(longErrorBody.Length));
    }

    private static async Task<NormalizedImportResponse> ImportAsync(HttpClient client, ImportRequest request)
    {
        var response = await client.PostAsJsonAsync("/api/imports/audio", request, JsonOptions);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Import response was empty.");
    }

    private static async Task<HttpClient> AuthenticatedClientAsync(LifenizerApiFactory factory, string email)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email, email.Split('@')[0]), JsonOptions);
        response.EnsureSuccessStatusCode();
        var auth = await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Auth response was empty.");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        return client;
    }

    private static MockHttpResponse Json(object value) => new("application/json", JsonSerializer.Serialize(value, JsonOptions));

    private sealed record CapturedRequest(string Path, System.Collections.Specialized.NameValueCollection Query, string? PartName, string? PartFileName, byte[] PartBytes)
    {
        public static CapturedRequest Capture(HttpListenerRequest request)
        {
            var path = request.Url?.AbsolutePath ?? string.Empty;
            var query = request.Url is null ? new System.Collections.Specialized.NameValueCollection() : System.Web.HttpUtility.ParseQueryString(request.Url.Query);

            var contentTypeHeader = request.ContentType ?? string.Empty;
            var boundary = new System.Net.Mime.ContentType(contentTypeHeader).Boundary
                ?? throw new InvalidOperationException("Expected a multipart request with a boundary.");
            var reader = new MultipartReader(boundary, request.InputStream);
            var section = reader.ReadNextSectionAsync().GetAwaiter().GetResult()
                ?? throw new InvalidOperationException("Expected at least one multipart section.");

            Microsoft.Net.Http.Headers.ContentDispositionHeaderValue.TryParse(section.ContentDisposition, out var contentDisposition);
            using var memory = new MemoryStream();
            section.Body.CopyTo(memory);

            return new CapturedRequest(
                path,
                query,
                contentDisposition?.Name.Value,
                contentDisposition?.FileName.Value,
                memory.ToArray());
        }
    }
}
