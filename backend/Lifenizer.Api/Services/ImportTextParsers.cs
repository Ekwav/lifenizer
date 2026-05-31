using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

public static partial class ImportTextParsers
{
    public static NormalizedImportResponse NormalizeLocal(string source, ImportRequest request)
    {
        var normalizedSource = source.ToLowerInvariant();
        return source.ToLowerInvariant() switch
        {
            "manual-text" => SingleConversation(source, request, EffectiveText(request), "Manual text import"),
            "scanned-pdf" => SingleConversation(source, request, EffectiveText(request, Metadata(request, "ocrText") ?? string.Empty), "OCR text import"),
            "live-recording" => SingleConversation(source, request, EffectiveText(request), "Recording transcript import"),
            "whatsapp" => ParseChatLines(source, request, WhatsAppLineRegex()),
            "signal" => ParseSignal(source, request),
            "telegram" => ParseTelegram(request),
            "discord" => ParseDiscord(request, source),
            "slack" => ParseSlack(request),
            "teams" => ParseTeams(request),
            "facebook-messenger" => ParseFacebookMessenger(request),
            "instagram" => ParseInstagram(request),
            "imessage" => ParseIMessage(request),
            "mbox" => ParseMbox(request),
            "git" => ParseGit(request),
            "browser-capture" => ParseBrowserCapture(request),
            "google-search-history" => ParseGoogleSearchHistory(request),
            "bookmarks" => ParseBookmarks(request),
            "lifenizer-backup" => ParseLifenizerBackup(request),
            "browser-history" => ParseBrowserHistory(request),
            "youtube-transcript" => ParseTranscript(source, request, EffectiveText(request), "YouTube transcript"),
            _ => SingleConversation(normalizedSource, request, EffectiveText(request), "Imported data")
        };
    }

    public static NormalizedImportResponse SingleConversation(
        string source,
        ImportRequest request,
        string text,
        string fallbackTitle,
        IReadOnlyList<string>? artifactNames = null,
        IReadOnlyDictionary<string, string>? metadata = null)
    {
        var participants = ParticipantNames(request).ToArray();
        var title = Clean(request.Title) ?? Clean(request.OriginalFileName) ?? fallbackTitle;
        var body = Clean(text) ?? $"Imported {source} item without textual body.";
        var segment = new NormalizedSegment(body, participants.FirstOrDefault(), 0, DateTimeOffset.UtcNow);
        var conversation = new NormalizedConversation(
            title,
            source,
            participants,
            [segment],
            artifactNames ?? ArtifactNames(request),
            metadata);
        return Response(source, $"Normalized 1 {source} conversation.", [conversation]);
    }

    public static NormalizedImportResponse ParseTranscript(string source, ImportRequest request, string text, string fallbackTitle)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            return ParseTranscriptJson(source, request, trimmed, fallbackTitle);
        }

        if (trimmed.StartsWith('<'))
        {
            return ParseTranscriptXml(source, request, trimmed, fallbackTitle);
        }

        return SingleConversation(source, request, text, fallbackTitle);
    }

    public static NormalizedImportResponse ParseDiscordMessages(string source, ImportRequest request, string json)
    {
        return ParseDiscord(request with { Text = json }, source);
    }

    public static IReadOnlyList<string> ParticipantNames(ImportRequest request)
    {
        var names = new List<string>();
        if (request.ParticipantNames is not null)
        {
            names.AddRange(request.ParticipantNames);
        }

        if (request.Metadata is not null && request.Metadata.TryGetValue("participants", out var metadataNames))
        {
            names.AddRange(metadataNames.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));
        }

        return names
            .Select(name => name.Trim())
            .Where(name => name.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static NormalizedImportResponse Response(string source, string message, IReadOnlyList<NormalizedConversation> conversations, IReadOnlyDictionary<string, string>? diagnostics = null)
    {
        var participants = conversations
            .SelectMany(conversation => conversation.ParticipantNames)
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(name => new NormalizedParticipant(name))
            .ToArray();

        return new NormalizedImportResponse(
            source,
            true,
            message,
            conversations,
            participants,
            diagnostics);
    }

    public static string? Metadata(ImportRequest request, string key)
    {
        if (request.Metadata is null) return null;
        return request.Metadata.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value : null;
    }

    private static NormalizedImportResponse ParseChatLines(string source, ImportRequest request, Regex lineRegex)
    {
        var title = Clean(request.Title) ?? $"{CultureInfo.InvariantCulture.TextInfo.ToTitleCase(source)} export";
        var conversations = new List<NormalizedSegment>();
        var participants = ParticipantNames(request).ToList();
        NormalizedSegment? current = null;
        var text = EffectiveText(request);

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;

            var match = lineRegex.Match(line);
            if (match.Success)
            {
                if (current is not null) conversations.Add(current);
                var speaker = match.Groups["speaker"].Value.Trim();
                if (speaker.Length > 0 && !participants.Contains(speaker, StringComparer.OrdinalIgnoreCase))
                {
                    participants.Add(speaker);
                }

                var messageText = match.Groups["text"].Value.Trim();
                current = new NormalizedSegment(messageText, speaker, conversations.Count * 1000, TryParseDate(match.Groups["date"].Value));
                continue;
            }

            if (current is null)
            {
                current = new NormalizedSegment(line, participants.FirstOrDefault(), conversations.Count * 1000, DateTimeOffset.UtcNow);
            }
            else
            {
                current = current with { Text = current.Text + "\n" + line };
            }
        }

        if (current is not null) conversations.Add(current);
        if (conversations.Count == 0)
        {
            return SingleConversation(source, request, text, title);
        }

        var conversation = new NormalizedConversation(title, source, participants, conversations);
        return Response(source, $"Normalized {conversations.Count} {source} message(s).", [conversation]);
    }

    private static NormalizedImportResponse ParseSignal(string source, ImportRequest request)
    {
        var text = EffectiveText(request);
        if (text.Contains(',') && text.Split('\n').FirstOrDefault()?.Contains("message", StringComparison.OrdinalIgnoreCase) == true)
        {
            var rows = ParseCsv(text).ToArray();
            var participants = ParticipantNames(request).ToList();
            var segments = new List<NormalizedSegment>();
            foreach (var row in rows)
            {
                var sender = FirstValue(row, "sender", "from", "author", "name") ?? "Unknown";
                var message = FirstValue(row, "message", "body", "text", "content") ?? string.Empty;
                if (message.Length == 0) continue;
                if (!participants.Contains(sender, StringComparer.OrdinalIgnoreCase)) participants.Add(sender);
                segments.Add(new NormalizedSegment(message, sender, segments.Count * 1000, TryParseDate(FirstValue(row, "timestamp", "date", "time"))));
            }

            if (segments.Count > 0)
            {
                return Response(source, $"Normalized {segments.Count} Signal message(s).", [new NormalizedConversation(Clean(request.Title) ?? "Signal export", source, participants, segments)]);
            }
        }

        return ParseChatLines(source, request, SimpleSpeakerLineRegex());
    }

    private static NormalizedImportResponse ParseTelegram(ImportRequest request)
    {
        var text = EffectiveText(request);
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines("telegram", request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var messages = root.ValueKind == JsonValueKind.Array
            ? root.EnumerateArray()
            : root.TryGetProperty("messages", out var array) && array.ValueKind == JsonValueKind.Array
                ? array.EnumerateArray()
                : Enumerable.Empty<JsonElement>();

        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = TelegramText(message);
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = JsonString(message, "from") ?? JsonString(message, "actor") ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);
            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, TryParseDate(JsonString(message, "date"))));
        }

        var title = Clean(request.Title) ?? JsonString(root, "name") ?? "Telegram export";
        return Response("telegram", $"Normalized {segments.Count} Telegram message(s).", [new NormalizedConversation(title, "telegram", participants, segments)]);
    }

    private static NormalizedImportResponse ParseDiscord(ImportRequest request, string source)
    {
        var text = EffectiveText(request);
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines(source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = EnumerateArray(doc.RootElement, "messages");
        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonString(message, "content") ?? JsonString(message, "message") ?? JsonString(message, "text") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = AuthorName(message) ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);
            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, TryParseDate(JsonString(message, "timestamp") ?? JsonString(message, "date"))));
        }

        var title = Clean(request.Title) ?? JsonString(doc.RootElement, "channelName") ?? "Discord export";
        return Response(source, $"Normalized {segments.Count} Discord message(s).", [new NormalizedConversation(title, source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseSlack(ImportRequest request)
    {
        var source = "slack";
        var text = EffectiveText(request);
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines(source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = EnumerateArray(doc.RootElement, "messages", "items");
        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonString(message, "text") ?? JsonString(message, "content") ?? JsonString(message, "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;
            var speaker = AuthorName(message)
                ?? (message.TryGetProperty("user_profile", out var profile)
                    ? JsonString(profile, "display_name") ?? JsonString(profile, "real_name")
                    : null)
                ?? JsonString(message, "user")
                ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);

            var createdAt = TryParseDate(JsonString(message, "timestamp") ?? JsonString(message, "date"))
                ?? ParseUnixEpoch(JsonString(message, "ts"));

            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, createdAt));
        }

        var title = Clean(request.Title) ?? Metadata(request, "channel") ?? Clean(request.OriginalFileName) ?? "Slack export";
        return Response(source, $"Normalized {segments.Count} Slack message(s).", [new NormalizedConversation(title, source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseTeams(ImportRequest request)
    {
        var source = "teams";
        var text = EffectiveText(request);
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines(source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var messages = EnumerateArray(doc.RootElement, "messages", "value", "conversations", "items");
        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var rawContent = JsonString(message, "content")
                ?? JsonString(message, "body")
                ?? JsonString(message, "text")
                ?? string.Empty;
            var content = StripHtml(rawContent).Trim();
            if (content.Length == 0) continue;

            var speaker = JsonString(message, "fromDisplayName")
                ?? JsonString(message, "sender")
                ?? (message.TryGetProperty("from", out var from)
                    ? JsonString(from, "displayName") ?? JsonString(from, "name")
                    : null)
                ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);

            var createdAt = TryParseDate(
                JsonString(message, "createdDateTime")
                ?? JsonString(message, "timestamp")
                ?? JsonString(message, "time")
                ?? JsonString(message, "date"));

            segments.Add(new NormalizedSegment(content, speaker, segments.Count * 1000, createdAt));
        }

        var title = Clean(request.Title) ?? Metadata(request, "thread") ?? Clean(request.OriginalFileName) ?? "Teams export";
        return Response(source, $"Normalized {segments.Count} Teams message(s).", [new NormalizedConversation(title, source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseBrowserHistory(ImportRequest request)
    {
        var text = EffectiveText(request);
        var segments = new List<NormalizedSegment>();
        if (text.TrimStart().StartsWith('[') || text.TrimStart().StartsWith('{'))
        {
            using var doc = JsonDocument.Parse(text);
            foreach (var item in EnumerateArray(doc.RootElement, "history", "visits", "items"))
            {
                var title = JsonString(item, "title") ?? JsonString(item, "name") ?? "Visited page";
                var url = JsonString(item, "url") ?? JsonString(item, "href") ?? string.Empty;
                if (url.Length == 0 && title == "Visited page") continue;
                segments.Add(new NormalizedSegment($"Visited {title}: {url}".Trim(), null, segments.Count * 1000, TryParseDate(JsonString(item, "time") ?? JsonString(item, "lastVisitTime") ?? JsonString(item, "date"))));
            }
        }
        else
        {
            foreach (var row in ParseCsv(text))
            {
                var title = FirstValue(row, "title", "name") ?? "Visited page";
                var url = FirstValue(row, "url", "href") ?? string.Empty;
                if (url.Length == 0 && title == "Visited page") continue;
                segments.Add(new NormalizedSegment($"Visited {title}: {url}".Trim(), null, segments.Count * 1000, TryParseDate(FirstValue(row, "time", "lastVisitTime", "date"))));
            }
        }

        if (segments.Count == 0) return SingleConversation("browser-history", request, text, "Browser history");
        return Response("browser-history", $"Normalized {segments.Count} browser history visit(s).", [new NormalizedConversation(Clean(request.Title) ?? "Browser history", "browser-history", ParticipantNames(request), segments)]);
    }

    private static NormalizedImportResponse ParseFacebookMessenger(ImportRequest request)
    {
        var source = "facebook-messenger";
        var text = EffectiveText(request);
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines(source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var messages = EnumerateArray(root, "messages", "items");
        var participants = ParticipantNames(request).ToList();
        foreach (var participant in EnumerateArray(root, "participants"))
        {
            var name = JsonString(participant, "name");
            if (!string.IsNullOrWhiteSpace(name) && !participants.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                participants.Add(name);
            }
        }

        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonString(message, "content") ?? JsonString(message, "text") ?? JsonString(message, "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;

            var speaker = JsonString(message, "sender_name") ?? JsonString(message, "sender") ?? AuthorName(message) ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);

            var createdAt = ParseUnixEpochMilliseconds(JsonString(message, "timestamp_ms"))
                ?? ParseUnixEpoch(JsonString(message, "timestamp"))
                ?? TryParseDate(JsonString(message, "date"));

            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, createdAt));
        }

        var title = Clean(request.Title) ?? JsonString(root, "title") ?? Metadata(request, "thread") ?? "Messenger export";
        return Response(source, $"Normalized {segments.Count} Messenger message(s).", [new NormalizedConversation(title, source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseInstagram(ImportRequest request)
    {
        var source = "instagram";
        var text = EffectiveText(request);
        if (!text.TrimStart().StartsWith('{') && !text.TrimStart().StartsWith('['))
        {
            return ParseChatLines(source, request, SimpleSpeakerLineRegex());
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var messages = EnumerateArray(root, "messages", "conversation", "items");
        var participants = ParticipantNames(request).ToList();
        foreach (var participant in EnumerateArray(root, "participants"))
        {
            var name = JsonString(participant, "name") ?? JsonString(participant, "username");
            if (!string.IsNullOrWhiteSpace(name) && !participants.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                participants.Add(name);
            }
        }

        var segments = new List<NormalizedSegment>();
        foreach (var message in messages)
        {
            var content = JsonString(message, "content") ?? JsonString(message, "text") ?? JsonString(message, "message") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(content)) continue;

            var speaker = JsonString(message, "sender_name") ?? JsonString(message, "sender") ?? AuthorName(message) ?? "Unknown";
            if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);

            var createdAt = ParseUnixEpochMilliseconds(JsonString(message, "timestamp_ms"))
                ?? ParseUnixEpoch(JsonString(message, "timestamp"))
                ?? TryParseDate(JsonString(message, "created_at") ?? JsonString(message, "date"));

            segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, createdAt));
        }

        var title = Clean(request.Title) ?? JsonString(root, "title") ?? Metadata(request, "thread") ?? "Instagram export";
        return Response(source, $"Normalized {segments.Count} Instagram message(s).", [new NormalizedConversation(title, source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseIMessage(ImportRequest request)
    {
        var source = "imessage";
        var text = EffectiveText(request);
        if (text.TrimStart().StartsWith('{') || text.TrimStart().StartsWith('['))
        {
            using var doc = JsonDocument.Parse(text);
            var messages = EnumerateArray(doc.RootElement, "messages", "items", "chat");
            var participants = ParticipantNames(request).ToList();
            var segments = new List<NormalizedSegment>();

            foreach (var message in messages)
            {
                var content = JsonString(message, "text") ?? JsonString(message, "body") ?? JsonString(message, "message") ?? string.Empty;
                if (string.IsNullOrWhiteSpace(content)) continue;
                var speaker = JsonString(message, "from") ?? JsonString(message, "sender") ?? JsonString(message, "author") ?? "Unknown";
                if (!participants.Contains(speaker, StringComparer.OrdinalIgnoreCase)) participants.Add(speaker);
                segments.Add(new NormalizedSegment(content.Trim(), speaker, segments.Count * 1000, TryParseDate(JsonString(message, "date") ?? JsonString(message, "timestamp"))));
            }

            return Response(source, $"Normalized {segments.Count} iMessage/SMS message(s).", [new NormalizedConversation(Clean(request.Title) ?? "iMessage export", source, participants, segments)]);
        }

        return ParseChatLines(source, request, AppleMessageLineRegex());
    }

    private static NormalizedImportResponse ParseMbox(ImportRequest request)
    {
        var source = "mbox";
        var text = EffectiveText(request);
        var blocks = SplitMboxBlocks(text);
        var conversations = new List<NormalizedConversation>();
        foreach (var block in blocks)
        {
            var split = HeaderBodySeparatorRegex().Split(block, 2);
            var headers = ParseHeaders(split[0]);
            var body = split.Length > 1 ? DecodeQuotedPrintable(split[1]) : string.Empty;
            var from = Header(headers, "From") ?? "Unknown sender";
            var to = Header(headers, "To");
            var subject = Header(headers, "Subject") ?? "Email message";
            var participants = ParticipantNames(request).ToList();
            foreach (var name in EmailNames(from).Concat(EmailNames(to)))
            {
                if (!participants.Contains(name, StringComparer.OrdinalIgnoreCase)) participants.Add(name);
            }

            var metadata = new Dictionary<string, string>();
            foreach (var key in new[] { "Message-Id", "Date", "From", "To" })
            {
                if (Header(headers, key) is { } value) metadata[key.ToLowerInvariant()] = value;
            }

            var sender = EmailNames(from).FirstOrDefault() ?? from;
            conversations.Add(new NormalizedConversation(
                subject,
                source,
                participants,
                [new NormalizedSegment(body.Trim(), sender, 0, TryParseDate(Header(headers, "Date")) ?? DateTimeOffset.UtcNow)],
                null,
                metadata));
        }

        if (conversations.Count == 0)
        {
            return SingleConversation(source, request, text, "Email export");
        }

        return Response(source, $"Normalized {conversations.Count} mbox email(s).", conversations);
    }

    private static NormalizedImportResponse ParseGit(ImportRequest request)
    {
        var source = "git";
        var text = EffectiveText(request);
        var participants = ParticipantNames(request).ToList();
        var segments = new List<NormalizedSegment>();

        if (LooksLikeJson(text))
        {
            using var doc = JsonDocument.Parse(text);
            var commits = EnumerateArray(doc.RootElement, "commits", "items", "history");
            foreach (var commit in commits)
            {
                var message = JsonString(commit, "message") ?? JsonString(commit, "subject") ?? string.Empty;
                if (string.IsNullOrWhiteSpace(message)) continue;
                var hash = JsonString(commit, "hash") ?? JsonString(commit, "sha") ?? JsonString(commit, "id") ?? string.Empty;
                var shortHash = hash.Length > 7 ? hash[..7] : hash;
                var author = JsonString(commit, "author")
                    ?? (commit.TryGetProperty("author", out var authorObject)
                        ? JsonString(authorObject, "name") ?? JsonString(authorObject, "email")
                        : null)
                    ?? "Unknown";
                if (!participants.Contains(author, StringComparer.OrdinalIgnoreCase)) participants.Add(author);
                var files = commit.TryGetProperty("files", out var filesArray) && filesArray.ValueKind == JsonValueKind.Array
                    ? string.Join(", ", filesArray.EnumerateArray().Select(file => file.ValueKind == JsonValueKind.String ? file.GetString() : JsonString(file, "path")).Where(path => !string.IsNullOrWhiteSpace(path)))
                    : string.Empty;
                var body = shortHash.Length > 0 ? $"{shortHash} {message}" : message;
                if (files.Length > 0) body += $"\nFiles: {files}";
                segments.Add(new NormalizedSegment(body, author, segments.Count * 1000, TryParseDate(JsonString(commit, "date") ?? JsonString(commit, "authoredDate"))));
            }
        }
        else
        {
            foreach (var block in GitCommitRegex().Split(text).Where(item => item.Trim().Length > 0))
            {
                var trimmed = block.Trim();
                var lines = trimmed.Split('\n').Select(line => line.TrimEnd('\r')).ToArray();
                if (lines.Length == 0) continue;
                var hash = lines[0].Trim();
                var shortHash = hash.Length > 7 ? hash[..7] : hash;
                var author = lines.FirstOrDefault(line => line.StartsWith("Author:", StringComparison.OrdinalIgnoreCase))?.Split(':', 2).ElementAtOrDefault(1)?.Trim() ?? "Unknown";
                if (!participants.Contains(author, StringComparer.OrdinalIgnoreCase)) participants.Add(author);
                var date = lines.FirstOrDefault(line => line.StartsWith("Date:", StringComparison.OrdinalIgnoreCase))?.Split(':', 2).ElementAtOrDefault(1)?.Trim();
                var bodyLines = lines.SkipWhile(line => !string.IsNullOrWhiteSpace(line)).Skip(1).Where(line => line.Length > 0).ToArray();
                var message = bodyLines.Length > 0 ? string.Join("\n", bodyLines) : trimmed;
                segments.Add(new NormalizedSegment($"{shortHash} {message}".Trim(), author, segments.Count * 1000, TryParseDate(date)));
            }
        }

        if (segments.Count == 0)
        {
            return SingleConversation(source, request, text, "Git import");
        }

        var title = Clean(request.Title)
            ?? Metadata(request, "repository")
            ?? Metadata(request, "repoUrl")
            ?? Clean(request.OriginalFileName)
            ?? "Git history";
        var metadata = new Dictionary<string, string>();
        if (Metadata(request, "repoUrl") is { } repoUrl) metadata["repoUrl"] = repoUrl;
        return Response(source, $"Normalized {segments.Count} git commit(s).", [new NormalizedConversation(title, source, participants, segments, null, metadata.Count > 0 ? metadata : null)]);
    }

    private static NormalizedImportResponse ParseBrowserCapture(ImportRequest request)
    {
        var source = "browser-capture";
        var text = EffectiveText(request);
        var participants = ParticipantNames(request);
        if (!LooksLikeJson(text))
        {
            var url = Metadata(request, "url");
            var title = Metadata(request, "title") ?? request.Title ?? "Browser capture";
            var body = url is null ? text : $"{title}\nURL: {url}\n\n{text}";
            return SingleConversation(source, request, body, title);
        }

        using var doc = JsonDocument.Parse(text);
        var items = EnumerateArray(doc.RootElement, "events", "captures", "items", "history");
        var segments = new List<NormalizedSegment>();
        foreach (var item in items)
        {
            var url = JsonString(item, "url") ?? JsonString(item, "href") ?? string.Empty;
            var title = JsonString(item, "title") ?? JsonString(item, "name") ?? "Consumed content";
            var content = JsonString(item, "content") ?? JsonString(item, "text") ?? JsonString(item, "summary") ?? string.Empty;
            if (url.Length == 0 && content.Length == 0) continue;
            var body = content.Length == 0
                ? $"{title}\nURL: {url}".Trim()
                : $"{title}\nURL: {url}\n\n{content}".Trim();
            segments.Add(new NormalizedSegment(body, null, segments.Count * 1000, TryParseDate(JsonString(item, "timestamp") ?? JsonString(item, "time") ?? JsonString(item, "date"))));
        }

        if (segments.Count == 0)
        {
            return SingleConversation(source, request, text, "Browser capture");
        }

        return Response(source, $"Normalized {segments.Count} browser capture item(s).", [new NormalizedConversation(Clean(request.Title) ?? "Browser capture", source, participants, segments)]);
    }

    private static NormalizedImportResponse ParseGoogleSearchHistory(ImportRequest request)
    {
        var source = "google-search-history";
        var text = EffectiveText(request);
        var segments = new List<NormalizedSegment>();

        if (LooksLikeJson(text))
        {
            using var doc = JsonDocument.Parse(text);
            var items = EnumerateArray(doc.RootElement, "events", "items", "history");
            foreach (var item in items)
            {
                var title = JsonString(item, "title") ?? JsonString(item, "query") ?? string.Empty;
                var url = JsonString(item, "titleUrl") ?? JsonString(item, "url") ?? string.Empty;
                var query = JsonString(item, "query") ?? ExtractGoogleQuery(url) ?? ExtractSearchedFor(title) ?? title;
                if (string.IsNullOrWhiteSpace(query) && string.IsNullOrWhiteSpace(url)) continue;
                segments.Add(new NormalizedSegment($"Searched: {query}" + (url.Length > 0 ? $"\nURL: {url}" : string.Empty), null, segments.Count * 1000, TryParseDate(JsonString(item, "time") ?? JsonString(item, "time_usec") ?? JsonString(item, "date"))));
            }
        }
        else if (text.Contains(','))
        {
            foreach (var row in ParseCsv(text))
            {
                var url = FirstValue(row, "url", "titleUrl", "link") ?? string.Empty;
                var query = FirstValue(row, "query", "search_term", "term", "title") ?? ExtractGoogleQuery(url) ?? string.Empty;
                if (query.Length == 0 && url.Length == 0) continue;
                segments.Add(new NormalizedSegment($"Searched: {query}" + (url.Length > 0 ? $"\nURL: {url}" : string.Empty), null, segments.Count * 1000, TryParseDate(FirstValue(row, "time", "date", "timestamp"))));
            }
        }

        if (segments.Count == 0)
        {
            return SingleConversation(source, request, text, "Google search history");
        }

        return Response(source, $"Normalized {segments.Count} Google search event(s).", [new NormalizedConversation(Clean(request.Title) ?? "Google search history", source, ParticipantNames(request), segments)]);
    }

    private static NormalizedImportResponse ParseBookmarks(ImportRequest request)
    {
        var source = "bookmarks";
        var text = EffectiveText(request);
        var segments = new List<NormalizedSegment>();

        if (LooksLikeJson(text))
        {
            using var doc = JsonDocument.Parse(text);
            var roots = new List<JsonElement>();
            if (doc.RootElement.TryGetProperty("roots", out var rootsObject) && rootsObject.ValueKind == JsonValueKind.Object)
            {
                foreach (var property in rootsObject.EnumerateObject())
                {
                    roots.Add(property.Value);
                }
            }
            else
            {
                roots.Add(doc.RootElement);
            }

            foreach (var root in roots)
            {
                foreach (var node in EnumerateBookmarkNodes(root))
                {
                    var title = JsonString(node, "name") ?? JsonString(node, "title") ?? "Bookmark";
                    var url = JsonString(node, "url") ?? JsonString(node, "href") ?? string.Empty;
                    if (url.Length == 0) continue;
                    segments.Add(new NormalizedSegment($"Bookmarked {title}: {url}", null, segments.Count * 1000, ParseUnixEpochMilliseconds(JsonString(node, "date_added")) ?? ParseUnixEpoch(JsonString(node, "date_added"))));
                }
            }
        }
        else
        {
            foreach (Match match in BookmarkHtmlRegex().Matches(text))
            {
                var url = match.Groups["url"].Value.Trim();
                var title = System.Net.WebUtility.HtmlDecode(match.Groups["title"].Value).Trim();
                if (url.Length == 0) continue;
                segments.Add(new NormalizedSegment($"Bookmarked {title}: {url}".Trim(), null, segments.Count * 1000, null));
            }
        }

        if (segments.Count == 0)
        {
            return SingleConversation(source, request, text, "Bookmarks");
        }

        return Response(source, $"Normalized {segments.Count} bookmark(s).", [new NormalizedConversation(Clean(request.Title) ?? "Bookmarks", source, ParticipantNames(request), segments)]);
    }

    private static NormalizedImportResponse ParseLifenizerBackup(ImportRequest request)
    {
        var source = "lifenizer-backup";
        var text = EffectiveText(request);
        if (!LooksLikeJson(text))
        {
            return SingleConversation(source, request, text, "Lifenizer backup");
        }

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var conversations = new List<NormalizedConversation>();
        var items = EnumerateArray(root, "conversations", "items", "data");
        foreach (var item in items)
        {
            var title = JsonString(item, "title") ?? "Backup conversation";
            var convSource = JsonString(item, "source") ?? "backup";
            var participants = new List<string>();
            foreach (var p in EnumerateArray(item, "participantNames", "participants"))
            {
                if (p.ValueKind == JsonValueKind.String)
                {
                    var name = p.GetString();
                    if (!string.IsNullOrWhiteSpace(name)) participants.Add(name!);
                }
                else
                {
                    var name = JsonString(p, "displayName") ?? JsonString(p, "name");
                    if (!string.IsNullOrWhiteSpace(name)) participants.Add(name!);
                }
            }

            var segments = new List<NormalizedSegment>();
            foreach (var segment in EnumerateArray(item, "segments", "messages"))
            {
                if (segment.ValueKind == JsonValueKind.String)
                {
                    var content = segment.GetString();
                    if (!string.IsNullOrWhiteSpace(content))
                    {
                        segments.Add(new NormalizedSegment(content!, null, segments.Count * 1000, null));
                    }
                    continue;
                }

                var segmentText = JsonString(segment, "text") ?? JsonString(segment, "content") ?? JsonString(segment, "message") ?? string.Empty;
                if (string.IsNullOrWhiteSpace(segmentText)) continue;
                var offsetMs = 0;
                if (segment.TryGetProperty("offsetMs", out var offsetMsJson) && offsetMsJson.ValueKind == JsonValueKind.Number)
                {
                    offsetMs = offsetMsJson.GetInt32();
                }
                segments.Add(new NormalizedSegment(segmentText, JsonString(segment, "participantName") ?? JsonString(segment, "speaker"), offsetMs, TryParseDate(JsonString(segment, "createdAt") ?? JsonString(segment, "date"))));
            }

            if (segments.Count == 0) continue;

            conversations.Add(new NormalizedConversation(
                title,
                convSource,
                participants,
                segments,
                EnumerateArray(item, "artifactNames", "artifacts").Where(value => value.ValueKind == JsonValueKind.String).Select(value => value.GetString()!).Where(value => !string.IsNullOrWhiteSpace(value)).ToArray(),
                null));
        }

        if (conversations.Count == 0)
        {
            return SingleConversation(source, request, text, "Lifenizer backup");
        }

        return Response(source, $"Normalized {conversations.Count} backup conversation(s).", conversations);
    }

    private static NormalizedImportResponse ParseTranscriptJson(string source, ImportRequest request, string json, string fallbackTitle)
    {
        using var doc = JsonDocument.Parse(json);
        var segments = new List<NormalizedSegment>();
        foreach (var item in EnumerateArray(doc.RootElement, "segments", "transcript", "items"))
        {
            var text = JsonString(item, "text") ?? JsonString(item, "content") ?? JsonString(item, "utterance") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(text)) continue;
            var offsetMs = 0;
            if (item.TryGetProperty("start", out var start) && start.ValueKind == JsonValueKind.Number)
            {
                offsetMs = (int)(start.GetDouble() * 1000);
            }
            else if (item.TryGetProperty("offsetMs", out var offset) && offset.ValueKind == JsonValueKind.Number)
            {
                offsetMs = offset.GetInt32();
            }
            segments.Add(new NormalizedSegment(text.Trim(), JsonString(item, "speaker"), offsetMs, null));
        }

        if (segments.Count == 0)
        {
            var text = JsonString(doc.RootElement, "text") ?? JsonString(doc.RootElement, "transcript") ?? string.Empty;
            return SingleConversation(source, request, text, fallbackTitle);
        }

        return Response(source, $"Normalized {segments.Count} transcript segment(s).", [new NormalizedConversation(Clean(request.Title) ?? fallbackTitle, source, ParticipantNames(request), segments)]);
    }

    private static NormalizedImportResponse ParseTranscriptXml(string source, ImportRequest request, string xml, string fallbackTitle)
    {
        var segments = new List<NormalizedSegment>();
        foreach (Match match in TranscriptTextRegex().Matches(xml))
        {
            var encoded = match.Groups["text"].Value;
            var start = match.Groups["start"].Success ? match.Groups["start"].Value : "0";
            var text = System.Net.WebUtility.HtmlDecode(encoded).Trim();
            if (text.Length == 0) continue;
            var offsetMs = double.TryParse(start, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) ? (int)(seconds * 1000) : segments.Count * 1000;
            segments.Add(new NormalizedSegment(text, null, offsetMs, null));
        }

        if (segments.Count == 0) return SingleConversation(source, request, xml, fallbackTitle);
        return Response(source, $"Normalized {segments.Count} XML transcript segment(s).", [new NormalizedConversation(Clean(request.Title) ?? fallbackTitle, source, ParticipantNames(request), segments)]);
    }

    private static IEnumerable<Dictionary<string, string>> ParseCsv(string csv)
    {
        var lines = csv.Split('\n').Select(line => line.TrimEnd('\r')).Where(line => line.Length > 0).ToArray();
        if (lines.Length < 2) yield break;
        var headers = SplitCsvLine(lines[0]).Select(header => header.Trim()).ToArray();
        for (var i = 1; i < lines.Length; i++)
        {
            var values = SplitCsvLine(lines[i]).ToArray();
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var j = 0; j < headers.Length && j < values.Length; j++)
            {
                row[headers[j]] = values[j];
            }
            yield return row;
        }
    }

    private static IEnumerable<string> SplitCsvLine(string line)
    {
        var value = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (c == '"')
            {
                if (quoted && i + 1 < line.Length && line[i + 1] == '"')
                {
                    value.Append('"');
                    i++;
                }
                else
                {
                    quoted = !quoted;
                }
                continue;
            }

            if (c == ',' && !quoted)
            {
                yield return value.ToString();
                value.Clear();
                continue;
            }

            value.Append(c);
        }
        yield return value.ToString();
    }

    private static IEnumerable<JsonElement> EnumerateArray(JsonElement root, params string[] propertyNames)
    {
        if (root.ValueKind == JsonValueKind.Array) return root.EnumerateArray().ToArray();
        foreach (var propertyName in propertyNames)
        {
            if (root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.Array)
            {
                return property.EnumerateArray().ToArray();
            }
        }
        return [];
    }

    private static string? TelegramText(JsonElement message)
    {
        if (!message.TryGetProperty("text", out var text)) return JsonString(message, "content");
        if (text.ValueKind == JsonValueKind.String) return text.GetString();
        if (text.ValueKind != JsonValueKind.Array) return null;

        var builder = new StringBuilder();
        foreach (var item in text.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                builder.Append(item.GetString());
            }
            else if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("text", out var nested))
            {
                builder.Append(nested.GetString());
            }
        }
        return builder.ToString();
    }

    private static string? AuthorName(JsonElement message)
    {
        if (message.TryGetProperty("author", out var author))
        {
            if (author.ValueKind == JsonValueKind.String) return author.GetString();
            if (author.ValueKind == JsonValueKind.Object)
            {
                return JsonString(author, "username") ?? JsonString(author, "name") ?? JsonString(author, "global_name");
            }
        }
        return JsonString(message, "from") ?? JsonString(message, "sender") ?? JsonString(message, "username");
    }

    private static string? JsonString(JsonElement element, string property)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(property, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.ToString(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null
        };
    }

    private static string? FirstValue(Dictionary<string, string> row, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (row.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)) return value.Trim();
        }
        return null;
    }

    private static IReadOnlyList<string> ArtifactNames(ImportRequest request)
    {
        var originalFileName = Clean(request.OriginalFileName);
        return originalFileName is null ? [] : [originalFileName];
    }

    private static string EffectiveText(ImportRequest request, string fallback = "")
    {
        if (!string.IsNullOrWhiteSpace(request.Text))
        {
            return request.Text;
        }

        if (string.IsNullOrWhiteSpace(request.PayloadBase64))
        {
            return fallback;
        }

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(request.PayloadBase64);
        }
        catch (FormatException)
        {
            return fallback;
        }

        var mimeType = request.MimeType?.Trim().ToLowerInvariant();
        var fileName = request.OriginalFileName?.Trim().ToLowerInvariant();
        var isZip = mimeType == "application/zip" || fileName?.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) == true;
        if (isZip)
        {
            return ExtractTextFromZip(bytes) ?? fallback;
        }

        var decoded = Encoding.UTF8.GetString(bytes).Trim();
        return decoded.Length == 0 ? fallback : decoded;
    }

    private static string? ExtractTextFromZip(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes, writable: false);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
        var preferredEntries = archive.Entries
            .Where(entry => entry.Length > 0)
            .OrderBy(entry => RankEntry(entry.FullName))
            .ThenBy(entry => entry.FullName, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (preferredEntries.Length == 0)
        {
            return null;
        }

        foreach (var entry in preferredEntries)
        {
            using var entryStream = entry.Open();
            using var reader = new StreamReader(entryStream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: false);
            var content = reader.ReadToEnd().Trim();
            if (content.Length == 0)
            {
                continue;
            }

            // Prefer the first relevant text-like file to avoid polluting parsers
            // with synthetic headers when importing chat exports from zip archives.
            return content;
        }

        return null;
    }

    private static int RankEntry(string fileName)
    {
        var lower = fileName.ToLowerInvariant();
        if (lower.EndsWith(".txt", StringComparison.Ordinal)) return 0;
        if (lower.EndsWith(".md", StringComparison.Ordinal)) return 1;
        if (lower.EndsWith(".csv", StringComparison.Ordinal)) return 2;
        if (lower.EndsWith(".json", StringComparison.Ordinal) || lower.EndsWith(".jsonl", StringComparison.Ordinal)) return 3;
        if (lower.EndsWith(".html", StringComparison.Ordinal) || lower.EndsWith(".htm", StringComparison.Ordinal)) return 4;
        if (lower.EndsWith(".xml", StringComparison.Ordinal)) return 5;
        return 10;
    }

    private static DateTimeOffset? ParseUnixEpoch(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)) return null;
        try
        {
            var milliseconds = (long)Math.Round(seconds * 1000);
            return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static DateTimeOffset? ParseUnixEpochMilliseconds(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var milliseconds)) return null;
        try
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static string StripHtml(string value)
    {
        if (value.IndexOf('<') < 0 || value.IndexOf('>') < 0)
        {
            return value;
        }

        var stripped = HtmlTagRegex().Replace(value, " ");
        var decoded = System.Net.WebUtility.HtmlDecode(stripped);
        return WhitespaceRegex().Replace(decoded, " ").Trim();
    }

    private static string[] SplitMboxBlocks(string text)
    {
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal);
        var parts = MboxSeparatorRegex().Split(normalized)
            .Select(part => part.Trim())
            .Where(part => part.Length > 0)
            .ToArray();
        return parts;
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

    private static string? Header(Dictionary<string, string> headers, string key)
    {
        return headers.TryGetValue(key, out var value) ? value : null;
    }

    private static IEnumerable<string> EmailNames(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) yield break;
        foreach (var part in value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var display = part;
            var lt = part.IndexOf('<');
            if (lt > 0)
            {
                display = part[..lt].Trim();
            }
            var gt = part.IndexOf('>');
            if (lt >= 0 && gt > lt)
            {
                var address = part[(lt + 1)..gt].Trim();
                if (display.Length == 0) display = address;
            }

            display = display.Trim('"', ' ');
            if (display.Length > 0) yield return display;
        }
    }

    private static string DecodeQuotedPrintable(string value)
    {
        return value
            .Replace("=\r\n", string.Empty, StringComparison.Ordinal)
            .Replace("=\n", string.Empty, StringComparison.Ordinal)
            .Replace("=20", " ", StringComparison.Ordinal)
            .Trim();
    }

    private static string? Clean(string? value)
    {
        var cleaned = value?.Trim();
        return string.IsNullOrWhiteSpace(cleaned) ? null : cleaned;
    }

    private static DateTimeOffset? TryParseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : null;
    }

    [GeneratedRegex(@"^\[?(?<date>\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}[^\]]*)\]?\s*-?\s*(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex WhatsAppLineRegex();

    [GeneratedRegex(@"^(?<speaker>[^:]+):\s*(?<text>.*)$")]
    private static partial Regex SimpleSpeakerLineRegex();

    [GeneratedRegex(@"<text(?:[^>]*start=""(?<start>[^""]+)"")?[^>]*>(?<text>.*?)</text>", RegexOptions.Singleline)]
    private static partial Regex TranscriptTextRegex();

    [GeneratedRegex(@"(?:^|\n)commit\s+", RegexOptions.Multiline)]
    private static partial Regex GitCommitRegex();

    [GeneratedRegex(@"<A[^>]*HREF=""(?<url>[^""]+)""[^>]*>(?<title>.*?)</A>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex BookmarkHtmlRegex();

    [GeneratedRegex(@"^(?<date>\d{1,2}/\d{1,2}/\d{2,4},\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?)[\s-]+(?<speaker>[^:]+):\s*(?<text>.*)$", RegexOptions.IgnoreCase)]
    private static partial Regex AppleMessageLineRegex();

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex HtmlTagRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();

    [GeneratedRegex(@"(?:^|\n)From\s.+\n")]
    private static partial Regex MboxSeparatorRegex();

    [GeneratedRegex(@"\r?\n\r?\n")]
    private static partial Regex HeaderBodySeparatorRegex();

    private static bool LooksLikeJson(string value)
    {
        var trimmed = value.TrimStart();
        return trimmed.StartsWith('{') || trimmed.StartsWith('[');
    }

    private static IEnumerable<JsonElement> EnumerateBookmarkNodes(JsonElement node)
    {
        if (node.ValueKind != JsonValueKind.Object) yield break;
        var type = JsonString(node, "type");
        if (string.Equals(type, "url", StringComparison.OrdinalIgnoreCase)
            || node.TryGetProperty("url", out var urlProperty) && urlProperty.ValueKind == JsonValueKind.String)
        {
            yield return node;
            yield break;
        }

        if (node.TryGetProperty("children", out var children) && children.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in children.EnumerateArray())
            {
                foreach (var nested in EnumerateBookmarkNodes(child))
                {
                    yield return nested;
                }
            }
        }
    }

    private static string? ExtractGoogleQuery(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return null;
        if (!uri.Host.Contains("google.", StringComparison.OrdinalIgnoreCase)) return null;
        var queryPart = uri.Query.TrimStart('?');
        foreach (var kvp in queryPart.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var equalsIndex = kvp.IndexOf('=');
            if (equalsIndex <= 0) continue;
            var key = kvp[..equalsIndex];
            if (!key.Equals("q", StringComparison.OrdinalIgnoreCase)) continue;
            return Uri.UnescapeDataString(kvp[(equalsIndex + 1)..]).Replace('+', ' ');
        }
        return null;
    }

    private static string? ExtractSearchedFor(string title)
    {
        var marker = "searched for";
        var index = title.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (index < 0) return null;
        return title[(index + marker.Length)..].Trim(' ', ':', '-', '"');
    }
}
