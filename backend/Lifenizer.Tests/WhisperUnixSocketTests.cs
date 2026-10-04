using System.Net.Sockets;
using System.Text;
using Lifenizer.Api.Infrastructure;
using Lifenizer.Api.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class WhisperUnixSocketTests
{
    [Test]
    public async Task TranscriptionUsesPrivateUnixRelayInsteadOfDnsOrHttpProxy()
    {
        if (!Socket.OSSupportsUnixDomainSockets) Assert.Ignore("Unix sockets are unavailable on this platform.");
        var path = Path.Combine(Path.GetTempPath(), $"lifenizer-whisper-{Guid.NewGuid():N}.sock");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(path));
        listener.Listen(1);
        try
        {
            var serve = Task.Run(async () =>
            {
                using var socket = await listener.AcceptAsync(timeout.Token);
                await using var stream = new NetworkStream(socket, ownsSocket: false);
                using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
                var firstLine = await reader.ReadLineAsync(timeout.Token);
                while (!string.IsNullOrEmpty(await reader.ReadLineAsync(timeout.Token))) { }
                const string body = "{\"text\":\"Private relay transcription\",\"language\":\"en\"}";
                var response = Encoding.UTF8.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nConnection: close\r\n\r\n{body}");
                await stream.WriteAsync(response, timeout.Token);
                return firstLine;
            }, timeout.Token);
            var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Whisper:UnixSocketPath"] = path,
                ["Whisper:BaseUrl"] = "http://does-not-resolve.invalid:9000"
            }).Build();
            var services = new ServiceCollection();
            services.AddSingleton<IConfiguration>(config);
            services.AddCoreServices();
            await using var provider = services.BuildServiceProvider();
            var client = new WhisperTranscriptionClient(provider.GetRequiredService<IHttpClientFactory>(), config);
            var transcript = await client.TranscribeAsync([0, 1, 2, 3], "audio.wav", "audio/wav", "en", timeout.Token);
            Assert.That(transcript.Text, Is.EqualTo("Private relay transcription"));
            Assert.That(await serve, Does.StartWith("POST /asr?task=transcribe&output=json&encode=true&language=en HTTP/1.1"));
        }
        finally { listener.Dispose(); File.Delete(path); }
    }

    [Test]
    public void HttpDefaultAndUnixRelayBothDisableRedirects()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection().Build();
        using var direct = WhisperTranscriptionClient.CreateHttpHandler(config);
        Assert.That(((HttpClientHandler)direct).AllowAutoRedirect, Is.False);
        config["Whisper:UnixSocketPath"] = "/tmp/private-whisper.sock";
        using var relay = WhisperTranscriptionClient.CreateHttpHandler(config);
        Assert.Multiple(() =>
        {
            Assert.That(((SocketsHttpHandler)relay).AllowAutoRedirect, Is.False);
            Assert.That(((SocketsHttpHandler)relay).UseProxy, Is.False);
        });
    }
}
