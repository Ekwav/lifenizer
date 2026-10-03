using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

public sealed class ImportOrchestrator(
    PlainImapImportClient imapImportClient,
    ProviderHttpImportClient providerHttpImportClient,
    ParserRegistry parserRegistry)
{
    public Task<NormalizedImportResponse> ImportAsync(string source, ImportRequest request, CancellationToken cancellationToken)
    {
        return source.ToLowerInvariant() switch
        {
            "email" => imapImportClient.ImportAsync(request, cancellationToken),
            "paperless" => providerHttpImportClient.ImportPaperlessAsync(request, cancellationToken),
            "youtube-transcript" => providerHttpImportClient.ImportYouTubeTranscriptAsync(request, cancellationToken),
            "discord" when ImportTextParsers.Metadata(request, "baseUrl") is not null => providerHttpImportClient.ImportDiscordApiAsync(request, cancellationToken),
            "audio" when string.IsNullOrWhiteSpace(request.Text) => providerHttpImportClient.ImportAudioTranscriptionAsync(request, cancellationToken),
            "manual-text" or "scanned-pdf" or "live-recording" or "whatsapp" or "telegram" or "signal" or "discord" or "slack" or "teams" or "facebook-messenger" or "instagram" or "imessage" or "mbox" or "git" or "browser-capture" or "google-search-history" or "bookmarks" or "lifenizer-backup" or "browser-history" or "audio" => Task.FromResult(ImportTextParsers.NormalizeLocal(source, request, parserRegistry)),
            _ => throw new KeyNotFoundException($"Unknown import source '{source}'.")
        };
    }
}
