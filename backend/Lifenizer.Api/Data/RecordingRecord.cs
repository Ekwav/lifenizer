namespace Lifenizer.Api.Data;

/// <summary>Encrypted audio blob metadata. Filenames and media details remain inside the envelope.</summary>
public sealed class RecordingRecord
{
    public Guid VaultId { get; set; }
    public string ConversationId { get; set; } = string.Empty;
    public Guid UserId { get; set; }
    public string BlobName { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
}
