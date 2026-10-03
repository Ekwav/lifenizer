using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;
using Microsoft.IdentityModel.Tokens;

namespace Lifenizer.Tests;

public sealed class ApiIntegrationTests
{
    private const string JwtIssuer = "lifenizer-next-tests";
    private const string JwtSecret = "test-secret-for-lifenizer-next-integration-tests";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    // ---------------------------------------------------------------------
    // Authentication flow (8 tests)
    // ---------------------------------------------------------------------

    [Test]
    public async Task Authentication_DevLogin_SucceedsAndReturnsVaultMaterial()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var auth = await DevLoginAsync(client, "auth-success@example.test");

        Assert.Multiple(() =>
        {
            Assert.That(auth.AuthToken, Is.Not.Empty);
            Assert.That(auth.UserId, Is.Not.EqualTo(Guid.Empty));
            Assert.That(auth.VaultId, Is.Not.EqualTo(Guid.Empty));
            Assert.That(auth.VaultSalt, Is.Not.Empty);
            Assert.That(auth.TokenType, Is.EqualTo("Bearer"));
        });
    }

    [Test]
    public async Task Authentication_DevLogin_RejectsMissingEmail()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync(
            "/api/auth/dev-login",
            new DevLoginRequest("", "missing-email"),
            JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("email_required"));
    }

    [Test]
    public async Task Authentication_ProtectedEndpoint_RejectsMissingBearerToken()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/api/sync/pull?since=0");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task Authentication_ProtectedEndpoint_RejectsInvalidBearerToken()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "not-a-valid-jwt");

        var response = await client.GetAsync("/api/sync/pull?since=0");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task Authentication_ExpiredToken_IsRejectedAndReportsExpiredHeader()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var expired = BuildJwt(userId: Guid.NewGuid(), expiresAtUtc: DateTime.UtcNow.AddMinutes(-30));
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", expired);

        var response = await client.GetAsync("/api/sync/pull?since=0");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That(response.Headers.TryGetValues("Token-Expired", out var values), Is.True);
        Assert.That(values?.SingleOrDefault(), Is.EqualTo("true"));
    }

    [Test]
    public async Task Authentication_FirebaseEndpoint_RejectsEmptyToken()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/api/auth/firebase", new TokenContainer(""), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("auth_token_required"));
    }

    [Test]
    public async Task Authentication_FirebaseEndpoint_RejectsInvalidToken()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/api/auth/firebase", new TokenContainer("invalid-token"), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("Firebase token verification failed"));
    }

    [Test]
    public async Task Authentication_LogoutEquivalent_RemovingTokenPreventsFurtherAccess()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "logout-equivalent@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var okBefore = await client.GetAsync("/api/sync/pull?since=0");
        Assert.That(okBefore.StatusCode, Is.EqualTo(HttpStatusCode.OK));

        client.DefaultRequestHeaders.Authorization = null;
        var unauthorizedAfter = await client.GetAsync("/api/sync/pull?since=0");
        Assert.That(unauthorizedAfter.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    // ---------------------------------------------------------------------
    // Import flow (24 tests: 20 formats + 4 edge/error/large)
    // ---------------------------------------------------------------------

    [TestCaseSource(nameof(ImportFormatCases))]
    public async Task Import_AllSupportedFormats_DispatchAndNormalize(ImportCase importCase)
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "import-formats@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.PostAsJsonAsync($"/api/imports/{importCase.Source}", importCase.Request, JsonOptions);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions);

        Assert.That(result, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(result!.Source, Is.EqualTo(importCase.Source));
            Assert.That(result.PlaintextCompute, Is.True);
            Assert.That(result.Conversations, Is.Not.Empty);
            Assert.That(result.Conversations[0].Segments, Is.Not.Empty);
            Assert.That(result.Conversations[0].Segments[0].Text, Does.Contain(importCase.ExpectedTextSnippet));
            Assert.That(result.Conversations[0].Source, Is.EqualTo(importCase.ExpectedConversationSource ?? importCase.Source));
        });
    }

    [Test]
    public async Task Import_LifenizerBackup_PreservesOriginalConversationSources()
    {
        // Regression test: restoring a backup must keep each conversation's original source so
        // source-filtered search still works after a restore, even though the request source is
        // "lifenizer-backup" and the individual conversations came from different importers.
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "import-backup-sources@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.PostAsJsonAsync(
            "/api/imports/lifenizer-backup",
            new ImportRequest(Text: "{\"conversations\":["
                + "{\"title\":\"WhatsApp thread\",\"source\":\"whatsapp\",\"segments\":[{\"text\":\"Hi there\",\"offsetMs\":0}]},"
                + "{\"title\":\"Note\",\"source\":\"manual-text\",\"segments\":[{\"text\":\"Reminder\",\"offsetMs\":0}]}"
                + "]}"),
            JsonOptions);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions);

        Assert.That(result, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(result!.Source, Is.EqualTo("lifenizer-backup"));
            Assert.That(result.Conversations, Has.Count.EqualTo(2));
            Assert.That(result.Conversations[0].Source, Is.EqualTo("whatsapp"));
            Assert.That(result.Conversations[1].Source, Is.EqualTo("manual-text"));
        });
    }

    [Test]
    public async Task Import_UnsupportedSource_ReturnsNotFound()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "import-unsupported@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.PostAsJsonAsync("/api/imports/unsupported-xyz", new ImportRequest(Text: "x"), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("unknown_import_source"));
    }

    [Test]
    public async Task Import_MalformedData_ReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "import-malformed@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.PostAsJsonAsync(
            "/api/imports/telegram",
            new ImportRequest(Text: "{\"messages\":"),
            JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("invalid_import_json").Or.Contain("invalid_import_request"));
    }

    [Test]
    public async Task Import_MissingRequiredMetadata_ReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "import-metadata@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.PostAsJsonAsync(
            "/api/imports/email",
            new ImportRequest(Text: "no metadata"),
            JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task Import_LargePayload_ProducesAtLeastThousandSegments()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "import-large@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var builder = new StringBuilder();
        for (var i = 0; i < 1200; i++)
        {
            builder.AppendLine($"[20.05.2026, 10:{i % 60:00}] User{i % 4}: Segment {i}");
        }

        var response = await client.PostAsJsonAsync(
            "/api/imports/whatsapp",
            new ImportRequest(Title: "Large import", Text: builder.ToString()),
            JsonOptions);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions);

        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Conversations.SelectMany(c => c.Segments).Count(), Is.GreaterThanOrEqualTo(1000));
    }

    // ---------------------------------------------------------------------
    // Search flow (4 tests) over pulled envelope payloads
    // ---------------------------------------------------------------------

    [Test]
    public async Task Search_QueryExecution_ReturnsExpectedMatches()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "search-flow@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        await PushConversationEnvelopeAsync(client, "email", "Alice", "work", "quarterly roadmap");
        await PushConversationEnvelopeAsync(client, "chat", "Bob", "personal", "weekend grocery list");

        var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);
        var matches = SearchPulledEnvelopes(pull!, "roadmap");

        Assert.That(matches, Has.Count.EqualTo(1));
        Assert.That(matches[0].Text, Does.Contain("quarterly roadmap"));
    }

    [Test]
    public async Task Search_Filtering_BySourceParticipantAndTag_Works()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "search-filtering@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        await PushConversationEnvelopeAsync(client, "email", "Alice", "work", "release notes");
        await PushConversationEnvelopeAsync(client, "chat", "Alice", "personal", "private reminder");
        await PushConversationEnvelopeAsync(client, "email", "Bob", "work", "infra task");

        var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);
        var filtered = SearchPulledEnvelopes(
            pull!,
            "",
            source: "email",
            participant: "Alice",
            tag: "work");

        Assert.That(filtered, Has.Count.EqualTo(1));
        Assert.That(filtered[0].Text, Does.Contain("release notes"));
    }

    [Test]
    public async Task Search_Pagination_ReturnsStableSlices()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "search-pagination@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        for (var i = 0; i < 13; i++)
        {
            await PushConversationEnvelopeAsync(client, "chat", $"User{i % 3}", "tag-x", $"common query item {i}");
        }

        var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);
        var page1 = SearchPulledEnvelopes(pull!, "common query", page: 1, pageSize: 5);
        var page3 = SearchPulledEnvelopes(pull, "common query", page: 3, pageSize: 5);

        Assert.Multiple(() =>
        {
            Assert.That(page1, Has.Count.EqualTo(5));
            Assert.That(page3, Has.Count.EqualTo(3));
            Assert.That(page1.Select(x => x.EntityId).Intersect(page3.Select(x => x.EntityId)), Is.Empty);
        });
    }

    [Test]
    public async Task Search_MalformedQuery_ReturnsHelpfulError()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "search-malformed@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        await PushConversationEnvelopeAsync(client, "chat", "Alice", "x", "hello world");
        var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);

        var ex = Assert.Throws<ArgumentException>(() => SearchPulledEnvelopes(pull!, "\"unterminated"));
        Assert.That(ex!.Message, Does.Contain("Malformed query"));
    }

    // ---------------------------------------------------------------------
    // Sync flow (4 tests)
    // ---------------------------------------------------------------------

    [Test]
    public async Task Sync_PushThenPull_ReturnsSameEnvelopeData()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "sync-pushpull@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var id = Guid.NewGuid();
        var payload = "{\"entity\":\"conversation\",\"text\":\"hello sync\"}";
        var push = await client.PostAsJsonAsync(
            "/api/sync/push",
            new PushSyncRequest([
                new SyncEnvelopeDto(id, "dev-a", "conversation", "c-1", "upsert", 1, payload, "nonce", "k1", DateTimeOffset.UtcNow)
            ]),
            JsonOptions);
        push.EnsureSuccessStatusCode();

        var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);

        Assert.That(pull, Is.Not.Null);
        Assert.That(pull!.Envelopes, Has.Count.EqualTo(1));
        Assert.That(pull.Envelopes[0].CipherText, Is.EqualTo(payload));
    }

    [Test]
    public async Task Sync_ConflictResolution_DuplicateEnvelopeIdIgnored()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "sync-conflict@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var duplicateId = Guid.NewGuid();
        var envelope = new SyncEnvelopeDto(
            duplicateId,
            "dev-a",
            "conversation",
            "dup-1",
            "upsert",
            1,
            "{\"v\":1}",
            "nonce",
            "k1",
            DateTimeOffset.UtcNow);

        var first = await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]), JsonOptions);
        var second = await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]), JsonOptions);

        var firstResult = await first.Content.ReadFromJsonAsync<PushSyncResponse>(JsonOptions);
        var secondResult = await second.Content.ReadFromJsonAsync<PushSyncResponse>(JsonOptions);

        Assert.Multiple(() =>
        {
            Assert.That(firstResult!.Accepted, Is.EqualTo(1));
            Assert.That(secondResult!.Accepted, Is.EqualTo(0));
        });
    }

    [Test]
    public async Task Sync_PullRespectsSinceCursor_OnlyReturnsNewChanges()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "sync-cursor@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        await PushConversationEnvelopeAsync(client, "chat", "A", "x", "first");
        var afterFirst = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);

        await PushConversationEnvelopeAsync(client, "chat", "A", "x", "second");
        var afterSecond = await client.GetFromJsonAsync<PullSyncResponse>($"/api/sync/pull?since={afterFirst!.Cursor}", JsonOptions);

        Assert.That(afterSecond, Is.Not.Null);
        Assert.That(afterSecond!.Envelopes, Has.Count.EqualTo(1));
        Assert.That(afterSecond.Envelopes[0].CipherText, Does.Contain("second"));
    }

    [Test]
    public async Task Sync_ErrorRecovery_ReauthAfterUnauthorizedContinuesSync()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await DevLoginAsync(client, "sync-recovery@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        await PushConversationEnvelopeAsync(client, "chat", "Alice", "tag", "before failure");

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "broken-token");
        var unauthorized = await client.GetAsync("/api/sync/pull?since=0");
        Assert.That(unauthorized.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));

        var refreshedAuth = await DevLoginAsync(client, "sync-recovery@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", refreshedAuth.AuthToken);
        var recovered = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);

        Assert.That(recovered, Is.Not.Null);
        Assert.That(recovered!.Envelopes.Select(x => x.CipherText), Has.Some.Contains("before failure"));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    private static IEnumerable<ImportCase> ImportFormatCases()
    {
        yield return new ImportCase("manual-text", new ImportRequest(Text: "Manual note for parser dispatch."), "Manual note");
        yield return new ImportCase("scanned-pdf", new ImportRequest(OriginalFileName: "invoice.pdf", MimeType: "application/pdf", Text: "OCR invoice text"), "OCR invoice text");
        yield return new ImportCase("live-recording", new ImportRequest(Text: "Segment from recording."), "Segment from recording");
        yield return new ImportCase("whatsapp", new ImportRequest(Text: "[20.05.2026, 10:00] Alice: WhatsApp parser works"), "WhatsApp parser works");
        yield return new ImportCase("telegram", new ImportRequest(Text: "{\"name\":\"Telegram\",\"messages\":[{\"from\":\"Alice\",\"text\":\"Telegram parser works\",\"date\":\"2026-05-20T10:00:00Z\"}]}"), "Telegram parser works");
        yield return new ImportCase("signal", new ImportRequest(Text: "timestamp,sender,message\n2026-05-20T10:00:00Z,Alice,Signal parser works"), "Signal parser works");
        yield return new ImportCase("discord", new ImportRequest(Text: "[{\"author\":{\"username\":\"Alice\"},\"content\":\"Discord parser works\",\"timestamp\":\"2026-05-20T10:00:00Z\"}]"), "Discord parser works");
        yield return new ImportCase("slack", new ImportRequest(Text: "[{\"user_profile\":{\"display_name\":\"Alice\"},\"text\":\"Slack parser works\",\"ts\":\"1716206400.0\"}]"), "Slack parser works");
        yield return new ImportCase("teams", new ImportRequest(Text: "{\"messages\":[{\"fromDisplayName\":\"Alice\",\"content\":\"<p>Teams parser works</p>\",\"createdDateTime\":\"2026-05-20T10:00:00Z\"}]}"), "Teams parser works");
        yield return new ImportCase("facebook-messenger", new ImportRequest(Text: "{\"title\":\"T\",\"messages\":[{\"sender_name\":\"Alice\",\"content\":\"Messenger parser works\",\"timestamp_ms\":1716206400000}]}"), "Messenger parser works");
        yield return new ImportCase("instagram", new ImportRequest(Text: "{\"title\":\"IG\",\"messages\":[{\"sender_name\":\"Alice\",\"content\":\"Instagram parser works\",\"timestamp_ms\":1716206400000}]}"), "Instagram parser works");
        yield return new ImportCase("imessage", new ImportRequest(Text: "5/20/2026, 9:41 AM - Alex: iMessage parser works"), "iMessage parser works");
        yield return new ImportCase("mbox", new ImportRequest(Text: "From sender@example.test Tue May 20 10:15:00 2026\nFrom: Sender <sender@example.test>\nTo: Receiver <receiver@example.test>\nSubject: Mbox parser\n\nMbox parser works"), "Mbox parser works");
        yield return new ImportCase("git", new ImportRequest(Text: "commit 0f4e9b7\nAuthor: Dev One <dev1@example.test>\nDate: 2026-05-20T14:00:00Z\n\nGit parser works"), "Git parser works");
        yield return new ImportCase("browser-capture", new ImportRequest(Text: "{\"events\":[{\"title\":\"Doc\",\"url\":\"https://docs.example.test\",\"content\":\"Browser capture parser works\",\"timestamp\":\"2026-05-20T10:00:00Z\"}]}"), "Browser capture parser works");
        yield return new ImportCase("google-search-history", new ImportRequest(Text: "query,url,time\nimport parser tests,https://google.com/search?q=import+parser+tests,2026-05-20T10:00:00Z"), "Searched: import parser tests");
        yield return new ImportCase("bookmarks", new ImportRequest(Text: "{\"roots\":{\"bookmark_bar\":{\"children\":[{\"type\":\"url\",\"name\":\"Repo\",\"url\":\"https://github.com/Ekwav/lifenizer\"}]}}}"), "https://github.com/Ekwav/lifenizer");
        // Restoring a backup must preserve each conversation's original source (so source-filtered search
        // keeps working after a restore) rather than relabeling it "lifenizer-backup".
        yield return new ImportCase("lifenizer-backup", new ImportRequest(Text: "{\"conversations\":[{\"title\":\"Recovered\",\"source\":\"manual-text\",\"participantNames\":[\"Alice\"],\"segments\":[{\"text\":\"Backup parser works\",\"participantName\":\"Alice\",\"offsetMs\":0}]}]}"), "Backup parser works", ExpectedConversationSource: "manual-text");
        yield return new ImportCase("browser-history", new ImportRequest(Text: "title,url,time\nIssue board,https://github.com/Ekwav/lifenizer/issues,2026-05-20T10:00:00Z"), "https://github.com/Ekwav/lifenizer/issues");
        yield return new ImportCase("audio", new ImportRequest(Text: "Audio transcription parser works", MimeType: "audio/wav", OriginalFileName: "meeting.wav"), "Audio transcription parser works");
    }

    private static async Task<AuthResponse> DevLoginAsync(HttpClient client, string email)
    {
        var response = await client.PostAsJsonAsync(
            "/api/auth/dev-login",
            new DevLoginRequest(email, email.Split('@')[0]),
            JsonOptions);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Auth response was empty.");
    }

    private static string BuildJwt(Guid userId, DateTime expiresAtUtc)
    {
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(JwtSecret));
        var creds = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);
        var token = new JwtSecurityToken(
            issuer: JwtIssuer,
            audience: JwtIssuer,
            claims:
            [
                new Claim(JwtRegisteredClaimNames.Sub, userId.ToString()),
                new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString("N"))
            ],
            notBefore: DateTime.UtcNow.AddHours(-2),
            expires: expiresAtUtc,
            signingCredentials: creds);

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    private static async Task PushConversationEnvelopeAsync(
        HttpClient client,
        string source,
        string participant,
        string tag,
        string text)
    {
        var payload = JsonSerializer.Serialize(new
        {
            source,
            participant,
            tag,
            text
        });

        var request = new PushSyncRequest([
            new SyncEnvelopeDto(
                Guid.NewGuid(),
                "search-device",
                "conversation",
                Guid.NewGuid().ToString("N"),
                "upsert",
                1,
                payload,
                "nonce",
                "k1",
                DateTimeOffset.UtcNow)
        ]);

        var response = await client.PostAsJsonAsync("/api/sync/push", request, JsonOptions);
        response.EnsureSuccessStatusCode();
    }

    private static List<SearchEnvelopeMatch> SearchPulledEnvelopes(
        PullSyncResponse pull,
        string query,
        string? source = null,
        string? participant = null,
        string? tag = null,
        int page = 1,
        int pageSize = 20)
    {
        if (query.Count(c => c == '"') % 2 != 0)
        {
            throw new ArgumentException("Malformed query: unmatched quote characters.");
        }

        var normalizedQuery = query.Trim().ToLowerInvariant();
        var filtered = new List<SearchEnvelopeMatch>();

        foreach (var envelope in pull.Envelopes)
        {
            using var doc = JsonDocument.Parse(envelope.CipherText);
            var root = doc.RootElement;
            var src = root.TryGetProperty("source", out var srcProp) ? srcProp.GetString() ?? string.Empty : string.Empty;
            var p = root.TryGetProperty("participant", out var pProp) ? pProp.GetString() ?? string.Empty : string.Empty;
            var t = root.TryGetProperty("tag", out var tProp) ? tProp.GetString() ?? string.Empty : string.Empty;
            var text = root.TryGetProperty("text", out var textProp) ? textProp.GetString() ?? string.Empty : string.Empty;

            if (!string.IsNullOrEmpty(source) && !src.Equals(source, StringComparison.OrdinalIgnoreCase)) continue;
            if (!string.IsNullOrEmpty(participant) && !p.Equals(participant, StringComparison.OrdinalIgnoreCase)) continue;
            if (!string.IsNullOrEmpty(tag) && !t.Equals(tag, StringComparison.OrdinalIgnoreCase)) continue;
            if (!string.IsNullOrEmpty(normalizedQuery) && !text.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase)) continue;

            filtered.Add(new SearchEnvelopeMatch(envelope.EntityId, text));
        }

        var start = Math.Max(0, (page - 1) * pageSize);
        if (start >= filtered.Count)
        {
            return [];
        }

        var count = Math.Min(pageSize, filtered.Count - start);
        return filtered.GetRange(start, count);
    }

    public sealed record ImportCase(string Source, ImportRequest Request, string ExpectedTextSnippet, string? ExpectedConversationSource = null);

    private sealed record SearchEnvelopeMatch(string EntityId, string Text);
}
