using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using Amazon.S3;
using Amazon.S3.Model;
using Coflnet.Payments.Client.Api;
using Lifenizer.Api.Data;
using Lifenizer.Api.Endpoints;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Hosting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace Lifenizer.Tests;

public sealed class OnlineStorageRetentionTests
{
    [Test]
    public async Task FeedbackRequiresAuthenticationValidatesAndPersistsTrimmedText()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        Assert.That((await client.PostAsJsonAsync("/api/premium/cancellation-feedback", new { feedback = "reason" })).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        var auth = await Login(client, "feedback");
        foreach (var feedback in new string?[] { null, "", "  ", new('x', 2001) })
            Assert.That((await client.PostAsJsonAsync("/api/premium/cancellation-feedback", new { feedback })).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await client.PostAsJsonAsync("/api/premium/cancellation-feedback", new { feedback = "  too expensive  " })).StatusCode, Is.EqualTo(HttpStatusCode.NoContent));
        using var scope = factory.Services.CreateScope();
        var record = await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().UsageEvents.SingleAsync();
        Assert.Multiple(() =>
        {
            Assert.That(record.UserId, Is.EqualTo(auth.UserId));
            Assert.That(record.VaultId, Is.EqualTo(auth.VaultId));
            Assert.That(record.Kind, Is.EqualTo("premium_cancellation_feedback"));
            Assert.That(record.Quantity, Is.EqualTo(1));
            Assert.That(record.Unit, Is.EqualTo("response"));
            Assert.That(JsonDocument.Parse(record.MetadataJson).RootElement.GetProperty("feedback").GetString(), Is.EqualTo("too expensive"));
        });
    }

    [Test]
    public async Task ScheduleIsThirtyDaysIdempotentDurableAndClearedByReactivation()
    {
        var path = Path.Combine(Path.GetTempPath(), $"retention-{Guid.NewGuid():N}.db");
        var config = new Dictionary<string, string?> { ["ConnectionStrings:Lifenizer"] = $"Data Source={path}", ["Payments:FreePremiumEnabled"] = "true", ["Payments:BaseUrl"] = "" };
        DateTimeOffset deadline;
        try
        {
            await using (var factory = new LifenizerApiFactory(config))
            {
                using var client = factory.CreateClient();
                await Login(client, "schedule");
                Assert.That((await Cancel(client)).GetProperty("onlineStorageDeleteAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
                (await client.PostAsync("/api/premium/activate", null)).EnsureSuccessStatusCode();
                var before = DateTimeOffset.UtcNow.AddDays(30).AddSeconds(-1);
                deadline = (await Cancel(client)).GetProperty("onlineStorageDeleteAt").GetDateTimeOffset();
                Assert.That(deadline, Is.InRange(before, DateTimeOffset.UtcNow.AddDays(30)));
                Assert.That((await Cancel(client)).GetProperty("onlineStorageDeleteAt").GetDateTimeOffset(), Is.EqualTo(deadline));
            }
            await using (var restarted = new LifenizerApiFactory(config))
            {
                using var client = restarted.CreateClient();
                await Login(client, "schedule");
                Assert.That((await client.GetFromJsonAsync<JsonElement>("/api/premium/status")).GetProperty("onlineStorageDeleteAt").GetDateTimeOffset(), Is.EqualTo(deadline));
                var activated = await client.PostAsync("/api/premium/activate", null);
                Assert.That((await activated.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("onlineStorageDeleteAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
            }
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); File.Delete(path); }
    }

    [Test]
    public async Task CleanupDeletesOnlyDueOwnersObjectsAndRetriesFailuresWithoutLosingReferences()
    {
        var deleted = new List<string>();
        var fail = true;
        var remote = Proxy<IAmazonS3>((method, args) =>
        {
            if (method.Name == "Dispose") return null;
            Assert.That(method.Name, Is.EqualTo("DeleteObjectsAsync"));
            var keys = ((DeleteObjectsRequest)args![0]!).Objects.Select(item => item.Key).ToArray();
            deleted.AddRange(keys);
            return Task.FromResult(new DeleteObjectsResponse { DeleteErrors = fail ? [new DeleteError { Key = "image", Code = "InternalError" }] : [] });
        });
        var config = new Dictionary<string, string?>
        {
            ["Payments:BaseUrl"] = "", ["ObjectStorage:Bucket"] = "test", ["ObjectStorage:AccessKeyId"] = "test",
            ["ObjectStorage:SecretAccessKey"] = "test", ["ObjectStorage:ServiceUrl"] = "https://objects.example.test"
        };
        await using var factory = new LifenizerApiFactory(config).WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            services.AddSingleton(provider => new ObjectStore(provider.GetRequiredService<IConfiguration>(), NullLogger<ObjectStore>.Instance, remote))));
        using var client = factory.CreateClient();
        var owner = await Login(client, "due");
        var other = await Login(client, "future");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        await db.Users.Where(user => user.Id == owner.UserId).ExecuteUpdateAsync(s => s.SetProperty(u => u.OnlineStorageDeleteAtUnixSeconds, DateTimeOffset.UtcNow.AddSeconds(-1).ToUnixTimeSeconds()).SetProperty(u => u.StorageUsedBytes, 999));
        await db.Users.Where(user => user.Id == other.UserId).ExecuteUpdateAsync(s => s.SetProperty(u => u.OnlineStorageDeleteAtUnixSeconds, DateTimeOffset.UtcNow.AddDays(1).ToUnixTimeSeconds()));
        foreach (var key in new string?[] { "sync/batch", "sync/batch", null })
            db.SyncEnvelopes.Add(new SyncEnvelopeRecord { Id = Guid.NewGuid(), UserId = owner.UserId, VaultId = owner.VaultId, BlobKey = key, CipherText = key is null ? "inline" : "" });
        db.SyncEnvelopes.Add(new SyncEnvelopeRecord { Id = Guid.NewGuid(), UserId = other.UserId, VaultId = other.VaultId, BlobKey = "other" });
        db.Images.Add(new ImageRecord { Id = Guid.NewGuid(), UserId = owner.UserId, BlobPath = "image" });
        db.Recordings.Add(new RecordingRecord { VaultId = owner.VaultId, UserId = owner.UserId, ConversationId = "recording", BlobName = "encrypted.bin" });
        db.UsageEvents.Add(new UsageEventRecord { Id = Guid.NewGuid(), UserId = owner.UserId, VaultId = owner.VaultId, Kind = "premium_cancellation_feedback" });
        await db.SaveChangesAsync();
        var retention = scope.ServiceProvider.GetRequiredService<OnlineStorageRetention>();
        await retention.DeleteDueAsync(default);
        Assert.That(await db.SyncEnvelopes.CountAsync(), Is.EqualTo(4));
        Assert.That(await db.Images.CountAsync(), Is.EqualTo(1));
        Assert.That((await db.Users.AsNoTracking().SingleAsync(u => u.Id == owner.UserId)).StorageUsedBytes, Is.EqualTo(999));
        fail = false;
        await retention.DeleteDueAsync(default);
        Assert.That(deleted.Count(key => key == "sync/batch"), Is.EqualTo(2), "One shared batch deletion per attempt");
        Assert.That(deleted, Does.Contain(RecordingEndpoints.ObjectKey(owner.VaultId, "encrypted.bin")));
        Assert.That(deleted, Does.Not.Contain("other"));
        Assert.That((await db.SyncEnvelopes.SingleAsync()).UserId, Is.EqualTo(other.UserId));
        Assert.That(await db.Images.CountAsync(), Is.Zero);
        Assert.That(await db.Recordings.CountAsync(), Is.Zero);
        Assert.That(await db.Users.CountAsync(), Is.EqualTo(2));
        Assert.That(await db.UsageEvents.CountAsync(), Is.EqualTo(1));
        var preserved = await db.Users.AsNoTracking().SingleAsync(u => u.Id == owner.UserId);
        Assert.That(preserved.StorageUsedBytes, Is.Zero);
        Assert.That(preserved.VaultId, Is.EqualTo(owner.VaultId));
        Assert.That(preserved.VaultSalt, Is.EqualTo(owner.VaultSalt));
        Assert.That(preserved.OnlineStorageDeleteAtUnixSeconds, Is.Not.Null);
        await Login(client, "due");
        var envelope = new SyncEnvelopeDto(Guid.NewGuid(), "test", "conversation", "new", "upsert", 1, "cipher", "nonce", "key", DateTimeOffset.UtcNow);
        Assert.That((await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]))).StatusCode, Is.EqualTo(HttpStatusCode.PaymentRequired));
    }

    [Test]
    public async Task SyntheticPremiumStatusCannotClearAStoredCancellationDeadline()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Payments:FreePremiumEnabled"] = "true", ["Payments:BaseUrl"] = "" });
        using var client = factory.CreateClient();
        await Login(client, "stale-grant");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        var deadline = DateTimeOffset.UtcNow.AddDays(30).ToUnixTimeSeconds();
        // Reproduce the stale grant snapshot an older status request could observe as cancellation commits.
        await db.Users.ExecuteUpdateAsync(s => s.SetProperty(u => u.FreePremiumActivatedAt, DateTimeOffset.UtcNow)
            .SetProperty(u => u.OnlineStorageDeleteAtUnixSeconds, deadline));
        var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
        Assert.That(status.GetProperty("plan").GetString(), Is.EqualTo("Premium"));
        Assert.That(status.GetProperty("onlineStorageDeleteAt").GetDateTimeOffset().ToUnixTimeSeconds(), Is.EqualTo(deadline));
        Assert.That((await db.Users.AsNoTracking().SingleAsync()).OnlineStorageDeleteAtUnixSeconds, Is.EqualTo(deadline));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task CleanupSerializesWithConcurrentActivationAndUpload(bool activate)
    {
        var deleting = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<DeleteObjectsResponse> Delete()
        {
            deleting.SetResult();
            await release.Task;
            return new DeleteObjectsResponse();
        }
        var remote = Proxy<IAmazonS3>((method, _) => method.Name == "Dispose" ? null : Delete());
        var config = new Dictionary<string, string?>
        {
            ["Payments:BaseUrl"] = "", ["Payments:FreePremiumEnabled"] = "true",
            ["ObjectStorage:Bucket"] = "test", ["ObjectStorage:AccessKeyId"] = "test",
            ["ObjectStorage:SecretAccessKey"] = "test", ["ObjectStorage:ServiceUrl"] = "https://objects.example.test"
        };
        await using var factory = new LifenizerApiFactory(config).WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            services.AddSingleton(provider => new ObjectStore(provider.GetRequiredService<IConfiguration>(), NullLogger<ObjectStore>.Instance, remote))));
        using var client = factory.CreateClient();
        var auth = await Login(client, "race");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        await db.Users.ExecuteUpdateAsync(s => s.SetProperty(u => u.OnlineStorageDeleteAtUnixSeconds, DateTimeOffset.UtcNow.AddSeconds(-1).ToUnixTimeSeconds()));
        db.Images.Add(new ImageRecord { Id = Guid.NewGuid(), UserId = auth.UserId, BlobPath = "old-image" });
        await db.SaveChangesAsync();
        var cleanup = scope.ServiceProvider.GetRequiredService<OnlineStorageRetention>().DeleteDueAsync(default);
        await deleting.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var envelope = new SyncEnvelopeDto(Guid.NewGuid(), "test", "conversation", "new", "upsert", 1, "cipher", "nonce", "key", DateTimeOffset.UtcNow);
        var request = activate ? client.PostAsync("/api/premium/activate", null)
            : client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]));
        try
        {
            Assert.That(await Task.WhenAny(request, Task.Delay(100)), Is.Not.SameAs(request), "Mutation must wait for deletion's SQLite write lock");
        }
        finally { release.TrySetResult(); }
        await cleanup.WaitAsync(TimeSpan.FromSeconds(5));
        var response = await request.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.That(response.StatusCode, Is.EqualTo(activate ? HttpStatusCode.OK : HttpStatusCode.PaymentRequired));
        Assert.That(await db.Images.CountAsync(), Is.Zero);
        Assert.That(await db.SyncEnvelopes.CountAsync(), Is.Zero);
        Assert.That((await db.Users.AsNoTracking().SingleAsync()).OnlineStorageDeleteAtUnixSeconds is null, Is.EqualTo(activate));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task CleanupProtectsPaidEntitlementAndFailsClosedOnProviderOutage(bool outage)
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Payments:BaseUrl"] = "https://payments.example.test" })
            .WithWebHostBuilder(builder => builder.ConfigureServices(services => services.AddSingleton(Proxy<IUserApi>((_, args) =>
            {
                if (outage) throw new IOException("synthetic payments outage");
                return Task.FromResult(new Dictionary<string, DateTime> { [((List<string>)args![1]!).Single()] = DateTime.UtcNow.AddDays(2) });
            }))));
        using var client = factory.CreateClient();
        var auth = await Login(client, "paid");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        await db.Users.ExecuteUpdateAsync(s => s.SetProperty(u => u.OnlineStorageDeleteAtUnixSeconds, DateTimeOffset.UtcNow.AddDays(-1).ToUnixTimeSeconds()));
        db.SyncEnvelopes.Add(new SyncEnvelopeRecord { Id = Guid.NewGuid(), UserId = auth.UserId, VaultId = auth.VaultId, CipherText = "keep" });
        await db.SaveChangesAsync();
        var retention = scope.ServiceProvider.GetRequiredService<OnlineStorageRetention>();
        await retention.DeleteDueAsync(default);
        Assert.That(await db.SyncEnvelopes.CountAsync(), Is.EqualTo(1));
        Assert.That((await db.Users.AsNoTracking().SingleAsync()).OnlineStorageDeleteAtUnixSeconds is null, Is.EqualTo(!outage));
    }

    private static async Task<AuthResponse> Login(HttpClient client, string name)
    {
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest($"{name}@retention.test", name));
        response.EnsureSuccessStatusCode();
        var auth = (await response.Content.ReadFromJsonAsync<AuthResponse>())!;
        client.DefaultRequestHeaders.Authorization = new("Bearer", auth.AuthToken);
        return auth;
    }
    private static async Task<JsonElement> Cancel(HttpClient client)
    {
        var response = await client.PostAsync("/api/premium/cancel-free", null);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    private static T Proxy<T>(Func<MethodInfo, object?[]?, object?> call) where T : class
    {
        var proxy = DispatchProxy.Create<T, PremiumTests.PaymentProxy>();
        ((PremiumTests.PaymentProxy)(object)proxy).Call = call;
        return proxy;
    }
}
