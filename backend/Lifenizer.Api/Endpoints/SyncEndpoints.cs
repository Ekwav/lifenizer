using Lifenizer.Api.Data;
using Lifenizer.Api.Security;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using System.Text.Json;

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
            ObjectStore objects,
            PremiumService premium,
            CancellationToken cancellationToken) =>
        {
            var account = await users.GetByIdAsync(user.UserId, cancellationToken);
            if (account is null)
            {
                return Results.Unauthorized();
            }

            var envelopes = (request.Envelopes ?? Array.Empty<SyncEnvelopeDto>()).DistinctBy(envelope => envelope.Id).ToArray();
            var ids = envelopes.Select(envelope => envelope.Id).ToArray();
            var quota = await premium.GetQuotaStatusAsync(account.Id, cancellationToken);
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var existing = await db.SyncEnvelopes.Where(envelope => ids.Contains(envelope.Id))
                .Select(envelope => new { envelope.Id, envelope.UserId }).ToListAsync(cancellationToken);
            if (existing.Any(envelope => envelope.UserId != account.Id))
                return Results.Conflict(new { error = "sync_id_conflict" });
            var existingIds = existing.Select(envelope => envelope.Id).ToHashSet();
            var pending = envelopes.Where(envelope => !existingIds.Contains(envelope.Id)).ToArray();
            if (pending.Any(envelope => string.IsNullOrEmpty(envelope.CipherText)))
                return Results.BadRequest(new { error = "missing_ciphertext" });
            string? key = null;
            var committed = false;
            try
            {
                if (pending.Length > 0)
                {
                    // One immutable object per already-batched client push, never one per entity.
                    var payload = JsonSerializer.SerializeToUtf8Bytes(pending.ToDictionary(e => e.Id, e => e.CipherText));
                    var reserved = await db.Users.Where(user => user.Id == account.Id && user.StorageUsedBytes <= quota.LimitBytes - payload.LongLength)
                        .ExecuteUpdateAsync(setters => setters.SetProperty(user => user.StorageUsedBytes, user => user.StorageUsedBytes + payload.LongLength), cancellationToken);
                    if (reserved == 0) return Results.Json(new { error = "quota_exceeded" }, statusCode: 402);
                    key = $"sync/{account.VaultId:N}/{Guid.NewGuid():N}.json";
                    using var content = new MemoryStream(payload, writable: false);
                    await objects.PutAsync(key, content, "application/json", cancellationToken);
                    foreach (var envelope in pending)
                    {
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
                            BlobKey = key,
                            Nonce = envelope.Nonce,
                            KeyId = envelope.KeyId,
                            ClientCreatedAt = envelope.ClientCreatedAt,
                            ServerReceivedAt = DateTimeOffset.UtcNow
                        });
                    }
                }

                await db.SaveChangesAsync(cancellationToken);
                await transaction.CommitAsync(cancellationToken);
                committed = true;
            }
            finally
            {
                if (!committed && key is not null) await objects.CleanupAsync(key);
            }
            var cursor = await db.SyncEnvelopes
                .Where(e => e.UserId == account.Id)
                .MaxAsync(e => (long?)e.Sequence, cancellationToken) ?? 0;

            return Results.Ok(new PushSyncResponse(cursor, pending.Length));
        });

        group.MapGet("/pull", async (
            [FromQuery] long since,
            ClaimsPrincipalUser user,
            LifenizerDbContext db,
            UserAccountService users,
            ObjectStore objects,
            CancellationToken cancellationToken) =>
        {
            var account = await users.GetByIdAsync(user.UserId, cancellationToken);
            if (account is null)
            {
                return Results.Unauthorized();
            }

            var records = await db.SyncEnvelopes
                .AsNoTracking()
                .Where(e => e.UserId == account.Id && e.Sequence > since)
                .OrderBy(e => e.Sequence)
                .Take(500)
                .ToListAsync(cancellationToken);

            foreach (var batch in records.Where(record => record.BlobKey is not null).GroupBy(record => record.BlobKey!))
            {
                await using var content = await objects.OpenReadAsync(batch.Key, cancellationToken);
                if (content is null) return Results.Problem("A sync batch is unavailable. Retry without changing the cursor.", statusCode: 503);
                var ciphertexts = await JsonSerializer.DeserializeAsync<Dictionary<Guid, string>>(content, cancellationToken: cancellationToken);
                foreach (var record in batch)
                {
                    if (ciphertexts is null || !ciphertexts.TryGetValue(record.Id, out var ciphertext) || string.IsNullOrEmpty(ciphertext))
                        return Results.Problem("A sync batch is incomplete. Retry without changing the cursor.", statusCode: 503);
                    record.CipherText = ciphertext;
                }
            }

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
