using Lifenizer.Core;

namespace Lifenizer.Api.Data;

public sealed class UserAccount
{
    public Guid Id { get; set; }
    public Guid VaultId { get; set; }
    public string VaultSalt { get; set; } = string.Empty;
    public string AuthProviderId { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? DisplayName { get; set; }
    public SubscriptionPlan Plan { get; set; } = SubscriptionPlan.Personal;
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset LastSeenAt { get; set; }
}