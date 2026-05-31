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
            return Results.Ok(new
            {
                plan = status.Plan.ToString(),
                usedBytes = status.UsedBytes,
                limitBytes = status.LimitBytes,
                expiresAt = status.ExpiresAt,
                usedPercent = status.LimitBytes > 0
                    ? (double)status.UsedBytes / status.LimitBytes * 100.0
                    : 0,
            });
        });

        // POST /api/premium/checkout/{plan}
        // plan: "premium" or "premium-plus"
        group.MapPost("/checkout/{plan}", async (
            string plan,
            ClaimsPrincipalUser currentUser,
            PremiumService premium,
            CancellationToken cancellationToken) =>
        {
            var url = await premium.CreateCheckoutUrlAsync(currentUser.UserId, plan, cancellationToken);
            return Results.Ok(new { checkoutUrl = url });
        });

        return app;
    }
}
