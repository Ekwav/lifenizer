using Lifenizer.Api.Data;
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
}