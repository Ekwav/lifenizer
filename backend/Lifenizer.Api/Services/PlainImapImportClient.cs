using System.Globalization;
using System.Net;
using System.Net.Sockets;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;
using MailKit;
using MailKit.Net.Imap;
using MailKit.Search;
using MailKit.Security;
using MimeKit;

namespace Lifenizer.Api.Services;

// The public service name is retained for compatibility; MailKit owns IMAP and TLS.
public sealed class PlainImapImportClient(IConfiguration configuration)
{
    private const long MaxPageBytes = 25 * 1024 * 1024;
    public object Settings()
    {
        var (host, port, tls) = ConnectionSettings();
        return new { configured = !string.IsNullOrWhiteSpace(host), host, port, tls = tls.ToString(), useTls = tls != SecureSocketOptions.None };
    }

    public async Task<NormalizedImportResponse> ImportAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        if (new[] { "host", "port", "useTls", "socketOptions", "allowInvalidCertificate" }.Any(key => request.Metadata?.ContainsKey(key) == true))
            throw new InvalidOperationException("The IMAP endpoint and TLS settings must be configured on the server.");
        var (host, port, tls) = ConnectionSettings();
        if (string.IsNullOrWhiteSpace(host)) throw new InvalidOperationException("The IMAP host is not configured.");
        var username = Required(request, "username");
        var password = Required(request, "password");
        var mailbox = CommonParsing.Metadata(request, "mailbox") ?? "INBOX";
        if (new[] { username, password, mailbox }.Any(value => value.Contains('\r') || value.Contains('\n')))
            throw new InvalidOperationException("IMAP credentials and mailbox must not contain newlines.");
        var limit = int.TryParse(CommonParsing.Metadata(request, "limit"), out var parsedLimit) ? Math.Clamp(parsedLimit, 1, 25) : 10;
        var afterUid = Cursor(request, "afterUid");
        var previousValidity = Cursor(request, "uidValidity");
        if (afterUid > 0 && previousValidity == 0) throw new InvalidOperationException("uidValidity is required when resuming afterUid.");
        var messages = new List<(MimeMessage Message, Dictionary<string, string>? Metadata)>();
        using var client = new ImapClient { Timeout = 30_000 };
        try
        {
            await client.ConnectAsync(host, port, tls, cancellationToken);
            await client.AuthenticateAsync(username, password, cancellationToken);
            var folder = mailbox.Equals("INBOX", StringComparison.OrdinalIgnoreCase) ? client.Inbox : await client.GetFolderAsync(mailbox, cancellationToken);
            await folder.OpenAsync(FolderAccess.ReadOnly, cancellationToken);
            var reset = previousValidity != 0 && previousValidity != folder.UidValidity;
            if (reset) afterUid = 0;
            IList<UniqueId> found = afterUid == uint.MaxValue ? [] : await folder.SearchAsync(
                SearchQuery.Uids(new UniqueIdRange(new UniqueId(afterUid + 1), UniqueId.MaxValue)), cancellationToken);
            var selected = found.Where(uid => uid.Id > afterUid).OrderBy(uid => uid.Id).Take(limit).ToArray();
            if (selected.Length > 0)
            {
                var sizes = await folder.FetchAsync(selected, MessageSummaryItems.UniqueId | MessageSummaryItems.Size, cancellationToken);
                if (sizes.Sum(message => (long)(message.Size ?? 0)) > MaxPageBytes)
                    throw new InvalidOperationException("This IMAP page exceeds the 25 MiB download limit. Reduce the page size (limit); a single oversized email must be exported separately.");
            }
            var downloaded = 0L;
            var nextUid = afterUid;
            foreach (var uid in selected)
            {
                try
                {
                    var progress = new BoundedProgress(MaxPageBytes - downloaded);
                    var message = await folder.GetMessageAsync(uid, cancellationToken, progress);
                    downloaded += progress.Bytes;
                    messages.Add((message, new Dictionary<string, string>
                    {
                        ["imap-uid"] = uid.Id.ToString(CultureInfo.InvariantCulture),
                        ["imap-uid-validity"] = folder.UidValidity.ToString(CultureInfo.InvariantCulture),
                        ["imap-message-id"] = $"imap:{host}/{username}/{folder.FullName}/{folder.UidValidity}/{uid.Id}"
                    }));
                }
                catch (MessageNotFoundException) { /* An expunge between SEARCH and FETCH is safe to skip. */ }
                nextUid = uid.Id;
            }
            var diagnostics = new Dictionary<string, string>
            {
                ["host"] = host, ["mailbox"] = folder.FullName,
                ["uidValidity"] = folder.UidValidity.ToString(CultureInfo.InvariantCulture),
                ["nextUid"] = nextUid.ToString(CultureInfo.InvariantCulture),
                ["hasMore"] = found.Any(uid => uid.Id > nextUid) ? "true" : "false",
                ["cursorReset"] = reset ? "true" : "false"
            };
            var result = EmailNormalization.Response("email", request, messages, diagnostics);
            await client.DisconnectAsync(true, cancellationToken);
            return result;
        }
        catch (Exception exception) when (exception is MailKit.Security.AuthenticationException or CommandException or ProtocolException or IOException or SocketException or NotSupportedException or SslHandshakeException)
        {
            throw new InvalidOperationException("IMAP connection, TLS, authentication, or mailbox access failed. Check the configured server and account credentials.");
        }
        finally { foreach (var (message, _) in messages) message.Dispose(); }
    }

    private sealed class BoundedProgress(long limit) : ITransferProgress
    {
        public long Bytes { get; private set; }
        public void Report(long bytesTransferred, long totalSize) => Report(bytesTransferred);
        public void Report(long bytesTransferred)
        {
            Bytes = bytesTransferred;
            if (bytesTransferred > limit) throw new InvalidOperationException("This IMAP page exceeds the 25 MiB download limit. Reduce the page size or export the oversized email separately.");
        }
    }

    private (string Host, int Port, SecureSocketOptions Tls) ConnectionSettings()
    {
        var host = configuration["Imports:Imap:Host"] ?? "";
        var port = configuration.GetValue("Imports:Imap:Port", 993);
        if (port is < 1 or > 65535) throw new InvalidOperationException("The configured IMAP port is invalid.");
        var tls = configuration.GetValue("Imports:Imap:UseTls", true)
            ? port == 143 ? SecureSocketOptions.StartTls : SecureSocketOptions.SslOnConnect
            : SecureSocketOptions.None;
        if (configuration["Imports:Imap:SocketOptions"] is { Length: > 0 } option &&
            (!Enum.TryParse(option, true, out tls) || tls is not (SecureSocketOptions.None or SecureSocketOptions.StartTls or SecureSocketOptions.SslOnConnect)))
            throw new InvalidOperationException("IMAP SocketOptions must require TLS (SslOnConnect or StartTls).");
        if (tls == SecureSocketOptions.None && !(host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || IPAddress.TryParse(host, out var address) && IPAddress.IsLoopback(address)))
            throw new InvalidOperationException("Plaintext IMAP is allowed only for loopback test servers.");
        return (host, port, tls);
    }

    private static string Required(ImportRequest request, string key) => CommonParsing.Metadata(request, key)
        ?? throw new InvalidOperationException($"IMAP {key} is required.");
    private static uint Cursor(ImportRequest request, string key)
    {
        var value = CommonParsing.Metadata(request, key);
        if (value is null) return 0;
        return uint.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var cursor)
            ? cursor : throw new InvalidOperationException($"IMAP {key} must be an unsigned integer.");
    }
}
