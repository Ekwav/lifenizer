using Lifenizer.Api.Services.Parsers;
using Lifenizer.Core;

namespace Lifenizer.Api.Services;

/// <summary>
/// Public API for text import normalization. Delegates to ParserRegistry for format-specific handling.
/// Phase 2: Refactored to use Strategy pattern with pluggable parsers.
/// </summary>
public static class ImportTextParsers
{
    /// <summary>
    /// Normalizes imported text from various sources using registered format-specific parsers.
    /// Replaces the previous massive switch statement with registry-based dispatch.
    /// </summary>
    /// <param name="source">The import source format (e.g., "telegram", "discord", "whatsapp").</param>
    /// <param name="request">The import request with text and metadata.</param>
    /// <param name="registry">The parser registry to dispatch to appropriate parser.</param>
    /// <returns>Normalized import response with parsed conversations.</returns>
    public static NormalizedImportResponse NormalizeLocal(string source, ImportRequest request, ParserRegistry registry)
    {
        return registry.Parse(source, request);
    }

    // --- Forwarding helpers for backward compatibility with callers not yet migrated ---

    public static string? Metadata(ImportRequest request, string key)
        => CommonParsing.Metadata(request, key);

    public static NormalizedImportResponse Response(
        string source,
        string message,
        IReadOnlyList<NormalizedConversation> conversations,
        IReadOnlyDictionary<string, string>? diagnostics = null)
        => CommonParsing.Response(source, message, conversations, diagnostics);

    public static NormalizedImportResponse SingleConversation(
        string source,
        ImportRequest request,
        string text,
        string fallbackTitle,
        IReadOnlyList<string>? artifactNames = null)
        => CommonParsing.SingleConversation(source, request, text, fallbackTitle, artifactNames);

    public static IReadOnlyList<string> ParticipantNames(ImportRequest request)
        => CommonParsing.ParticipantNames(request);

    public static NormalizedImportResponse ParseTranscript(
        string source,
        ImportRequest request,
        string text,
        string fallbackTitle,
        ParserRegistry registry)
    {
        // Delegate to transcript parser logic via a temporary request override
        var req = request with { Text = text };
        var trimmed = text.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('[') || trimmed.StartsWith('<'))
        {
            return NormalizeLocal("youtube-transcript", req, registry);
        }

        return CommonParsing.SingleConversation(source, req, text, fallbackTitle);
    }

    public static NormalizedImportResponse ParseDiscordMessages(
        string source,
        ImportRequest request,
        string json,
        ParserRegistry registry)
    {
        return NormalizeLocal(source, request with { Text = json }, registry);
    }
}
