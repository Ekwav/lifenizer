using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Lifenizer.Api.Configuration;
using Lifenizer.Api.Data;
using Lifenizer.Core;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Lifenizer.Tests;

public sealed class AccountAuthTests
{
    private const string Password = "correct horse battery account password";

    [Test]
    public async Task AccountLoginReturnsSameVaultAndSyncsAcrossDevices()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Auth:AllowDevLogin"] = "false" });
        using var desktop = factory.CreateClient();
        using var phone = factory.CreateClient();
        var registration = await desktop.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest("Alice@example.test", Password, "Alice"));
        registration.EnsureSuccessStatusCode();
        var first = (await registration.Content.ReadFromJsonAsync<AuthResponse>())!;
        var login = await phone.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest(" ALICE@example.test ", Password));
        login.EnsureSuccessStatusCode();
        var second = (await login.Content.ReadFromJsonAsync<AuthResponse>())!;
        Assert.Multiple(() =>
        {
            Assert.That(second.UserId, Is.EqualTo(first.UserId));
            Assert.That(second.VaultId, Is.EqualTo(first.VaultId));
            Assert.That(second.VaultSalt, Is.EqualTo(first.VaultSalt));
            Assert.That(Convert.FromBase64String(first.VaultSalt), Has.Length.EqualTo(32));
        });
        desktop.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", first.AuthToken);
        phone.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", second.AuthToken);
        var envelope = new SyncEnvelopeDto(Guid.NewGuid(), "desktop", "conversation", "memory", "upsert", 1, "encrypted-memory", "nonce", "vault-v1", DateTimeOffset.UtcNow);
        (await desktop.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]))).EnsureSuccessStatusCode();
        var pull = (await phone.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0"))!;
        Assert.That(pull.Envelopes.Single().CipherText, Is.EqualTo("encrypted-memory"));

        using var scope = factory.Services.CreateScope();
        var account = await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Users.SingleAsync();
        Assert.That(account.PasswordHash, Is.Not.EqualTo(Password));
        var bytes = Convert.FromBase64String(account.PasswordHash!);
        Assert.That(System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(5, 4)), Is.EqualTo(220_000));
        Assert.That(scope.ServiceProvider.GetRequiredService<IPasswordHasher<UserAccount>>().VerifyHashedPassword(account, account.PasswordHash!, Password), Is.EqualTo(PasswordVerificationResult.Success));
        Assert.That((await desktop.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest("alice@example.test"))).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [Test]
    public async Task RegistrationCannotClaimExistingDevelopmentAccount()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        (await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest("Alice@example.test"))).EnsureSuccessStatusCode();
        var response = await client.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest("alice@example.test", Password));
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That((await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest("alice@example.test", Password))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        using var scope = factory.Services.CreateScope();
        Assert.That((await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Users.SingleAsync()).PasswordHash, Is.Null);
    }

    [Test]
    public async Task DuplicateRegistrationAndInvalidCredentialsAreRejected()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        (await client.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest("alice@example.test", Password))).EnsureSuccessStatusCode();
        Assert.That((await client.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest("ALICE@example.test", Password))).StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That((await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest("alice@example.test", "wrong-password"))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest("unknown@example.test", Password))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [TestCase("not-email", "long-enough-password")]
    [TestCase("Name <alice@example.test>", "long-enough-password")]
    [TestCase("alice@example.test", "short")]
    [TestCase("alice@example.test", null)]
    public async Task RegistrationValidatesInputs(string email, string? password)
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        Assert.That((await client.PostAsJsonAsync("/api/auth/register", new { email, password })).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task AuthenticationAttemptsAreRateLimited()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        for (var attempt = 0; attempt < 10; attempt++)
            Assert.That((await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest("unknown@example.test", Password))).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest("unknown@example.test", Password))).StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
    }

    [Test]
    public void ProductionRejectsShippedDevelopmentJwtSecret()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Jwt:Secret"] = "replace-this-development-secret-with-a-host-secret-please",
            ["Products:Premium"] = "premium", ["Products:PremiumPlus"] = "plus"
        }).Build();
        Assert.Throws<InvalidOperationException>(() => StartupConfigurationValidator.Validate(config, NullLogger.Instance));
        Assert.DoesNotThrow(() => StartupConfigurationValidator.Validate(config, NullLogger.Instance, isDevelopment: true));
    }

    [Test]
    public async Task LoginUpgradesWeakerPasswordHashWithoutChangingVaultSalt()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = factory.CreateClient();
        (await client.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest("alice@example.test", Password))).EnsureSuccessStatusCode();
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<LifenizerDbContext>();
            var account = await db.Users.SingleAsync();
            account.PasswordHash = new PasswordHasher<UserAccount>(Options.Create(new PasswordHasherOptions { IterationCount = 10_000 })).HashPassword(account, Password);
            await db.SaveChangesAsync();
        }
        var response = await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest("alice@example.test", Password));
        response.EnsureSuccessStatusCode();
        using var verifyScope = factory.Services.CreateScope();
        var updated = await verifyScope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Users.SingleAsync();
        Assert.That(verifyScope.ServiceProvider.GetRequiredService<IPasswordHasher<UserAccount>>().VerifyHashedPassword(updated, updated.PasswordHash!, Password), Is.EqualTo(PasswordVerificationResult.Success));
    }
}
