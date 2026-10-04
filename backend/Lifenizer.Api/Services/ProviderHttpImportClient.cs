using System.Net.Http.Headers;
using System.Text.Json;
using Lifenizer.Api.Services.Parsers;
using Lifenizer.Api.Services.Utilities;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

public sealed class ProviderHttpImportClient(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    WhisperTranscriptionClient whisperTranscriptionClient,
    ParserRegistry parserRegistry)
{
    public async Task<NormalizedImportResponse> ImportPaperlessAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        var baseUrl = ProviderBaseUrl(request, "Imports:Paperless:BaseUrl", "Paperless");
        var token = ProviderSecret(request, "token", "Imports:Paperless:Token", "Paperless");
        var limit = int.TryParse(ImportTextParsers.Metadata(request, "limit"), out var parsedLimit) ? Math.Clamp(parsedLimit, 1, 50) : 10;
        var page = ImportTextParsers.Metadata(request, "page") is { } rawPage
            ? int.TryParse(rawPage, out var parsedPage) && parsedPage > 0 ? parsedPage : throw new InvalidOperationException("Paperless page must be a positive integer.") : 1;
        var since = ImportTextParsers.Metadata(request, "modifiedAfter");
        if (since is not null && CommonParsing.TryParseDate(since) is null) throw new InvalidOperationException("Paperless modifiedAfter must be an ISO date-time.");
        var root = new Uri(baseUrl.TrimEnd('/') + "/");
        var relative = $"api/documents/?page_size={limit}&page={page}&ordering=modified,id" +
            (since is null ? "" : "&modified__gte=" + Uri.EscapeDataString(since));
        using var doc = JsonDocument.Parse(await PaperlessTextAsync(new Uri(root, relative), token, cancellationToken));
        var conversations = new List<NormalizedConversation>();
        DateTimeOffset? latest = CommonParsing.TryParseDate(since);
        var correspondents = new Dictionary<string, string>();
        foreach (var listed in CommonParsing.EnumerateArray(doc.RootElement, "results", "documents", "items"))
        {
            var id = JsonFieldExtractor.GetString(listed, "id") ?? throw new InvalidOperationException("Paperless document is missing its ID.");
            if (!long.TryParse(id, out var numericId) || numericId <= 0) throw new InvalidOperationException("Paperless document ID is invalid.");
            var document = listed;
            JsonDocument? detail = null;
            try
            {
                var content = JsonFieldExtractor.GetString(document, "content");
                if (string.IsNullOrWhiteSpace(content))
                {
                    detail = JsonDocument.Parse(await PaperlessTextAsync(new Uri(root, $"api/documents/{id}/"), token, cancellationToken));
                    document = detail.RootElement;
                    content = JsonFieldExtractor.GetString(document, "content");
                }
                if (string.IsNullOrWhiteSpace(content))
                {
                    var bytes = await PaperlessBytesAsync(new Uri(root, $"api/documents/{id}/download/"), token, cancellationToken);
                    content = PdfTextExtractor.Extract(bytes);
                }
                var title = JsonFieldExtractor.GetString(document, "title", "original_file_name") ?? "Paperless document";
                var correspondent = CorrespondentName(document);
                var correspondentId = document.TryGetProperty("correspondent", out var field) && field.ValueKind == JsonValueKind.Number ? field.ToString() : null;
                if (correspondentId is not null)
                {
                    if (!correspondents.TryGetValue(correspondentId, out correspondent))
                    {
                        using var person = JsonDocument.Parse(await PaperlessTextAsync(new Uri(root, $"api/correspondents/{correspondentId}/"), token, cancellationToken));
                        correspondent = JsonFieldExtractor.GetString(person.RootElement, "name") ?? "Paperless";
                        correspondents[correspondentId] = correspondent;
                    }
                }
                correspondent ??= "Paperless";
                var identity = $"paperless:{root.AbsoluteUri}:{id}";
                var metadata = new Dictionary<string, string>();
                foreach (var key in new[] { "id", "created", "modified", "document_type", "archive_serial_number" })
                    if (JsonFieldExtractor.GetString(document, key) is { } value) metadata[key] = value;
                var modified = CommonParsing.TryParseDate(JsonFieldExtractor.GetString(document, "modified"));
                if (modified is not null && (latest is null || modified > latest)) latest = modified;
                conversations.Add(new NormalizedConversation(title, "paperless", [correspondent],
                    [new NormalizedSegment(content, correspondent, 0, CommonParsing.TryParseDate(JsonFieldExtractor.GetString(document, "created")), SourceMessageId: identity)],
                    JsonFieldExtractor.GetString(document, "original_file_name") is { } fileName ? [fileName] : [], metadata,
                    SourceThreadId: identity, SourceUrl: new Uri(root, $"documents/{id}/details").AbsoluteUri));
            }
            finally { detail?.Dispose(); }
        }
        var hasMore = doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("next", out var next) && next.ValueKind != JsonValueKind.Null && !string.IsNullOrWhiteSpace(next.ToString());
        return ImportTextParsers.Response("paperless", $"Fetched and normalized {conversations.Count} Paperless document(s).", conversations,
            new Dictionary<string, string> { ["baseUrl"] = baseUrl, ["hasMore"] = hasMore ? "true" : "false", ["nextPage"] = hasMore ? checked(page + 1).ToString() : "", ["nextModifiedAfter"] = latest?.ToString("O") ?? "" });
    }

    private async Task<string> PaperlessTextAsync(Uri uri, string token, CancellationToken cancellationToken)
        => System.Text.Encoding.UTF8.GetString(await PaperlessBytesAsync(uri, token, cancellationToken));

    private async Task<byte[]> PaperlessBytesAsync(Uri uri, string token, CancellationToken cancellationToken)
    {
        using var message = new HttpRequestMessage(HttpMethod.Get, uri);
        message.Headers.Authorization = new AuthenticationHeaderValue("Token", token);
        using var response = await httpClientFactory.CreateClient("imports").SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Paperless request failed with {(int)response.StatusCode}.");
        if (response.Content.Headers.ContentLength > PdfTextExtractor.MaxBytes) throw new InvalidOperationException("Paperless response exceeds 25 MiB; reduce page size or split the document.");
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var output = new MemoryStream();
        var buffer = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken)) != 0)
        {
            if (output.Length + read > PdfTextExtractor.MaxBytes) throw new InvalidOperationException("Paperless response exceeds 25 MiB; reduce page size or split the document.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    public async Task<NormalizedImportResponse> ImportYouTubeTranscriptAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        var transcriptText = request.Text;
        if (string.IsNullOrWhiteSpace(transcriptText))
        {
            var baseUrl = ProviderBaseUrl(request, "Imports:YouTube:BaseUrl", "YouTube");
            var videoId = Required(request, "videoId");
            var url = new Uri(new Uri(baseUrl.TrimEnd('/') + "/"), $"api/transcripts/{Uri.EscapeDataString(videoId)}");

            using var message = new HttpRequestMessage(HttpMethod.Get, url);
            transcriptText = await SendForTextAsync(message, cancellationToken);
        }

        return ImportTextParsers.ParseTranscript("youtube-transcript", request, transcriptText, request.Title ?? "YouTube transcript", parserRegistry);
    }

    public async Task<NormalizedImportResponse> ImportDiscordApiAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        if (ImportTextParsers.Metadata(request, "channelId") is null && ImportTextParsers.Metadata(request, "baseUrl") is null)
        {
            return ImportTextParsers.NormalizeLocal("discord", request, parserRegistry);
        }

        var baseUrl = ProviderBaseUrl(request, "Imports:Discord:BaseUrl", "Discord");
        var channelId = Required(request, "channelId");
        var token = ProviderSecret(request, "token", "Imports:Discord:Token", "Discord");
        var limit = int.TryParse(ImportTextParsers.Metadata(request, "limit"), out var parsedLimit) ? Math.Clamp(parsedLimit, 1, 100) : 50;
        var uri = new Uri(new Uri(baseUrl.TrimEnd('/') + "/"), $"api/channels/{Uri.EscapeDataString(channelId)}/messages?limit={limit}");
        using var message = new HttpRequestMessage(HttpMethod.Get, uri);
        message.Headers.Authorization = new AuthenticationHeaderValue("Bot", token);
        var json = await SendForTextAsync(message, cancellationToken);
        return ImportTextParsers.ParseDiscordMessages("discord", request, json, parserRegistry);
    }

    public async Task<NormalizedImportResponse> ImportAudioTranscriptionAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        var recordedAt = ParseRecordedAt(request);

        if (!string.IsNullOrWhiteSpace(request.Text))
        {
            var textResponse = ImportTextParsers.SingleConversation("audio", request, request.Text, request.OriginalFileName ?? "Audio transcript", ImportTextParsers.Metadata(request, "fileName") is { } name ? [name] : null);
            return recordedAt is null ? textResponse : WithRecordedAt(textResponse, recordedAt.Value);
        }

        if (string.IsNullOrWhiteSpace(request.PayloadBase64))
        {
            throw new InvalidOperationException("Audio import requires either text or a base64-encoded payloadBase64 audio file.");
        }

        byte[] audioBytes;
        try
        {
            audioBytes = Convert.FromBase64String(request.PayloadBase64);
        }
        catch (FormatException)
        {
            throw new InvalidOperationException("Audio import payloadBase64 is not valid base64.");
        }

        var fileName = request.OriginalFileName ?? ImportTextParsers.Metadata(request, "fileName") ?? "audio-upload";
        var mimeType = request.MimeType ?? "application/octet-stream";
        // NOTE: language is the only per-request override honored here. The whisper-trained base
        // URL is intentionally configuration-only (Whisper:BaseUrl) -- it must never come from
        // request metadata, or any authenticated user could redirect server-side requests to
        // arbitrary in-cluster addresses (SSRF).
        var language = ImportTextParsers.Metadata(request, "language");

        var transcription = await whisperTranscriptionClient.TranscribeAsync(audioBytes, fileName, mimeType, language, cancellationToken);

        var segments = new List<NormalizedSegment>();
        foreach (var segment in transcription.Segments)
        {
            var text = segment.Text.Trim();
            if (text.Length == 0) continue;
            var offsetMs = (int)Math.Round(segment.Start * 1000);
            var createdAt = recordedAt is null ? (DateTimeOffset?)null : recordedAt.Value + TimeSpan.FromMilliseconds(offsetMs);
            segments.Add(new NormalizedSegment(text, null, offsetMs, createdAt));
        }

        if (segments.Count == 0)
        {
            throw new InvalidOperationException("Whisper transcription returned no usable text.");
        }

        var metadata = !string.IsNullOrWhiteSpace(transcription.Language)
            ? new Dictionary<string, string> { ["language"] = transcription.Language }
            : null;
        var title = CommonParsing.Clean(request.Title) ?? CommonParsing.Clean(request.OriginalFileName) ?? "Audio transcript";
        IReadOnlyList<string> artifactNames = ImportTextParsers.Metadata(request, "fileName") is { } explicitFileName ? [explicitFileName] : CommonParsing.ArtifactNames(request);
        var conversation = new NormalizedConversation(
            title,
            "audio",
            ImportTextParsers.ParticipantNames(request),
            segments,
            artifactNames,
            metadata);

        return ImportTextParsers.Response("audio", $"Transcribed and normalized {segments.Count} audio segment(s).", [conversation]);
    }

    /// <summary>
    /// Parses the optional metadata.recordedAt override for audio imports (ISO 8601 date-time).
    /// A string with an explicit offset/"Z" round-trips as given; a string without one is assumed
    /// UTC, matching <see cref="CommonParsing.TryParseDate"/>'s existing semantics. Rejects
    /// unparseable values and values more than 1 day in the future (guards against swapped
    /// day/month typos creating future-dated memories).
    /// </summary>
    private static DateTimeOffset? ParseRecordedAt(ImportRequest request)
    {
        var raw = ImportTextParsers.Metadata(request, "recordedAt");
        if (raw is null) return null;

        var parsed = CommonParsing.TryParseDate(raw);
        if (parsed is null)
        {
            throw new InvalidOperationException($"Audio import metadata.recordedAt is not a valid ISO 8601 date-time (was '{raw}').");
        }

        if (parsed.Value > DateTimeOffset.UtcNow.AddDays(1))
        {
            throw new InvalidOperationException($"Audio import metadata.recordedAt must not be more than 1 day in the future (was '{raw}').");
        }

        return parsed;
    }

    /// <summary>
    /// Rewrites every segment's CreatedAt to recordedAt + segment.OffsetMs, so a "recorded on"
    /// timestamp supplied by the client anchors the whole conversation instead of import time.
    /// </summary>
    private static NormalizedImportResponse WithRecordedAt(NormalizedImportResponse response, DateTimeOffset recordedAt)
    {
        var conversations = response.Conversations
            .Select(conversation => conversation with
            {
                Segments = conversation.Segments
                    .Select(segment => segment with { CreatedAt = recordedAt + TimeSpan.FromMilliseconds(segment.OffsetMs) })
                    .ToArray()
            })
            .ToList();
        return response with { Conversations = conversations };
    }

    private async Task<string> SendForTextAsync(HttpRequestMessage message, CancellationToken cancellationToken)
    {
        var client = httpClientFactory.CreateClient("imports");
        using var response = await client.SendAsync(message, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Provider request to {message.RequestUri} failed with {(int)response.StatusCode}: {body}");
        }
        return body;
    }

    private static string? CorrespondentName(JsonElement document)
    {
        if (!document.TryGetProperty("correspondent", out var correspondent)) return null;
        if (correspondent.ValueKind == JsonValueKind.String) return correspondent.GetString();
        if (correspondent.ValueKind == JsonValueKind.Object)
        {
            return JsonFieldExtractor.GetString(correspondent, "name", "display_name");
        }
        return null;
    }

    private static string Required(ImportRequest request, string key)
    {
        return ImportTextParsers.Metadata(request, key)
            ?? throw new InvalidOperationException($"Import requires metadata.{key}.");
    }

    private string ProviderBaseUrl(ImportRequest request, string configKey, string providerName)
    {
        if (ImportTextParsers.Metadata(request, "baseUrl") is not null || ImportTextParsers.Metadata(request, "transcriptUrl") is not null)
            throw new InvalidOperationException($"{providerName} endpoint is configuration-only; set {configKey} on the server.");

        var baseUrl = configuration[configKey];
        if (string.IsNullOrWhiteSpace(baseUrl) || !Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("http" or "https") || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            throw new InvalidOperationException($"{providerName} import requires an absolute http(s) URL in configuration {configKey}.");

        return baseUrl;
    }

    private string ProviderSecret(ImportRequest request, string metadataKey, string configKey, string providerName)
    {
        return ImportTextParsers.Metadata(request, metadataKey)
            ?? configuration[configKey]
            ?? throw new InvalidOperationException($"{providerName} import requires metadata.{metadataKey} or configuration {configKey}.");
    }
}
