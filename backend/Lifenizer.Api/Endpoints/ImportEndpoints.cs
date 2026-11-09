using Lifenizer.Core;
using Lifenizer.Api.Services;
using Microsoft.AspNetCore.Mvc;
using System.Text.Json;

namespace Lifenizer.Api.Endpoints;

/// <summary>Marks the endpoints that run audio transcription (the limiters key off the matched route, not the path text).</summary>
public sealed record AudioImportRoute(bool Always);

public static class ImportEndpoints
{
    /// <summary>True for the upload route and for the generic import route when its source is "audio".</summary>
    public static bool IsAudioImport(HttpContext context)
    {
        if (context.GetEndpoint()?.Metadata.GetMetadata<AudioImportRoute>() is not { } route) return false;
        return route.Always || string.Equals(context.Request.RouteValues["source"] as string, "audio", StringComparison.OrdinalIgnoreCase);
    }

    private static readonly ImportCapability[] Capabilities =
    [
        new("manual-text", "Manual text or chat paste", true, false, "Normalizes plaintext/chat paste into encrypted client sync.", ["text/plain", "text/markdown"]),
        new("audio", "Audio file upload", true, false, "Can call the self-hosted whisper-trained transcription service, then the client encrypts the transcript.", ["audio/wav", "audio/mpeg", "audio/mp4", "audio/ogg"]),
        new("live-recording", "Live VAD recording", true, false, "Client route groups VAD chunks into one encrypted conversation.", ["audio/wav"]),
        new("scanned-pdf", "Scanned PDF", true, false, "Extracts PDF text and OCRs scanned pages/images; also accepts supplied OCR text.", ["application/pdf", "image/png", "image/jpeg", "text/plain"]),
        new("photo", "Photo", true, false, "Single camera image (payloadBase64, max 25 MiB): EXIF capture date/camera, OCR text, idempotent by content hash. GPS coordinates are never stored.", ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"], [".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"]),
        new("youtube-watch-history", "YouTube watch history", true, false, "Parses Google Takeout watch-history.json/.html; one conversation per video, repeated watches merged. No transcripts fetched.", ["application/json", "text/html", "application/zip"], ["watch-history.json", "watch-history.html", "Wiedergabeverlauf.json", "Wiedergabeverlauf.html"]),
        new("tiktok-watch-history", "TikTok watch history", true, false, "Parses TikTok data export JSON (user_data*.json) or Browsing History .txt; one conversation per video. No titles or transcripts available.", ["application/json", "text/plain", "application/zip"], ["user_data.json", "user_data_tiktok.json", "Video Browsing History.txt", "Browsing History.txt"]),
        new("paperless", "Paperless", true, true, "Fetches Paperless document metadata/content from a configured base URL and token.", ["application/json"]),
        new("paperless-export", "Paperless ZIP export", true, false, "Imports Paperless manifest OCR/metadata or bulk PDF/scan ZIPs, with bounded extraction. Up to 25 MiB compressed and 100 MiB expanded.", ["application/zip"], ["manifest.json", "*-manifest.json"]),
        new("email", "Email", true, true, "Fetches mail from IMAP with request-scoped credentials and normalizes messages.", ["message/rfc822"]),
        new("whatsapp", "WhatsApp chat export", true, false, "Parses manual WhatsApp text exports.", ["text/plain", "application/zip"]),
        new("telegram", "Telegram export", true, false, "Parses Telegram JSON/text/zip exports.", ["application/json", "text/html", "text/plain", "application/zip"]),
        new("signal", "Signal export", true, false, "Parses Signal-style CSV/JSON/text/zip exports.", ["text/csv", "application/json", "text/plain", "application/zip"]),
        new("discord", "Discord export", true, true, "Parses Discord exports or fetches mock/live channel messages from a configured API URL.", ["application/json", "text/plain", "application/zip"]),
        new("slack", "Slack export", true, false, "Parses Slack JSON exports (single file or zip payload).", ["application/json", "text/plain", "application/zip"]),
        new("teams", "Microsoft Teams export", true, false, "Parses Teams JSON or HTML-embedded message exports.", ["application/json", "text/html", "text/plain", "application/zip"]),
        new("facebook-messenger", "Facebook Messenger export", true, false, "Parses Messenger JSON/text/zip exports.", ["application/json", "text/plain", "application/zip"]),
        new("instagram", "Instagram DM export", true, false, "Parses Instagram DM JSON/text/zip exports.", ["application/json", "text/plain", "application/zip"]),
        new("imessage", "iMessage / SMS export", true, false, "Parses iMessage/SMS transcript text and JSON exports.", ["text/plain", "application/json", "application/zip"]),
        new("mbox", "Email mbox export", true, false, "Parses local .mbox email exports without live IMAP credentials.", ["text/plain", "message/rfc822", "application/mbox"]),
        new("git", "Git history export", true, false, "Parses git logs, commit JSON, and repository activity snapshots.", ["text/plain", "application/json", "application/zip"]),
        new("browser-capture", "Browser extension capture", true, false, "Parses captured URLs and consumed page content from extension/web payloads.", ["text/plain", "application/json"]),
        new("google-search-history", "Google search history", true, false, "Parses Google search history JSON/CSV exports.", ["application/json", "text/csv", "text/plain", "application/zip"]),
        new("bookmarks", "Browser bookmarks", true, false, "Parses bookmark exports from JSON or Netscape HTML formats.", ["application/json", "text/html", "text/plain", "application/zip"]),
        new("lifenizer-backup", "Lifenizer backup", true, false, "Parses portable Lifenizer backup JSON bundles into normalized conversations.", ["application/json", "application/zip", "text/plain"]),
        new("browser-history", "Browser history", true, false, "Parses CSV/JSON browser history exports.", ["text/csv", "application/json", "application/zip"]),
        new("youtube-transcript", "YouTube transcript", true, false, "Fetches transcript JSON/XML/text from a configured transcript service, or (built-in fetcher) public YouTube captions by metadata.videoId, or parses supplied text.", ["text/plain", "application/json", "application/xml"])
    ];

    private static string RemoteModeStatus(IConfiguration configuration)
        => !string.IsNullOrWhiteSpace(configuration["Imports:YouTube:BaseUrl"]) ? " Remote mode: available (configured transcript service)."
            : YouTubeCaptionFetcher.IsBuiltInEnabled(configuration) ? " Remote mode: available (built-in YouTube captions, best effort)."
            : " Remote mode: unavailable (set Imports:YouTube:BaseUrl or enable Imports:YouTube:BuiltInCaptions).";

    public static IEndpointRouteBuilder MapImportEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/imports").WithTags("Imports");

        group.MapGet("/capabilities", (IConfiguration configuration) => Results.Ok(Capabilities.Select(c => c.Source == "youtube-transcript" ? c with { Status = c.Status + RemoteModeStatus(configuration) } : c))).AllowAnonymous();

        group.MapGet("/paperless/settings", (IConfiguration configuration) => Results.Ok(new { configured = !string.IsNullOrWhiteSpace(configuration["Imports:Paperless:BaseUrl"]), baseUrl = configuration["Imports:Paperless:BaseUrl"] })).RequireAuthorization();

        group.MapGet("/email/settings", (PlainImapImportClient imap) => Results.Ok(imap.Settings())).RequireAuthorization();

        group.MapPost("/audio/upload", ImportAudioUploadAsync).RequireAuthorization().WithMetadata(new AudioImportRoute(Always: true));

        group.MapPost("/{source}", async ([FromRoute] string source, [FromBody] ImportRequest request, ImportOrchestrator orchestrator, HttpContext httpContext, CancellationToken cancellationToken) =>
        {
            var capability = Capabilities.FirstOrDefault(c => string.Equals(c.Source, source, StringComparison.OrdinalIgnoreCase));
            if (capability is null)
            {
                return Results.NotFound(new { error = "unknown_import_source", source });
            }

            return await RunImportAsync(httpContext, () => orchestrator.ImportAsync(capability.Source, request, cancellationToken));
        }).RequireAuthorization().WithMetadata(new AudioImportRoute(Always: false));

        return app;
    }

    private static Task<IResult> ImportAudioUploadAsync(HttpContext httpContext, ImportOrchestrator orchestrator, IConfiguration configuration, CancellationToken cancellationToken) =>
        RunImportAsync(httpContext, async () =>
        {
            var upload = await AudioUploadReader.ReadAsync(httpContext.Request, configuration, cancellationToken);
            return await orchestrator.ImportAudioUploadAsync(upload.Request, upload.Audio, upload.MimeType, cancellationToken);
        });

    /// <summary>Runs an import and maps failures to the HTTP errors shared by all import routes.</summary>
    private static async Task<IResult> RunImportAsync(HttpContext httpContext, Func<Task<NormalizedImportResponse>> import)
    {
        try
        {
            return Results.Ok(await import());
        }
        catch (YouTubeCaptionException exception)
        {
            if (exception.RetryAfter is { } retry) httpContext.Response.Headers.RetryAfter = ((int)Math.Ceiling(retry.TotalSeconds)).ToString();
            return Results.Json(new { error = exception.Code, message = exception.Message }, statusCode: exception.StatusCode);
        }
        catch (BadHttpRequestException exception)
        {
            return Results.Json(new { error = "invalid_import_request", message = exception.Message }, statusCode: exception.StatusCode);
        }
        catch (InvalidOperationException exception)
        {
            return Results.BadRequest(new { error = "invalid_import_request", message = exception.Message });
        }
        catch (JsonException exception)
        {
            return Results.BadRequest(new { error = "invalid_import_json", message = exception.Message });
        }
    }
}
