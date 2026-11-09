using System.Diagnostics;
using System.Security.Cryptography;
using System.Xml;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;
using MimeKit;

namespace Lifenizer.Api.Services;

public static class EmailNormalization
{
    private static string Identifier(MailboxAddress address) => "email:" + address.Address.Trim().ToLowerInvariant();
    private static string Name(MailboxAddress address) => string.IsNullOrWhiteSpace(address.Name) ? address.Address : address.Name;

    public static NormalizedImportResponse Response(string source, ImportRequest request,
        IEnumerable<(MimeMessage Message, Dictionary<string, string>? Metadata)> messages,
        IReadOnlyDictionary<string, string>? diagnostics = null)
    {
        var participants = new Dictionary<string, NormalizedParticipant>(StringComparer.Ordinal);
        var conversations = new List<NormalizedConversation>();
        var budget = Stopwatch.StartNew();
        var attempts = 0;
        var indexedChars = 0;
        foreach (var (message, extraMetadata) in messages)
        {
            var addresses = message.From.Mailboxes.Concat(message.To.Mailboxes).Concat(message.Cc.Mailboxes).Concat(message.Bcc.Mailboxes);
            if (message.Sender is not null) addresses = addresses.Append(message.Sender);
            var identities = addresses.DistinctBy(Identifier).ToArray();
            foreach (var address in identities)
            {
                var id = Identifier(address);
                if (!participants.TryGetValue(id, out var old) || old.DisplayName.Equals(address.Address, StringComparison.OrdinalIgnoreCase))
                    participants[id] = new NormalizedParticipant(Name(address), [id]);
            }

            var sender = message.From.Mailboxes.FirstOrDefault() ?? message.Sender;
            var text = !string.IsNullOrWhiteSpace(message.TextBody) ? message.TextBody : (message.HtmlBody is { } html ? CommonParsing.StripHtml(html) : "");
            var metadata = extraMetadata ?? new Dictionary<string, string>();
            foreach (var header in message.Headers.Where(header => header.Id is HeaderId.MessageId or HeaderId.InReplyTo or HeaderId.References or HeaderId.Date or HeaderId.From or HeaderId.To or HeaderId.Cc))
                metadata[header.Field.ToLowerInvariant()] = header.Value;
            var messageId = message.MessageId ?? metadata.GetValueOrDefault("imap-message-id");
            var threadId = message.References.FirstOrDefault() ?? message.InReplyTo ?? messageId;
            var attachments = message.Attachments.Select(part => part.ContentDisposition?.FileName ?? part.ContentType.Name)
                .Where(name => !string.IsNullOrWhiteSpace(name)).Cast<string>().ToArray();
            var segments = new List<NormalizedSegment> { new(text.Trim(), sender is null ? null : Name(sender), 0,
                message.Date == DateTimeOffset.MinValue ? null : message.Date, sender is null ? null : Identifier(sender), messageId) };
            var pdfIndex = 0;
            var indexedPdfs = 0;
            var attachmentIndex = 0;
            foreach (var attachment in message.Attachments)
            {
                var index = attachmentIndex++;
                var key = $"attachment-{index}-indexing";
                var name = attachment.ContentDisposition?.FileName ?? attachment.ContentType.Name ?? "attachment";
                var kind = BoundedAttachmentText.Kind(name, attachment.ContentType.MimeType);
                var pdfId = kind == "pdf" ? pdfIndex++ : -1;
                if (kind is null || attachment is not MimePart part)
                {
                    metadata[key] = "skipped: unsupported attachment type";
                    continue;
                }
                if (attempts >= 32 || indexedChars >= 8 * 1024 * 1024 || budget.Elapsed >= TimeSpan.FromMinutes(2))
                {
                    metadata[key] = "skipped: email attachment indexing budget exceeded";
                    continue;
                }
                attempts++;
                try
                {
                    using var decoded = new BoundedAttachmentStream();
                    if (part.Content is null) throw new InvalidDataException("Attachment has no content.");
                    part.Content.DecodeTo(decoded);
                    var bytes = decoded.ToArray();
                    var remaining = TimeSpan.FromMinutes(2) - budget.Elapsed;
                    if (remaining <= TimeSpan.Zero) throw new InvalidDataException("Email attachment indexing time budget exceeded.");
                    var attachmentText = BoundedAttachmentText.Extract(bytes, kind, part.ContentType.Charset, remaining);
                    if (attachmentText.Length > 8 * 1024 * 1024 - indexedChars)
                        throw new InvalidDataException("Email attachment text exceeds the response indexing budget.");
                    indexedChars += attachmentText.Length;
                    var sourceId = messageId ?? "attachment-sha256:" + Convert.ToHexString(SHA256.HashData(bytes));
                    segments.Add(new NormalizedSegment($"{(kind == "pdf" ? "PDF attachment" : "Attachment")}: {name}\n{attachmentText}", sender is null ? null : Name(sender), 0,
                        message.Date == DateTimeOffset.MinValue ? null : message.Date, sender is null ? null : Identifier(sender),
                        kind == "pdf" ? $"{sourceId}:pdf:{pdfId}" : $"{sourceId}:attachment:{index}"));
                    metadata[key] = "indexed";
                    if (kind == "pdf") indexedPdfs++;
                }
                catch (Exception exception) when (exception is InvalidDataException or IOException or InvalidOperationException or ArgumentException or XmlException or NotSupportedException or FormatException)
                {
                    metadata[key] = "failed: " + exception.Message;
                }
            }
            if (indexedPdfs > 0) metadata["indexed-pdf-attachments"] = indexedPdfs.ToString();
            conversations.Add(new NormalizedConversation(
                message.Subject ?? request.Title ?? "Email message", source,
                CommonParsing.ParticipantNames(request).Concat(identities.Select(Name)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
                segments,
                attachments, metadata, identities.Select(Identifier).ToArray(), threadId));
        }

        var extras = CommonParsing.ParticipantNames(request)
            .Where(name => !participants.Values.Any(participant => participant.DisplayName.Equals(name, StringComparison.OrdinalIgnoreCase)))
            .Select(name => new NormalizedParticipant(name));
        return new NormalizedImportResponse(source, true, $"Normalized {conversations.Count} email message(s).",
            conversations, participants.Values.Concat(extras).ToArray(), diagnostics);
    }
    private sealed class BoundedAttachmentStream : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count)
        {
            if (Length + count > BoundedImportArchive.MaxBytes) throw new InvalidOperationException("Email attachment exceeds 25 MiB.");
            base.Write(buffer, offset, count);
        }
        public override void Write(ReadOnlySpan<byte> buffer)
        {
            if (Length + buffer.Length > BoundedImportArchive.MaxBytes) throw new InvalidOperationException("Email attachment exceeds 25 MiB.");
            base.Write(buffer);
        }
    }
}
