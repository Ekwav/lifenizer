using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text.Json;

namespace Lifenizer.Api.Services;

/// <summary>
/// Client for the self-hosted whisper-trained transcription service
/// (onerahmet/openai-whisper-asr-webservice, running with ASR_ENGINE=faster_whisper on CPU).
/// The base URL is configuration-only (never request-scoped) so an authenticated user cannot
/// direct the server to make outbound requests to arbitrary in-cluster addresses (SSRF).
/// </summary>
public sealed class WhisperTranscriptionClient(IHttpClientFactory httpClientFactory, IConfiguration configuration)
{
    public const string HttpClientName = "whisper";

    private const string DefaultBaseUrl = "http://whisper-trained.tab:9000";

    public static HttpMessageHandler CreateHttpHandler(IConfiguration configuration)
    {
        var path = configuration["Whisper:UnixSocketPath"];
        if (string.IsNullOrWhiteSpace(path)) return new HttpClientHandler { AllowAutoRedirect = false };
        return new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseProxy = false,
            ConnectCallback = async (_, cancellationToken) =>
            {
                var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                try
                {
                    await socket.ConnectAsync(new UnixDomainSocketEndPoint(path), cancellationToken);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch { socket.Dispose(); throw; }
            }
        };
    }

    /// <summary>
    /// Sends audio bytes to whisper-trained's /asr endpoint and parses the transcript response.
    /// </summary>
    /// <param name="audioBytes">The decoded audio payload.</param>
    /// <param name="fileName">File name to attach to the multipart upload (cosmetic; whisper-trained sniffs content).</param>
    /// <param name="mimeType">MIME type for the multipart part; falls back to application/octet-stream.</param>
    /// <param name="requestLanguage">Per-request language override (ISO code). Empty or "auto" means unset.</param>
    public async Task<WhisperTranscriptionResult> TranscribeAsync(
        byte[] audioBytes,
        string fileName,
        string? mimeType,
        string? requestLanguage,
        CancellationToken cancellationToken)
    {
        var baseUrl = string.IsNullOrWhiteSpace(configuration["Whisper:BaseUrl"])
            ? DefaultBaseUrl
            : configuration["Whisper:BaseUrl"]!;

        if (!Uri.TryCreate(baseUrl.TrimEnd('/') + "/", UriKind.Absolute, out var baseUri) || baseUri.Scheme is not ("http" or "https"))
        {
            throw new InvalidOperationException($"Whisper transcription requires a valid absolute http(s) URL in configuration Whisper:BaseUrl (was '{baseUrl}').");
        }

        var language = NormalizeLanguage(requestLanguage) ?? NormalizeLanguage(configuration["Whisper:Language"]);
        var query = "task=transcribe&output=json&encode=true";
        if (language is not null)
        {
            query += $"&language={Uri.EscapeDataString(language)}";
        }

        var uri = new Uri(baseUri, $"asr?{query}");

        using var content = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent(audioBytes);
        fileContent.Headers.ContentType = !string.IsNullOrWhiteSpace(mimeType) && MediaTypeHeaderValue.TryParse(mimeType, out var parsedType)
            ? parsedType
            : new MediaTypeHeaderValue("application/octet-stream");
        content.Add(fileContent, "audio_file", string.IsNullOrWhiteSpace(fileName) ? "audio" : fileName);

        using var message = new HttpRequestMessage(HttpMethod.Post, uri) { Content = content };

        var client = httpClientFactory.CreateClient(HttpClientName);
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(message, cancellationToken);
        }
        catch (HttpRequestException exception)
        {
            throw new InvalidOperationException($"Whisper transcription service at {baseUrl} is unreachable: {exception.Message}");
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new InvalidOperationException($"Whisper transcription service at {baseUrl} timed out.");
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                var excerpt = body.Length > 300 ? body[..300] + "…" : body;
                throw new InvalidOperationException($"Whisper transcription service at {baseUrl} failed with {(int)response.StatusCode}: {excerpt}");
            }

            return ParseResponse(body);
        }
    }

    private static WhisperTranscriptionResult ParseResponse(string body)
    {
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        var text = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("text", out var textProp) && textProp.ValueKind == JsonValueKind.String
            ? textProp.GetString() ?? string.Empty
            : string.Empty;
        var language = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("language", out var langProp) && langProp.ValueKind == JsonValueKind.String
            ? langProp.GetString()
            : null;

        var segments = new List<WhisperSegment>();
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("segments", out var segmentsProp) && segmentsProp.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in segmentsProp.EnumerateArray())
            {
                if (ParseSegment(element) is { } segment)
                {
                    segments.Add(segment);
                }
            }
        }

        if (segments.Count == 0 && !string.IsNullOrWhiteSpace(text))
        {
            segments.Add(new WhisperSegment(0, null, text));
        }

        return new WhisperTranscriptionResult(text, language, segments);
    }

    /// <summary>
    /// Maps one whisper segment. Depending on engine version, a segment is either an object
    /// ({start, end, text, ...}) or a positional faster-whisper array [id, seek, start, end, text, tokens, ...].
    /// </summary>
    private static WhisperSegment? ParseSegment(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var text = element.TryGetProperty("text", out var textProp) && textProp.ValueKind == JsonValueKind.String
                ? textProp.GetString()
                : null;
            if (string.IsNullOrWhiteSpace(text)) return null;

            var start = element.TryGetProperty("start", out var startProp) && startProp.ValueKind == JsonValueKind.Number
                ? startProp.GetDouble()
                : 0;
            double? end = element.TryGetProperty("end", out var endProp) && endProp.ValueKind == JsonValueKind.Number
                ? endProp.GetDouble()
                : null;
            return new WhisperSegment(start, end, text);
        }

        if (element.ValueKind == JsonValueKind.Array)
        {
            var items = element.EnumerateArray().ToArray();
            if (items.Length < 5) return null;

            var text = items[4].ValueKind == JsonValueKind.String ? items[4].GetString() : null;
            if (string.IsNullOrWhiteSpace(text)) return null;

            var start = items[2].ValueKind == JsonValueKind.Number ? items[2].GetDouble() : 0;
            double? end = items[3].ValueKind == JsonValueKind.Number ? items[3].GetDouble() : null;
            return new WhisperSegment(start, end, text);
        }

        return null;
    }

    private static string? NormalizeLanguage(string? language)
    {
        var trimmed = language?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        return string.Equals(trimmed, "auto", StringComparison.OrdinalIgnoreCase) ? null : trimmed;
    }
}

public sealed record WhisperTranscriptionResult(string Text, string? Language, IReadOnlyList<WhisperSegment> Segments);

public sealed record WhisperSegment(double Start, double? End, string Text);
