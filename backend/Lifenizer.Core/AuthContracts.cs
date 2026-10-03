namespace Lifenizer.Core;

public sealed record TokenContainer(string AuthToken);

public sealed record DevLoginRequest(
    string Email,
    string? DisplayName = null,
    string? ProviderId = null);

public sealed record RegisterAccountRequest(string Email, string Password, string? DisplayName = null);

public sealed record AccountLoginRequest(string Email, string Password);

public sealed record AuthResponse(
    string AuthToken,
    Guid UserId,
    Guid VaultId,
    string VaultSalt,
    string TokenType = "Bearer");

public enum SubscriptionPlan
{
    Personal = 0,
    Hosted = 1,
    Team = 2,
    /// <summary>Free tier — 50 MB image storage.</summary>
    Free = 10,
    /// <summary>Premium tier (4.99 €/month) — 10 GB image storage.</summary>
    Premium = 11,
    /// <summary>PremiumPlus tier (19.99 €/month) — 100 GB image storage.</summary>
    PremiumPlus = 12,
}

public static class StorageQuota
{
    public const long FreeLimitBytes     = 50L  * 1024 * 1024;        //  50 MB
    public const long PremiumLimitBytes  = 10L  * 1024 * 1024 * 1024; //  10 GB
    public const long PremiumPlusLimitBytes = 100L * 1024 * 1024 * 1024; // 100 GB

    public static long ForPlan(SubscriptionPlan plan) => plan switch
    {
        SubscriptionPlan.Premium     => PremiumLimitBytes,
        SubscriptionPlan.PremiumPlus => PremiumPlusLimitBytes,
        _                            => FreeLimitBytes,
    };
}
