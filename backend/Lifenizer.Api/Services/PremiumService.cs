using Coflnet.Payments.Client.Api;
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
    ITopUpApi topUpApi,
    UserAccountService accountService,
    IMemoryCache cache,
    IConfiguration configuration,
    ILogger<PremiumService> logger)
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);
    public bool FreePremiumEnabled => configuration.GetValue<bool>("Payments:FreePremiumEnabled");

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
        if (FreePremiumEnabled && StorageQuota.ForPlan(plan) < StorageQuota.PremiumLimitBytes)
            (plan, expiresAt) = (SubscriptionPlan.Premium, null);
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

        if (string.IsNullOrWhiteSpace(configuration["Payments:BaseUrl"])) return (SubscriptionPlan.Free, null);

        try
        {
            var userIdStr = userId.ToString();
            var plusOwns = await userApi.UserUserIdOwnsUntilPostAsync(
                userIdStr,
                new List<string> { ProductSlugPremiumPlus }, cancellationToken: cancellationToken);
            if (plusOwns?.TryGetValue(ProductSlugPremiumPlus, out var plusExpiry) == true
                && plusExpiry > DateTime.UtcNow)
            {
                var result = (SubscriptionPlan.PremiumPlus, (DateTimeOffset?)plusExpiry);
                cache.Set(cacheKey, result, plusExpiry < DateTime.UtcNow.Add(CacheTtl) ? plusExpiry : DateTime.UtcNow.Add(CacheTtl));
                return result;
            }

            var premiumOwns = await userApi.UserUserIdOwnsUntilPostAsync(
                userIdStr,
                new List<string> { ProductSlugPremium }, cancellationToken: cancellationToken);
            if (premiumOwns?.TryGetValue(ProductSlugPremium, out var premiumExpiry) == true
                && premiumExpiry > DateTime.UtcNow)
            {
                var result = (SubscriptionPlan.Premium, (DateTimeOffset?)premiumExpiry);
                cache.Set(cacheKey, result, premiumExpiry < DateTime.UtcNow.Add(CacheTtl) ? premiumExpiry : DateTime.UtcNow.Add(CacheTtl));
                return result;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
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
            "premium" => ProductSlugPremium,
            _ => throw new ArgumentException("Unknown premium plan.", nameof(plan)),
        };

        if (FreePremiumEnabled)
            throw new InvalidOperationException("Premium is temporarily free; paid checkout is paused.");
        if (string.IsNullOrWhiteSpace(configuration["Payments:BaseUrl"]))
            throw new InvalidOperationException("Payments are not configured.");
        var checkout = await topUpApi.TopUpLemonsqueezySubscribePostAsync(
            userId.ToString(), slug, cancellationToken: cancellationToken);
        if (!Uri.TryCreate(checkout?.DirectLink, UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Payments returned an invalid checkout URL.");
        return url.AbsoluteUri;
    }
}
