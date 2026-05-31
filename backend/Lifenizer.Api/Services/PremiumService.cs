using Coflnet.Payments.Client.Api;
using Coflnet.Payments.Client.Model;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.Extensions.Caching.Memory;

namespace Lifenizer.Api.Services;

/// <summary>
/// Resolves a user's subscription tier by querying the Coflnet payments API,
/// caches the result for 5 minutes, and updates the local user record when the
/// tier changes.
/// </summary>
public sealed class PremiumService(
    IUserApi userApi,
    UserAccountService accountService,
    IMemoryCache cache,
    IConfiguration configuration,
    ILogger<PremiumService> logger)
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);

    private string ProductSlugPremium => configuration["Products:Premium"] ?? "lifenizer-premium";
    private string ProductSlugPremiumPlus => configuration["Products:PremiumPlus"] ?? "lifenizer-premium-plus";

    public sealed record QuotaStatus(
        SubscriptionPlan Plan,
        string PlanName,
        long UsedBytes,
        long LimitBytes,
        DateTimeOffset? ExpiresAt);

    /// <summary>
    /// Returns the current quota status for <paramref name="userId"/>.
    /// The subscription tier is determined by the payments API and cached.
    /// </summary>
    public async Task<QuotaStatus> GetQuotaStatusAsync(Guid userId, CancellationToken cancellationToken)
    {
        var (plan, expiresAt) = await ResolvePlanAsync(userId, cancellationToken);
        var user = await accountService.GetByIdAsync(userId, cancellationToken)
            ?? throw new InvalidOperationException($"User {userId} not found.");

        // Sync plan to db if it changed.
        if (user.Plan != plan)
        {
            await accountService.SetPlanAsync(userId, plan, cancellationToken);
            user = await accountService.GetByIdAsync(userId, cancellationToken)!;
        }

        return new QuotaStatus(
            plan,
            plan.ToString(),
            user!.StorageUsedBytes,
            StorageQuota.ForPlan(plan),
            expiresAt);
    }

    private async Task<(SubscriptionPlan Plan, DateTimeOffset? ExpiresAt)> ResolvePlanAsync(
        Guid userId,
        CancellationToken cancellationToken)
    {
        var cacheKey = $"premium:{userId}";
        if (cache.TryGetValue(cacheKey, out (SubscriptionPlan, DateTimeOffset?) cached))
        {
            return cached;
        }

        try
        {
            var userIdStr = userId.ToString();
            var plusOwns = await userApi.UserUserIdOwnsUntilPostAsync(
                userIdStr,
                new List<string> { ProductSlugPremiumPlus });
            if (plusOwns?.TryGetValue(ProductSlugPremiumPlus, out var plusExpiry) == true
                && plusExpiry > DateTime.UtcNow)
            {
                var result = (SubscriptionPlan.PremiumPlus, (DateTimeOffset?)plusExpiry);
                cache.Set(cacheKey, result, CacheTtl);
                return result;
            }

            var premiumOwns = await userApi.UserUserIdOwnsUntilPostAsync(
                userIdStr,
                new List<string> { ProductSlugPremium });
            if (premiumOwns?.TryGetValue(ProductSlugPremium, out var premiumExpiry) == true
                && premiumExpiry > DateTime.UtcNow)
            {
                var result = (SubscriptionPlan.Premium, (DateTimeOffset?)premiumExpiry);
                cache.Set(cacheKey, result, CacheTtl);
                return result;
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Payments API unavailable for user {UserId}, defaulting to Free.", userId);
        }

        var free = (SubscriptionPlan.Free, (DateTimeOffset?)null);
        cache.Set(cacheKey, free, CacheTtl);
        return free;
    }

    /// <summary>
    /// Creates a LemonSqueezy checkout URL for the given product slug and returns it.
    /// </summary>
    public async Task<string> CreateCheckoutUrlAsync(
        Guid userId,
        string plan,
        CancellationToken cancellationToken)
    {
        var slug = plan.ToLowerInvariant() switch
        {
            "premium-plus" or "premiumplus" => ProductSlugPremiumPlus,
            _ => ProductSlugPremium,
        };

        // POST /TopUp/lemonsqueezy/subscribe
        // The Coflnet.Payments.Client wraps this via ITopUpApi.
        // We return a redirect URL the client can open in a browser.
        var baseUrl = configuration["Payments:BaseUrl"]
            ?? throw new InvalidOperationException("Payments:BaseUrl is not configured.");
        return $"{baseUrl.TrimEnd('/')}/TopUp/lemonsqueezy/subscribe?userId={userId}&productId={slug}";
    }
}
