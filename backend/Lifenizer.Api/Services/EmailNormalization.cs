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
            var text = message.TextBody ?? (message.HtmlBody is { } html ? CommonParsing.StripHtml(html) : "");
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
            foreach (var attachment in message.Attachments.OfType<MimePart>())
            {
                var name = attachment.FileName ?? attachment.ContentType.Name ?? "attachment.pdf";
                if (!attachment.ContentType.IsMimeType("application", "pdf") && !name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) continue;
                using var decoded = new BoundedAttachmentStream();
                if (attachment.Content is null) throw new InvalidOperationException("Email PDF attachment has no content.");
                attachment.Content.DecodeTo(decoded);
                var attachmentText = PdfTextExtractor.Extract(decoded.ToArray());
                segments.Add(new NormalizedSegment($"PDF attachment: {name}\n{attachmentText}", sender is null ? null : Name(sender), 0,
                    message.Date == DateTimeOffset.MinValue ? null : message.Date, sender is null ? null : Identifier(sender),
                    messageId is null ? null : $"{messageId}:pdf:{pdfIndex}"));
                pdfIndex++;
            }
            if (pdfIndex > 0) metadata["indexed-pdf-attachments"] = pdfIndex.ToString();
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
            if (Length + count > PdfTextExtractor.MaxBytes) throw new InvalidOperationException("Email PDF attachment exceeds 25 MiB.");
            base.Write(buffer, offset, count);
        }
        public override void Write(ReadOnlySpan<byte> buffer)
        {
            if (Length + buffer.Length > PdfTextExtractor.MaxBytes) throw new InvalidOperationException("Email PDF attachment exceeds 25 MiB.");
            base.Write(buffer);
        }
    }
}
