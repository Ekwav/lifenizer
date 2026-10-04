using Lifenizer.Api.Data;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Tests;

public sealed class DatabaseUpgradeTests
{
    [TestCase("new")]
    [TestCase("legacy")]
    [TestCase("current")]
    public async Task UpgradePreservesDataAndIsRepeatable(string schema)
    {
        var path = Path.Combine(Path.GetTempPath(), $"lifenizer-schema-{Guid.NewGuid():N}.db");
        var options = new DbContextOptionsBuilder<LifenizerDbContext>().UseSqlite($"Data Source={path}").Options;
        var userId = Guid.NewGuid();
        var vaultId = Guid.NewGuid();
        try
        {
            await using var db = new LifenizerDbContext(options);
            if (schema != "new")
            {
                await db.Database.EnsureCreatedAsync();
                db.Users.Add(new UserAccount { Id = userId, VaultId = vaultId, VaultSalt = "unchanged-salt", AuthProviderId = "dev:existing", StorageUsedBytes = 123 });
                db.SyncEnvelopes.Add(new SyncEnvelopeRecord { Id = Guid.NewGuid(), UserId = userId, VaultId = vaultId, CipherText = "original-ciphertext" });
                db.UsageEvents.Add(new UsageEventRecord { Id = Guid.NewGuid(), UserId = userId, VaultId = vaultId, MetadataJson = "{\"preserve\":true}" });
                if (schema == "current")
                    db.Images.Add(new ImageRecord { Id = Guid.NewGuid(), UserId = userId, BlobPath = "existing-image", SizeBytes = 123 });
                await db.SaveChangesAsync();
                await db.Database.ExecuteSqlRawAsync("ALTER TABLE Users DROP COLUMN PasswordHash");
                await db.Database.ExecuteSqlRawAsync("DROP TABLE PairingStates");
                await db.Database.ExecuteSqlRawAsync("DROP TABLE PairingRequests");
                await db.Database.ExecuteSqlRawAsync("DROP TABLE PairedDevices");
                if (schema == "legacy")
                {
                    await db.Database.ExecuteSqlRawAsync("ALTER TABLE Users DROP COLUMN StorageUsedBytes");
                    await db.Database.ExecuteSqlRawAsync("DROP TABLE Images");
                }
                db.ChangeTracker.Clear();
            }

            await DatabaseSchema.UpgradeAsync(db);
            await DatabaseSchema.UpgradeAsync(db);
            Assert.That(await db.Database.GetAppliedMigrationsAsync(), Is.Not.Empty);
            Assert.That(await db.Images.CountAsync(), Is.EqualTo(schema == "current" ? 1 : 0));
            Assert.That(await db.PairingStates.CountAsync(), Is.Zero);
            Assert.That(await db.PairingRequests.CountAsync(), Is.Zero);
            Assert.That(await db.PairedDevices.CountAsync(), Is.Zero);
            if (schema != "new")
            {
                var account = await db.Users.SingleAsync();
                Assert.Multiple(() =>
                {
                    Assert.That(account.Id, Is.EqualTo(userId));
                    Assert.That(account.VaultId, Is.EqualTo(vaultId));
                    Assert.That(account.VaultSalt, Is.EqualTo("unchanged-salt"));
                    Assert.That(account.StorageUsedBytes, Is.EqualTo(schema == "legacy" ? 0 : 123));
                });
                Assert.That((await db.SyncEnvelopes.SingleAsync()).CipherText, Is.EqualTo("original-ciphertext"));
                Assert.That((await db.UsageEvents.SingleAsync()).MetadataJson, Is.EqualTo("{\"preserve\":true}"));
            }
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            File.Delete(path);
        }
    }
}
