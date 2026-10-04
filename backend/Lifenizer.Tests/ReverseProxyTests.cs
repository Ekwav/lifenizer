using System.Net;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;

namespace Lifenizer.Tests;

public sealed class ReverseProxyTests
{
    private const string Proxy = "192.168.80.3";
    private sealed class RequestBody : IHttpRequestBodyDetectionFeature
    {
        public bool CanHaveBody => true;
    }

    private static Task<HttpContext> LoginAsync(LifenizerApiFactory factory, string remoteAddress, string clientAddress) => factory.Server.SendAsync(context =>
    {
        context.Connection.RemoteIpAddress = IPAddress.Parse(remoteAddress);
        context.Request.Method = "POST";
        context.Request.Path = "/api/auth/login";
        context.Request.Scheme = "http";
        context.Request.ContentType = "application/json";
        context.Request.Body = new MemoryStream(Encoding.UTF8.GetBytes("{\"email\":\"unknown@example.test\",\"password\":\"wrong-password\"}"));
        context.Request.ContentLength = context.Request.Body.Length;
        context.Features.Set<IHttpRequestBodyDetectionFeature>(new RequestBody());
        context.Request.Headers["X-Forwarded-For"] = clientAddress;
        context.Request.Headers["X-Forwarded-Proto"] = "https";
        context.Request.Headers["X-Forwarded-Prefix"] = "/lifenizer";
    });

    [Test]
    public async Task TrustedProxyRestoresClientSchemeAndPrefixBeforePerClientRateLimit()
    {
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["ReverseProxy:KnownProxies:0"] = Proxy });
        using var initialize = factory.CreateClient();
        for (var attempt = 0; attempt < 10; attempt++)
        {
            var result = await LoginAsync(factory, Proxy, "198.51.100.20");
            Assert.Multiple(() =>
            {
                Assert.That(result.Response.StatusCode, Is.EqualTo(StatusCodes.Status401Unauthorized));
                Assert.That(result.Connection.RemoteIpAddress, Is.EqualTo(IPAddress.Parse("198.51.100.20")));
                Assert.That(result.Request.Scheme, Is.EqualTo("https"));
                Assert.That(result.Request.PathBase.Value, Is.EqualTo("/lifenizer"));
            });
        }
        Assert.That((await LoginAsync(factory, Proxy, "198.51.100.20")).Response.StatusCode, Is.EqualTo(StatusCodes.Status429TooManyRequests));
        Assert.That((await LoginAsync(factory, Proxy, "198.51.100.21")).Response.StatusCode, Is.EqualTo(StatusCodes.Status401Unauthorized));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task UnknownPeerCannotSpoofHeadersOrEscapeRateLimit(bool configureProxy)
    {
        await using var factory = new LifenizerApiFactory(configureProxy
            ? new Dictionary<string, string?> { ["ReverseProxy:KnownProxies:0"] = Proxy } : null);
        using var initialize = factory.CreateClient();
        for (var attempt = 0; attempt < 11; attempt++)
        {
            var result = await LoginAsync(factory, "203.0.113.40", $"198.51.100.{attempt + 1}");
            Assert.Multiple(() =>
            {
                Assert.That(result.Response.StatusCode, Is.EqualTo(attempt < 10 ? StatusCodes.Status401Unauthorized : StatusCodes.Status429TooManyRequests));
                Assert.That(result.Connection.RemoteIpAddress, Is.EqualTo(IPAddress.Parse("203.0.113.40")));
                Assert.That(result.Request.Scheme, Is.EqualTo("http"));
                Assert.That(result.Request.PathBase.Value, Is.Null.Or.Empty);
            });
        }
    }
}
