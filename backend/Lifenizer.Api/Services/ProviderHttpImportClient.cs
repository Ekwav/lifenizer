using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

public sealed class ProviderHttpImportClient(IHttpClientFactory httpClientFactory, IConfiguration configuration)
{
    public async Task<NormalizedImportResponse> ImportPaperlessAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        var baseUrl = ProviderBaseUrl(request, "baseUrl", "Imports:Paperless:BaseUrl", "Paperless");
        var token = ProviderSecret(request, "token", "Imports:Paperless:Token", "baseUrl", "Imports:Paperless:BaseUrl", "Paperless");
        var limit = int.TryParse(ImportTextParsers.Metadata(request, "limit"), out var parsedLimit) ? Math.Clamp(parsedLimit, 1, 50) : 10;
        var uri = new Uri(new Uri(baseUrl.TrimEnd('/') + "/"), $"api/documents/?page_size={limit}");
        using var message = new HttpRequestMessage(HttpMethod.Get, uri);
        message.Headers.Authorization = new AuthenticationHeaderValue("Token", token);

        var json = await SendForTextAsync(message, cancellationToken);
        using var doc = JsonDocument.Parse(json);
        var documents = EnumerateArray(doc.RootElement, "results", "documents", "items");
        var conversations = new List<NormalizedConversation>();
        foreach (var document in documents)
        {
            var title = JsonString(document, "title") ?? JsonString(document, "original_file_name") ?? "Paperless document";
            var correspondent = CorrespondentName(document) ?? "Paperless";
            var content = JsonString(document, "content") ?? JsonString(document, "notes") ?? JsonString(document, "archive_serial_number") ?? title;
            var metadata = new Dictionary<string, string>();
            foreach (var key in new[] { "id", "created", "document_type", "archive_serial_number" })
            {
                if (JsonString(document, key) is { } value) metadata[key] = value;
            }
            conversations.Add(new NormalizedConversation(
                title,
                "paperless",
                [correspondent],
                [new NormalizedSegment(content, correspondent, 0, TryParseDate(JsonString(document, "created")))],
                JsonString(document, "original_file_name") is { } fileName ? [fileName] : [],
                metadata));
        }

        return ImportTextParsers.Response("paperless", $"Fetched and normalized {conversations.Count} Paperless document(s).", conversations, new Dictionary<string, string> { ["baseUrl"] = baseUrl });
    }

    public async Task<NormalizedImportResponse> ImportYouTubeTranscriptAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        var transcriptText = request.Text;
        if (string.IsNullOrWhiteSpace(transcriptText))
        {
            var url = ImportTextParsers.Metadata(request, "transcriptUrl");
            if (url is null)
            {
                var baseUrl = Required(request, "baseUrl");
                var videoId = Required(request, "videoId");
                url = new Uri(new Uri(baseUrl.TrimEnd('/') + "/"), $"api/transcripts/{Uri.EscapeDataString(videoId)}").ToString();
            }

            using var message = new HttpRequestMessage(HttpMethod.Get, url);
            transcriptText = await SendForTextAsync(message, cancellationToken);
        }

        return ImportTextParsers.ParseTranscript("youtube-transcript", request, transcriptText, request.Title ?? "YouTube transcript");
    }

    public async Task<NormalizedImportResponse> ImportDiscordApiAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        if (ImportTextParsers.Metadata(request, "baseUrl") is null)
        {
            return ImportTextParsers.NormalizeLocal("discord", request);
        }

        var baseUrl = ProviderBaseUrl(request, "baseUrl", "Imports:Discord:BaseUrl", "Discord");
        var channelId = Required(request, "channelId");
        var token = ProviderSecret(request, "token", "Imports:Discord:Token", "baseUrl", "Imports:Discord:BaseUrl", "Discord");
        var limit = int.TryParse(ImportTextParsers.Metadata(request, "limit"), out var parsedLimit) ? Math.Clamp(parsedLimit, 1, 100) : 50;
        var uri = new Uri(new Uri(baseUrl.TrimEnd('/') + "/"), $"api/channels/{Uri.EscapeDataString(channelId)}/messages?limit={limit}");
        using var message = new HttpRequestMessage(HttpMethod.Get, uri);
        message.Headers.Authorization = new AuthenticationHeaderValue("Bot", token);
        var json = await SendForTextAsync(message, cancellationToken);
        return ImportTextParsers.ParseDiscordMessages("discord", request, json);
    }

    public async Task<NormalizedImportResponse> ImportAudioTranscriptionAsync(ImportRequest request, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(request.Text))
        {
            return ImportTextParsers.SingleConversation("audio", request, request.Text, request.OriginalFileName ?? "Audio transcript", ImportTextParsers.Metadata(request, "fileName") is { } name ? [name] : null);
        }

        var baseUrl = ProviderBaseUrl(request, "tapBaseUrl", "Tap:BaseUrl", "TAP transcription", "https://tap.coflnet.com");
        var path = ImportTextParsers.Metadata(request, "tapPath") ?? configuration["Tap:TranscriptionPath"] ?? "/api/transcribe";
        var apiKey = ProviderSecret(request, "tapApiKey", "Tap:ApiKey", "tapBaseUrl", "Tap:BaseUrl", "TAP transcription", "placeholder-tap-api-key");
        var uri = new Uri(new Uri(baseUrl.TrimEnd('/') + "/"), path.TrimStart('/'));
        var payload = new
        {
            fileName = request.OriginalFileName ?? ImportTextParsers.Metadata(request, "fileName") ?? "audio-upload",
            mimeType = request.MimeType ?? "application/octet-stream",
            audioBase64 = request.PayloadBase64,
            audioUrl = ImportTextParsers.Metadata(request, "audioUrl"),
            language = ImportTextParsers.Metadata(request, "language") ?? "auto"
        };

        using var message = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = JsonContent.Create(payload)
        };
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        var json = await SendForTextAsync(message, cancellationToken);
        var transcript = ExtractTranscript(json);
        return ImportTextParsers.ParseTranscript("audio", request, transcript, request.OriginalFileName ?? "Audio transcript");
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

    private static string ExtractTranscript(string body)
    {
        var trimmed = body.Trim();
        if (!trimmed.StartsWith('{') && !trimmed.StartsWith('[')) return body;

        using var doc = JsonDocument.Parse(trimmed);
        if (doc.RootElement.ValueKind == JsonValueKind.Object)
        {
            foreach (var key in new[] { "text", "transcript", "content" })
            {
                if (JsonString(doc.RootElement, key) is { } value) return value;
            }
            if (doc.RootElement.TryGetProperty("segments", out _)) return trimmed;
        }
        return trimmed;
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

    private static string? CorrespondentName(JsonElement document)
    {
        if (!document.TryGetProperty("correspondent", out var correspondent)) return null;
        if (correspondent.ValueKind == JsonValueKind.String) return correspondent.GetString();
        if (correspondent.ValueKind == JsonValueKind.Object)
        {
            return JsonString(correspondent, "name") ?? JsonString(correspondent, "display_name");
        }
        return null;
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

    private static DateTimeOffset? TryParseDate(string? value)
    {
        return DateTimeOffset.TryParse(value, out var parsed) ? parsed : null;
    }

    private static string Required(ImportRequest request, string key)
    {
        return ImportTextParsers.Metadata(request, key)
            ?? throw new InvalidOperationException($"Import requires metadata.{key}.");
    }

    private string ProviderBaseUrl(ImportRequest request, string metadataKey, string configKey, string providerName, string? fallback = null)
    {
        var baseUrl = ImportTextParsers.Metadata(request, metadataKey) ?? configuration[configKey] ?? fallback;
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            throw new InvalidOperationException($"{providerName} import requires metadata.{metadataKey} or configuration {configKey}.");
        }

        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
        {
            throw new InvalidOperationException($"{providerName} import requires an absolute http or https URL in metadata.{metadataKey} or configuration {configKey}.");
        }

        return baseUrl;
    }

    private string ProviderSecret(
        ImportRequest request,
        string metadataKey,
        string configKey,
        string baseUrlMetadataKey,
        string baseUrlConfigKey,
        string providerName,
        string? fallback = null)
    {
        if (ImportTextParsers.Metadata(request, metadataKey) is { } requestSecret)
        {
            return requestSecret;
        }

        var requestBaseUrl = ImportTextParsers.Metadata(request, baseUrlMetadataKey);
        var configuredBaseUrl = configuration[baseUrlConfigKey];
        if (requestBaseUrl is not null && !SameOrigin(requestBaseUrl, configuredBaseUrl))
        {
            throw new InvalidOperationException($"{providerName} import requires request-scoped metadata.{metadataKey} when metadata.{baseUrlMetadataKey} overrides the configured provider URL.");
        }

        return configuration[configKey]
            ?? fallback
            ?? throw new InvalidOperationException($"{providerName} import requires metadata.{metadataKey} or configuration {configKey}.");
    }

    private static bool SameOrigin(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        if (!Uri.TryCreate(left, UriKind.Absolute, out var leftUri)) return false;
        if (!Uri.TryCreate(right, UriKind.Absolute, out var rightUri)) return false;
        return leftUri.Scheme.Equals(rightUri.Scheme, StringComparison.OrdinalIgnoreCase)
            && leftUri.IdnHost.Equals(rightUri.IdnHost, StringComparison.OrdinalIgnoreCase)
            && leftUri.Port == rightUri.Port;
    }
}
