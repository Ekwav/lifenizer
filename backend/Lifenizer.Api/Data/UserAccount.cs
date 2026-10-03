using Lifenizer.Core;

namespace Lifenizer.Api.Data;

public sealed class UserAccount
{
    public Guid Id { get; set; }
    public Guid VaultId { get; set; }
    public string VaultSalt { get; set; } = string.Empty;
    public string AuthProviderId { get; set; } = string.Empty;
    public string? PasswordHash { get; set; }
    public string? Email { get; set; }
    public string? DisplayName { get; set; }
    public SubscriptionPlan Plan { get; set; } = SubscriptionPlan.Free;
    /// <summary>
    /// Running total of image artifact bytes stored for this user. Sync envelopes are not counted.
    /// Incremented on upload / push, decremented on delete.
    /// </summary>
    public long StorageUsedBytes { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset LastSeenAt { get; set; }

    /// <summary>Quota in bytes derived from the current plan.</summary>
    public long QuotaBytes => StorageQuota.ForPlan(Plan);
    public long StorageAvailableBytes => Math.Max(0, QuotaBytes - StorageUsedBytes);
}
