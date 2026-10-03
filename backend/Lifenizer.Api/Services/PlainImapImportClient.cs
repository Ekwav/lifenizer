using System.Net.Mail;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

public sealed partial class PlainImapImportClient(IConfiguration configuration)
{
    public async Task<NormalizedImportResponse> ImportAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        if (new[] { "host", "port", "useTls", "allowInvalidCertificate" }.Any(key => ImportTextParsers.Metadata(request, key) is not null))
            throw new InvalidOperationException("IMAP endpoint and TLS settings are configuration-only; set Imports:Imap on the server.");
        var host = configuration["Imports:Imap:Host"];
        if (string.IsNullOrWhiteSpace(host)) throw new InvalidOperationException("Email import requires configuration Imports:Imap:Host.");
        var port = configuration.GetValue("Imports:Imap:Port", 993);
        var username = Required(request, "username");
        var password = Required(request, "password");
        var mailbox = ImportTextParsers.Metadata(request, "mailbox") ?? "INBOX";
        var useTls = configuration.GetValue("Imports:Imap:UseTls", true);
        var limit = int.TryParse(ImportTextParsers.Metadata(request, "limit"), out var parsedLimit) ? Math.Clamp(parsedLimit, 1, 25) : 10;

        using var tcp = new TcpClient();
        await tcp.ConnectAsync(host, port, cancellationToken);
        await using var networkStream = tcp.GetStream();
        Stream stream = networkStream;
        if (useTls)
        {
            var ssl = new SslStream(networkStream, leaveInnerStreamOpen: false, (_, _, _, errors) => errors == SslPolicyErrors.None);
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = host }, cancellationToken);
            stream = ssl;
        }

        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 8192, leaveOpen: true);
        await using var writer = new StreamWriter(stream, Encoding.UTF8, bufferSize: 8192, leaveOpen: true) { NewLine = "\r\n", AutoFlush = true };

        await reader.ReadLineAsync(cancellationToken);
        await SendAsync(writer, reader, "A001", $"LOGIN {Quote(username)} {Quote(password)}", cancellationToken);
        await SendAsync(writer, reader, "A002", $"SELECT {Quote(mailbox)}", cancellationToken);
        var searchResponse = await SendAsync(writer, reader, "A003", "SEARCH ALL", cancellationToken);
        var messageIds = SearchIds(searchResponse).Take(limit).ToArray();

        var conversations = new List<NormalizedConversation>();
        foreach (var messageId in messageIds)
        {
            var fetchResponse = await SendAsync(writer, reader, NextTag(), $"FETCH {messageId} BODY.PEEK[]", cancellationToken);
            var rawMessage = ExtractLiteral(fetchResponse);
            if (rawMessage is null) continue;
            conversations.Add(ParseMessage(rawMessage, request));
        }

        await SendAsync(writer, reader, NextTag(), "LOGOUT", cancellationToken);

        return ImportTextParsers.Response(
            "email",
            $"Fetched and normalized {conversations.Count} email message(s) from {mailbox}.",
            conversations,
            new Dictionary<string, string> { ["host"] = host, ["mailbox"] = mailbox });
    }

    private static NormalizedConversation ParseMessage(string rawMessage, ImportRequest request)
    {
        var split = HeaderBodySeparatorRegex().Split(rawMessage, 2);
        var headers = ParseHeaders(split[0]);
        var body = split.Length > 1 ? DecodeBody(split[1]) : string.Empty;
        var subject = Header(headers, "Subject") ?? ImportTextParsers.Metadata(request, "defaultTitle") ?? "Email message";
        var from = Header(headers, "From") ?? "Unknown sender";
        var to = Header(headers, "To");
        var cc = Header(headers, "Cc");
        var participants = ImportTextParsers.ParticipantNames(request).ToList();
        foreach (var name in EmailNames(from).Concat(EmailNames(to)).Concat(EmailNames(cc)))
        {
            if (!participants.Contains(name, StringComparer.OrdinalIgnoreCase)) participants.Add(name);
        }

        var metadata = new Dictionary<string, string>();
        foreach (var key in new[] { "Message-Id", "Date", "From", "To", "Cc" })
        {
            if (Header(headers, key) is { } value) metadata[key.ToLowerInvariant()] = value;
        }

        var sender = EmailNames(from).FirstOrDefault() ?? from;
        return new NormalizedConversation(
            subject,
            "email",
            participants,
            [new NormalizedSegment(body.Trim(), sender, 0, DateTimeOffset.TryParse(Header(headers, "Date"), out var date) ? date : DateTimeOffset.UtcNow)],
            [],
            metadata);
    }

    private static Dictionary<string, string> ParseHeaders(string headerText)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? currentKey = null;
        foreach (var rawLine in headerText.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if ((line.StartsWith(' ') || line.StartsWith('\t')) && currentKey is not null)
            {
                headers[currentKey] += " " + line.Trim();
                continue;
            }

            var index = line.IndexOf(':');
            if (index <= 0) continue;
            currentKey = line[..index];
            headers[currentKey] = line[(index + 1)..].Trim();
        }
        return headers;
    }

    private static IEnumerable<string> EmailNames(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) yield break;
        foreach (var part in value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            MailAddress? parsed = null;
            try
            {
                parsed = new MailAddress(part);
            }
            catch (FormatException)
            {
                // Some exports contain bare names rather than RFC addresses.
            }

            var name = parsed?.DisplayName;
            if (string.IsNullOrWhiteSpace(name)) name = parsed?.Address ?? part;
            if (!string.IsNullOrWhiteSpace(name)) yield return name.Trim('"', ' ');
        }
    }

    private static string DecodeBody(string value)
    {
        return value
            .Replace("=\r\n", string.Empty, StringComparison.Ordinal)
            .Replace("=\n", string.Empty, StringComparison.Ordinal)
            .Replace("=20", " ", StringComparison.Ordinal)
            .Trim();
    }

    private static async Task<string> SendAsync(StreamWriter writer, StreamReader reader, string tag, string command, CancellationToken cancellationToken)
    {
        await writer.WriteLineAsync($"{tag} {command}".AsMemory(), cancellationToken);
        var builder = new StringBuilder();
        while (true)
        {
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) break;
            builder.AppendLine(line);
            if (line.StartsWith(tag + " ", StringComparison.OrdinalIgnoreCase)) break;
        }

        var response = builder.ToString();
        if (!response.Contains($"{tag} OK", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"IMAP {command.Split(' ')[0]} command failed.");
        }
        return response;
    }

    private static IEnumerable<string> SearchIds(string response)
    {
        foreach (Match match in SearchLineRegex().Matches(response))
        {
            foreach (var id in match.Groups["ids"].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                yield return id;
            }
        }
    }

    private static string? ExtractLiteral(string response)
    {
        var match = LiteralRegex().Match(response);
        return match.Success ? match.Groups["body"].Value.TrimEnd('\r', '\n') : null;
    }

    private static string? Header(Dictionary<string, string> headers, string key)
    {
        return headers.TryGetValue(key, out var value) ? value : null;
    }

    private static string Required(ImportRequest request, string key)
    {
        return ImportTextParsers.Metadata(request, key)
            ?? throw new InvalidOperationException($"Email import requires metadata.{key}.");
    }

    private static string Quote(string value)
    {
        if (value.Contains('\r') || value.Contains('\n')) throw new InvalidOperationException("IMAP values cannot contain line breaks.");
        return '"' + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + '"';
    }

    private static int tagCounter = 4;

    private static string NextTag() => $"A{Interlocked.Increment(ref tagCounter):000}";

    [GeneratedRegex(@"\r?\n\r?\n")]
    private static partial Regex HeaderBodySeparatorRegex();

    [GeneratedRegex(@"\* SEARCH (?<ids>[0-9 ]*)", RegexOptions.IgnoreCase)]
    private static partial Regex SearchLineRegex();

    [GeneratedRegex(@"\{\d+\}\r?\n(?<body>.*?)\r?\n\)\r?\nA\d+ OK", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex LiteralRegex();
}
