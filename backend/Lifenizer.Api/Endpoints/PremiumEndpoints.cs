using Coflnet.Payments.Client.Client;
using Lifenizer.Api.Security;
using Lifenizer.Api.Services;

namespace Lifenizer.Api.Endpoints;

public static class PremiumEndpoints
{
    public static IEndpointRouteBuilder MapPremiumEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/premium").WithTags("Premium").RequireAuthorization();

        // GET /api/premium/status
        group.MapGet("/status", async (
            ClaimsPrincipalUser currentUser,
            PremiumService premium,
            CancellationToken cancellationToken) =>
        {
            var status = await premium.GetQuotaStatusAsync(currentUser.UserId, cancellationToken);
            return QuotaResponse(premium, status);
        });

        group.MapPost("/activate", async (
            ClaimsPrincipalUser currentUser,
            PremiumService premium,
            CancellationToken cancellationToken) =>
        {
            if (!premium.FreePremiumEnabled)
                return Results.Conflict(new { error = "free_premium_unavailable" });
            var status = await premium.ActivateFreePremiumAsync(currentUser.UserId, cancellationToken);
            return QuotaResponse(premium, status);
        });

        group.MapPost("/cancel-free", async (
            ClaimsPrincipalUser currentUser,
            PremiumService premium,
            CancellationToken cancellationToken) =>
        {
            try
            {
                var status = await premium.CancelFreePremiumAsync(currentUser.UserId, cancellationToken);
                return QuotaResponse(premium, status);
            }
            catch (InvalidOperationException)
            {
                return Results.Json(new { error = "free_premium_cancellation_unavailable" }, statusCode: 503);
            }
        });

        // POST /api/premium/checkout/{plan}
        // plan: "premium" or "premium-plus"
        group.MapPost("/checkout/{plan}", async (
            string plan,
            ClaimsPrincipalUser currentUser,
            PremiumService premium,
            CancellationToken cancellationToken,
            ILogger<PremiumService> logger) =>
        {
            try
            {
                var url = await premium.CreateCheckoutUrlAsync(currentUser.UserId, plan, cancellationToken);
                return Results.Ok(new { checkoutUrl = url });
            }
            catch (ArgumentException) { return Results.BadRequest(new { error = "unknown_plan" }); }
            catch (Exception error) when (error is ApiException or InvalidOperationException)
            {
                logger.LogWarning(error, "Unable to create subscription checkout");
                return Results.Json(new { error = "checkout_unavailable" }, statusCode: 503);
            }
        });

        return app;
    }

    private static IResult QuotaResponse(PremiumService premium, PremiumService.QuotaStatus status) => Results.Ok(new
    {
        plan = status.PlanName,
        usedBytes = status.UsedBytes,
        limitBytes = status.LimitBytes,
        expiresAt = status.ExpiresAt,
        freePremiumEnabled = premium.FreePremiumEnabled,
        freePremiumActivatedAt = status.FreePremiumActivatedAt,
        usedPercent = status.LimitBytes > 0 ? (double)status.UsedBytes / status.LimitBytes * 100.0 : 0,
    });
}
