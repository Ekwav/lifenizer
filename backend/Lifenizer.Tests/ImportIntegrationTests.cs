using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class ImportIntegrationTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Test]
    public async Task EmailImportFetchesMessagesFromMockImapServer()
    {
        const string rawEmail = "From: Alice Example <alice@example.test>\r\nTo: Bob Example <bob@example.test>\r\nSubject: Quarterly Plan\r\nDate: Tue, 21 May 2026 10:15:00 +0000\r\nMessage-Id: <plan@example.test>\r\n\r\nBob, the Paperless import and TAP transcription are ready for review.";
        await using var imap = new MockImapServer(rawEmail);
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/email", new ImportRequest(
            Metadata: new Dictionary<string, string>
            {
                ["host"] = "127.0.0.1",
                ["port"] = imap.Port.ToString(),
                ["username"] = "alice@example.test",
                ["password"] = "placeholder-imap-secret",
                ["useTls"] = "false",
                ["mailbox"] = "INBOX"
            }), JsonOptions);
        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions);

        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Conversations, Has.Count.EqualTo(1));
        Assert.Multiple(() =>
        {
            Assert.That(result.Source, Is.EqualTo("email"));
            Assert.That(result.PlaintextCompute, Is.True);
            Assert.That(result.Conversations[0].Title, Is.EqualTo("Quarterly Plan"));
            Assert.That(result.Conversations[0].Segments[0].Text, Does.Contain("TAP transcription"));
            Assert.That(result.Participants.Select(p => p.DisplayName), Does.Contain("Alice Example"));
            Assert.That(result.Participants.Select(p => p.DisplayName), Does.Contain("Bob Example"));
        });
    }

    [Test]
    public async Task RemoteProviderImportsUseMockHttpApis()
    {
        await using var mockApi = new MockHttpServer(request => request.Url?.AbsolutePath switch
        {
            "/api/documents/" => Json(new
            {
                results = new[]
                {
                    new
                    {
                        id = 42,
                        title = "Paperless Invoice",
                        correspondent = new { name = "Acme GmbH" },
                        content = "Invoice for scanner and OCR work.",
                        original_file_name = "invoice.pdf",
                        created = "2026-05-20T08:00:00Z"
                    }
                }
            }),
            "/api/transcripts/video-1" => Json(new
            {
                segments = new[]
                {
                    new { text = "Welcome to the private archive demo.", start = 0.0 },
                    new { text = "Participants and transcripts become searchable.", start = 2.5 }
                }
            }),
            "/api/channels/channel-1/messages" => Json(new[]
            {
                new { author = new { username = "Dev One" }, content = "Discord export through a mock API.", timestamp = "2026-05-21T09:00:00Z" },
                new { author = new { username = "Dev Two" }, content = "This should become a normalized conversation.", timestamp = "2026-05-21T09:01:00Z" }
            }),
            "/api/transcribe" => Json(new
            {
                segments = new[]
                {
                    new { speaker = "Alice", text = "TAP mock transcription segment one.", start = 0.0 },
                    new { speaker = "Bob", text = "TAP mock transcription segment two.", start = 3.0 }
                }
            }),
            _ => Text("not found", 404)
        });
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var paperless = await ImportAsync(client, "paperless", new ImportRequest(Metadata: new Dictionary<string, string>
        {
            ["baseUrl"] = mockApi.Url,
            ["token"] = "placeholder-paperless-token"
        }));
        var youtube = await ImportAsync(client, "youtube-transcript", new ImportRequest(Title: "Private archive video", Metadata: new Dictionary<string, string>
        {
            ["baseUrl"] = mockApi.Url,
            ["videoId"] = "video-1"
        }));
        var discord = await ImportAsync(client, "discord", new ImportRequest(Metadata: new Dictionary<string, string>
        {
            ["baseUrl"] = mockApi.Url,
            ["channelId"] = "channel-1",
            ["token"] = "placeholder-discord-token"
        }));
        var audio = await ImportAsync(client, "audio", new ImportRequest(
            OriginalFileName: "meeting.wav",
            MimeType: "audio/wav",
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("fake wav")),
            Metadata: new Dictionary<string, string>
            {
                ["tapBaseUrl"] = mockApi.Url,
                ["tapPath"] = "/api/transcribe",
                ["tapApiKey"] = "placeholder-tap-secret"
            }));

        Assert.Multiple(() =>
        {
            Assert.That(paperless.Conversations[0].Title, Is.EqualTo("Paperless Invoice"));
            Assert.That(paperless.Participants.Select(p => p.DisplayName), Does.Contain("Acme GmbH"));
            Assert.That(youtube.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(discord.Participants.Select(p => p.DisplayName), Does.Contain("Dev One"));
            Assert.That(audio.Conversations[0].Segments.Select(s => s.Text), Does.Contain("TAP mock transcription segment one."));
        });
    }

    [Test]
    public async Task ManualExportParsersNormalizeChatsAndHistory()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var whatsapp = await ImportAsync(client, "whatsapp", new ImportRequest(
            Title: "WhatsApp family export",
            Text: "[20.05.2026, 10:00] Alice: Person X works with Person Z.\n[20.05.2026, 10:01] Bob: Person Y is Person X's sister."));
        var telegram = await ImportAsync(client, "telegram", new ImportRequest(
            Text: "{\"name\":\"Telegram Project\",\"messages\":[{\"from\":\"Mira\",\"text\":\"Ship the Flutter app.\",\"date\":\"2026-05-20T11:00:00Z\"}]}"));
        var signal = await ImportAsync(client, "signal", new ImportRequest(
            Text: "timestamp,sender,message\n2026-05-20T12:00:00Z,Sam,Signal CSV import works"));
        var history = await ImportAsync(client, "browser-history", new ImportRequest(
            Text: "title,url,time\nPaperless docs,https://paperless.example.test,2026-05-20T12:30:00Z"));

        Assert.Multiple(() =>
        {
            Assert.That(whatsapp.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(telegram.Participants.Select(p => p.DisplayName), Does.Contain("Mira"));
            Assert.That(signal.Conversations[0].Segments[0].Text, Is.EqualTo("Signal CSV import works"));
            Assert.That(history.Conversations[0].Segments[0].Text, Does.Contain("paperless.example.test"));
        });
    }

    [Test]
    public async Task ProviderImportMissingMetadataReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/email", new ImportRequest(), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task ConfiguredProviderSecretIsNotSentToOverriddenProviderUrl()
    {
        await using var mockApi = new MockHttpServer(_ => Json(new { results = Array.Empty<object>() }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Imports:Paperless:BaseUrl"] = "https://configured-paperless.example.test/",
            ["Imports:Paperless:Token"] = "server-side-paperless-secret"
        });
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/paperless", new ImportRequest(Metadata: new Dictionary<string, string>
        {
            ["baseUrl"] = mockApi.Url
        }), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(mockApi.RequestCount, Is.EqualTo(0));
    }

    [Test]
    public async Task MalformedImportJsonReturnsBadRequest()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var response = await client.PostAsJsonAsync("/api/imports/telegram", new ImportRequest(Text: "{\"messages\":"), JsonOptions);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    private static async Task<NormalizedImportResponse> ImportAsync(HttpClient client, string source, ImportRequest request)
    {
        var response = await client.PostAsJsonAsync($"/api/imports/{source}", request, JsonOptions);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<NormalizedImportResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Import response was empty.");
    }

    private static async Task<HttpClient> AuthenticatedClientAsync(LifenizerApiFactory factory, string email)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/dev-login", new DevLoginRequest(email, email.Split('@')[0]), JsonOptions);
        response.EnsureSuccessStatusCode();
        var auth = await response.Content.ReadFromJsonAsync<AuthResponse>(JsonOptions)
            ?? throw new InvalidOperationException("Auth response was empty.");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", auth.AuthToken);
        return client;
    }

    private static MockHttpResponse Json(object value) => new("application/json", JsonSerializer.Serialize(value, JsonOptions));

    private static MockHttpResponse Text(string value, int statusCode = 200) => new("text/plain", value, statusCode);
}

internal sealed record MockHttpResponse(string ContentType, string Body, int StatusCode = 200);

internal sealed class MockHttpServer : IAsyncDisposable
{
    private readonly HttpListener listener = new();
    private readonly Func<HttpListenerRequest, MockHttpResponse> handler;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task loop;

    public MockHttpServer(Func<HttpListenerRequest, MockHttpResponse> handler)
    {
        this.handler = handler;
        Port = FreePort();
        Url = $"http://127.0.0.1:{Port}/";
        listener.Prefixes.Add(Url);
        listener.Start();
        loop = Task.Run(HandleLoopAsync);
    }

    public int Port { get; }

    public string Url { get; }

    public int RequestCount { get; private set; }

    public async ValueTask DisposeAsync()
    {
        cancellation.Cancel();
        listener.Stop();
        listener.Close();
        try
        {
            await loop;
        }
        catch (ObjectDisposedException)
        {
        }
        catch (HttpListenerException)
        {
        }
        cancellation.Dispose();
    }

    private async Task HandleLoopAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            var context = await listener.GetContextAsync();
            RequestCount++;
            var response = handler(context.Request);
            var bytes = Encoding.UTF8.GetBytes(response.Body);
            context.Response.StatusCode = response.StatusCode;
            context.Response.ContentType = response.ContentType;
            context.Response.ContentLength64 = bytes.Length;
            await context.Response.OutputStream.WriteAsync(bytes, cancellation.Token);
            context.Response.Close();
        }
    }

    private static int FreePort()
    {
        var tcp = new TcpListener(IPAddress.Loopback, 0);
        tcp.Start();
        var port = ((IPEndPoint)tcp.LocalEndpoint).Port;
        tcp.Stop();
        return port;
    }
}

internal sealed class MockImapServer : IAsyncDisposable
{
    private readonly TcpListener listener;
    private readonly string rawMessage;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task loop;

    public MockImapServer(string rawMessage)
    {
        this.rawMessage = rawMessage;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        loop = Task.Run(HandleAsync);
    }

    public int Port { get; }

    public async ValueTask DisposeAsync()
    {
        cancellation.Cancel();
        listener.Stop();
        try
        {
            await loop;
        }
        catch (SocketException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        cancellation.Dispose();
    }

    private async Task HandleAsync()
    {
        using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
        await using var stream = client.GetStream();
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 8192, leaveOpen: true);
        await using var writer = new StreamWriter(stream, new UTF8Encoding(false), bufferSize: 8192, leaveOpen: true) { NewLine = "\r\n", AutoFlush = true };
        await writer.WriteLineAsync("* OK Mock IMAP ready");

        while (!cancellation.IsCancellationRequested)
        {
            var line = await reader.ReadLineAsync(cancellation.Token);
            if (line is null) break;
            var tag = line.Split(' ', 2)[0];
            if (line.Contains("LOGIN", StringComparison.OrdinalIgnoreCase))
            {
                await writer.WriteLineAsync($"{tag} OK LOGIN completed");
            }
            else if (line.Contains("SELECT", StringComparison.OrdinalIgnoreCase))
            {
                await writer.WriteLineAsync("* 1 EXISTS");
                await writer.WriteLineAsync($"{tag} OK SELECT completed");
            }
            else if (line.Contains("SEARCH", StringComparison.OrdinalIgnoreCase))
            {
                await writer.WriteLineAsync("* SEARCH 1");
                await writer.WriteLineAsync($"{tag} OK SEARCH completed");
            }
            else if (line.Contains("FETCH", StringComparison.OrdinalIgnoreCase))
            {
                var length = Encoding.UTF8.GetByteCount(rawMessage);
                await writer.WriteLineAsync($"* 1 FETCH (BODY[] {{{length}}}");
                await writer.WriteLineAsync(rawMessage);
                await writer.WriteLineAsync(")");
                await writer.WriteLineAsync($"{tag} OK FETCH completed");
            }
            else if (line.Contains("LOGOUT", StringComparison.OrdinalIgnoreCase))
            {
                await writer.WriteLineAsync("* BYE Mock IMAP logging out");
                await writer.WriteLineAsync($"{tag} OK LOGOUT completed");
                break;
            }
            else
            {
                await writer.WriteLineAsync($"{tag} BAD unsupported command");
            }
        }
    }
}
