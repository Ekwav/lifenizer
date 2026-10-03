using System.Security.Cryptography;
using Lifenizer.Api.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.Sqlite;
using Lifenizer.Core;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Services;

public sealed class UserAccountService(LifenizerDbContext db, IPasswordHasher<UserAccount> passwordHasher)
{
    public async Task<UserAccount?> RegisterAsync(string email, string password, string? displayName, CancellationToken cancellationToken)
    {
        var normalizedEmail = email.Trim().ToLowerInvariant();
        // Never bind a new password to an existing development/external vault.
        if (await db.Users.AnyAsync(user => user.Email != null && user.Email.ToLower() == normalizedEmail, cancellationToken)) return null;
        var now = DateTimeOffset.UtcNow;
        var account = new UserAccount
        {
            Id = Guid.NewGuid(), VaultId = Guid.NewGuid(),
            VaultSalt = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)),
            AuthProviderId = $"local:{normalizedEmail}", Email = normalizedEmail,
            DisplayName = displayName?.Trim(), CreatedAt = now, LastSeenAt = now
        };
        account.PasswordHash = passwordHasher.HashPassword(account, password);
        db.Users.Add(account);
        try { await db.SaveChangesAsync(cancellationToken); }
        catch (DbUpdateException exception) when (exception.InnerException is SqliteException { SqliteErrorCode: 19 })
        {
            // The unique provider ID also handles concurrent registrations.
            return null;
        }
        return account;
    }

    public async Task<UserAccount?> LoginAsync(string email, string password, CancellationToken cancellationToken)
    {
        var providerId = $"local:{email.Trim().ToLowerInvariant()}";
        var account = await db.Users.SingleOrDefaultAsync(user => user.AuthProviderId == providerId, cancellationToken);
        if (account?.PasswordHash is null)
        {
            // Match password verification cost without revealing whether the account exists.
            passwordHasher.HashPassword(new UserAccount(), password);
            return null;
        }
        var result = passwordHasher.VerifyHashedPassword(account, account.PasswordHash, password);
        if (result == PasswordVerificationResult.Failed) return null;
        if (result == PasswordVerificationResult.SuccessRehashNeeded)
            account.PasswordHash = passwordHasher.HashPassword(account, password);
        account.LastSeenAt = DateTimeOffset.UtcNow;
        await db.SaveChangesAsync(cancellationToken);
        return account;
    }

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
        var changed = await db.Users.Where(user => user.Id == userId).ExecuteUpdateAsync(
            setters => setters.SetProperty(user => user.StorageUsedBytes, user => Math.Max(0, user.StorageUsedBytes + deltaBytes)),
            cancellationToken);
        if (changed == 0) throw new InvalidOperationException($"User {userId} not found.");
        return await db.Users.Where(user => user.Id == userId).Select(user => user.StorageUsedBytes).SingleAsync(cancellationToken);
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
