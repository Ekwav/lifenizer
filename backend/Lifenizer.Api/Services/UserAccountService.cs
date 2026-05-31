using Lifenizer.Api.Data;
using Lifenizer.Core;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Services;

public sealed class UserAccountService(LifenizerDbContext db)
{
    public async Task<UserAccount> GetOrCreateExternalUserAsync(
        string authProviderId,
        string? email,
        string? displayName,
        CancellationToken cancellationToken)
    {
        var normalizedProviderId = authProviderId.Trim();
        var existing = await db.Users.FirstOrDefaultAsync(
            user => user.AuthProviderId == normalizedProviderId,
            cancellationToken);

        if (existing is not null)
        {
            existing.LastSeenAt = DateTimeOffset.UtcNow;
            if (!string.IsNullOrWhiteSpace(email))
            {
                existing.Email = email.Trim();
            }
            if (!string.IsNullOrWhiteSpace(displayName))
            {
                existing.DisplayName = displayName.Trim();
            }
            await db.SaveChangesAsync(cancellationToken);
            return existing;
        }

        var now = DateTimeOffset.UtcNow;
        var user = new UserAccount
        {
            Id = Guid.NewGuid(),
            VaultId = Guid.NewGuid(),
            VaultSalt = Convert.ToBase64String(Guid.NewGuid().ToByteArray()),
            AuthProviderId = normalizedProviderId,
            Email = string.IsNullOrWhiteSpace(email) ? null : email.Trim(),
            DisplayName = string.IsNullOrWhiteSpace(displayName) ? null : displayName.Trim(),
            Plan = SubscriptionPlan.Free,
            CreatedAt = now,
            LastSeenAt = now
        };

        db.Users.Add(user);
        await db.SaveChangesAsync(cancellationToken);
        return user;
    }

    public Task<UserAccount?> GetByIdAsync(Guid userId, CancellationToken cancellationToken)
    {
        return db.Users.FirstOrDefaultAsync(user => user.Id == userId, cancellationToken);
    }

    /// <summary>
    /// Atomically adjusts <see cref="UserAccount.StorageUsedBytes"/> and returns the
    /// updated value. Negative <paramref name="deltaBytes"/> decrements usage.
    /// The value is clamped to zero on the way down to avoid negative usage from
    /// concurrent deletes of already-deleted files.
    /// </summary>
    public async Task<long> AdjustStorageUsageAsync(
        Guid userId,
        long deltaBytes,
        CancellationToken cancellationToken)
    {
        var user = await db.Users.FirstOrDefaultAsync(u => u.Id == userId, cancellationToken)
            ?? throw new InvalidOperationException($"User {userId} not found.");

        user.StorageUsedBytes = Math.Max(0, user.StorageUsedBytes + deltaBytes);
        await db.SaveChangesAsync(cancellationToken);
        return user.StorageUsedBytes;
    }

    /// <summary>
    /// Promotes a user's <see cref="SubscriptionPlan"/> and persists the change.
    /// Called by <see cref="PremiumService"/> after a webhook or status refresh.
    /// </summary>
    public async Task SetPlanAsync(
        Guid userId,
        SubscriptionPlan plan,
        CancellationToken cancellationToken)
    {
        var user = await db.Users.FirstOrDefaultAsync(u => u.Id == userId, cancellationToken)
            ?? throw new InvalidOperationException($"User {userId} not found.");

        user.Plan = plan;
        await db.SaveChangesAsync(cancellationToken);
    }
}
