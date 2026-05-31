using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Data;

public sealed class LifenizerDbContext(DbContextOptions<LifenizerDbContext> options) : DbContext(options)
{
    public DbSet<UserAccount> Users => Set<UserAccount>();
    public DbSet<SyncEnvelopeRecord> SyncEnvelopes => Set<SyncEnvelopeRecord>();
    public DbSet<UsageEventRecord> UsageEvents => Set<UsageEventRecord>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<UserAccount>(entity =>
        {
            entity.HasKey(user => user.Id);
            entity.HasIndex(user => user.AuthProviderId).IsUnique();
            entity.HasIndex(user => user.Email);
            entity.Property(user => user.AuthProviderId).HasMaxLength(256);
            entity.Property(user => user.Email).HasMaxLength(320);
            entity.Property(user => user.VaultSalt).HasMaxLength(128);
        });

        modelBuilder.Entity<SyncEnvelopeRecord>(entity =>
        {
            entity.HasKey(envelope => envelope.Sequence);
            entity.HasIndex(envelope => envelope.Id).IsUnique();
            entity.HasIndex(envelope => new { envelope.UserId, envelope.Sequence });
            entity.HasIndex(envelope => new { envelope.VaultId, envelope.EntityType, envelope.EntityId });
            entity.Property(envelope => envelope.DeviceId).HasMaxLength(128);
            entity.Property(envelope => envelope.EntityType).HasMaxLength(64);
            entity.Property(envelope => envelope.EntityId).HasMaxLength(128);
            entity.Property(envelope => envelope.Operation).HasMaxLength(32);
            entity.Property(envelope => envelope.KeyId).HasMaxLength(128);
        });

        modelBuilder.Entity<UsageEventRecord>(entity =>
        {
            entity.HasKey(usage => usage.Id);
            entity.HasIndex(usage => new { usage.UserId, usage.CreatedAt });
            entity.Property(usage => usage.Kind).HasMaxLength(96);
            entity.Property(usage => usage.Unit).HasMaxLength(32);
        });
    }
}