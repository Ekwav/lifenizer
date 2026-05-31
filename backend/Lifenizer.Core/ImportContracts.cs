namespace Lifenizer.Core;

public sealed record ImportCapability(
    string Source,
    string DisplayName,
    bool AvailableNow,
    bool RequiresCredentials,
    string Status,
    string[] AcceptedFormats);

public sealed record ImportRequest(
    string? Title = null,
    string? Text = null,
    string? OriginalFileName = null,
    string? MimeType = null,
    IReadOnlyList<string>? ParticipantIds = null,
    Dictionary<string, string>? Metadata = null,
    IReadOnlyList<string>? ParticipantNames = null,
    string? PayloadBase64 = null);

public sealed record ImportJobResponse(
    Guid JobId,
    string Source,
    string Status,
    bool Placeholder,
    string Message);