using Lifenizer.Core;

namespace Lifenizer.Api.Services.Parsers;

/// <summary>
/// Registry for import format parsers, enabling dictionary-based dispatch and dynamic registration.
/// Replaces massive switch statement with extensible plugin architecture.
/// </summary>
public sealed class ParserRegistry
{
    private readonly Dictionary<string, IImportParser> _parsers = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Registers a parser for the given source format.
    /// </summary>
    /// <param name="parser">The parser to register.</param>
    public void Register(IImportParser parser)
    {
        _parsers[parser.Source] = parser;
    }

    /// <summary>
    /// Registers multiple parsers at once.
    /// </summary>
    /// <param name="parsers">The parsers to register.</param>
    public void RegisterAll(params IImportParser[] parsers)
    {
        foreach (var parser in parsers)
        {
            Register(parser);
        }
    }

    /// <summary>
    /// Parses an import request using the appropriate registered parser, or falls back to a single conversation if parser not found.
    /// </summary>
    /// <param name="source">The source format identifier.</param>
    /// <param name="request">The import request to parse.</param>
    /// <returns>A normalized import response.</returns>
    public NormalizedImportResponse Parse(string source, ImportRequest request)
    {
        if (_parsers.TryGetValue(source, out var parser))
        {
            return parser.Parse(request);
        }

        // Fallback: treat as manual import
        return CommonParsing.SingleConversation(source, request, CommonParsing.EffectiveText(request), "Imported data");
    }

    /// <summary>
    /// Checks if a parser is registered for the given source.
    /// </summary>
    public bool HasParser(string source) => _parsers.ContainsKey(source);

    /// <summary>
    /// Gets all registered source identifiers.
    /// </summary>
    public IReadOnlyCollection<string> RegisteredSources => _parsers.Keys;
}
