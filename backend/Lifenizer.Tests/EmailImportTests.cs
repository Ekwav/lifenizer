using Lifenizer.Api.Services;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;
using Microsoft.Extensions.Configuration;

namespace Lifenizer.Tests;

public sealed class EmailImportTests
{
    private const string MimeEmail = "From: =?utf-8?B?Sm9zw6k=?= <JOSE@example.test>\r\nTo: Sam <sam.one@example.test>, Sam <sam.two@example.test>\r\nSubject: =?utf-8?Q?R=C3=A9sum=C3=A9?=\r\nDate: Fri, 02 Oct 2026 10:00:00 +0000\r\nMessage-ID: <reply@example.test>\r\nReferences: <root@example.test> <prior@example.test>\r\nIn-Reply-To: <prior@example.test>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nCaf=C3=A9 on a soft=\r\n line.\r\n--inner\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Wrong alternative</p>\r\n--inner--\r\n--outer\r\nContent-Type: text/plain; name=private.txt\r\nContent-Disposition: attachment; filename=private.txt\r\nContent-Transfer-Encoding: base64\r\n\r\nU0VDUkVUIEFUVEFDSE1FTlQ=\r\n--outer--\r\n";

    [Test]
    public void MboxDecodesMimeAndKeepsAddressIdentitiesAndThreadIds()
    {
        var result = new MboxParser().Parse(new ImportRequest(Text: "From jose@example.test Fri Oct 02 10:00:00 2026\n" + MimeEmail));
        var conversation = result.Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(conversation.Title, Is.EqualTo("Résumé"));
            Assert.That(conversation.Segments.Single().Text, Is.EqualTo("Café on a soft line."));
            Assert.That(conversation.Segments.Single().ParticipantName, Is.EqualTo("José"));
            Assert.That(conversation.Segments.Single().ParticipantIdentifier, Is.EqualTo("email:jose@example.test"));
            Assert.That(conversation.Segments.Single().SourceMessageId, Is.EqualTo("reply@example.test"));
            Assert.That(conversation.SourceThreadId, Is.EqualTo("root@example.test"));
            Assert.That(conversation.ArtifactNames, Is.EqualTo(new[] { "private.txt" }));
            Assert.That(result.Participants.Where(person => person.DisplayName == "Sam").ToArray(), Has.Length.EqualTo(2));
            Assert.That(result.Participants.SelectMany(person => person.Identifiers!), Is.EquivalentTo(new[] { "email:jose@example.test", "email:sam.one@example.test", "email:sam.two@example.test" }));
        });
    }

    [Test]
    public void Rfc822Base64AndLegacyCharsetAreDecodedFromOriginalBytes()
    {
        const string raw = "From: One <one@example.test>\r\nSubject: Legacy\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\nCafé";
        var result = new MboxParser().Parse(new ImportRequest(PayloadBase64: Convert.ToBase64String(System.Text.Encoding.Latin1.GetBytes(raw))));
        Assert.That(result.Conversations.Single().Segments.Single().Text, Is.EqualTo("Café"));
        var html = new MboxParser().Parse(new ImportRequest(Text: "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nPHA+SGVsbG8gJmFtcDsgd29ybGQ8L3A+"));
        Assert.That(html.Conversations.Single().Segments.Single().Text, Is.EqualTo("Hello & world"));
    }

    [Test]
    public async Task ImapUidPagesAreReadOnlyResumeWithoutRepeatsAndResetOnUidValidityChange()
    {
        await using var server = new MockImapServer(new Dictionary<uint, string> { [2] = MimeEmail, [9] = MimeEmail, [40] = MimeEmail });
        var importer = Client(server);
        var request = Request(new() { ["limit"] = "2" });
        var first = await importer.ImportAsync(request, CancellationToken.None);
        Assert.That(first.Conversations.Select(item => item.Metadata!["imap-uid"]), Is.EqualTo(new[] { "2", "9" }));
        Assert.That(first.Diagnostics!["hasMore"], Is.EqualTo("true"));
        var second = await importer.ImportAsync(Request(new() { ["afterUid"] = first.Diagnostics["nextUid"], ["uidValidity"] = first.Diagnostics["uidValidity"] }), CancellationToken.None);
        Assert.That(second.Conversations.Single().Metadata!["imap-uid"], Is.EqualTo("40"));
        Assert.That(second.Diagnostics!["hasMore"], Is.EqualTo("false"));
        var end = await importer.ImportAsync(Request(new() { ["afterUid"] = "40", ["uidValidity"] = "123" }), CancellationToken.None);
        Assert.That(end.Conversations, Is.Empty);
        server.UidValidity = 456;
        var reset = await importer.ImportAsync(Request(new() { ["afterUid"] = "40", ["uidValidity"] = "123" }), CancellationToken.None);
        Assert.Multiple(() =>
        {
            Assert.That(reset.Conversations, Has.Count.EqualTo(3));
            Assert.That(reset.Diagnostics!["cursorReset"], Is.EqualTo("true"));
            Assert.That(server.Commands, Does.Contain("EXAMINE INBOX"));
            Assert.That(server.Commands.Where(command => command.Contains("BODY")), Is.All.Contains("BODY.PEEK[]"));
            Assert.That(server.Commands, Has.None.Contains("STORE"));
            Assert.That(System.Text.Json.JsonSerializer.Serialize(reset), Does.Not.Contain("not-a-real-password"));
        });
    }

    [Test]
    public async Task OversizedPageFailsBeforeDownloadingAndRetryDoesNotAdvanceCursor()
    {
        await using var server = new MockImapServer(MimeEmail) { ReportedMessageSize = 26 * 1024 * 1024 };
        var importer = Client(server);
        Assert.That(async () => await importer.ImportAsync(Request(), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("25 MiB"));
        Assert.That(server.Commands, Has.None.Contains("BODY.PEEK"));
        server.ReportedMessageSize = null;
        var result = await importer.ImportAsync(Request(), CancellationToken.None);
        Assert.That(result.Conversations.Single().Metadata!["imap-uid"], Is.EqualTo("1"));
    }

    [Test]
    public async Task MandatoryTlsFailsBeforeSendingCredentialsWhenServerCannotStartTls()
    {
        await using var server = new MockImapServer(MimeEmail);
        var importer = Client(server, new() { ["Imports:Imap:SocketOptions"] = "StartTls" });
        Assert.That(async () => await importer.ImportAsync(Request(), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("TLS"));
        Assert.That(server.Commands, Does.Not.Contain("LOGIN"));
    }

    [Test]
    public async Task RejectsUntrustedTlsCertificate()
    {
        using var key = System.Security.Cryptography.RSA.Create(2048);
        var certificateRequest = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=localhost", key,
            System.Security.Cryptography.HashAlgorithmName.SHA256, System.Security.Cryptography.RSASignaturePadding.Pkcs1);
        using var certificate = certificateRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(1));
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var serve = Task.Run(async () =>
        {
            using var connection = await listener.AcceptTcpClientAsync();
            using var tls = new System.Net.Security.SslStream(connection.GetStream());
            try { await tls.AuthenticateAsServerAsync(certificate); }
            catch (Exception exception) when (exception is System.Security.Authentication.AuthenticationException or IOException) { }
        });
        try
        {
            var importer = new PlainImapImportClient(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Imports:Imap:Host"] = "127.0.0.1", ["Imports:Imap:Port"] = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port.ToString()
            }).Build());
            Assert.That(async () => await importer.ImportAsync(Request(), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("TLS"));
            await serve.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { listener.Stop(); }
    }

    [Test]
    public void RejectsRemotePlaintextOpportunisticTlsAndRequestDestinationOverrides()
    {
        var remote = new PlainImapImportClient(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Imports:Imap:Host"] = "imap.example.test", ["Imports:Imap:UseTls"] = "false" }).Build());
        Assert.That(async () => await remote.ImportAsync(Request(), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("loopback"));
        var insecure = new PlainImapImportClient(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Imports:Imap:SocketOptions"] = "StartTlsWhenAvailable" }).Build());
        Assert.That(() => insecure.Settings(), Throws.TypeOf<InvalidOperationException>());
        Assert.That(async () => await remote.ImportAsync(Request(new() { ["host"] = "127.0.0.1" }), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("configured on the server"));
    }

    [Test]
    public void RejectsInvalidCursorAndCredentialNewlinesBeforeConnecting()
    {
        var importer = new PlainImapImportClient(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Imports:Imap:Host"] = "127.0.0.1", ["Imports:Imap:UseTls"] = "false" }).Build());
        Assert.That(async () => await importer.ImportAsync(Request(new() { ["afterUid"] = "-1" }), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("unsigned"));
        Assert.That(async () => await importer.ImportAsync(Request(new() { ["afterUid"] = "1" }), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("uidValidity"));
        Assert.That(async () => await importer.ImportAsync(Request(new() { ["username"] = "bad\r\nLOGIN" }), CancellationToken.None), Throws.TypeOf<InvalidOperationException>().With.Message.Contains("newlines"));
    }

    private static PlainImapImportClient Client(MockImapServer server, Dictionary<string, string?>? overrides = null)
    {
        var configuration = overrides ?? new();
        configuration["Imports:Imap:Host"] = "127.0.0.1";
        configuration["Imports:Imap:Port"] = server.Port.ToString();
        configuration["Imports:Imap:UseTls"] = "false";
        return new PlainImapImportClient(new ConfigurationBuilder().AddInMemoryCollection(configuration).Build());
    }
    private static ImportRequest Request(Dictionary<string, string>? metadata = null)
    {
        metadata ??= new();
        metadata.TryAdd("username", "one@example.test");
        metadata.TryAdd("password", "not-a-real-password");
        return new ImportRequest(Metadata: metadata);
    }
}
