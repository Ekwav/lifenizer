using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Amazon.S3;
using Lifenizer.Api.Data;
using Lifenizer.Core;
using Microsoft.AspNetCore.Hosting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class BatchedSyncTests
{
    private static SyncEnvelopeDto Envelope(string ciphertext = "encrypted-memory") =>
        new(Guid.NewGuid(), "phone", "conversation", Guid.NewGuid().ToString(), "upsert", 1, ciphertext, "nonce", "vault-v1", DateTimeOffset.UtcNow);

    [Test]
    public async Task BatchedObjectsPreservePagingIsolationLegacyDataAndRetryWithoutExtraWrites()
    {
        var s3 = new ObjectStoreTests.FakeS3();
        await using var factory = new LifenizerApiFactory(ObjectStoreTests.Config(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString())))
            .WithWebHostBuilder(builder => builder.ConfigureServices(services => services.AddSingleton<IAmazonS3>(s3)));
        using var phone = factory.CreateClient();
        using var pc = factory.CreateClient();
        using var other = factory.CreateClient();
        var auth = await Login(phone, "batch@example.test");
        await Login(pc, "batch@example.test");
        await Login(other, "other@example.test");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        var legacy = Envelope("legacy-ciphertext");
        db.SyncEnvelopes.Add(new SyncEnvelopeRecord { Id = legacy.Id, UserId = auth.UserId, VaultId = auth.VaultId, CipherText = legacy.CipherText });
        await db.SaveChangesAsync();
        var batch = Enumerable.Range(0, 501).Select(i => Envelope($"ciphertext-{i}")).ToArray();
        var first = await phone.PostAsJsonAsync("/api/sync/push", new PushSyncRequest(batch));
        first.EnsureSuccessStatusCode();
        Assert.That((await first.Content.ReadFromJsonAsync<PushSyncResponse>())!.Accepted, Is.EqualTo(501));
        (await phone.PostAsJsonAsync("/api/sync/push", new PushSyncRequest(batch))).EnsureSuccessStatusCode();
        Assert.That(s3.Writes, Is.EqualTo(1));
        Assert.That(s3.Objects.Count, Is.EqualTo(1));
        Assert.That(await db.SyncEnvelopes.CountAsync(e => e.BlobKey != null && e.CipherText == ""), Is.EqualTo(501));
        var page = (await pc.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!;
        Assert.That(page.Envelopes[0].CipherText, Is.EqualTo(legacy.CipherText));
        Assert.That(page.Envelopes.Count, Is.EqualTo(500));
        var tail = (await pc.GetFromJsonAsync<PullSyncResponse>($"/api/sync/pull?since={page.Cursor}"))!;
        Assert.That(tail.Envelopes.Count, Is.EqualTo(2));
        Assert.That(page.Envelopes.Skip(1).Concat(tail.Envelopes).Select(e => e.CipherText), Is.EqualTo(batch.Select(e => e.CipherText)));
        Assert.That(s3.Reads, Is.EqualTo(2));
        Assert.That((await other.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!.Envelopes, Is.Empty);
        Assert.That(s3.Reads, Is.EqualTo(2));
        var used = (await db.Users.AsNoTracking().SingleAsync(u => u.Id == auth.UserId)).StorageUsedBytes;
        Assert.That(used, Is.EqualTo(s3.Objects.Single().Value.LongLength));

        // A missing or corrupt object must never turn into an acknowledged empty page.
        var key = s3.Objects.Keys.Single();
        s3.Objects[key] = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<Guid, string>());
        Assert.That((await pc.GetAsync("/api/sync/pull?since=0")).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        s3.Objects.Clear();
        Assert.That((await pc.GetAsync("/api/sync/pull?since=0")).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
    }

    [Test]
    public async Task FailedUploadsInvalidCiphertextAndQuotaDoNotAdvanceSyncOrConsumeStorage()
    {
        var s3 = new ObjectStoreTests.FakeS3();
        await using var factory = new LifenizerApiFactory(ObjectStoreTests.Config(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString())))
            .WithWebHostBuilder(builder => builder.ConfigureServices(services => services.AddSingleton<IAmazonS3>(s3)));
        using var client = factory.CreateClient();
        var auth = await Login(client, "failures@example.test");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        var request = new PushSyncRequest([Envelope()]);
        foreach (var invalid in new[] { "", null })
            Assert.That((await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([Envelope(invalid!)]))).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(s3.Writes, Is.Zero);
        s3.Failure = HttpStatusCode.ServiceUnavailable;
        Assert.That((await client.PostAsJsonAsync("/api/sync/push", request)).StatusCode, Is.EqualTo(HttpStatusCode.InternalServerError));
        s3.Failure = null;
        Assert.That(await db.SyncEnvelopes.CountAsync(), Is.Zero);
        Assert.That((await db.Users.AsNoTracking().SingleAsync()).StorageUsedBytes, Is.Zero);
        (await client.PostAsJsonAsync("/api/sync/push", request)).EnsureSuccessStatusCode();
        await db.Users.Where(u => u.Id == auth.UserId).ExecuteUpdateAsync(setters => setters.SetProperty(u => u.StorageUsedBytes, StorageQuota.FreeLimitBytes));
        Assert.That((await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([Envelope()]))).StatusCode, Is.EqualTo(HttpStatusCode.PaymentRequired));
        var retry = await client.PostAsJsonAsync("/api/sync/push", request);
        retry.EnsureSuccessStatusCode();
        Assert.That((await retry.Content.ReadFromJsonAsync<PushSyncResponse>())!.Accepted, Is.Zero);
        Assert.That(s3.Writes, Is.EqualTo(1));
        Assert.That(await db.SyncEnvelopes.CountAsync(), Is.EqualTo(1));
    }

    private static async Task<AuthResponse> Login(HttpClient client, string email)
    {
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email));
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>())!;
        client.DefaultRequestHeaders.Authorization = new("Bearer", auth.AuthToken);
        return auth;
    }
}
