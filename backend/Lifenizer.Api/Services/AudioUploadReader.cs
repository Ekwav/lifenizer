using System.Text.Json;
using Lifenizer.Core;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Net.Http.Headers;

namespace Lifenizer.Api.Services;

public sealed record AudioUpload(ImportRequest Request, byte[] Audio, string? MimeType);

/// <summary>Reads the multipart body of POST /api/imports/audio/upload: a JSON `metadata` part and an `audio` file part.</summary>
public static class AudioUploadReader
{
    private const long DefaultMaxBytes = 200_000_000L;
    private const int MaxMetadataBytes = 1_000_000;
    private const int MaxBoundaryLength = 70; // RFC 2046
    private const int MinBufferBytes = 64 * 1024;
    private const int MaxInitialBufferBytes = 8 * 1024 * 1024;
    private const int MaxParts = 8;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <exception cref="InvalidOperationException">The body is not a usable audio upload (mapped to 400).</exception>
    /// <exception cref="BadHttpRequestException">The body exceeds Imports:MaxRequestBytes (413).</exception>
    public static async Task<AudioUpload> ReadAsync(HttpRequest request, IConfiguration configuration, CancellationToken cancellationToken)
    {
        var maxBytes = configuration.GetValue<long?>("Imports:MaxRequestBytes") ?? DefaultMaxBytes;
        if (request.ContentLength > maxBytes) throw TooLarge("Audio upload");

        var reader = new MultipartReader(ParseBoundary(request), request.Body);
        var parts = await ReadPartsAsync(reader, request.ContentLength, maxBytes, cancellationToken);
        if (parts.Audio is null) throw new InvalidOperationException("Audio upload is missing the 'audio' part.");

        var importRequest = (parts.Metadata ?? new ImportRequest()) with { PayloadBase64 = null };
        return new AudioUpload(importRequest, parts.Audio, parts.AudioType ?? importRequest.MimeType);
    }

    private sealed record Parts(ImportRequest? Metadata, byte[]? Audio, string? AudioType);

    private static string ParseBoundary(HttpRequest request)
    {
        if (!request.HasFormContentType || !MediaTypeHeaderValue.TryParse(request.ContentType, out var contentType)) throw InvalidBody();
        var boundary = HeaderUtilities.RemoveQuotes(contentType.Boundary).Value;
        return string.IsNullOrEmpty(boundary) || boundary.Length > MaxBoundaryLength ? throw InvalidBody() : boundary;
    }

    private static InvalidOperationException InvalidBody() =>
        new("Audio upload requires a multipart/form-data body with a valid boundary and 'metadata' and 'audio' parts.");

    private static async Task<Parts> ReadPartsAsync(MultipartReader reader, long? contentLength, long maxBytes, CancellationToken cancellationToken)
    {
        ImportRequest? metadata = null;
        byte[]? audio = null;
        string? audioType = null;
        var sections = 0;
        try
        {
            while (await reader.ReadNextSectionAsync(cancellationToken) is { } section)
            {
                if (++sections > MaxParts) throw InvalidBody();
                var name = ContentDispositionHeaderValue.TryParse(section.ContentDisposition, out var disposition) ? disposition.Name.Value : null;
                if (name == "metadata")
                {
                    metadata = metadata is null ? await ReadMetadataAsync(section, cancellationToken) : throw DuplicatePart(name);
                }
                if (name != "audio") continue;
                if (audio is not null) throw DuplicatePart(name);
                audioType = section.ContentType;
                audio = await ReadBoundedAsync(section.Body, maxBytes, contentLength ?? 0, "Audio upload", cancellationToken);
            }
        }
        catch (Exception exception) when (exception is InvalidDataException or ArgumentException || (exception is IOException && exception is not BadHttpRequestException))
        {
            throw InvalidBody();
        }
        return new Parts(metadata, audio, audioType);
    }

    private static InvalidOperationException DuplicatePart(string name) => new($"Audio upload has more than one '{name}' part.");

    private static async Task<ImportRequest?> ReadMetadataAsync(MultipartSection section, CancellationToken cancellationToken)
    {
        var json = await ReadBoundedAsync(section.Body, MaxMetadataBytes, 0, "Audio upload metadata", cancellationToken);
        return json.Length == 0 ? null : JsonSerializer.Deserialize<ImportRequest>(json, JsonOptions);
    }

    /// <summary>
    /// Reads into one buffer. The Content-Length hint only sizes the starting buffer (bounded, so a client announcing a huge
    /// body and stalling cannot pin memory); beyond that the buffer doubles as bytes actually arrive.
    /// </summary>
    private static async Task<byte[]> ReadBoundedAsync(Stream body, long limit, long capacityHint, string what, CancellationToken cancellationToken)
    {
        var buffer = new byte[(int)Math.Min(Math.Clamp(capacityHint, MinBufferBytes, MaxInitialBufferBytes), Math.Min(limit, Array.MaxLength))];
        var length = 0;
        while (true)
        {
            if (length == buffer.Length && !TryGrow(ref buffer, limit, capacityHint)) return await EnsureEndAsync(body, buffer, what, cancellationToken);
            var read = await body.ReadAsync(buffer.AsMemory(length), cancellationToken);
            if (read == 0) break;
            length += read;
        }
        return length == buffer.Length ? buffer : buffer[..length];
    }

    private static bool TryGrow(ref byte[] buffer, long limit, long contentLength)
    {
        var next = NextBufferSize(buffer.Length, limit, contentLength);
        if (next <= buffer.Length) return false;
        Array.Resize(ref buffer, next);
        return true;
    }

    /// <summary>Doubles, but never beyond the request limit or (when known) the announced Content-Length: no part can be larger.</summary>
    public static int NextBufferSize(int current, long limit, long contentLength)
    {
        var ceiling = Math.Min(limit, Array.MaxLength);
        if (contentLength > 0) ceiling = Math.Min(ceiling, contentLength);
        return (int)Math.Min(ceiling, (long)current * 2);
    }

    /// <summary>The buffer is full at the limit: any further byte means the part is too large.</summary>
    private static async Task<byte[]> EnsureEndAsync(Stream body, byte[] buffer, string what, CancellationToken cancellationToken)
    {
        var probe = new byte[1];
        if (await body.ReadAsync(probe, cancellationToken) > 0) throw TooLarge(what);
        return buffer;
    }

    private static BadHttpRequestException TooLarge(string what) =>
        new($"{what} exceeds the maximum request size.", StatusCodes.Status413PayloadTooLarge);
}
