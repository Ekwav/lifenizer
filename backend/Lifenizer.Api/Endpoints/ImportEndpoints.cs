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
        new("audio", "Audio file upload", true, true, "Can call the configurable TAP/Coflnet transcription API, then the client encrypts the transcript.", ["audio/wav", "audio/mpeg", "audio/mp4", "audio/ogg"]),
        new("live-recording", "Live VAD recording", true, false, "Client route groups VAD chunks into one encrypted conversation.", ["audio/wav"]),
        new("scanned-pdf", "Scanned PDF", true, false, "Accepts supplied OCR text now; OCR providers can feed the same route.", ["application/pdf", "image/png", "image/jpeg", "text/plain"]),
        new("paperless", "Paperless", true, true, "Fetches Paperless document metadata/content from a configured base URL and token.", ["application/json"]),
        new("email", "Email", true, true, "Fetches mail from IMAP with request-scoped credentials and normalizes messages.", ["message/rfc822"]),
        new("whatsapp", "WhatsApp chat export", true, false, "Parses manual WhatsApp text exports.", ["text/plain", "application/zip"]),
        new("telegram", "Telegram export", true, false, "Parses Telegram JSON/text exports.", ["application/json", "text/html", "text/plain"]),
        new("signal", "Signal export", true, false, "Parses Signal-style CSV/text exports.", ["text/csv", "application/json", "text/plain"]),
        new("discord", "Discord export", true, true, "Parses Discord exports or fetches mock/live channel messages from a configured API URL.", ["application/json", "text/plain"]),
        new("browser-history", "Browser history", true, false, "Parses CSV/JSON browser history exports.", ["text/csv", "application/json"]),
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