using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class RecordingTests
{
    private static readonly byte[] Envelope = JsonSerializer.SerializeToUtf8Bytes(new
    {
        cipherText = Convert.ToBase64String(Encoding.UTF8.GetBytes("opaque encrypted recording")),
        nonce = Convert.ToBase64String(new byte[12]), keyId = "test-key"
    });
    private static HttpContent Content() => new ByteArrayContent(Envelope) { Headers = { ContentType = new("application/json") } };
    private static async Task Login(HttpClient client, string email)
    {
        using var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email, email));
        response.EnsureSuccessStatusCode();
        var auth = await response.Content.ReadFromJsonAsync<AuthResponse>();
        client.DefaultRequestHeaders.Authorization = new("Bearer", auth!.AuthToken);
    }
    private static string NewRoot() => Path.Combine(Path.GetTempPath(), "lifenizer-recording-tests", Guid.NewGuid().ToString("N"));

    [Test]
    public async Task PersistenceIsOptInVaultIsolatedAndQuotaAccounted()
    {
        var root = NewRoot();
        try
        {
            await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Artifacts:StorePath"] = root });
            using var owner = factory.CreateClient();
            using var other = factory.CreateClient();
            Assert.That((await owner.GetAsync("/api/recordings/chat")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
            await Login(owner, "recording-owner@example.test");
            await Login(other, "recording-other@example.test");
            Assert.That((await owner.GetAsync("/api/recordings/chat")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
            Assert.That(Directory.Exists(root), Is.False);
            (await owner.PutAsync("/api/recordings/chat", Content())).EnsureSuccessStatusCode();
            Assert.That(await owner.GetByteArrayAsync("/api/recordings/chat"), Is.EqualTo(Envelope));
            Assert.That((await other.GetAsync("/api/recordings/chat")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
            Assert.That((await other.DeleteAsync("/api/recordings/chat")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
            (await owner.PutAsync("/api/recordings/chat", Content())).EnsureSuccessStatusCode();
            using var scope = factory.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
            Assert.That((await db.Users.SingleAsync(user => user.Email == "recording-owner@example.test")).StorageUsedBytes, Is.EqualTo(Envelope.Length));
            Assert.That(Directory.GetFiles(root, "*.bin", SearchOption.AllDirectories).Length, Is.EqualTo(1));
            Assert.That(await File.ReadAllBytesAsync(Directory.GetFiles(root, "*.bin", SearchOption.AllDirectories).Single()), Is.EqualTo(Envelope));
            (await owner.DeleteAsync("/api/recordings/chat")).EnsureSuccessStatusCode();
            db.ChangeTracker.Clear();
            Assert.That((await db.Users.SingleAsync(user => user.Email == "recording-owner@example.test")).StorageUsedBytes, Is.Zero);
            Assert.That(Directory.GetFiles(root, "*.bin", SearchOption.AllDirectories), Is.Empty);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Test]
    public async Task LiveProviderRelaysEncryptedBytesWithoutPersistingAndRejectsOtherVault()
    {
        var root = NewRoot();
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Artifacts:StorePath"] = root });
        using var owner = factory.CreateClient();
        using var other = factory.CreateClient();
        await Login(owner, "relay-owner@example.test");
        await Login(other, "relay-other@example.test");
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var stream = await owner.GetAsync("/api/recordings/requests", HttpCompletionOption.ResponseHeadersRead, cancellation.Token);
        stream.EnsureSuccessStatusCode();
        using var reader = new StreamReader(await stream.Content.ReadAsStreamAsync(cancellation.Token));
        Assert.That(await reader.ReadLineAsync(cancellation.Token), Is.EqualTo(": ready"));
        var download = owner.GetAsync("/api/recordings/recording-chat", cancellation.Token);
        string? line;
        do { line = await reader.ReadLineAsync(cancellation.Token); } while (line is not null && !line.StartsWith("data: "));
        using var request = JsonDocument.Parse(line![6..]);
        var id = request.RootElement.GetProperty("requestId").GetGuid();
        Assert.That(request.RootElement.GetProperty("conversationId").GetString(), Is.EqualTo("recording-chat"));
        Assert.That((await other.PostAsync($"/api/recordings/requests/{id}", Content(), cancellation.Token)).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        (await owner.PostAsync($"/api/recordings/requests/{id}", Content(), cancellation.Token)).EnsureSuccessStatusCode();
        using var result = await download;
        Assert.That(await result.Content.ReadAsByteArrayAsync(cancellation.Token), Is.EqualTo(Envelope));
        Assert.That((await owner.PostAsync($"/api/recordings/requests/{id}", Content(), cancellation.Token)).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(Directory.Exists(root), Is.False);
        using var scope = factory.Services.CreateScope();
        Assert.That(await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Recordings.CountAsync(), Is.Zero);
        cancellation.Cancel();
    }

    [Test]
    public async Task MissingProviderReplyTimesOutAndExpiresRequest()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Recordings:RelayTimeoutSeconds"] = "0.05" });
        using var owner = factory.CreateClient();
        await Login(owner, "relay-timeout@example.test");
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var stream = await owner.GetAsync("/api/recordings/requests", HttpCompletionOption.ResponseHeadersRead, cancellation.Token);
        using var reader = new StreamReader(await stream.Content.ReadAsStreamAsync(cancellation.Token));
        var download = owner.GetAsync("/api/recordings/chat", cancellation.Token);
        string? line;
        do { line = await reader.ReadLineAsync(cancellation.Token); } while (line is not null && !line.StartsWith("data: "));
        using var request = JsonDocument.Parse(line![6..]);
        var id = request.RootElement.GetProperty("requestId").GetGuid();
        Assert.That((await download).StatusCode, Is.EqualTo(HttpStatusCode.GatewayTimeout));
        Assert.That((await owner.PostAsync($"/api/recordings/requests/{id}", Content(), cancellation.Token)).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        cancellation.Cancel();
    }

    [Test]
    public async Task InvalidAndOversizedEnvelopesNeverPersist()
    {
        var root = NewRoot();
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Artifacts:StorePath"] = root, ["Recordings:MaxRequestBytes"] = "1024" });
        using var client = factory.CreateClient();
        await Login(client, "recording-bounds@example.test");
        Assert.That((await client.PutAsync("/api/recordings/chat", new StringContent("plaintext audio"))).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await client.PutAsync("/api/recordings/chat", new StringContent(new string('x', 1025)))).StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
        Assert.That(Directory.Exists(root), Is.False);
    }

    [Test]
    public async Task OnlineStorageRejectsQuotaOverflowWithoutCreatingABlob()
    {
        var root = NewRoot();
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Artifacts:StorePath"] = root });
        using var client = factory.CreateClient();
        await Login(client, "recording-quota@example.test");
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        await db.Users.ExecuteUpdateAsync(update => update.SetProperty(user => user.StorageUsedBytes, StorageQuota.FreeLimitBytes));
        Assert.That((await client.PutAsync("/api/recordings/chat", Content())).StatusCode, Is.EqualTo(HttpStatusCode.PaymentRequired));
        Assert.That(await db.Recordings.CountAsync(), Is.Zero);
        Assert.That(Directory.Exists(root), Is.False);
    }

    [Test]
    public async Task RelayBoundsAndDisconnectionCleanUpPendingRequests()
    {
        var relay = new RecordingRelay();
        var vault = Guid.NewGuid();
        var subscription = relay.Subscribe(vault)!.Value;
        var first = relay.RequestAsync(vault, "one", TimeSpan.FromSeconds(5), default);
        var second = relay.RequestAsync(vault, "two", TimeSpan.FromSeconds(5), default);
        Assert.ThrowsAsync<InvalidOperationException>(async () => await relay.RequestAsync(vault, "three", TimeSpan.FromSeconds(5), default));
        relay.Unsubscribe(subscription.Id);
        Assert.ThrowsAsync<IOException>(async () => await first);
        Assert.ThrowsAsync<IOException>(async () => await second);
        Assert.That(await relay.RequestAsync(vault, "one", TimeSpan.FromSeconds(5), default), Is.Null);
    }
}
