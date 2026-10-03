using Lifenizer.Core;
using Lifenizer.Api.Services;
using Microsoft.AspNetCore.Mvc;
using System.Text.Json;

namespace Lifenizer.Api.Endpoints;

public static class ImportEndpoints
{
    private static readonly ImportCapability[] Capabilities =
    [
        new("manual-text", "Manual text or chat paste", true, false, "Normalizes plaintext/chat paste into encrypted client sync.", ["text/plain", "text/markdown"]),
        new("audio", "Audio file upload", true, true, "Can call the self-hosted whisper-trained transcription service, then the client encrypts the transcript.", ["audio/wav", "audio/mpeg", "audio/mp4", "audio/ogg"]),
        new("live-recording", "Live VAD recording", true, false, "Client route groups VAD chunks into one encrypted conversation.", ["audio/wav"]),
        new("scanned-pdf", "Scanned PDF", true, false, "Accepts supplied OCR text now; OCR providers can feed the same route.", ["application/pdf", "image/png", "image/jpeg", "text/plain"]),
        new("paperless", "Paperless", true, true, "Fetches Paperless document metadata/content from a configured base URL and token.", ["application/json"]),
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
        new("youtube-transcript", "YouTube transcript", true, false, "Fetches transcript JSON/XML/text from a configured transcript URL or parses supplied text.", ["text/plain", "application/json", "application/xml"])
    ];

    public static IEndpointRouteBuilder MapImportEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/imports").WithTags("Imports");

        group.MapGet("/capabilities", () => Results.Ok(Capabilities)).AllowAnonymous();

        group.MapPost("/{source}", async ([FromRoute] string source, [FromBody] ImportRequest request, ImportOrchestrator orchestrator, CancellationToken cancellationToken) =>
        {
            var capability = Capabilities.FirstOrDefault(c => string.Equals(c.Source, source, StringComparison.OrdinalIgnoreCase));
            if (capability is null)
            {
                return Results.NotFound(new { error = "unknown_import_source", source });
            }

            try
            {
                var result = await orchestrator.ImportAsync(capability.Source, request, cancellationToken);
                return Results.Ok(result);
            }
            catch (InvalidOperationException exception)
            {
                return Results.BadRequest(new { error = "invalid_import_request", message = exception.Message });
            }
            catch (JsonException exception)
            {
                return Results.BadRequest(new { error = "invalid_import_json", message = exception.Message });
            }
        }).RequireAuthorization();

        return app;
    }
}