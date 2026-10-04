using System.IO.Compression;
using System.Text;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Tests;

public sealed class BackupParserTests
{
    [Test]
    public void TelegramFullExportKeepsChatsSpeakersDatesAndRichTextSeparate()
    {
        var result = new TelegramParser().Parse(new ImportRequest(Title: "Whole export", Text: """
            {"chats":{"list":[
              {"name":"Atlas planning","messages":[{"from":"Alice","date":"2025-06-15T09:00:00Z","text":["Atlas ",{"type":"bold","text":"deadline"}]}]},
              {"name":"Travel","messages":[{"from":"Bob","date":"2025-06-16T10:00:00Z","text":"Train reservation"}]},
              {"name":"Empty media chat","messages":[{"from":"Alice","text":""}]}
            ]}}
            """));
        Assert.Multiple(() =>
        {
            Assert.That(result.Conversations.Select(c => c.Title), Is.EqualTo(new[] { "Atlas planning", "Travel" }));
            Assert.That(result.Conversations[0].Segments[0].Text, Is.EqualTo("Atlas deadline"));
            Assert.That(result.Conversations[0].Segments[0].ParticipantName, Is.EqualTo("Alice"));
            Assert.That(result.Conversations[0].Segments[0].CreatedAt, Is.EqualTo(DateTimeOffset.Parse("2025-06-15T09:00:00Z")));
            Assert.That(result.Conversations[1].ParticipantNames, Is.EqualTo(new[] { "Bob" }));
        });
    }

    [Test]
    public void LifenizerSnapshotResolvesParticipantIdsAndKeepsHistoricalSegments()
    {
        var result = new LifenizerBackupParser().Parse(new ImportRequest(Text: """
            {"participants":[{"id":"alice-id","displayName":"Alice"}],
             "conversations":[{"title":"Restored atlas","source":"telegram","participantIds":["alice-id"],
               "segments":[{"text":"Atlas deadline","participantId":"alice-id","offsetMs":3000,"createdAt":"2025-06-15T09:00:00Z"}]}]}
            """));
        var conversation = result.Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(conversation.ParticipantNames, Is.EqualTo(new[] { "Alice" }));
            Assert.That(conversation.Source, Is.EqualTo("telegram"));
            Assert.That(conversation.Segments[0].ParticipantName, Is.EqualTo("Alice"));
            Assert.That(conversation.Segments[0].OffsetMs, Is.EqualTo(3000));
            Assert.That(conversation.Segments[0].CreatedAt, Is.EqualTo(DateTimeOffset.Parse("2025-06-15T09:00:00Z")));
        });
    }

    [Test]
    public void DiscordSnapshotPreservesSourceLinksIdentityContextAndAttachmentOnlyMessages()
    {
        var result = new LifenizerBackupParser().Parse(new ImportRequest(Text: """
            {"participants":[{"id":"author-id","displayName":"Author","identifiers":["discord:111","email:author@example.test"],"aliases":["Former author"]}],
             "conversations":[{"title":"Example thread","source":"discord","sourceThreadId":"discord:333",
               "sourceUrl":"https://discord.com/channels/555/333","metadata":{"messageScope":"own-sent-messages","channelType":"PUBLIC_THREAD"},
               "participantIds":["author-id"],"segments":[{"text":"","sourceMessageId":"discord:999","participantId":"author-id",
                 "attachmentUrls":["https://example.test/attachment"],"createdAt":"2025-06-15T09:00:00Z"}]}]}
            """));
        var conversation = result.Conversations.Single();
        Assert.Multiple(() =>
        {
            Assert.That(conversation.SourceThreadId, Is.EqualTo("discord:333"));
            Assert.That(conversation.SourceUrl, Is.EqualTo("https://discord.com/channels/555/333"));
            Assert.That(conversation.Metadata!["messageScope"], Is.EqualTo("own-sent-messages"));
            Assert.That(conversation.ParticipantIdentifiers, Is.EqualTo(new[] { "discord:111" }));
            Assert.That(conversation.Segments.Single().SourceMessageId, Is.EqualTo("discord:999"));
            Assert.That(conversation.Segments.Single().ParticipantIdentifier, Is.EqualTo("discord:111"));
            Assert.That(conversation.Segments.Single().AttachmentUrls, Is.EqualTo(new[] { "https://example.test/attachment" }));
            Assert.That(result.Participants.Single().Identifiers, Is.EqualTo(new[] { "discord:111", "email:author@example.test" }));
            Assert.That(result.Participants.Single().Aliases, Is.EqualTo(new[] { "Former author" }));
        });
    }

    [Test]
    public void EmptyBackupDoesNotImportItsRawJsonAsConversationText()
    {
        var result = new LifenizerBackupParser().Parse(new ImportRequest(Text: "{\"conversations\":[]}"));
        Assert.That(result.Conversations, Is.Empty);
    }

    [Test]
    public void TelegramZipUsesItsJsonExport()
    {
        using var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            using var writer = new StreamWriter(archive.CreateEntry("result.json").Open(), Encoding.UTF8);
            writer.Write("{\"name\":\"Atlas\",\"messages\":[{\"from\":\"Alice\",\"text\":\"Atlas deadline\"}]}");
        }
        var result = new TelegramParser().Parse(new ImportRequest(Title: "Custom chat title", OriginalFileName: "telegram.zip", PayloadBase64: Convert.ToBase64String(stream.ToArray())));
        Assert.That(result.Conversations.Single().Segments.Single().Text, Is.EqualTo("Atlas deadline"));
        Assert.That(result.Conversations.Single().Title, Is.EqualTo("Custom chat title"));
    }
}
