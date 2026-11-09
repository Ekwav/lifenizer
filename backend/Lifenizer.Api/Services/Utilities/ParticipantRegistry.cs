using Lifenizer.Core;

namespace Lifenizer.Api.Services.Utilities;

/// <summary>
/// Efficient registry for managing unique participants with case-insensitive deduplication.
/// Uses HashSet internally for O(1) lookups, significantly faster than List.Contains() for larger participant sets.
/// </summary>
public sealed class ParticipantRegistry
{
    private readonly HashSet<string> _participants = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Creates a ParticipantRegistry from an ImportRequest's participant names.
    /// </summary>
    public static ParticipantRegistry FromRequest(ImportRequest request)
    {
        var registry = new ParticipantRegistry();
        if (request.ParticipantNames is not null)
        {
            foreach (var name in request.ParticipantNames)
            {
                registry.TryAdd(name);
            }
        }

        if (request.Metadata is not null && request.Metadata.TryGetValue("participants", out var metadataNames))
        {
            foreach (var name in metadataNames.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            {
                registry.TryAdd(name);
            }
        }

        return registry;
    }

    /// <summary>
    /// Attempts to add a participant name to the registry, handling nulls and whitespace gracefully.
    /// </summary>
    /// <returns>True if the participant was added (new or case-variant), false if already exists (case-insensitive).</returns>
    public bool TryAdd(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        var trimmed = name.Trim();
        return _participants.Add(trimmed);
    }

    /// <summary>
    /// Checks if a participant exists in the registry (case-insensitive).
    /// </summary>
    public bool Contains(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        return _participants.Contains(name.Trim());
    }

    /// <summary>
    /// Returns the registry as a list of NormalizedParticipant objects for API responses.
    /// </summary>
    public IReadOnlyList<NormalizedParticipant> ToParticipants()
    {
        return _participants
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(name => new NormalizedParticipant(name))
            .ToArray();
    }

    /// <summary>
    /// Returns the participants as a sorted list of strings.
    /// </summary>
    public IReadOnlyList<string> ToList()
    {
        return _participants
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    /// <summary>
    /// Returns the participants as a list of strings (unsorted).
    /// </summary>
    public IReadOnlyList<string> ToUnsortedList()
    {
        return _participants.ToArray();
    }

    /// <summary>
    /// Gets the count of unique participants.
    /// </summary>
    public int Count => _participants.Count;
}
