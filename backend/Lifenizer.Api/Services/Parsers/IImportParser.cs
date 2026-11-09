using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Interface for import format parsers. Implementing Strategy pattern for extensible import handling.
/// </summary>
public interface IImportParser
{
    /// <summary>
    /// Gets the source identifier for this parser (e.g., "telegram", "discord", "whatsapp").
    /// </summary>
    string Source { get; }

    /// <summary>
    /// Parses the import request and returns normalized conversation data.
    /// </summary>
    /// <param name="request">The import request containing text, metadata, and participant information.</param>
    /// <returns>A normalized import response with parsed conversations.</returns>
    NormalizedImportResponse Parse(ImportRequest request);
}
