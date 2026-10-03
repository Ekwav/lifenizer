using Lifenizer.Api.Data;
using Lifenizer.Api.Security;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Endpoints;

public static class SyncEndpoints
{
    public static IEndpointRouteBuilder MapSyncEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/sync").RequireAuthorization().WithTags("Sync");

        group.MapPost("/push", async (
            [FromBody] PushSyncRequest request,
            ClaimsPrincipalUser user,
            LifenizerDbContext db,
            UserAccountService users,
            CancellationToken cancellationToken) =>
        {
            var account = await users.GetByIdAsync(user.UserId, cancellationToken);
            if (account is null)
            {
                return Results.Unauthorized();
            }

            var envelopes = (request.Envelopes ?? Array.Empty<SyncEnvelopeDto>()).DistinctBy(envelope => envelope.Id).ToArray();
            var ids = envelopes.Select(envelope => envelope.Id).ToArray();
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var existing = await db.SyncEnvelopes.Where(envelope => ids.Contains(envelope.Id))
                .Select(envelope => new { envelope.Id, envelope.UserId }).ToListAsync(cancellationToken);
            if (existing.Any(envelope => envelope.UserId != account.Id))
                return Results.Conflict(new { error = "sync_id_conflict" });
            var existingIds = existing.Select(envelope => envelope.Id).ToHashSet();
            var accepted = 0;
            foreach (var envelope in envelopes)
            {
                if (existingIds.Contains(envelope.Id)) continue;

                db.SyncEnvelopes.Add(new SyncEnvelopeRecord
                {
                    Id = envelope.Id,
                    UserId = account.Id,
                    VaultId = account.VaultId,
                    DeviceId = envelope.DeviceId,
                    EntityType = envelope.EntityType,
                    EntityId = envelope.EntityId,
                    Operation = envelope.Operation,
                    Revision = envelope.Revision,
                    CipherText = envelope.CipherText,
                    Nonce = envelope.Nonce,
                    KeyId = envelope.KeyId,
                    ClientCreatedAt = envelope.ClientCreatedAt,
                    ServerReceivedAt = DateTimeOffset.UtcNow
                });
                accepted++;
            }

            await db.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            var cursor = await db.SyncEnvelopes
                .Where(e => e.UserId == account.Id)
                .MaxAsync(e => (long?)e.Sequence, cancellationToken) ?? 0;

            return Results.Ok(new PushSyncResponse(cursor, accepted));
        });

        group.MapGet("/pull", async (
            [FromQuery] long since,
            ClaimsPrincipalUser user,
            LifenizerDbContext db,
            UserAccountService users,
            CancellationToken cancellationToken) =>
        {
            var account = await users.GetByIdAsync(user.UserId, cancellationToken);
            if (account is null)
            {
                return Results.Unauthorized();
            }

            var records = await db.SyncEnvelopes
                .Where(e => e.UserId == account.Id && e.Sequence > since)
                .OrderBy(e => e.Sequence)
                .Take(500)
                .ToListAsync(cancellationToken);

            var cursor = records.Count == 0
                ? since
                : records[^1].Sequence;

            return Results.Ok(new PullSyncResponse(cursor, records.Select(ToDto).ToArray()));
        });

        return app;
    }

    private static SyncEnvelopeDto ToDto(SyncEnvelopeRecord record)
    {
        return new SyncEnvelopeDto(
            record.Id,
            record.DeviceId,
            record.EntityType,
            record.EntityId,
            record.Operation,
            record.Revision,
            record.CipherText,
            record.Nonce,
            record.KeyId,
            record.ClientCreatedAt,
            record.Sequence);
    }
}

public sealed class ClaimsPrincipalUser(IHttpContextAccessor accessor)
{
    public Guid UserId => accessor.HttpContext?.User.GetUserId()
        ?? throw new InvalidOperationException("No authenticated user is available.");
}