using System.Buffers.Binary;
using System.Net.Http.Json;
using System.Text.Json;

namespace Lifenizer.Api.Services;

public sealed record TabConsentRequest(string ContributionKey, string Version, bool AcceptTerms);
public sealed record TabCorrectionRequest(string ContributionKey, string ConsentId, string PayloadBase64, string OriginalText, string CorrectedText, bool IsReplacement = false);
public sealed record TabWithdrawalRequest(string ContributionKey);

/// <summary>Explicit selected-speech contributions; no vault data is discovered or stored here.</summary>
public sealed class TabTrainingClient(IHttpClientFactory clients, IConfiguration configuration)
{
    public const string HttpClientName = "tab-training";
    private const int MaxAudioBytes = 8 * 1024 * 1024;

    public Task<JsonElement> NoticeAsync(CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Get, "api/dialect/consents/notice", null, null, cancellationToken);

    public Task<JsonElement> ConsentAsync(TabConsentRequest request, CancellationToken cancellationToken)
    {
        ValidateKey(request.ContributionKey);
        if (!request.AcceptTerms || string.IsNullOrWhiteSpace(request.Version) || request.Version.Length > 200)
            throw new ArgumentException("Review and accept the current TAB training notice before contributing.");
        return SendAsync(HttpMethod.Post, "api/dialect/consents", request.ContributionKey,
            new { email = (string?)null, purposes = 4, version = request.Version, acceptTerms = true }, cancellationToken);
    }

    public async Task<object> CorrectAsync(TabCorrectionRequest request, CancellationToken cancellationToken)
    {
        ValidateKey(request.ContributionKey);
        ValidateConsentId(request.ConsentId);
        if (string.IsNullOrWhiteSpace(request.CorrectedText) || request.CorrectedText.Length > 10_000 ||
            (request.IsReplacement ? request.OriginalText != string.Empty :
                string.IsNullOrWhiteSpace(request.OriginalText) || request.OriginalText.Length > 10_000 ||
                request.CorrectedText.Trim() == request.OriginalText.Trim()))
            throw new ArgumentException(request.IsReplacement
                ? "Enter the replacement sentence (up to 10,000 characters) without an original transcript."
                : "Select an erroneous sentence and enter its corrected text (up to 10,000 characters).");
        if (string.IsNullOrEmpty(request.PayloadBase64) || request.PayloadBase64.Length > (MaxAudioBytes + 2) / 3 * 4)
            throw new ArgumentException("Select one WAV clip of at most 8 MB and 120 seconds.");
        byte[] audio;
        try { audio = Convert.FromBase64String(request.PayloadBase64); }
        catch (FormatException) { throw new ArgumentException("The selected audio clip is not valid base64."); }
        ValidateWav(audio);

        var consent = await SendAsync(HttpMethod.Get, $"api/dialect/consents/{Uri.EscapeDataString(request.ConsentId)}",
            request.ContributionKey, null, cancellationToken);
        if (!consent.TryGetProperty("purposes", out var purposes) || !purposes.TryGetInt32(out var mask) || (mask & 4) == 0)
            throw new ArgumentException("This TAB receipt no longer allows Coflnet speech-recognition training. Review your contribution consent.");
        var alias = consent.TryGetProperty("contributorAlias", out var contributorAlias) ? contributorAlias.GetString() : null;
        var uploaded = await SendAsync(HttpMethod.Post, "api/Dialect/upload", request.ContributionKey,
            new { contributionConsentId = request.ConsentId, base64Audio = request.PayloadBase64,
                uploaderEmail = alias, transcription = request.CorrectedText.Trim() }, cancellationToken);
        if (!uploaded.TryGetProperty("id", out var id) || !uploaded.TryGetProperty("audioId", out var audioId))
            throw new InvalidOperationException("TAB accepted the request without a contribution reference. Check TAB before retrying this clip.");
        return new { id = id.GetString(), audioId = audioId.GetString(), status = "submitted_for_validation" };
    }

    public Task<JsonElement> WithdrawAsync(string id, TabWithdrawalRequest request, CancellationToken cancellationToken)
    {
        ValidateKey(request.ContributionKey);
        ValidateConsentId(id);
        return SendAsync(HttpMethod.Post, $"api/dialect/consents/{Uri.EscapeDataString(id)}/withdraw",
            request.ContributionKey, new { purposes = 4 }, cancellationToken);
    }

    private async Task<JsonElement> SendAsync(HttpMethod method, string path, string? key, object? body, CancellationToken cancellationToken)
    {
        var configured = configuration["Training:Tab:BaseUrl"] ?? "https://tab.coflnet.com";
        if (!Uri.TryCreate(configured.TrimEnd('/') + "/", UriKind.Absolute, out var root) ||
            root.Scheme is not ("http" or "https") || root.UserInfo.Length != 0 || root.Query.Length != 0 || root.Fragment.Length != 0)
            throw new InvalidOperationException("TAB training requires a configured absolute HTTP(S) base URL.");
        using var message = new HttpRequestMessage(method, new Uri(root, path));
        message.Headers.UserAgent.ParseAdd("Lifenizer/1.0 Mozilla/5.0");
        if (key is not null) message.Headers.Add("X-Contribution-Key", key);
        if (body is not null) message.Content = JsonContent.Create(body);
        using var response = await clients.CreateClient(HttpClientName).SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            if ((int)response.StatusCode is 400 or 401 or 403 or 404 or 409 or 422)
                throw new ArgumentException($"TAB rejected this contribution request ({(int)response.StatusCode}). Check the current notice and contribution receipt before retrying.");
            throw new InvalidOperationException("TAB training is unavailable. Your local recording and correction were preserved.");
        }
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var bounded = new MemoryStream();
        var buffer = new byte[8192];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (bounded.Length + read > 1024 * 1024) throw new InvalidOperationException("TAB returned an oversized response.");
            bounded.Write(buffer, 0, read);
        }
        using var json = JsonDocument.Parse(bounded.ToArray());
        return json.RootElement.Clone();
    }

    private static void ValidateKey(string key)
    {
        if (key is null || key.Length != 64 || !key.All(Uri.IsHexDigit))
            throw new ArgumentException("A private 64-character contribution device key is required.");
    }

    private static void ValidateConsentId(string id)
    {
        if (string.IsNullOrWhiteSpace(id) || id.Length > 100 || !id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_'))
            throw new ArgumentException("A valid TAB contribution receipt is required.");
    }

    private static void ValidateWav(byte[] audio)
    {
        if (audio.Length < 44 || audio.Length > MaxAudioBytes || !audio.AsSpan(0, 4).SequenceEqual("RIFF"u8) ||
            !audio.AsSpan(8, 4).SequenceEqual("WAVE"u8) || BinaryPrimitives.ReadUInt32LittleEndian(audio.AsSpan(4, 4)) != audio.Length - 8)
            throw new ArgumentException("The selected clip must be a valid 16 kHz mono PCM WAV file.");
        var validFormat = false;
        var formatSeen = false;
        var samples = 0;
        var offset = 12;
        while (offset + 8 <= audio.Length)
        {
            var size = BinaryPrimitives.ReadUInt32LittleEndian(audio.AsSpan(offset + 4, 4));
            if (size > audio.Length - offset - 8) throw new ArgumentException("The selected WAV clip is truncated.");
            var content = offset + 8;
            if (audio.AsSpan(offset, 4).SequenceEqual("fmt "u8))
            {
                if (formatSeen) throw new ArgumentException("The selected WAV clip has conflicting format headers.");
                formatSeen = true;
                validFormat = size >= 16 && BinaryPrimitives.ReadUInt16LittleEndian(audio.AsSpan(content, 2)) == 1 &&
                    BinaryPrimitives.ReadUInt16LittleEndian(audio.AsSpan(content + 2, 2)) == 1 &&
                    BinaryPrimitives.ReadUInt32LittleEndian(audio.AsSpan(content + 4, 4)) == 16_000 &&
                    BinaryPrimitives.ReadUInt32LittleEndian(audio.AsSpan(content + 8, 4)) == 32_000 &&
                    BinaryPrimitives.ReadUInt16LittleEndian(audio.AsSpan(content + 12, 2)) == 2 &&
                    BinaryPrimitives.ReadUInt16LittleEndian(audio.AsSpan(content + 14, 2)) == 16;
            }
            if (audio.AsSpan(offset, 4).SequenceEqual("data"u8))
            {
                if (size % 2 != 0) throw new ArgumentException("The selected WAV samples are truncated.");
                samples += (int)size / 2;
            }
            offset = content + (int)size + (int)(size % 2);
        }
        if (!validFormat || samples == 0 || samples > 16_000 * 120 || offset != audio.Length)
            throw new ArgumentException("Select one 16 kHz mono PCM WAV clip of at most 120 seconds.");
    }
}
