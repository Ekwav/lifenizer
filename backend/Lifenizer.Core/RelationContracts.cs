namespace Lifenizer.Core;

public sealed record RelationExtractionRequest(
    string Text,
    IReadOnlyList<string>? KnownParticipants = null,
    string? EvidenceSegmentId = null);

public sealed record ExtractedRelation(
    string Subject,
    string Relation,
    string Object,
    double Confidence,
    string Evidence,
    string? EvidenceSegmentId = null);

public sealed record RelationExtractionResponse(
    bool PlaintextCompute,
    string Compromise,
    IReadOnlyList<ExtractedRelation> Relations);