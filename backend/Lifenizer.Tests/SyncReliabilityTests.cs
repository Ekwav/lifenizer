using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class SyncReliabilityTests
{
    [Test]
    public async Task PushDeduplicatesSameBatchAndRetry()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await LoginAsync(factory, "alice@example.test");
        var envelope = Envelope();
        var first = await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope, envelope]));
        first.EnsureSuccessStatusCode();
        Assert.That((await first.Content.ReadFromJsonAsync<PushSyncResponse>())!.Accepted, Is.EqualTo(1));
        var retry = await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]));
        retry.EnsureSuccessStatusCode();
        Assert.That((await retry.Content.ReadFromJsonAsync<PushSyncResponse>())!.Accepted, Is.Zero);
        Assert.That((await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!.Envelopes, Has.Count.EqualTo(1));
    }

    [Test]
    public async Task ConcurrentRetryStoresOneEnvelope()
    {
        await using var factory = new LifenizerApiFactory();
        using var firstDevice = await LoginAsync(factory, "alice@example.test");
        using var secondDevice = await LoginAsync(factory, "alice@example.test");
        var request = new PushSyncRequest([Envelope()]);
        var responses = await Task.WhenAll(firstDevice.PostAsJsonAsync("/api/sync/push", request), secondDevice.PostAsJsonAsync("/api/sync/push", request));
        foreach (var response in responses) response.EnsureSuccessStatusCode();
        var accepted = await Task.WhenAll(responses.Select(response => response.Content.ReadFromJsonAsync<PushSyncResponse>()));
        Assert.That(accepted.Sum(response => response!.Accepted), Is.EqualTo(1));
        Assert.That((await firstDevice.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!.Envelopes, Has.Count.EqualTo(1));
    }

    [Test]
    public async Task CollidingEnvelopeFromAnotherAccountRejectsWholeBatch()
    {
        await using var factory = new LifenizerApiFactory();
        using var alice = await LoginAsync(factory, "alice@example.test");
        using var bob = await LoginAsync(factory, "bob@example.test");
        var envelope = Envelope();
        (await alice.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]))).EnsureSuccessStatusCode();
        var conflict = await bob.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([Envelope(), envelope with { CipherText = "bob-data" }]));
        Assert.That(conflict.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That((await bob.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!.Envelopes, Is.Empty);
        Assert.That((await alice.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!.Envelopes.Single().CipherText, Is.EqualTo(envelope.CipherText));
    }

    [Test]
    public async Task PullCursorIncludesEveryPageWithoutSkippingRecords()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await LoginAsync(factory, "alice@example.test");
        var envelopes = Enumerable.Range(0, 501).Select(_ => Envelope()).ToArray();
        (await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest(envelopes))).EnsureSuccessStatusCode();
        var page = (await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!;
        Assert.That(page.Envelopes, Has.Count.EqualTo(500));
        var last = (await client.GetFromJsonAsync<PullSyncResponse>($"/api/sync/pull?since={page.Cursor}"))!;
        Assert.That(last.Envelopes, Has.Count.EqualTo(1));
        Assert.That(page.Envelopes.Concat(last.Envelopes).Select(envelope => envelope.Id), Is.EquivalentTo(envelopes.Select(envelope => envelope.Id)));
        var empty = (await client.GetFromJsonAsync<PullSyncResponse>($"/api/sync/pull?since={last.Cursor}"))!;
        Assert.That(empty.Envelopes, Is.Empty);
        Assert.That(empty.Cursor, Is.EqualTo(last.Cursor));
    }

    private static SyncEnvelopeDto Envelope() => new(Guid.NewGuid(), "test", "conversation", "memory", "upsert", 1, "encrypted-memory", "nonce", "vault-v1", DateTimeOffset.UtcNow);

    private static async Task<HttpClient> LoginAsync(LifenizerApiFactory factory, string email)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email));
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>())!;
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        return client;
    }
}
