using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Data;
using Lifenizer.Core;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;

namespace Lifenizer.Tests;

public sealed class PairingTests
{
    private sealed class Harness : IAsyncDisposable
    {
        public readonly byte[] Secret = RandomNumberGenerator.GetBytes(32);
        public readonly LifenizerApiFactory Factory;
        public readonly HttpClient Client;
        public readonly string BootstrapToken;
        public Harness(bool expired = false)
        {
            BootstrapToken = Base64UrlEncoder.Encode(HMACSHA256.HashData(Secret, Encoding.UTF8.GetBytes("lifenizer:enroll:v1")));
            Factory = new LifenizerApiFactory(new Dictionary<string, string?>
            {
                ["Pairing:BootstrapTokenHash"] = Hash(BootstrapToken),
                ["Pairing:BootstrapExpiresAt"] = DateTimeOffset.UtcNow.AddMinutes(expired ? -1 : 59).ToString("O")
            });
            Client = Factory.CreateClient();
        }
        public (PairingEnrollmentRequest Request, string RefreshToken) Enrollment(string name)
        {
            var refresh = Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(32));
            var key = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
            var nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
            var hash = Hash(refresh);
            var proof = Convert.ToBase64String(HMACSHA256.HashData(Secret, Encoding.UTF8.GetBytes($"lifenizer:device:v1\n{key}\n{nonce}\n{name}\n{hash}")));
            return (new PairingEnrollmentRequest(BootstrapToken, name, key, nonce, proof, hash), refresh);
        }
        public async Task<JsonElement> Enroll(PairingEnrollmentRequest request) => await Json(await Client.PostAsJsonAsync("/api/pairing/request", request));
        public async Task<JsonElement> Bootstrap()
        {
            var result = await Enroll(Enrollment("Desktop").Request);
            Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", result.GetProperty("session").GetProperty("authToken").GetString());
            return result;
        }
        public async ValueTask DisposeAsync() { Client.Dispose(); await Factory.DisposeAsync(); }
    }
    private static string Hash(string token) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
    private static async Task<JsonElement> Json(HttpResponseMessage response)
    {
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<JsonElement>());
    }
    private static PairingTransfer Transfer() => new(Convert.ToBase64String(Encoding.UTF8.GetBytes("opaque-encrypted-vault-transfer")), Convert.ToBase64String(RandomNumberGenerator.GetBytes(12)), Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)));

    [Test]
    public async Task ConcurrentFirstDevicesBindExactlyOnePasswordlessOwnerAndRequireApproval()
    {
        await using var harness = new Harness();
        var results = await Task.WhenAll(harness.Enroll(harness.Enrollment("Desktop").Request), harness.Enroll(harness.Enrollment("Phone").Request));
        Assert.That(results.Count(result => result.GetProperty("status").GetString() == "bootstrap"), Is.EqualTo(1));
        var pending = results.Single(result => result.GetProperty("status").GetString() == "pending");
        Assert.That(pending.TryGetProperty("session", out _), Is.False);
        using var scope = harness.Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        var owner = await db.Users.SingleAsync();
        Assert.Multiple(() =>
        {
            Assert.That(owner.PasswordHash, Is.Null);
            Assert.That(owner.Email, Does.EndWith("@lifenizer.invalid"));
            Assert.That(Convert.FromBase64String(owner.VaultSalt), Has.Length.EqualTo(32));
        });
        Assert.That((await db.PairingStates.SingleAsync()).UserId, Is.EqualTo(owner.Id));
        Assert.That((await db.PairingRequests.SingleAsync()).UserId, Is.EqualTo(owner.Id));
        Assert.That(await db.PairedDevices.CountAsync(), Is.EqualTo(1));
        var bootstrap = results.Single(result => result.GetProperty("status").GetString() == "bootstrap");
        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(bootstrap.GetProperty("session").GetProperty("authToken").GetString());
        Assert.That(jwt.ValidTo - jwt.ValidFrom, Is.EqualTo(TimeSpan.FromHours(1)));
    }

    [Test]
    public async Task LostBootstrapResponseCanBeRetriedOnlyByInitialDeviceWithinWindow()
    {
        await using var harness = new Harness();
        var initialDevice = harness.Enrollment("Desktop");
        var first = await harness.Enroll(initialDevice.Request);
        var retried = await harness.Enroll(initialDevice.Request);
        Assert.That(retried.GetProperty("status").GetString(), Is.EqualTo("bootstrap"));
        Assert.That(retried.GetProperty("deviceId").GetGuid(), Is.EqualTo(first.GetProperty("deviceId").GetGuid()));
        Assert.That(retried.GetProperty("session").GetProperty("vaultSalt").GetString(), Is.EqualTo(first.GetProperty("session").GetProperty("vaultSalt").GetString()));
        var otherDevice = harness.Enrollment("Phone");
        Assert.That((await harness.Enroll(otherDevice.Request)).GetProperty("status").GetString(), Is.EqualTo("pending"));
        Assert.That((await harness.Enroll(otherDevice.Request)).GetProperty("status").GetString(), Is.EqualTo("pending"));
        harness.Factory.Services.GetRequiredService<IConfiguration>()["Pairing:BootstrapExpiresAt"] = DateTimeOffset.UtcNow.AddHours(-1).ToString("O");
        Assert.That((await harness.Enroll(initialDevice.Request)).GetProperty("status").GetString(), Is.EqualTo("pending"));
        using var scope = harness.Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        Assert.That(await db.Users.CountAsync(), Is.EqualTo(1));
        Assert.That(await db.PairedDevices.CountAsync(), Is.EqualTo(1));
    }

    [Test]
    public async Task BootstrapCannotStartAfterDeadlineButBoundLinkRemainsApprovalOnly()
    {
        await using (var expired = new Harness(expired: true))
        {
            var result = await expired.Client.PostAsJsonAsync("/api/pairing/request", expired.Enrollment("Phone").Request);
            Assert.That(result.StatusCode, Is.EqualTo(HttpStatusCode.Gone));
            using var scope = expired.Factory.Services.CreateScope();
            Assert.That(await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Users.CountAsync(), Is.Zero);
        }
        await using var bound = new Harness();
        await bound.Bootstrap();
        bound.Factory.Services.GetRequiredService<IConfiguration>()["Pairing:BootstrapExpiresAt"] = DateTimeOffset.UtcNow.AddHours(-1).ToString("O");
        var pending = await bound.Enroll(bound.Enrollment("Phone").Request);
        Assert.That(pending.GetProperty("status").GetString(), Is.EqualTo("pending"));
        Assert.That(pending.TryGetProperty("session", out _), Is.False);
    }

    [Test]
    public async Task OwnerOnlyApprovalTransfersOpaqueSecretRetryablyAndNeverStoresCredentials()
    {
        await using var harness = new Harness();
        var owner = await harness.Bootstrap();
        var enrollment = harness.Enrollment("Phone");
        var pending = await harness.Enroll(enrollment.Request);
        var id = pending.GetProperty("requestId").GetGuid();
        var requestToken = pending.GetProperty("requestToken").GetString()!;
        using var other = harness.Factory.CreateClient();
        var otherSession = await Json(await other.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest("other@example.test", "separate-account-password")));
        other.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", otherSession.GetProperty("authToken").GetString());
        Assert.That((await other.GetFromJsonAsync<JsonElement[]>("/api/pairing/pending"))!, Is.Empty);
        var transfer = Transfer();
        Assert.That((await other.PostAsJsonAsync($"/api/pairing/{id}/approve", transfer)).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That((await other.PostAsJsonAsync($"/api/pairing/{id}/deny", new { })).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        var listed = (await harness.Client.GetFromJsonAsync<JsonElement[]>("/api/pairing/pending"))!.Single();
        Assert.That(listed.GetProperty("refreshTokenHash").GetString(), Is.EqualTo(enrollment.Request.RefreshTokenHash));
        Assert.That(listed.GetProperty("proof").GetString(), Is.EqualTo(enrollment.Request.Proof));
        Assert.That((await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/approve", transfer with { Nonce = "bad-nonce" })).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/approve", transfer with { CipherText = new string('x', 65537) })).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/approve", transfer)).StatusCode, Is.EqualTo(HttpStatusCode.NoContent));
        Assert.That((await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/approve", transfer)).StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That((await other.PostAsJsonAsync($"/api/pairing/{id}/poll", new PairingPollRequest(new string('x', 43)))).StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        for (var retry = 0; retry < 2; retry++)
        {
            var approved = await Json(await other.PostAsJsonAsync($"/api/pairing/{id}/poll", new PairingPollRequest(requestToken)));
            Assert.Multiple(() =>
            {
                Assert.That(approved.GetProperty("status").GetString(), Is.EqualTo("approved"));
                Assert.That(approved.GetProperty("session").GetProperty("userId").GetGuid(), Is.EqualTo(owner.GetProperty("session").GetProperty("userId").GetGuid()));
                Assert.That(approved.GetProperty("session").GetProperty("vaultSalt").GetString(), Is.EqualTo(owner.GetProperty("session").GetProperty("vaultSalt").GetString()));
                Assert.That(approved.GetProperty("transfer").GetProperty("cipherText").GetString(), Is.EqualTo(transfer.CipherText));
                Assert.That(approved.GetProperty("deviceId").GetGuid(), Is.EqualTo(id));
            });
        }
        using var scope = harness.Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        var stored = JsonSerializer.Serialize(new { states = await db.PairingStates.ToListAsync(), requests = await db.PairingRequests.ToListAsync(), devices = await db.PairedDevices.ToListAsync() });
        Assert.Multiple(() =>
        {
            Assert.That(stored, Does.Not.Contain(Convert.ToBase64String(harness.Secret)));
            Assert.That(stored, Does.Not.Contain(harness.BootstrapToken));
            Assert.That(stored, Does.Not.Contain(requestToken));
            Assert.That(stored, Does.Not.Contain(enrollment.RefreshToken));
            Assert.That(stored, Does.Not.Contain("opaque-encrypted-vault-transfer"));
        });
        var refreshed = await Json(await other.PostAsJsonAsync("/api/pairing/refresh", new PairingRefreshRequest(id, enrollment.RefreshToken)));
        Assert.That(refreshed.GetProperty("session").GetProperty("userId").GetGuid(), Is.EqualTo(owner.GetProperty("session").GetProperty("userId").GetGuid()));
        Assert.That((await other.DeleteAsync($"/api/pairing/devices/{id}")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That((await harness.Client.DeleteAsync($"/api/pairing/devices/{id}")).StatusCode, Is.EqualTo(HttpStatusCode.NoContent));
        Assert.That((await other.PostAsJsonAsync("/api/pairing/refresh", new PairingRefreshRequest(id, enrollment.RefreshToken))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task DeniedAndExpiredRequestsNeverReceiveSessions()
    {
        await using var harness = new Harness();
        await harness.Bootstrap();
        var pending = await harness.Enroll(harness.Enrollment("Phone").Request);
        var id = pending.GetProperty("requestId").GetGuid();
        var token = new PairingPollRequest(pending.GetProperty("requestToken").GetString()!);
        Assert.That((await Json(await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/poll", token))).GetProperty("status").GetString(), Is.EqualTo("pending"));
        Assert.That((await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/deny", new { })).StatusCode, Is.EqualTo(HttpStatusCode.NoContent));
        Assert.That((await Json(await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/poll", token))).GetProperty("status").GetString(), Is.EqualTo("denied"));
        using var scope = harness.Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        await db.PairingRequests.ExecuteUpdateAsync(setters => setters.SetProperty(request => request.ExpiresAtUnixSeconds, 0));
        Assert.That((await Json(await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/poll", token))).GetProperty("status").GetString(), Is.EqualTo("expired"));
        Assert.That((await harness.Client.PostAsJsonAsync($"/api/pairing/{id}/approve", Transfer())).StatusCode, Is.EqualTo(HttpStatusCode.Gone));
        Assert.That(await db.PairedDevices.CountAsync(), Is.EqualTo(1));
    }

    [Test]
    public async Task RefreshUsesHashedDeviceTokenWithSlidingExpiryAndCannotRebindOwner()
    {
        await using var harness = new Harness();
        var enrollment = harness.Enrollment("Desktop");
        var initial = await harness.Enroll(enrollment.Request);
        var deviceId = initial.GetProperty("deviceId").GetGuid();
        Assert.That((await harness.Client.PostAsJsonAsync("/api/pairing/refresh", new PairingRefreshRequest(deviceId, new string('x', 43)))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await harness.Client.PostAsJsonAsync("/api/pairing/refresh", new PairingRefreshRequest(Guid.NewGuid(), enrollment.RefreshToken))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        using var scope = harness.Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        await db.PairedDevices.ExecuteUpdateAsync(setters => setters.SetProperty(device => device.ExpiresAtUnixSeconds, DateTimeOffset.UtcNow.AddDays(1).ToUnixTimeSeconds()));
        var refreshed = await Json(await harness.Client.PostAsJsonAsync("/api/pairing/refresh", new PairingRefreshRequest(deviceId, enrollment.RefreshToken)));
        Assert.That(refreshed.GetProperty("session").GetProperty("userId").GetGuid(), Is.EqualTo(initial.GetProperty("session").GetProperty("userId").GetGuid()));
        Assert.That((await db.PairedDevices.SingleAsync()).ExpiresAtUnixSeconds, Is.GreaterThan(DateTimeOffset.UtcNow.AddDays(89).ToUnixTimeSeconds()));
        await db.PairedDevices.ExecuteUpdateAsync(setters => setters.SetProperty(device => device.ExpiresAtUnixSeconds, 0));
        Assert.That((await harness.Client.PostAsJsonAsync("/api/pairing/refresh", new PairingRefreshRequest(deviceId, enrollment.RefreshToken))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task QueueIsBoundedAndExpiredEntriesAreRemovedWithoutLosingOwner()
    {
        await using var harness = new Harness();
        var owner = await harness.Bootstrap();
        using var scope = harness.Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
        for (var i = 0; i < 32; i++) db.PairingRequests.Add(new PairingRequest { Id = Guid.NewGuid(), UserId = owner.GetProperty("session").GetProperty("userId").GetGuid(), ExpiresAtUnixSeconds = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds() });
        await db.SaveChangesAsync();
        Assert.That((await harness.Client.PostAsJsonAsync("/api/pairing/request", harness.Enrollment("Phone").Request)).StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        await db.PairingRequests.ExecuteUpdateAsync(setters => setters.SetProperty(request => request.ExpiresAtUnixSeconds, 0));
        Assert.That((await harness.Enroll(harness.Enrollment("Phone").Request)).GetProperty("status").GetString(), Is.EqualTo("pending"));
        Assert.That(await db.PairingRequests.CountAsync(), Is.EqualTo(1));
        Assert.That(await db.Users.CountAsync(), Is.EqualTo(1));
    }

    [Test]
    public async Task DisabledPairingAndInvalidEnrollmentDoNotCreateAccounts()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        Assert.That((await client.PostAsJsonAsync("/api/pairing/request", new PairingEnrollmentRequest("", "", "", "", "", ""))).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        await using var harness = new Harness();
        var request = harness.Enrollment("Phone").Request;
        Assert.That((await harness.Client.PostAsJsonAsync("/api/pairing/request", request with { BootstrapToken = "wrong" })).StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        foreach (var invalid in new[] { request with { PublicKey = "bad-key" }, request with { Nonce = "bad-nonce" }, request with { Proof = "bad-proof" }, request with { RefreshTokenHash = "bad-hash" }, request with { DeviceName = new string('x', 129) } })
            Assert.That((await harness.Client.PostAsJsonAsync("/api/pairing/request", invalid)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        using var scope = harness.Factory.Services.CreateScope();
        Assert.That(await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Users.CountAsync(), Is.Zero);
    }
}
