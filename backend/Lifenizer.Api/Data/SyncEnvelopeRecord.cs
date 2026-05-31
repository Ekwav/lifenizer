namespace Lifenizer.Api.Data;

public sealed class SyncEnvelopeRecord
{
    public long Sequence { get; set; }
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid VaultId { get; set; }
    public string DeviceId { get; set; } = string.Empty;
    public string EntityType { get; set; } = string.Empty;
    public string EntityId { get; set; } = string.Empty;
    public string Operation { get; set; } = string.Empty;
    public int Revision { get; set; }
    public string CipherText { get; set; } = string.Empty;
    public string Nonce { get; set; } = string.Empty;
    public string KeyId { get; set; } = string.Empty;
    public DateTimeOffset ClientCreatedAt { get; set; }
    public DateTimeOffset ServerReceivedAt { get; set; }
}