using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using MimeKit;

namespace Lifenizer.Tests;

public sealed class EmailAttachmentTests
{
    [TestCase("notes.txt", "text/plain", "Invoice 4832", "Invoice 4832")]
    [TestCase("table.csv", "text/csv", "name,total\nAlice,48", "Alice,48")]
    [TestCase("page.html", "text/html", "<h1>Invoice &amp; receipt</h1>", "Invoice & receipt")]
    public void TextAttachmentsAreSearchableAndHaveStableIds(string name, string mime, string content, string expected)
    {
        using var message = Message(Part(name, mime, Encoding.UTF8.GetBytes(content)));
        var first = Normalize(message);
        var second = Normalize(message);
        Assert.That(first.Segments[0].Text, Is.EqualTo("Email body survives"));
        Assert.That(first.Segments[1].Text, Does.Contain(expected));
        Assert.That(first.Segments[1].SourceMessageId, Is.EqualTo("message@example.test:attachment:0"));
        Assert.That(second.Segments[1].SourceMessageId, Is.EqualTo(first.Segments[1].SourceMessageId));
        Assert.That(first.Metadata!["attachment-0-indexing"], Is.EqualTo("indexed"));
    }

    [Test]
    public void HtmlAttachmentOmitsScriptsAndStylesAndMissingMessageIdsStayStable()
    {
        using var message = Message(Part("page.html", "text/html", "<style>secret-css</style><script>secret-script</script><p>Useful receipt</p>"u8.ToArray()));
        message.Headers.RemoveAll(HeaderId.MessageId);
        var first = Normalize(message).Segments[1];
        Assert.That(first.Text, Does.Contain("Useful receipt").And.Not.Contain("secret-"));
        Assert.That(first.SourceMessageId, Does.StartWith("attachment-sha256:"));
        Assert.That(Normalize(message).Segments[1].SourceMessageId, Is.EqualTo(first.SourceMessageId));
    }

    [Test]
    public void CorruptOfficeArchivePreservesTheEmailBody()
    {
        using var message = Message(Part("bad.docx", "application/octet-stream", "not a zip"u8.ToArray()));
        var result = Normalize(message);
        Assert.That(result.Segments.Single().Text, Is.EqualTo("Email body survives"));
        Assert.That(result.Metadata!["attachment-0-indexing"], Does.StartWith("failed:"));
    }

    [Test]
    public void DeclaredLegacyCharsetIsUsedWithoutIndexingBinaryGarbage()
    {
        var part = Part("notes.txt", "text/plain", Encoding.Latin1.GetBytes("Café"));
        part.ContentType.Charset = "iso-8859-1";
        using var message = Message(part, Part("binary.txt", "text/plain", [0xff, 0xfe, 0xff]));
        var result = Normalize(message);
        Assert.That(result.Segments[1].Text, Does.Contain("Café"));
        Assert.That(result.Segments, Has.Count.EqualTo(2));
        Assert.That(result.Metadata!["attachment-1-indexing"], Does.StartWith("failed:"));
    }

    [TestCase("letter.docx", "word/document.xml", "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Quarterly invoice</w:t></w:r></w:p><w:p><w:r><w:t>Amount 473</w:t></w:r></w:p></w:body></w:document>")]
    [TestCase("letter.odt", "content.xml", "<office:document-content xmlns:office='urn:oasis:names:tc:opendocument:xmlns:office:1.0' xmlns:text='urn:oasis:names:tc:opendocument:xmlns:text:1.0'><office:body><text:p>Quarterly invoice</text:p><text:p>Amount 473</text:p></office:body></office:document-content>")]
    public void OfficeDocumentTextKeepsParagraphBoundaries(string name, string entry, string xml)
    {
        using var message = Message(Part(name, "application/octet-stream", Zip((entry, Encoding.UTF8.GetBytes(xml)))));
        var result = Normalize(message);
        Assert.That(result.Segments[1].Text, Does.Contain("Quarterly invoice\nAmount 473"));
        Assert.That(result.Metadata!["attachment-0-indexing"], Is.EqualTo("indexed"));
    }

    [Test]
    public void BadAndUnsupportedAttachmentsDoNotHideOtherMessagesOrChangeLaterAttachmentIds()
    {
        using var bad = Message(Part("broken.pdf", "application/pdf", "broken"u8.ToArray()),
            Part("archive.zip", "application/zip", Zip(("hidden.txt", "must not recurse"u8.ToArray()))),
            Part("good.txt", "text/plain", "Searchable receipt"u8.ToArray()));
        using var next = Message();
        var results = EmailNormalization.Response("mbox", new ImportRequest(), [(bad, null), (next, null)]);
        Assert.That(results.Conversations, Has.Count.EqualTo(2));
        var result = results.Conversations[0];
        Assert.That(result.Segments[0].Text, Is.EqualTo("Email body survives"));
        Assert.That(result.Segments[1].SourceMessageId, Is.EqualTo("message@example.test:attachment:2"));
        Assert.That(result.Metadata!["attachment-0-indexing"], Does.StartWith("failed:"));
        Assert.That(result.Metadata["attachment-1-indexing"], Does.StartWith("skipped:"));
        Assert.That(result.Metadata["attachment-2-indexing"], Is.EqualTo("indexed"));
    }

    [Test]
    public void XmlExternalEntitiesAreRejectedAndNeverExpanded()
    {
        var xml = "<!DOCTYPE document [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><document>&secret;</document>";
        using var message = Message(Part("bad.docx", "application/octet-stream", Zip(("word/document.xml", Encoding.UTF8.GetBytes(xml)))));
        var result = Normalize(message);
        Assert.That(result.Segments, Has.Count.EqualTo(1));
        Assert.That(result.Metadata!["attachment-0-indexing"], Does.StartWith("failed:"));
    }

    [Test]
    public void ResponseAttachmentBudgetSkipsExcessWithoutDiscardingMailBody()
    {
        using var first = Message(Enumerable.Range(0, 32).Select(i => Part($"{i}.txt", "text/plain", "searchable"u8.ToArray())).ToArray());
        using var second = Message(Part("last.txt", "text/plain", "over budget"u8.ToArray()));
        var result = EmailNormalization.Response("mbox", new ImportRequest(), [(first, null), (second, null)]);
        Assert.That(result.Conversations[0].Segments, Has.Count.EqualTo(33));
        Assert.That(result.Conversations[1].Segments.Single().Text, Is.EqualTo("Email body survives"));
        Assert.That(result.Conversations[1].Metadata!["attachment-0-indexing"], Does.StartWith("skipped:").And.Contain("budget"));
    }

    [Test]
    public void AggregateTextLimitDoesNotDiscardTheEmailBody()
    {
        var text = Encoding.UTF8.GetBytes(new string('x', BoundedAttachmentText.MaxTextChars));
        using var first = Message(Part("a.txt", "text/plain", text), Part("b.txt", "text/plain", text), Part("c.txt", "text/plain", [1]));
        var full = Normalize(first);
        Assert.That(full.Segments, Has.Count.EqualTo(3));
        Assert.That(full.Metadata!["attachment-2-indexing"], Does.StartWith("skipped:").And.Contain("budget"));
    }

    [Test]
    public void OrdinaryPdfPagesCanIndexMoreThanFourAttachmentsWithinTheSharedBudget()
    {
        var pdf = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "MockData", "documents", "text.pdf"));
        using var message = Message(Enumerable.Range(0, 5).Select(i => Part($"{i}.pdf", "application/pdf", pdf)).ToArray());
        var result = Normalize(message);
        Assert.That(result.Segments, Has.Count.EqualTo(6));
        Assert.That(result.Metadata!["attachment-4-indexing"], Is.EqualTo("indexed"));
    }

    [Test]
    public void WhitespacePlainBodyFallsBackToHtml()
    {
        using var message = new MimeMessage { Body = new MultipartAlternative()
        {
            new TextPart("plain") { Text = "  \n " }, new TextPart("html") { Text = "<p>Useful HTML body</p>" }
        }};
        Assert.That(Normalize(message).Segments.Single().Text, Is.EqualTo("Useful HTML body"));
    }

    [Test]
    public void OversizedDecodedAttachmentIsReportedWithoutAbortingMail()
    {
        using var message = Message(Part("large.txt", "text/plain", new byte[BoundedImportArchive.MaxBytes + 1]));
        var result = Normalize(message);
        Assert.That(result.Segments, Has.Count.EqualTo(1));
        Assert.That(result.Metadata!["attachment-0-indexing"], Does.StartWith("failed:").And.Contain("25 MiB"));
    }

    [Test]
    public void SafeArchiveReadsAreBoundedAndForgedExpandedSizesAreRejected()
    {
        var bytes = Zip(("word/document.xml", "real document data"u8.ToArray()));
        using (var archive = BoundedImportArchive.Open(bytes))
        {
            Assert.That(BoundedImportArchive.Read(archive.Entries[0]), Is.EqualTo("real document data"u8.ToArray()));
            Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Read(archive.Entries[0], 4));
        }
        var central = bytes.AsSpan().IndexOf(new byte[] { 0x50, 0x4b, 0x01, 0x02 });
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(central + 24, 4), 1);
        using var forged = BoundedImportArchive.Open(bytes);
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Read(forged.Entries[0]));
    }

    [TestCase("../escape")]
    [TestCase("/absolute")]
    [TestCase("C:\\absolute")]
    [TestCase("folder\\..\\escape")]
    public void UnsafeArchivePathsAreRejectedBeforeOfficeExtraction(string path)
    {
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(Zip((path, [1]))));
    }

    [Test]
    public void ArchiveEntryCountDuplicatesSymlinksAndExpansionRatioAreBounded()
    {
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(Zip(Enumerable.Range(0, 2001).Select(i => (i.ToString(), new byte[] { 1 })).ToArray())));
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(Zip(("same", [1]), ("SAME", [2]))));
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(Zip(("bomb", new byte[2 * 1024 * 1024]))));
        using var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, true))
            archive.CreateEntry("link").ExternalAttributes = 0xa000 << 16;
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(stream.ToArray()));
    }

    [Test]
    public void DeclaredArchiveEntryAndAggregateExpansionLimitsAreRejectedBeforeReading()
    {
        var bytes = Zip(("one", [1]));
        var central = bytes.AsSpan().IndexOf(new byte[] { 0x50, 0x4b, 0x01, 0x02 });
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(central + 24, 4), BoundedImportArchive.MaxBytes + 1);
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(bytes));
        bytes = Zip(Enumerable.Range(0, 5).Select(i => (i.ToString(), new byte[] { 1 })).ToArray());
        for (var start = 0; start < bytes.Length;)
        {
            var index = bytes.AsSpan(start).IndexOf(new byte[] { 0x50, 0x4b, 0x01, 0x02 });
            if (index < 0) break;
            central = start + index;
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(central + 20, 4), BoundedImportArchive.MaxBytes);
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(central + 24, 4), BoundedImportArchive.MaxBytes);
            start = central + 46;
        }
        Assert.Throws<InvalidDataException>(() => BoundedImportArchive.Open(bytes));
    }

    private static NormalizedConversation Normalize(MimeMessage message) =>
        EmailNormalization.Response("mbox", new ImportRequest(), [(message, null)]).Conversations.Single();

    private static MimeMessage Message(params MimeEntity[] attachments)
    {
        var message = new MimeMessage { MessageId = "message@example.test", Subject = "Attachment test" };
        message.Body = new Multipart("mixed") { new TextPart("plain") { Text = "Email body survives" } };
        foreach (var attachment in attachments) ((Multipart)message.Body).Add(attachment);
        return message;
    }

    private static MimePart Part(string name, string mime, byte[] bytes) => new(ContentType.Parse(mime))
    {
        ContentDisposition = new ContentDisposition(ContentDisposition.Attachment), FileName = name,
        Content = new MimeContent(new MemoryStream(bytes)), ContentTransferEncoding = ContentEncoding.Base64
    };

    private static byte[] Zip(params (string Name, byte[] Content)[] entries)
    {
        using var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, true))
            foreach (var (name, content) in entries)
            {
                using var output = archive.CreateEntry(name).Open();
                output.Write(content);
            }
        return stream.ToArray();
    }
}
