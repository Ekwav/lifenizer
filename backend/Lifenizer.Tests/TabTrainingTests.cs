using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class TabTrainingTests
{
    private const string Key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string Receipt = "receipt-one";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task NoticeConsentAndWithdrawal_UseActualTabDeviceReceiptContract()
    {
        var requests = new List<(string Path, string? Key, JsonElement? Body)>();
        await using var tab = new MockHttpServer(request =>
        {
            requests.Add((request.Url!.AbsolutePath, request.Headers["X-Contribution-Key"], ReadBody(request)));
            return request.Url.AbsolutePath.EndsWith("/notice")
                ? Json(new { version = "notice-v3", information = "Full notice", terms = "Own voice only", purposes = new[] { new { value = 4, title = "Train speech recognition" } } })
                : Json(new { id = Receipt, version = "notice-v3", purposes = 4, contributorAlias = "alias@contribution.invalid" });
        });
        await using var factory = Factory(tab);
        using var client = await AuthenticatedAsync(factory);
        var notice = await client.GetFromJsonAsync<JsonElement>("/api/training/tab/notice");
        Assert.That(notice.GetProperty("terms").GetString(), Is.EqualTo("Own voice only"));
        var consent = await client.PostAsJsonAsync("/api/training/tab/consents", new { contributionKey = Key, version = "notice-v3", acceptTerms = true });
        consent.EnsureSuccessStatusCode();
        var withdraw = await client.PostAsJsonAsync($"/api/training/tab/consents/{Receipt}/withdraw", new { contributionKey = Key });
        withdraw.EnsureSuccessStatusCode();
        Assert.Multiple(() =>
        {
            Assert.That(requests.Select(r => r.Path), Is.EqualTo(new[] { "/api/dialect/consents/notice", "/api/dialect/consents", $"/api/dialect/consents/{Receipt}/withdraw" }));
            Assert.That(requests[0].Key, Is.Null);
            Assert.That(requests[1].Key, Is.EqualTo(Key));
            Assert.That(requests[1].Body!.Value.GetProperty("purposes").GetInt32(), Is.EqualTo(4));
            Assert.That(requests[1].Body!.Value.GetProperty("email").ValueKind, Is.EqualTo(JsonValueKind.Null));
            Assert.That(requests[1].Body!.Value.GetProperty("acceptTerms").GetBoolean(), Is.True);
            Assert.That(requests[2].Body!.Value.GetProperty("purposes").GetInt32(), Is.EqualTo(4));
        });
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task SelectedCorrection_VerifiesTrainingPurposeAndUploadsOnlySelectedClipAndCorrectedText(bool isReplacement)
    {
        var requests = new List<string>();
        JsonElement? upload = null;
        await using var tab = new MockHttpServer(request =>
        {
            requests.Add(request.Url!.AbsolutePath);
            Assert.That(request.Headers["X-Contribution-Key"], Is.EqualTo(Key));
            Assert.That(request.Headers["Authorization"], Is.Null, "Lifenizer credentials must never reach TAB");
            if (request.Url.AbsolutePath.EndsWith($"/consents/{Receipt}"))
                return Json(new { id = Receipt, purposes = 4, contributorAlias = "alias@contribution.invalid" });
            upload = ReadBody(request);
            return Json(new { id = "sample-one", audioId = "sample-one.opus" });
        });
        await using var factory = Factory(tab);
        using var client = await AuthenticatedAsync(factory);
        var wav = Wav();
        var response = await client.PostAsJsonAsync("/api/training/tab/corrections", isReplacement ? new
        {
            contributionKey = Key, consentId = Receipt, payloadBase64 = Convert.ToBase64String(wav),
            originalText = "", correctedText = "Replacement sample sentence.", isReplacement = true
        } : Correction(wav));
        response.EnsureSuccessStatusCode();
        var result = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Multiple(() =>
        {
            Assert.That(requests, Is.EqualTo(new[] { $"/api/dialect/consents/{Receipt}", "/api/Dialect/upload" }));
            Assert.That(upload!.Value.GetProperty("base64Audio").GetString(), Is.EqualTo(Convert.ToBase64String(wav)));
            Assert.That(upload.Value.GetProperty("transcription").GetString(), Is.EqualTo(isReplacement ? "Replacement sample sentence." : "Correct selected sentence."));
            Assert.That(upload.Value.GetProperty("contributionConsentId").GetString(), Is.EqualTo(Receipt));
            Assert.That(upload.Value.GetProperty("uploaderEmail").GetString(), Is.EqualTo("alias@contribution.invalid"));
            Assert.That(upload.Value.TryGetProperty("originalText", out _), Is.False);
            Assert.That(upload.Value.TryGetProperty("contributionKey", out _), Is.False);
            Assert.That(upload.Value.TryGetProperty("isReplacement", out _), Is.False);
            Assert.That(result.GetProperty("status").GetString(), Is.EqualTo("submitted_for_validation"));
        });
    }

    [TestCase("invalid-base64")]
    [TestCase("not-wav")]
    [TestCase("wrong-rate")]
    [TestCase("too-long")]
    [TestCase("unchanged-text")]
    [TestCase("replacement-original-text")]
    [TestCase("replacement-empty-text")]
    [TestCase("replacement-long-text")]
    [TestCase("replacement-invalid-wav")]
    public async Task InvalidSelection_IsRejectedBeforeAnyProviderRequest(string problem)
    {
        var requests = 0;
        await using var tab = new MockHttpServer(_ => { requests++; return Json(new { }); });
        await using var factory = Factory(tab);
        using var client = await AuthenticatedAsync(factory);
        var payload = problem switch
        {
            "invalid-base64" => "not-base64!",
            "not-wav" or "replacement-invalid-wav" => Convert.ToBase64String(Encoding.UTF8.GetBytes("not a WAV recording")),
            "wrong-rate" => Convert.ToBase64String(Wav(rate: 8000)),
            "too-long" => Convert.ToBase64String(Wav(seconds: 121)),
            _ => Convert.ToBase64String(Wav())
        };
        var response = await client.PostAsJsonAsync("/api/training/tab/corrections", new
        {
            contributionKey = Key, consentId = Receipt, payloadBase64 = payload,
            originalText = problem.StartsWith("replacement-") && problem != "replacement-original-text" ? "" : "Wrong sentence.",
            correctedText = problem switch
            {
                "unchanged-text" => "Wrong sentence.",
                "replacement-empty-text" => " ",
                "replacement-long-text" => new string('a', 10_001),
                _ => "Correct sentence."
            },
            isReplacement = problem.StartsWith("replacement-")
        });
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(requests, Is.Zero);
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task WithdrawnReceipt_DoesNotUploadAudio(bool isReplacement)
    {
        var requests = new List<string>();
        await using var tab = new MockHttpServer(request =>
        {
            requests.Add(request.Url!.AbsolutePath);
            return Json(new { id = Receipt, purposes = 0 });
        });
        await using var factory = Factory(tab);
        using var client = await AuthenticatedAsync(factory);
        var response = await client.PostAsJsonAsync("/api/training/tab/corrections", isReplacement ? new
        {
            contributionKey = Key, consentId = Receipt, payloadBase64 = Convert.ToBase64String(Wav()),
            originalText = "", correctedText = "Replacement sample sentence.", isReplacement = true
        } : Correction(Wav()));
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(requests, Is.EqualTo(new[] { $"/api/dialect/consents/{Receipt}" }));
    }

    [Test]
    public async Task TrainingRoutesRequireLifenizerAuthentication()
    {
        var requests = 0;
        await using var tab = new MockHttpServer(_ => { requests++; return Json(new { }); });
        await using var factory = Factory(tab);
        using var client = factory.CreateClient();
        foreach (var path in new[] { "consents", "corrections", $"consents/{Receipt}/withdraw" })
        {
            var response = await client.PostAsJsonAsync($"/api/training/tab/{path}", new { });
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        }
        Assert.That((await client.GetAsync("/api/training/tab/notice")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That(requests, Is.Zero);
    }

    [Test]
    public async Task ProviderRedirectsAreNotFollowedAndFailureBodiesAreNotExposed()
    {
        var targetRequests = 0;
        await using var target = new MockHttpServer(_ => { targetRequests++; return Json(new { secret = "private provider detail" }); });
        await using var tab = new MockHttpServer(_ => new MockHttpResponse("text/plain", "private provider detail", 302, target.Url));
        await using var factory = Factory(tab);
        using var client = await AuthenticatedAsync(factory);
        var response = await client.GetAsync("/api/training/tab/notice");
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Not.Contain("private provider detail"));
        Assert.That(targetRequests, Is.Zero);
    }

    private static object Correction(byte[] wav) => new
    {
        contributionKey = Key, consentId = Receipt, payloadBase64 = Convert.ToBase64String(wav),
        originalText = "Wrong selected sentence.", correctedText = "Correct selected sentence."
    };
    private static LifenizerApiFactory Factory(MockHttpServer tab) => new(new Dictionary<string, string?> { ["Training:Tab:BaseUrl"] = tab.Url });
    private static MockHttpResponse Json(object value) => new("application/json", JsonSerializer.Serialize(value, JsonOptions));
    private static JsonElement? ReadBody(HttpListenerRequest request)
    {
        if (!request.HasEntityBody) return null;
        using var reader = new StreamReader(request.InputStream);
        using var json = JsonDocument.Parse(reader.ReadToEnd());
        return json.RootElement.Clone();
    }
    private static async Task<HttpClient> AuthenticatedAsync(LifenizerApiFactory factory)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest("tab-training@example.test", "training"), JsonOptions);
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions))!;
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        return client;
    }
    private static byte[] Wav(int seconds = 1, int rate = 16_000)
    {
        var length = rate * seconds * 2;
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8.ToArray()); writer.Write(length + 36); writer.Write("WAVEfmt "u8.ToArray());
        writer.Write(16); writer.Write((ushort)1); writer.Write((ushort)1); writer.Write(rate); writer.Write(rate * 2);
        writer.Write((ushort)2); writer.Write((ushort)16); writer.Write("data"u8.ToArray()); writer.Write(length); writer.Write(new byte[length]);
        return stream.ToArray();
    }
}
