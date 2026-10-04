using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.IO.Compression;
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
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Imports:Imap:Host"] = "127.0.0.1",
            ["Imports:Imap:Port"] = imap.Port.ToString(),
            ["Imports:Imap:UseTls"] = "false"
        });
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");
        using var anonymous = factory.CreateClient();
        Assert.That((await anonymous.GetAsync("/api/imports/email/settings")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        var settings = await client.GetFromJsonAsync<JsonElement>("/api/imports/email/settings");
        Assert.That(settings.GetProperty("host").GetString(), Is.EqualTo("127.0.0.1"));
        Assert.That(settings.GetProperty("configured").GetBoolean(), Is.True);

        var response = await client.PostAsJsonAsync("/api/imports/email", new ImportRequest(
            Metadata: new Dictionary<string, string>
            {
                ["username"] = "alice@example.test",
                ["password"] = "placeholder-imap-secret",
                ["mailbox"] = "INBOX"
            }), JsonOptions);
        Assert.That(response.IsSuccessStatusCode, Is.True, await response.Content.ReadAsStringAsync() + " Commands:" + string.Join(";", imap.Commands));

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
            "/asr" => Json(new
            {
                text = "Whisper mock transcription segment one. Whisper mock transcription segment two.",
                language = "en",
                segments = new[]
                {
                    new { text = "Whisper mock transcription segment one.", start = 0.0, end = 2.5 },
                    new { text = "Whisper mock transcription segment two.", start = 3.0, end = 5.5 }
                }
            }),
            _ => Text("not found", 404)
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Whisper:BaseUrl"] = mockApi.Url,
            ["Imports:Paperless:BaseUrl"] = mockApi.Url,
            ["Imports:Discord:BaseUrl"] = mockApi.Url,
            ["Imports:YouTube:BaseUrl"] = mockApi.Url
        });
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var paperless = await ImportAsync(client, "paperless", new ImportRequest(Metadata: new Dictionary<string, string>
        {
            ["token"] = "placeholder-paperless-token"
        }));
        var youtube = await ImportAsync(client, "youtube-transcript", new ImportRequest(Title: "Private archive video", Metadata: new Dictionary<string, string>
        {
            ["videoId"] = "video-1"
        }));
        var discord = await ImportAsync(client, "discord", new ImportRequest(Metadata: new Dictionary<string, string>
        {
            ["channelId"] = "channel-1",
            ["token"] = "placeholder-discord-token"
        }));
        var audio = await ImportAsync(client, "audio", new ImportRequest(
            OriginalFileName: "meeting.wav",
            MimeType: "audio/wav",
            PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("fake wav"))));

        Assert.Multiple(() =>
        {
            Assert.That(paperless.Conversations[0].Title, Is.EqualTo("Paperless Invoice"));
            Assert.That(paperless.Participants.Select(p => p.DisplayName), Does.Contain("Acme GmbH"));
            Assert.That(youtube.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(discord.Participants.Select(p => p.DisplayName), Does.Contain("Dev One"));
            Assert.That(audio.Conversations[0].Segments.Select(s => s.Text), Does.Contain("Whisper mock transcription segment one."));
            Assert.That(audio.Conversations[0].Metadata, Is.Not.Null);
            Assert.That(audio.Conversations[0].Metadata!["language"], Is.EqualTo("en"));
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
    public async Task ExtendedImportParsersHandleSlackTeamsAndZipPayloads()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var slack = await ImportAsync(client, "slack", new ImportRequest(
            Text: "[{\"user_profile\":{\"display_name\":\"Alice\"},\"text\":\"Slack import works\",\"ts\":\"1716206400.0\"}]",
            OriginalFileName: "general.json",
            MimeType: "application/json"));

        var teams = await ImportAsync(client, "teams", new ImportRequest(
            Text: "{\"messages\":[{\"fromDisplayName\":\"Bob\",\"content\":\"<p>Teams <b>HTML</b> export works</p>\",\"createdDateTime\":\"2026-05-20T12:45:00Z\"}]}",
            OriginalFileName: "teams-export.json",
            MimeType: "application/json"));

        var zipPayloadBase64 = BuildZipPayloadBase64(("chat.txt", "[20.05.2026, 10:00] Cara: Zipped WhatsApp export works."));
        var whatsappZip = await ImportAsync(client, "whatsapp", new ImportRequest(
            OriginalFileName: "whatsapp-export.zip",
            MimeType: "application/zip",
            PayloadBase64: zipPayloadBase64));

        Assert.Multiple(() =>
        {
            Assert.That(slack.Participants.Select(p => p.DisplayName), Does.Contain("Alice"));
            Assert.That(slack.Conversations[0].Segments[0].Text, Is.EqualTo("Slack import works"));

            Assert.That(teams.Participants.Select(p => p.DisplayName), Does.Contain("Bob"));
            Assert.That(teams.Conversations[0].Segments[0].Text, Does.Contain("Teams HTML export works"));

            Assert.That(whatsappZip.Conversations[0].Segments, Has.Count.EqualTo(1));
            Assert.That(whatsappZip.Conversations[0].Segments[0].Text, Does.Contain("Zipped WhatsApp export works"));
        });
    }

    [Test]
    public async Task ExtendedImportParsersHandleMessengerInstagramIMessageAndMbox()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var messenger = await ImportAsync(client, "facebook-messenger", new ImportRequest(
            Text: "{\"title\":\"Friends Thread\",\"participants\":[{\"name\":\"Ava\"},{\"name\":\"Liam\"}],\"messages\":[{\"sender_name\":\"Ava\",\"content\":\"Messenger parser works\",\"timestamp_ms\":1716206400000}]}",
            OriginalFileName: "message_1.json",
            MimeType: "application/json"));

        var instagram = await ImportAsync(client, "instagram", new ImportRequest(
            Text: "{\"title\":\"DM with Sam\",\"messages\":[{\"sender_name\":\"Sam\",\"content\":\"Instagram parser works\",\"timestamp_ms\":1716207400000}]}",
            OriginalFileName: "inbox.json",
            MimeType: "application/json"));

        var imessage = await ImportAsync(client, "imessage", new ImportRequest(
            Text: "5/20/2026, 9:41 AM - Alex: iMessage parser works"));

        var mbox = await ImportAsync(client, "mbox", new ImportRequest(
            Text: "From sender@example.test Tue May 20 10:15:00 2026\nFrom: Sender <sender@example.test>\nTo: Receiver <receiver@example.test>\nSubject: Mbox parser\nDate: Tue, 20 May 2026 10:15:00 +0000\n\nMbox parser works"));

        Assert.Multiple(() =>
        {
            Assert.That(messenger.Participants.Select(p => p.DisplayName), Does.Contain("Ava"));
            Assert.That(messenger.Conversations[0].Segments[0].Text, Is.EqualTo("Messenger parser works"));

            Assert.That(instagram.Participants.Select(p => p.DisplayName), Does.Contain("Sam"));
            Assert.That(instagram.Conversations[0].Segments[0].Text, Is.EqualTo("Instagram parser works"));

            Assert.That(imessage.Conversations[0].Segments[0].Text, Is.EqualTo("iMessage parser works"));

            Assert.That(mbox.Conversations[0].Title, Is.EqualTo("Mbox parser"));
            Assert.That(mbox.Conversations[0].Segments[0].Text, Is.EqualTo("Mbox parser works"));
        });
    }

    [Test]
    public async Task ExtendedImportParsersHandleGitBrowserSearchBookmarksAndBackup()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var git = await ImportAsync(client, "git", new ImportRequest(
            Text: "commit 0f4e9b7\nAuthor: Dev One <dev1@example.test>\nDate: 2026-05-20T14:00:00Z\n\nAdd importer support"));

        var browserCapture = await ImportAsync(client, "browser-capture", new ImportRequest(
            Text: "{\"events\":[{\"title\":\"Importer docs\",\"url\":\"https://docs.example.test/importers\",\"content\":\"Read browser capture schema.\",\"timestamp\":\"2026-05-20T15:00:00Z\"}]}"));

        var googleSearch = await ImportAsync(client, "google-search-history", new ImportRequest(
            Text: "query,url,time\nflutter receive sharing intent,https://www.google.com/search?q=flutter+receive+sharing+intent,2026-05-20T15:30:00Z"));

        var bookmarks = await ImportAsync(client, "bookmarks", new ImportRequest(
            Text: "{\"roots\":{\"bookmark_bar\":{\"children\":[{\"type\":\"url\",\"name\":\"Lifenizer\",\"url\":\"https://github.com/Ekwav/lifenizer\"}]}}}"));

        var backup = await ImportAsync(client, "lifenizer-backup", new ImportRequest(
            Text: "{\"conversations\":[{\"title\":\"Recovered\",\"source\":\"manual-text\",\"participantNames\":[\"Alice\"],\"segments\":[{\"text\":\"Recovered from backup\",\"participantName\":\"Alice\",\"offsetMs\":0}]}]}"));

        Assert.Multiple(() =>
        {
            Assert.That(git.Conversations[0].Title, Is.EqualTo("Git history"));
            Assert.That(git.Conversations[0].Segments[0].Text, Does.Contain("Add importer support"));

            Assert.That(browserCapture.Conversations[0].Segments[0].Text, Does.Contain("https://docs.example.test/importers"));

            Assert.That(googleSearch.Conversations[0].Segments[0].Text, Does.Contain("flutter receive sharing intent"));

            Assert.That(bookmarks.Conversations[0].Segments[0].Text, Does.Contain("github.com/Ekwav/lifenizer"));

            Assert.That(backup.Conversations[0].Title, Is.EqualTo("Recovered"));
            Assert.That(backup.Conversations[0].Segments[0].Text, Is.EqualTo("Recovered from backup"));
        });
    }

    [Test]
    public async Task RealisticImporterMocksNormalizeKeySources()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var whatsapp = await ImportAsync(client, "whatsapp", new ImportRequest(
            Title: "WhatsApp export",
            Text: LoadMockData("whatsapp-export.txt")));

        var git = await ImportAsync(client, "git", new ImportRequest(
            OriginalFileName: "git-log-fuller.txt",
            Text: LoadMockData("git-log-fuller.txt"),
            Metadata: new Dictionary<string, string>
            {
                ["repoUrl"] = "https://github.com/Ekwav/lifenizer"
            }));

        var browserCapture = await ImportAsync(client, "browser-capture", new ImportRequest(
            Text: LoadMockData("browser-capture-events.json"),
            MimeType: "application/json"));

        var googleSearch = await ImportAsync(client, "google-search-history", new ImportRequest(
            Text: LoadMockData("google-myactivity-search.json"),
            MimeType: "application/json"));

        var bookmarkJson = await ImportAsync(client, "bookmarks", new ImportRequest(
            OriginalFileName: "Bookmarks",
            Text: LoadMockData("chrome-bookmarks.json"),
            MimeType: "application/json"));

        var bookmarkHtml = await ImportAsync(client, "bookmarks", new ImportRequest(
            OriginalFileName: "bookmarks.html",
            Text: LoadMockData("chrome-bookmarks.html"),
            MimeType: "text/html"));

        var backup = await ImportAsync(client, "lifenizer-backup", new ImportRequest(
            OriginalFileName: "lifenizer-backup.json",
            Text: LoadMockData("lifenizer-backup.json"),
            MimeType: "application/json"));

        Assert.Multiple(() =>
        {
            Assert.That(whatsapp.Conversations[0].Segments, Has.Count.EqualTo(3));
            Assert.That(whatsapp.Conversations[0].Segments[1].Text, Does.Contain("Continuation line without timestamp"));

            Assert.That(git.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(git.Conversations[0].Segments[0].Text, Does.Contain("importer: add browser capture parser"));
            Assert.That(git.Participants.Select(p => p.DisplayName), Does.Contain("Max Mustermann <max@example.test>"));

            Assert.That(browserCapture.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(browserCapture.Conversations[0].Segments[1].Text, Does.Contain("ACTION_SEND_MULTIPLE"));

            Assert.That(googleSearch.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(googleSearch.Conversations[0].Segments[0].Text, Does.Contain("lifenizer importer coverage"));

            Assert.That(bookmarkJson.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(bookmarkJson.Conversations[0].Segments.Select(s => s.Text), Does.Contain("Bookmarked Lifenizer Repo: https://github.com/Ekwav/lifenizer"));

            Assert.That(bookmarkHtml.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(bookmarkHtml.Conversations[0].Segments.Select(s => s.Text), Does.Contain("Bookmarked Git pretty formats: https://git-scm.com/docs/pretty-formats"));

            Assert.That(backup.Conversations[0].Title, Is.EqualTo("Recovered planning thread"));
            Assert.That(backup.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(backup.Conversations[0].Segments[1].Text, Does.Contain("realistic payloads"));
        });
    }

    [Test]
    public async Task RealisticImporterMocksNormalizeRemainingChatAndArchiveSources()
    {
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");

        var slack = await ImportAsync(client, "slack", new ImportRequest(
            OriginalFileName: "slack-channel.json",
            MimeType: "application/json",
            Text: LoadMockData("slack-channel.json")));

        var teams = await ImportAsync(client, "teams", new ImportRequest(
            OriginalFileName: "teams-export.json",
            MimeType: "application/json",
            Text: LoadMockData("teams-export.json")));

        var telegram = await ImportAsync(client, "telegram", new ImportRequest(
            OriginalFileName: "telegram-result.json",
            MimeType: "application/json",
            Text: LoadMockData("telegram-result.json")));

        var signal = await ImportAsync(client, "signal", new ImportRequest(
            OriginalFileName: "signal-export.csv",
            MimeType: "text/csv",
            Text: LoadMockData("signal-export.csv")));

        var messenger = await ImportAsync(client, "facebook-messenger", new ImportRequest(
            OriginalFileName: "facebook-messenger-message_1.json",
            MimeType: "application/json",
            Text: LoadMockData("facebook-messenger-message_1.json")));

        var instagram = await ImportAsync(client, "instagram", new ImportRequest(
            OriginalFileName: "instagram-inbox.json",
            MimeType: "application/json",
            Text: LoadMockData("instagram-inbox.json")));

        var imessage = await ImportAsync(client, "imessage", new ImportRequest(
            OriginalFileName: "imessage-export.txt",
            MimeType: "text/plain",
            Text: LoadMockData("imessage-export.txt")));

        var mbox = await ImportAsync(client, "mbox", new ImportRequest(
            OriginalFileName: "mailbox.mbox",
            MimeType: "application/mbox",
            Text: LoadMockData("mailbox.mbox")));

        var history = await ImportAsync(client, "browser-history", new ImportRequest(
            OriginalFileName: "browser-history.csv",
            MimeType: "text/csv",
            Text: LoadMockData("browser-history.csv")));

        Assert.Multiple(() =>
        {
            Assert.That(slack.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(slack.Participants.Select(p => p.DisplayName), Does.Contain("Nina"));

            Assert.That(teams.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(teams.Conversations[0].Segments[0].Text, Does.Contain("strip tags"));

            Assert.That(telegram.Conversations[0].Title, Is.EqualTo("Release coordination"));
            Assert.That(telegram.Conversations[0].Segments[0].Text, Does.Contain("nested Telegram text arrays"));

            Assert.That(signal.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(signal.Conversations[0].Segments[1].Text, Is.EqualTo("Signal backup import completed"));

            Assert.That(messenger.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(messenger.Participants.Select(p => p.DisplayName), Does.Contain("Liam"));

            Assert.That(instagram.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(instagram.Conversations[0].Segments[0].Text, Is.EqualTo("Instagram export parser check"));

            Assert.That(imessage.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(imessage.Conversations[0].Segments[0].Text, Is.EqualTo("iMessage plain export line one"));

            Assert.That(mbox.Conversations, Has.Count.EqualTo(2));
            Assert.That(mbox.Conversations[0].Title, Is.EqualTo("Importer verification mail"));

            Assert.That(history.Conversations[0].Segments, Has.Count.EqualTo(2));
            Assert.That(history.Conversations[0].Segments[0].Text, Does.Contain("github.com/Ekwav/lifenizer/pull/60"));
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

    [TestCase("paperless", "baseUrl")]
    [TestCase("discord", "baseUrl")]
    [TestCase("youtube-transcript", "baseUrl")]
    [TestCase("youtube-transcript", "transcriptUrl")]
    [TestCase("email", "host")]
    [TestCase("email", "allowInvalidCertificate")]
    public async Task RequestCannotOverrideProviderDestination(string source, string key)
    {
        await using var target = new MockHttpServer(_ => Json(new { }));
        await using var factory = new LifenizerApiFactory();
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");
        var response = await client.PostAsJsonAsync($"/api/imports/{source}", new ImportRequest(Metadata: new Dictionary<string, string>
        {
            [key] = target.Url,
            ["token"] = "attacker-token",
            ["channelId"] = "test",
            ["videoId"] = "test"
        }), JsonOptions);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(target.RequestCount, Is.Zero);
    }

    [TestCase("paperless", "Imports:Paperless:BaseUrl")]
    [TestCase("discord", "Imports:Discord:BaseUrl")]
    [TestCase("youtube-transcript", "Imports:YouTube:BaseUrl")]
    [TestCase("audio", "Whisper:BaseUrl")]
    public async Task ProviderDoesNotFollowRedirects(string source, string configKey)
    {
        await using var target = new MockHttpServer(_ => Json(new { }));
        await using var redirect = new MockHttpServer(_ => new MockHttpResponse("text/plain", "redirect", 307, target.Url));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { [configKey] = redirect.Url });
        using var client = await AuthenticatedClientAsync(factory, "alice@example.test");
        var response = await client.PostAsJsonAsync($"/api/imports/{source}", new ImportRequest(PayloadBase64: "YQ==", Metadata: new Dictionary<string, string>
        {
            ["token"] = "provider-token",
            ["channelId"] = "test",
            ["videoId"] = "test"
        }), JsonOptions);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(redirect.RequestCount, Is.EqualTo(1));
        Assert.That(target.RequestCount, Is.Zero);
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

    private static string LoadMockData(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "MockData", "importers", fileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Mock data file not found: {path}");
        }

        return File.ReadAllText(path, Encoding.UTF8);
    }

    private static string BuildZipPayloadBase64(params (string Name, string Content)[] files)
    {
        using var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var file in files)
            {
                var entry = archive.CreateEntry(file.Name);
                using var entryStream = entry.Open();
                using var writer = new StreamWriter(entryStream, Encoding.UTF8, 1024, leaveOpen: false);
                writer.Write(file.Content);
            }
        }

        return Convert.ToBase64String(stream.ToArray());
    }
}

internal sealed record MockHttpResponse(string ContentType, string Body, int StatusCode = 200, string? RedirectLocation = null);

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
            if (response.RedirectLocation is not null) context.Response.RedirectLocation = response.RedirectLocation;
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
    private readonly IReadOnlyDictionary<uint, string> messages;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task loop;
    public MockImapServer(string rawMessage) : this(new Dictionary<uint, string> { [1] = rawMessage }) { }
    public MockImapServer(IReadOnlyDictionary<uint, string> messages)
    {
        this.messages = messages;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        loop = Task.Run(HandleAsync);
    }
    public int Port { get; }
    public uint UidValidity { get; set; } = 123;
    public uint? ReportedMessageSize { get; set; }
    public List<string> Commands { get; } = [];
    public async ValueTask DisposeAsync()
    {
        cancellation.Cancel();
        listener.Stop();
        try { await loop; }
        catch (Exception exception) when (exception is SocketException or ObjectDisposedException or OperationCanceledException) { }
        cancellation.Dispose();
    }
    private async Task HandleAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
            await using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8, false, 8192, true);
            await using var writer = new StreamWriter(stream, new UTF8Encoding(false), 8192, true) { NewLine = "\r\n", AutoFlush = true };
            await writer.WriteLineAsync("* OK [CAPABILITY IMAP4rev1] Mock IMAP ready");
            while (!cancellation.IsCancellationRequested)
            {
                var line = await reader.ReadLineAsync(cancellation.Token);
                if (line is null) break;
                var pieces = line.Split(' ', 3);
                var tag = pieces[0];
                var command = pieces[1].ToUpperInvariant();
                // No authentication secrets are retained in the command trace.
                Commands.Add(command == "LOGIN" ? "LOGIN" : line[(tag.Length + 1)..]);
                if (command == "CAPABILITY")
                    await writer.WriteLineAsync("* CAPABILITY IMAP4rev1");
                else if (command == "LOGIN") { }
                else if (command is "LIST" or "LSUB")
                    await writer.WriteLineAsync("* LIST (\\HasNoChildren) \"/\" \"INBOX\"");
                else if (command == "EXAMINE")
                {
                    await writer.WriteLineAsync("* FLAGS (\\Seen)");
                    await writer.WriteLineAsync($"* {messages.Count} EXISTS");
                    await writer.WriteLineAsync($"* OK [UIDVALIDITY {UidValidity}] valid");
                    await writer.WriteLineAsync($"* OK [UIDNEXT {messages.Keys.Max() + 1}] next");
                }
                else if (line.Contains("UID SEARCH", StringComparison.OrdinalIgnoreCase))
                {
                    var match = System.Text.RegularExpressions.Regex.Match(line, @"UID (\d+):\*");
                    var after = match.Success ? uint.Parse(match.Groups[1].Value) : 1;
                    await writer.WriteLineAsync("* SEARCH " + string.Join(' ', messages.Keys.Where(uid => uid >= after).Order()));
                }
                else if (line.Contains("UID FETCH", StringComparison.OrdinalIgnoreCase))
                {
                    var uidSet = pieces[2].Split(' ')[1];
                    var uids = new MailKit.UniqueIdSet();
                    MailKit.UniqueIdSet.TryParse(uidSet, out uids);
                    foreach (var id in uids!)
                    {
                        if (!messages.TryGetValue(id.Id, out var raw)) continue;
                        if (line.Contains("RFC822.SIZE"))
                            await writer.WriteLineAsync($"* 1 FETCH (UID {id.Id} RFC822.SIZE {ReportedMessageSize ?? (uint)Encoding.UTF8.GetByteCount(raw)})");
                        else
                        {
                            var bytes = Encoding.UTF8.GetBytes(raw);
                            await writer.WriteLineAsync($"* 1 FETCH (UID {id.Id} BODY[] {{{bytes.Length}}}");
                            await stream.WriteAsync(bytes);
                            await writer.WriteLineAsync("");
                            await writer.WriteLineAsync(")");
                        }
                    }
                }
                else if (command == "LOGOUT")
                {
                    await writer.WriteLineAsync("* BYE Mock IMAP logging out");
                    await writer.WriteLineAsync($"{tag} OK LOGOUT completed");
                    break;
                }
                else
                {
                    await writer.WriteLineAsync($"{tag} BAD unsupported command");
                    continue;
                }
                await writer.WriteLineAsync(command == "EXAMINE" ? $"{tag} OK [READ-ONLY] completed" : $"{tag} OK completed");
            }
        }
    }
}
