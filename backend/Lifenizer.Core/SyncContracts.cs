namespace Lifenizer.Core;

public sealed record SyncEnvelopeDto(
    Guid Id,
    string DeviceId,
    string EntityType,
    string EntityId,
    string Operation,
    int Revision,
    string CipherText,
    string Nonce,
    string KeyId,
    DateTimeOffset ClientCreatedAt,
    long ServerSequence = 0);

public sealed record PushSyncRequest(IReadOnlyList<SyncEnvelopeDto> Envelopes);

public sealed record PushSyncResponse(long Cursor, int Accepted);

public sealed record PullSyncResponse(long Cursor, IReadOnlyList<SyncEnvelopeDto> Envelopes);