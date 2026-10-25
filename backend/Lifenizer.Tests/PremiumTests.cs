using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using Coflnet.Payments.Client.Api;
using Coflnet.Payments.Client.Client;
using Coflnet.Payments.Client.Model;
using Lifenizer.Core;
using Lifenizer.Api.Infrastructure;
using Lifenizer.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class PremiumTests
{
    [Test]
    public async Task FreeActivationAndCancellationSurviveRestartWithoutChangingVaultIdentity()
    {
        var path = Path.Combine(Path.GetTempPath(), $"lifenizer-premium-{Guid.NewGuid():N}.db");
        var config = new Dictionary<string, string?>
        {
            ["ConnectionStrings:Lifenizer"] = $"Data Source={path}",
            ["Payments:FreePremiumEnabled"] = "true", ["Payments:BaseUrl"] = "",
        };
        const string email = "activation@example.test";
        const string password = "private account password for test";
        AuthResponse original;
        string? activatedAt;
        try
        {
            await using (var factory = new LifenizerApiFactory(config))
            {
                using var client = factory.CreateClient();
                Assert.That((await client.PostAsync("/api/premium/activate", null)).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
                Assert.That((await client.PostAsync("/api/premium/cancel-free", null)).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
                var registration = await client.PostAsJsonAsync("/api/auth/register", new RegisterAccountRequest(email, password));
                registration.EnsureSuccessStatusCode();
                original = (await registration.Content.ReadFromJsonAsync<AuthResponse>())!;
                client.DefaultRequestHeaders.Authorization = new("Bearer", original.AuthToken);
                var envelope = new SyncEnvelopeDto(Guid.NewGuid(), "desktop", "conversation", "existing-memory", "upsert", 1,
                    "encrypted-before-upgrade", "nonce", "vault-v1", DateTimeOffset.UtcNow);
                (await client.PostAsJsonAsync("/api/sync/push", new PushSyncRequest([envelope]))).EnsureSuccessStatusCode();
                var before = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
                Assert.That(before.GetProperty("plan").GetString(), Is.EqualTo("Free"));
                Assert.That(before.GetProperty("freePremiumActivatedAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
                var activation = await client.PostAsync("/api/premium/activate", null);
                activation.EnsureSuccessStatusCode();
                var status = await activation.Content.ReadFromJsonAsync<JsonElement>();
                Assert.That(status.GetProperty("plan").GetString(), Is.EqualTo("Premium"));
                Assert.That(status.GetProperty("usedBytes").GetInt64(), Is.EqualTo(before.GetProperty("usedBytes").GetInt64()));
                activatedAt = status.GetProperty("freePremiumActivatedAt").GetString();
                Assert.That(activatedAt, Is.Not.Null);
                var repeated = await client.PostAsync("/api/premium/activate", null);
                repeated.EnsureSuccessStatusCode();
                Assert.That((await repeated.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("freePremiumActivatedAt").GetString(), Is.EqualTo(activatedAt));
            }
            await using (var restarted = new LifenizerApiFactory(config))
            {
                using var client = restarted.CreateClient();
                var login = await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest(email, password));
                login.EnsureSuccessStatusCode();
                var restored = (await login.Content.ReadFromJsonAsync<AuthResponse>())!;
                Assert.That((restored.UserId, restored.VaultId, restored.VaultSalt), Is.EqualTo((original.UserId, original.VaultId, original.VaultSalt)));
                client.DefaultRequestHeaders.Authorization = new("Bearer", restored.AuthToken);
                var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0");
                Assert.That(pull!.Envelopes.Single().CipherText, Is.EqualTo("encrypted-before-upgrade"));
                var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
                Assert.That(status.GetProperty("plan").GetString(), Is.EqualTo("Premium"));
                Assert.That(status.GetProperty("limitBytes").GetInt64(), Is.EqualTo(StorageQuota.PremiumLimitBytes));
                Assert.That(status.GetProperty("freePremiumActivatedAt").GetString(), Is.EqualTo(activatedAt));
                restarted.Services.GetRequiredService<IConfiguration>()["Payments:FreePremiumEnabled"] = "false";
                Assert.That((await client.PostAsync("/api/premium/activate", null)).StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
                var disabled = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
                Assert.That(disabled.GetProperty("plan").GetString(), Is.EqualTo("Free"));
                Assert.That(disabled.GetProperty("freePremiumActivatedAt").GetString(), Is.EqualTo(activatedAt));
                // Opting out remains possible even after the server disables the offer.
                for (var attempt = 0; attempt < 2; attempt++)
                {
                    var cancellation = await client.PostAsync("/api/premium/cancel-free", null);
                    cancellation.EnsureSuccessStatusCode();
                    var cancelled = await cancellation.Content.ReadFromJsonAsync<JsonElement>();
                    Assert.That(cancelled.GetProperty("plan").GetString(), Is.EqualTo("Free"));
                    Assert.That(cancelled.GetProperty("freePremiumActivatedAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
                    Assert.That(cancelled.GetProperty("usedBytes").GetInt64(), Is.EqualTo(status.GetProperty("usedBytes").GetInt64()));
                }
            }
            await using (var restarted = new LifenizerApiFactory(config))
            {
                using var client = restarted.CreateClient();
                var login = await client.PostAsJsonAsync("/api/auth/login", new AccountLoginRequest(email, password));
                login.EnsureSuccessStatusCode();
                var restored = (await login.Content.ReadFromJsonAsync<AuthResponse>())!;
                Assert.That((restored.UserId, restored.VaultId, restored.VaultSalt), Is.EqualTo((original.UserId, original.VaultId, original.VaultSalt)));
                client.DefaultRequestHeaders.Authorization = new("Bearer", restored.AuthToken);
                var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
                Assert.That(status.GetProperty("plan").GetString(), Is.EqualTo("Free"));
                Assert.That(status.GetProperty("limitBytes").GetInt64(), Is.EqualTo(StorageQuota.FreeLimitBytes));
                Assert.That(status.GetProperty("freePremiumActivatedAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
                var pull = await client.GetFromJsonAsync<PullSyncResponse>("/api/sync/pull?since=0");
                Assert.That(pull!.Envelopes.Single().CipherText, Is.EqualTo("encrypted-before-upgrade"));
                var reactivation = await client.PostAsync("/api/premium/activate", null);
                reactivation.EnsureSuccessStatusCode();
                Assert.That((await reactivation.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("plan").GetString(), Is.EqualTo("Premium"));
            }
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            File.Delete(path);
        }
    }

    private static async Task Login(HttpClient client)
    {
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest("premium-test@example.test", "Premium"));
        var auth = await response.Content.ReadFromJsonAsync<AuthResponse>();
        client.DefaultRequestHeaders.Authorization = new("Bearer", auth!.AuthToken);
    }

    [TestCase(null)]
    [TestCase("")]
    [TestCase("   ")]
    public async Task UnconfiguredPaymentsReturnFreeWithoutCallingSdkAndCheckoutIsUnavailable(string? baseUrl)
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Payments:BaseUrl"] = baseUrl })
            .WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            {
                services.AddSingleton(Proxy<IUserApi>((_, _) => throw new AssertionException("Unconfigured payments must not call SDK")));
                services.AddSingleton(Proxy<ITopUpApi>((_, _) => throw new AssertionException("Unconfigured checkout must not call SDK")));
            }));
        using var client = factory.CreateClient();
        await Login(client);
        var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
        Assert.That(status.GetProperty("plan").GetString(), Is.EqualTo("Free"));
        Assert.That((await client.PostAsync("/api/premium/checkout/premium", null)).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That((await client.PostAsync("/api/premium/checkout/unknown", null)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        factory.Services.GetRequiredService<IConfiguration>()["Payments:FreePremiumEnabled"] = "true";
        (await client.PostAsync("/api/premium/activate", null)).EnsureSuccessStatusCode();
        var cancellation = await client.PostAsync("/api/premium/cancel-free", null);
        cancellation.EnsureSuccessStatusCode();
        Assert.That((await cancellation.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("plan").GetString(), Is.EqualTo("Free"));
    }

    [Test]
    public void ConfiguredSdkClientsResolveAndUseConfiguredBaseUrl()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Payments:BaseUrl"] = "https://payments.example.test"
        }).Build();
        using var services = new ServiceCollection().AddPaymentServices(config).BuildServiceProvider();
        Assert.That(((UserApi)services.GetRequiredService<IUserApi>()).Configuration.BasePath, Is.EqualTo("https://payments.example.test"));
        Assert.That(((TopUpApi)services.GetRequiredService<ITopUpApi>()).Configuration.BasePath, Is.EqualTo("https://payments.example.test"));
    }

    [Test]
    public async Task CheckoutCallsSubscriptionPostForRequestedProductAndReturnsProviderLink()
    {
        string? slug = null;
        object?[]? arguments = null;
        var fail = false;
        var directLink = "https://shop.lemonsqueezy.com/checkout/test";
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Payments:BaseUrl"] = "https://payments.example.test", ["Products:PremiumPlus"] = "configured-plus"
        }).WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            services.AddSingleton(Proxy<ITopUpApi>((method, args) =>
            {
                Assert.That(method.Name, Is.EqualTo("TopUpLemonsqueezySubscribePostAsync"));
                arguments = args;
                slug = (string)args![1]!;
                if (fail) throw new ApiException(503, "synthetic provider failure");
                return Task.FromResult(new TopUpIdResponse { DirectLink = directLink });
            }))));
        using var client = factory.CreateClient();
        await Login(client);
        var response = await client.PostAsync("/api/premium/checkout/premium-plus", null);
        response.EnsureSuccessStatusCode();
        Assert.That((await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("checkoutUrl").GetString(), Is.EqualTo(directLink));
        Assert.That(slug, Is.EqualTo("configured-plus"));
        Assert.That(Guid.TryParse(arguments![0] as string, out _), Is.True);
        Assert.That(arguments[^1], Is.TypeOf<CancellationToken>());
        fail = true;
        Assert.That((await client.PostAsync("/api/premium/checkout/premium", null)).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(slug, Is.EqualTo("lifenizer-premium"));
        fail = false;
        directLink = "http://insecure.example.test/checkout";
        Assert.That((await client.PostAsync("/api/premium/checkout/premium", null)).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task ConfiguredPlanUsesSdkEntitlementAndCancellation(bool freePremiumEnabled)
    {
        var expiry = DateTime.UtcNow.AddDays(1);
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
            { ["Payments:BaseUrl"] = "https://payments.example.test", ["Payments:FreePremiumEnabled"] = freePremiumEnabled.ToString() })
            .WithWebHostBuilder(builder => builder.ConfigureServices(services =>
                services.AddSingleton(Proxy<IUserApi>((method, args) =>
                {
                    Assert.That(method.Name, Is.EqualTo("UserUserIdOwnsUntilPostAsync"));
                    Assert.That(args![^1], Is.TypeOf<CancellationToken>());
                    var product = ((List<string>)args[1]!).Single();
                    return Task.FromResult(new Dictionary<string, DateTime> { [product] = expiry });
                }))));
        using var client = factory.CreateClient();
        await Login(client);
        var status = await client.GetFromJsonAsync<JsonElement>("/api/premium/status");
        Assert.That(status.GetProperty("plan").GetString(), Is.EqualTo("PremiumPlus"));
        Assert.That(status.GetProperty("limitBytes").GetInt64(), Is.EqualTo(StorageQuota.ForPlan(SubscriptionPlan.PremiumPlus)));
    }

    [TestCase("Premium")]
    [TestCase("PremiumPlus")]
    public async Task CancellingFreeGrantPreservesPaidEntitlementAndRetriesProviderFailure(string paidPlan)
    {
        var fail = false;
        var calls = 0;
        var expiry = DateTime.UtcNow.AddDays(1);
        var paidProduct = paidPlan == "PremiumPlus" ? "lifenizer-premium-plus" : "lifenizer-premium";
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Payments:BaseUrl"] = "https://payments.example.test", ["Payments:FreePremiumEnabled"] = "true"
        }).WithWebHostBuilder(builder => builder.ConfigureServices(services =>
        {
            services.AddSingleton(Proxy<IUserApi>((method, args) =>
            {
                Assert.That(method.Name, Is.EqualTo("UserUserIdOwnsUntilPostAsync"));
                calls++;
                if (fail) throw new ApiException(503, "synthetic provider outage");
                var product = ((List<string>)args![1]!).Single();
                return Task.FromResult(product == paidProduct
                    ? new Dictionary<string, DateTime> { [product] = expiry }
                    : new Dictionary<string, DateTime>());
            }));
            services.AddSingleton(Proxy<ITopUpApi>((_, _) => throw new AssertionException("Demo cancellation must not modify a paid subscription")));
        }));
        using var client = factory.CreateClient();
        await Login(client);
        var activation = await client.PostAsync("/api/premium/activate", null);
        activation.EnsureSuccessStatusCode();
        var before = await activation.Content.ReadFromJsonAsync<JsonElement>();
        Assert.That(before.GetProperty("plan").GetString(), Is.EqualTo(paidPlan));
        var cachedCalls = calls;
        fail = true;
        Assert.That((await client.PostAsync("/api/premium/cancel-free", null)).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(calls, Is.GreaterThan(cachedCalls), "Cancellation must freshly verify even a cached paid entitlement");
        using (var scope = factory.Services.CreateScope())
        {
            var user = await scope.ServiceProvider.GetRequiredService<LifenizerDbContext>().Users.SingleAsync();
            Assert.That(user.FreePremiumActivatedAt, Is.EqualTo(DateTimeOffset.Parse(before.GetProperty("freePremiumActivatedAt").GetString()!)));
            Assert.That(user.Plan.ToString(), Is.EqualTo(paidPlan));
        }
        fail = false;
        var cancellation = await client.PostAsync("/api/premium/cancel-free", null);
        cancellation.EnsureSuccessStatusCode();
        var after = await cancellation.Content.ReadFromJsonAsync<JsonElement>();
        Assert.That(after.GetProperty("plan").GetString(), Is.EqualTo(paidPlan));
        Assert.That(after.GetProperty("limitBytes").GetInt64(), Is.EqualTo(before.GetProperty("limitBytes").GetInt64()));
        Assert.That(after.GetProperty("expiresAt").GetString(), Is.EqualTo(before.GetProperty("expiresAt").GetString()));
        Assert.That(after.GetProperty("freePremiumActivatedAt").ValueKind, Is.EqualTo(JsonValueKind.Null));
    }

    private static T Proxy<T>(Func<MethodInfo, object?[]?, object?> invoke) where T : class
    {
        var proxy = DispatchProxy.Create<T, PaymentProxy>();
        ((PaymentProxy)(object)proxy).Call = invoke;
        return proxy;
    }

    public class PaymentProxy : DispatchProxy
    {
        public Func<MethodInfo, object?[]?, object?> Call { get; set; } = null!;
        protected override object? Invoke(MethodInfo? targetMethod, object?[]? args) => Call(targetMethod!, args);
    }
}
