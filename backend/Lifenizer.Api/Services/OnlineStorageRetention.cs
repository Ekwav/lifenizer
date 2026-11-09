using Lifenizer.Api.Data;
using Lifenizer.Api.Endpoints;
using Lifenizer.Core;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Services;

public sealed class OnlineStorageRetention(LifenizerDbContext db, PremiumService premium, ObjectStore objects, ILogger<OnlineStorageRetention> logger)
{
    public async Task DeleteDueAsync(CancellationToken token)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var candidates = await db.Users.AsNoTracking()
            .Where(user => user.OnlineStorageDeleteAtUnixSeconds <= now)
            .Select(user => new { user.Id, user.OnlineStorageDeleteAtUnixSeconds }).ToListAsync(token);
        foreach (var candidate in candidates)
        {
            try
            {
                // Microsoft.Data.Sqlite starts an immediate transaction: other replicas, activation,
                // and upload reservations cannot change ownership or eligibility during object deletion.
                await using var transaction = await db.Database.BeginTransactionAsync(token);
                var user = await db.Users.AsNoTracking().SingleAsync(user => user.Id == candidate.Id, token);
                if (user.OnlineStorageDeleteAtUnixSeconds != candidate.OnlineStorageDeleteAtUnixSeconds
                    || user.OnlineStorageDeleteAtUnixSeconds > DateTimeOffset.UtcNow.ToUnixTimeSeconds()) continue;
                var (paid, _) = await premium.ResolvePlanAsync(user.Id, token, requireAvailable: true);
                if (paid != SubscriptionPlan.Free || (premium.FreePremiumEnabled && user.FreePremiumActivatedAt is not null))
                {
                    await db.Users.Where(account => account.Id == user.Id).ExecuteUpdateAsync(
                        setters => setters.SetProperty(account => account.OnlineStorageDeleteAtUnixSeconds, (long?)null), token);
                    await transaction.CommitAsync(token);
                    continue;
                }

                var syncKeys = await db.SyncEnvelopes.Where(record => record.UserId == user.Id && record.BlobKey != null)
                    .Select(record => record.BlobKey!).Distinct().ToListAsync(token);
                var imageKeys = await db.Images.Where(record => record.UserId == user.Id).Select(record => record.BlobPath).ToListAsync(token);
                var recordings = await db.Recordings.Where(record => record.UserId == user.Id)
                    .Select(record => new { record.VaultId, record.BlobName }).ToListAsync(token);
                // Retain every reference on failure, including references to objects already deleted;
                // DeleteAsync is idempotent, so a later run can safely finish the same deletion.
                await objects.DeleteManyAsync(syncKeys.Concat(imageKeys).Concat(recordings.Select(record => RecordingEndpoints.ObjectKey(record.VaultId, record.BlobName))), token);
                await db.SyncEnvelopes.Where(record => record.UserId == user.Id).ExecuteDeleteAsync(token);
                await db.Images.Where(record => record.UserId == user.Id).ExecuteDeleteAsync(token);
                await db.Recordings.Where(record => record.UserId == user.Id).ExecuteDeleteAsync(token);
                await db.Users.Where(account => account.Id == user.Id).ExecuteUpdateAsync(
                    setters => setters.SetProperty(account => account.StorageUsedBytes, 0L), token);
                // Keep the expired deadline until reactivation to block stale upload quota decisions.
                await transaction.CommitAsync(token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception error) { logger.LogError(error, "Online storage retention failed for user {UserId}; references retained for retry", candidate.Id); }
        }
    }
}

public sealed class OnlineStorageRetentionWorker(IServiceScopeFactory scopes, ILogger<OnlineStorageRetentionWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        do
        {
            try
            {
                using var scope = scopes.CreateScope();
                await scope.ServiceProvider.GetRequiredService<OnlineStorageRetention>().DeleteDueAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception error) { logger.LogError(error, "Online storage retention failed; retained deletion references will be retried"); }
            try { await Task.Delay(TimeSpan.FromHours(1), stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
        } while (!stoppingToken.IsCancellationRequested);
    }
}
