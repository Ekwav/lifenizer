namespace Lifenizer.Api.Data;

/// <summary>
/// Metadata for a user-uploaded image artifact.
/// The binary content is stored under <c>BlobPath</c> in the configured object store.
/// </summary>
public sealed class ImageRecord
{
    public Guid   Id          { get; set; }
    public Guid   UserId      { get; set; }
    /// <summary>Original client-side filename (sanitised before storing).</summary>
    public string FileName    { get; set; } = string.Empty;
    public string ContentType { get; set; } = "image/jpeg";
    /// <summary>File size in bytes at the time of upload.</summary>
    public long   SizeBytes   { get; set; }
    /// <summary>Path relative to the blob root directory.</summary>
    public string BlobPath    { get; set; } = string.Empty;
    /// <summary>Optional reference to a conversation that owns this image.</summary>
    public string? ConversationId { get; set; }
    public DateTimeOffset UploadedAt { get; set; }
}
