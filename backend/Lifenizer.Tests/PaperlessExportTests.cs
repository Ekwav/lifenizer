using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Lifenizer.Api.Services;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class PaperlessExportTests
{
    private static byte[] Zip(params (string Name, byte[] Bytes)[] files)
    {
        using var output = new MemoryStream();
        using (var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
            foreach (var (name, bytes) in files)
            {
                using var entry = archive.CreateEntry(name).Open();
                entry.Write(bytes);
            }
        return output.ToArray();
    }

    private static NormalizedImportResponse Import(byte[] bytes) => new PaperlessExportParser().Parse(
        new ImportRequest(OriginalFileName: "export.zip", MimeType: "application/zip", PayloadBase64: Convert.ToBase64String(bytes)));

    [TestCase("manifest.json")]
    [TestCase("json/invoice-manifest.json")]
    public void ExporterManifestPreservesOcrTitleParticipantsTagsAndStableIds(string name)
    {
        var manifest = JsonSerializer.SerializeToUtf8Bytes(new object[]
        {
            new { model = "documents.correspondent", pk = 4, fields = new { name = "Electric company" } },
            new { model = "documents.tag", pk = 9, fields = new { name = "Utilities" } },
            new { model = "documents.document", pk = 42, fields = new { title = "Power invoice", content = "METER READING 7319", correspondent = 4, tags = new[] { 9 }, checksum = "document-checksum", created = "2026-10-02T10:00:00Z" }, __exported_file_name__ = "originals/invoice.pdf" },
            new { model = "paperless_mail.mailaccount", pk = 1, fields = new { password = "private-account-secret" } }
        });
        var first = Import(Zip((name, manifest), ("originals/invoice.pdf", "no extraction needed"u8.ToArray())));
        var second = Import(Zip((name, manifest)));
        var conversation = first.Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(conversation.Title, Is.EqualTo("Power invoice"));
            Assert.That(conversation.Source, Is.EqualTo("paperless"));
            Assert.That(conversation.ParticipantNames, Is.EqualTo(new[] { "Electric company" }));
            Assert.That(conversation.Metadata!["paperless-tags"], Is.EqualTo("Utilities"));
            Assert.That(conversation.Segments.Single().Text, Is.EqualTo("METER READING 7319"));
            Assert.That(conversation.Segments.Single().CreatedAt, Is.EqualTo(DateTimeOffset.Parse("2026-10-02T10:00:00Z")));
            Assert.That(conversation.SourceThreadId, Is.EqualTo(second.Conversations.Single().SourceThreadId));
            Assert.That(conversation.SourceThreadId, Is.EqualTo(conversation.Segments.Single().SourceMessageId));
            Assert.That(JsonSerializer.Serialize(first), Does.Not.Contain("private-account-secret"));
        });
    }

    [Test]
    public void DocumentsWithoutOcrKeepAnEmptyStableSegmentAndSearchableTitle()
    {
        var result = Import(Zip(("manifest.json", """
            [{"model":"documents.document","pk":7,"fields":{"title":"Awaiting OCR","content":""}}]
            """u8.ToArray())));
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations.Single().Title, Is.EqualTo("Awaiting OCR"));
            Assert.That(result.Conversations.Single().Segments.Single().Text, Is.Empty);
            Assert.That(result.Diagnostics!["documentsWithoutText"], Is.EqualTo("1"));
        });
    }

    [Test]
    public void BulkZipExtractsPdfTextWithIdempotentContentIdentity()
    {
        var pdf = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "MockData", "documents", "text.pdf"));
        var result = Import(Zip(("downloads/invoice.pdf", pdf), ("ignored.zip", Zip(("nested.pdf", pdf)))));
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations, Has.Count.EqualTo(1));
            Assert.That(result.Conversations.Single().Segments.Single().Text, Does.Contain("SEARCHABLE QUARTERLY INVOICE 4827"));
            Assert.That(result.Conversations.Single().SourceThreadId, Is.EqualTo(Import(Zip(("renamed.pdf", pdf))).Conversations.Single().SourceThreadId));
        });
    }

    [TestCase("../outside.txt")]
    [TestCase("/absolute.txt")]
    [TestCase("C:\\outside.txt")]
    public void UnsafePathsAreRejectedBeforeAnyDocumentIsRead(string path)
    {
        Assert.Throws<InvalidOperationException>(() => Import(Zip((path, "bad"u8.ToArray()), ("manifest.json", "[]"u8.ToArray()))));
    }

    [Test]
    public void HighRatioArchiveIsRejectedByPaperlessAndGenericTextImports()
    {
        var bytes = Zip(("huge.txt", new byte[2 * 1024 * 1024]));
        Assert.Multiple(() =>
        {
            Assert.Throws<InvalidOperationException>(() => Import(bytes));
            Assert.Throws<InvalidOperationException>(() => CommonParsing.EffectiveText(new ImportRequest(OriginalFileName: "export.zip", PayloadBase64: Convert.ToBase64String(bytes))));
        });
    }

    [Test]
    public void GenericZipIgnoresNestedArchivesAndBinaryFiles()
    {
        var zip = Zip(("nested.zip", Zip(("secret.txt", "NESTED SECRET"u8.ToArray()))), ("binary.exe", new byte[] { 0xff, 0, 1 }), ("readme.txt", "Readable export"u8.ToArray()));
        Assert.That(CommonParsing.EffectiveText(new ImportRequest(OriginalFileName: "export.zip", PayloadBase64: Convert.ToBase64String(zip))), Is.EqualTo("Readable export"));
    }

    [Test]
    public void EmptyOrUnknownArchivesOfferRecoveryInsteadOfImportingBinaryData()
    {
        Assert.Throws<InvalidOperationException>(() => Import(Zip(("ignored.zip", Zip(("secret.txt", "nested"u8.ToArray()))))));
        Assert.Throws<InvalidOperationException>(() => Import("invalid zip"u8.ToArray()));
    }

    [Test]
    public void ExhaustedDocumentBudgetIsRejectedBeforeLaunchingTools()
    {
        Assert.Throws<InvalidOperationException>(() => PdfTextExtractor.Extract("%PDF-"u8.ToArray(), timeout: TimeSpan.Zero));
    }
}
