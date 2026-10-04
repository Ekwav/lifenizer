namespace Lifenizer.Core;

public sealed record NormalizedImportResponse(
    string Source,
    bool PlaintextCompute,
    string Message,
    IReadOnlyList<NormalizedConversation> Conversations,
    IReadOnlyList<NormalizedParticipant> Participants,
    IReadOnlyDictionary<string, string>? Diagnostics = null);

public sealed record NormalizedParticipant(
    string DisplayName,
    IReadOnlyList<string>? Identifiers = null,
    IReadOnlyList<string>? Aliases = null);

public sealed record NormalizedConversation(
    string Title,
    string Source,
    IReadOnlyList<string> ParticipantNames,
    IReadOnlyList<NormalizedSegment> Segments,
    IReadOnlyList<string>? ArtifactNames = null,
    IReadOnlyDictionary<string, string>? Metadata = null,
    IReadOnlyList<string>? ParticipantIdentifiers = null,
    string? SourceThreadId = null,
    string? SourceUrl = null);

public sealed record NormalizedSegment(
    string Text,
    string? ParticipantName = null,
    int OffsetMs = 0,
    DateTimeOffset? CreatedAt = null,
    string? ParticipantIdentifier = null,
    string? SourceMessageId = null,
    IReadOnlyList<string>? AttachmentUrls = null);
