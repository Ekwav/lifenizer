using System.Text.Json;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Mvc;

namespace Lifenizer.Api.Endpoints;

public static class UsageEndpoints
{
    public static IEndpointRouteBuilder MapUsageEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/usage").RequireAuthorization().WithTags("Usage");

        group.MapPost("/events", async (
            [FromBody] UsageEventRequest request,
            ClaimsPrincipalUser user,
            UserAccountService users,
            LifenizerDbContext db,
            CancellationToken cancellationToken) =>
        {
            var account = await users.GetByIdAsync(user.UserId, cancellationToken);
            if (account is null)
            {
                return Results.Unauthorized();
            }

            var record = new UsageEventRecord
            {
                Id = Guid.NewGuid(),
                UserId = account.Id,
                VaultId = account.VaultId,
                Kind = request.Kind,
                Quantity = request.Quantity,
                Unit = request.Unit,
                MetadataJson = JsonSerializer.Serialize(request.Metadata ?? new Dictionary<string, string>()),
                CreatedAt = DateTimeOffset.UtcNow
            };
            db.UsageEvents.Add(record);
            await db.SaveChangesAsync(cancellationToken);

            return Results.Ok(new UsageEventResponse(record.Id, record.CreatedAt));
        });

        return app;
    }
}