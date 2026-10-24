using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using Coflnet.Payments.Client.Api;
using Coflnet.Payments.Client.Client;
using Coflnet.Payments.Client.Model;
using Lifenizer.Core;
using Lifenizer.Api.Infrastructure;
using Microsoft.Extensions.Configuration;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class PremiumTests
{
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
