using System.Text;
using System.Text.Json;
using Lifenizer.Api.Services;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;
using Microsoft.Extensions.DependencyInjection;

namespace Lifenizer.Tests;

public sealed class DocumentImportTests
{
    private static byte[] Fixture(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "MockData", "documents", name));

    [TestCase("text.pdf", "SEARCHABLE QUARTERLY INVOICE 4827")]
    [TestCase("scanned.pdf", "SCANNED RECHNUNG 7391")]
    [TestCase("scan.png", "SCANNED RECHNUNG 7391")]
    [TestCase("scan.jpg", "SCANNED RECHNUNG 7391")]
    public void PdfAndImagePayloadsActuallyExtractSearchableText(string file, string expected)
    {
        var result = new ScannedPdfParser().Parse(new ImportRequest(OriginalFileName: file,
            MimeType: file.EndsWith("png") ? "image/png" : file.EndsWith("jpg") ? "image/jpeg" : "application/pdf", PayloadBase64: Convert.ToBase64String(Fixture(file)),
            Metadata: new Dictionary<string, string> { ["documentId"] = "folder-doc-1" }));
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations.Single().Segments.Single().Text, Does.Contain(expected));
            Assert.That(result.Conversations.Single().SourceThreadId, Is.EqualTo("folder-doc-1"));
            Assert.That(result.Conversations.Single().Segments.Single().SourceMessageId, Is.EqualTo("folder-doc-1"));
        });
    }

    [TestCase("scan.png")]
    [TestCase("scan.jpg")]
    public void ImagePayloadMagicWorksWithoutMimeOrKnownFileExtension(string file)
    {
        var result = new ScannedPdfParser().Parse(new ImportRequest(OriginalFileName: "picked-file.bin",
            PayloadBase64: Convert.ToBase64String(Fixture(file))));
        Assert.That(result.Conversations.Single().Segments.Single().Text, Does.Contain("SCANNED RECHNUNG 7391"));
    }

    [Test]
    public void MixedPdfOcrsPagesWithoutTextEvenWhenOtherPagesHaveText()
    {
        var text = PdfTextExtractor.Extract(Fixture("mixed.pdf"));
        Assert.That(text, Does.Contain("DIGITAL FIRST PAGE").And.Contain("SCANNED RECHNUNG 7391"));
    }

    [Test]
    public void OversizedImageDimensionsAreRejectedBeforeOcr()
    {
        var png = Fixture("scan.png");
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(png.AsSpan(16, 4), 100001);
        var exception = Assert.Throws<InvalidOperationException>(() => PdfTextExtractor.Extract(png, image: true));
        Assert.That(exception!.Message, Does.Contain("25 megapixels"));
    }

    [Test]
    public void InvalidPdfIsRejectedInsteadOfIndexingBinaryBytes()
    {
        Assert.Throws<InvalidOperationException>(() => new ScannedPdfParser().Parse(new ImportRequest(
            MimeType: "application/pdf", PayloadBase64: Convert.ToBase64String(Encoding.UTF8.GetBytes("not a PDF")))));
    }

    private static string PdfEmail(byte[] pdf) => "From: Ekwav <ekwav@example.test>\r\nTo: Partner <partner@example.test>\r\nSubject: Attached invoice\r\nMessage-ID: <pdf-mail@example.test>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=pdfboundary\r\n\r\n--pdfboundary\r\nContent-Type: text/plain\r\n\r\nBody alone has no invoice text\r\n--pdfboundary\r\nContent-Type: application/pdf; name=invoice.pdf\r\nContent-Disposition: attachment; filename=invoice.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Convert.ToBase64String(pdf, Base64FormattingOptions.InsertLineBreaks) + "\r\n--pdfboundary--\r\n";

    [Test]
    public async Task ImapAndMboxBothIndexRealPdfAttachmentWithStableIdentity()
    {
        var email = PdfEmail(Fixture("text.pdf"));
        var mbox = new MboxParser().Parse(new ImportRequest(Text: email));
        await using var server = new MockImapServer(email);
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?>
        {
            ["Imports:Imap:Host"] = "127.0.0.1", ["Imports:Imap:Port"] = server.Port.ToString(), ["Imports:Imap:UseTls"] = "false"
        });
        using var scope = factory.Services.CreateScope();
        var imap = await scope.ServiceProvider.GetRequiredService<PlainImapImportClient>().ImportAsync(new ImportRequest(Metadata:
            new Dictionary<string, string> { ["username"] = "test", ["password"] = "test" }), CancellationToken.None);
        foreach (var result in new[] { mbox, imap })
        {
            var conversation = result.Conversations.Single();
            Assert.Multiple(() =>
            {
                Assert.That(conversation.Segments[0].SourceMessageId, Is.EqualTo("pdf-mail@example.test"));
                Assert.That(conversation.Segments[1].Text, Does.Contain("SEARCHABLE QUARTERLY INVOICE 4827"));
                Assert.That(conversation.Segments[1].SourceMessageId, Is.EqualTo("pdf-mail@example.test:pdf:0"));
                Assert.That(conversation.Metadata!["indexed-pdf-attachments"], Is.EqualTo("1"));
                Assert.That(conversation.ParticipantIdentifiers, Does.Contain("email:partner@example.test"));
            });
        }
    }

    [Test]
    public void BadAttachmentDoesNotSilentlyAdvanceEmailImport()
    {
        Assert.Throws<InvalidOperationException>(() => new MboxParser().Parse(new ImportRequest(Text: PdfEmail(Encoding.UTF8.GetBytes("corrupt")))));
    }

    [Test]
    public async Task PaperlessPagesUseTrustedBaseStableDocumentLinksAndModifiedCursor()
    {
        var queries = new List<string>();
        await using var server = new MockHttpServer(request =>
        {
            queries.Add(request.Url!.Query);
            var page = request.QueryString["page"] ?? "1";
            return new MockHttpResponse("application/json", JsonSerializer.Serialize(new
            {
                next = page == "1" ? "https://untrusted.invalid/api/documents/?page=2" : null,
                results = new[] { new { id = int.Parse(page), title = "Invoice", content = "Paperless indexed OCR invoice", correspondent = "Partner", modified = "2026-10-04T10:00:00Z", created = "2026-10-01T08:00:00Z" } }
            }));
        });
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Imports:Paperless:BaseUrl"] = server.Url });
        using var scope = factory.Services.CreateScope();
        var provider = scope.ServiceProvider.GetRequiredService<ProviderHttpImportClient>();
        var request = new ImportRequest(Metadata: new Dictionary<string, string> { ["token"] = "secret", ["modifiedAfter"] = "2026-10-03T12:00:00Z" });
        var first = await provider.ImportPaperlessAsync(request, CancellationToken.None);
        var second = await provider.ImportPaperlessAsync(request with { Metadata = new Dictionary<string, string>(request.Metadata!) { ["page"] = first.Diagnostics!["nextPage"] } }, CancellationToken.None);
        Assert.Multiple(() =>
        {
            Assert.That(first.Diagnostics!["hasMore"], Is.EqualTo("true"));
            Assert.That(first.Diagnostics["nextPage"], Is.EqualTo("2"));
            Assert.That(second.Diagnostics!["hasMore"], Is.EqualTo("false"));
            Assert.That(first.Diagnostics["nextModifiedAfter"], Does.StartWith("2026-10-04T10:00:00"));
            Assert.That(first.Conversations.Single().SourceUrl, Is.EqualTo(server.Url + "documents/1/details"));
            Assert.That(first.Conversations.Single().SourceThreadId, Is.EqualTo(first.Conversations.Single().Segments.Single().SourceMessageId));
            Assert.That(queries.All(query => query.Contains("modified__gte=")), Is.True);
        });
    }
    [Test]
    public async Task PaperlessLoadsDetailContentAndResolvesNumericCorrespondent()
    {
        await using var server = new MockHttpServer(request => new MockHttpResponse("application/json", request.Url!.AbsolutePath switch
        {
            "/api/documents/" => "{\"results\":[{\"id\":42,\"title\":\"Invoice\",\"content\":\"\"}],\"next\":null}",
            "/api/documents/42/" => "{\"id\":42,\"title\":\"Invoice\",\"content\":\"DETAILED PAPERLESS OCR CONTENT\",\"correspondent\":7}",
            "/api/correspondents/7/" => "{\"id\":7,\"name\":\"Actual counterparty\"}",
            _ => throw new InvalidOperationException("Unexpected request")
        }));
        await using var factory = new LifenizerApiFactory(new Dictionary<string, string?> { ["Imports:Paperless:BaseUrl"] = server.Url });
        using var scope = factory.Services.CreateScope();
        var result = await scope.ServiceProvider.GetRequiredService<ProviderHttpImportClient>().ImportPaperlessAsync(
            new ImportRequest(Metadata: new Dictionary<string, string> { ["token"] = "secret" }), CancellationToken.None);
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations.Single().Segments.Single().Text, Is.EqualTo("DETAILED PAPERLESS OCR CONTENT"));
            Assert.That(result.Conversations.Single().ParticipantNames, Is.EqualTo(new[] { "Actual counterparty" }));
        });
    }

}
