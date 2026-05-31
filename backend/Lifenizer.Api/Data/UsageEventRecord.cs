namespace Lifenizer.Api.Data;

public sealed class UsageEventRecord
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid VaultId { get; set; }
    public string Kind { get; set; } = string.Empty;
    public double Quantity { get; set; }
    public string Unit { get; set; } = string.Empty;
    public string MetadataJson { get; set; } = "{}";
    public DateTimeOffset CreatedAt { get; set; }
}