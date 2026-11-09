using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Lifenizer.Core;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace Lifenizer.Tests;

public sealed class ApiFlowTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task DevLoginReturnsVaultMaterial()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var auth = await LoginAsync(client, "alice@example.test");

        Assert.Multiple(() =>
        {
            Assert.That(auth.AuthToken, Is.Not.Empty);
            Assert.That(auth.UserId, Is.Not.EqualTo(Guid.Empty));
            Assert.That(auth.VaultId, Is.Not.EqualTo(Guid.Empty));
            Assert.That(auth.VaultSalt, Is.Not.Empty);
        });
    }

    [Test]
    public async Task SameUserCanPullSyncedEncryptedEnvelope()
    {
        await using var factory = new LifenizerApiFactory();
        using var firstDevice = factory.CreateClient();
        using var secondDevice = factory.CreateClient();

        var firstAuth = await LoginAsync(firstDevice, "alice@example.test");
        var secondAuth = await LoginAsync(secondDevice, "alice@example.test");
        firstDevice.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", firstAuth.AuthToken);
        secondDevice.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", secondAuth.AuthToken);

        var envelope = NewEnvelope("conversation", "conv-1", "ciphertext-for-alice");
        var push = await firstDevice.PostAsJsonAsync("/api/sync/push", new PushSyncRequest(new[] { envelope }), JsonOptions);
        push.EnsureSuccessStatusCode();

        var pull = await secondDevice.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);

        Assert.That(pull, Is.Not.Null);
        Assert.That(pull!.Envelopes, Has.Count.EqualTo(1));
        Assert.That(pull.Envelopes[0].CipherText, Is.EqualTo("ciphertext-for-alice"));
    }

    [Test]
    public async Task SyncIsIsolatedBetweenUsers()
    {
        await using var factory = new LifenizerApiFactory();
        using var alice = factory.CreateClient();
        using var bob = factory.CreateClient();

        var aliceAuth = await LoginAsync(alice, "alice@example.test");
        var bobAuth = await LoginAsync(bob, "bob@example.test");
        alice.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", aliceAuth.AuthToken);
        bob.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", bobAuth.AuthToken);

        var envelope = NewEnvelope("conversation", "private-conv", "alice-only");
        var push = await alice.PostAsJsonAsync("/api/sync/push", new PushSyncRequest(new[] { envelope }), JsonOptions);
        push.EnsureSuccessStatusCode();

        var bobPull = await bob.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0", JsonOptions);

        Assert.That(bobPull, Is.Not.Null);
        Assert.That(bobPull!.Envelopes, Is.Empty);
    }

    [Test]
    public async Task RelationExtractionReturnsPlaintextComputeResult()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        var auth = await LoginAsync(client, "alice@example.test");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);

        var response = await client.PostAsJsonAsync(
            "/api/analysis/relations/extract",
            new RelationExtractionRequest("Person X is Person Y's brother. Person X works with Person Z."),
            JsonOptions);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<RelationExtractionResponse>(JsonOptions);

        Assert.That(result, Is.Not.Null);
        Assert.That(result!.PlaintextCompute, Is.True);
        Assert.That(result.Relations.Select(r => r.Relation), Does.Contain("brother"));
        Assert.That(result.Relations.Select(r => r.Relation), Does.Contain("works with"));
    }

    [Test]
    public async Task ImportCapabilitiesExposeRequestedSources()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();

        var capabilities = await client.GetFromJsonAsync<ImportCapability[]>("/api/imports/capabilities", JsonOptions);

        Assert.That(capabilities, Is.Not.Null);
        var sources = capabilities!.Select(c => c.Source).ToHashSet();
        Assert.That(sources, Is.SupersetOf(new[]
        {
            "email", "scanned-pdf", "paperless", "whatsapp", "telegram", "signal", "discord",
            "audio", "live-recording", "browser-history", "youtube-transcript", "manual-text"
        }));
    }

    private static async Task<AuthResponse> LoginAsync(HttpClient client, string email)
    {
        var response = await client.PostAsJsonAsync(
            "/api/auth/dev-login",
            new DevLoginRequest(email, email.Split('@')[0]),
            JsonOptions);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Auth response was empty.");
    }

    private static SyncEnvelopeDto NewEnvelope(string entityType, string entityId, string cipherText)
    {
        return new SyncEnvelopeDto(
            Guid.NewGuid(),
            "test-device",
            entityType,
            entityId,
            "upsert",
            1,
            cipherText,
            "nonce",
            "vault-v1",
            DateTimeOffset.UtcNow);
    }
}

internal sealed class LifenizerApiFactory : WebApplicationFactory<Program>
{
    private readonly IReadOnlyDictionary<string, string?> configurationOverrides;
    private readonly string dbPath = Path.Combine(Path.GetTempPath(), "lifenizer-next-tests", $"{Guid.NewGuid():N}.db");

    public LifenizerApiFactory(IReadOnlyDictionary<string, string?>? configurationOverrides = null)
    {
        this.configurationOverrides = configurationOverrides ?? new Dictionary<string, string?>();
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(dbPath)!);
        builder.UseEnvironment("Development");
        builder.ConfigureAppConfiguration((_, config) =>
        {
            var values = new Dictionary<string, string?>
            {
                ["ConnectionStrings:Lifenizer"] = $"Data Source={dbPath}",
                ["Jwt:Issuer"] = "lifenizer-next-tests",
                ["Jwt:Secret"] = "test-secret-for-lifenizer-next-integration-tests",
                ["Auth:AllowDevLogin"] = "true"
            };
            foreach (var (key, value) in configurationOverrides)
            {
                values[key] = value;
            }

            config.AddInMemoryCollection(values);
        });
    }
}