using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Lifenizer.Api.Data;

public static class DatabaseSchema
{
    // Adopt the two schemas shipped before migrations: original users/sync/usage, and
    // the same schema with image storage. Existing rows and vault material stay intact.
    public static async Task UpgradeAsync(LifenizerDbContext db, CancellationToken cancellationToken = default)
    {
        await db.Database.OpenConnectionAsync(cancellationToken);
        try
        {
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var connection = db.Database.GetDbConnection();
            await using var command = connection.CreateCommand();
            command.Transaction = transaction.GetDbTransaction();
            command.CommandText = "PRAGMA table_info('Users')";
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken)) columns.Add(reader.GetString(1));
            }
            if (columns.Count > 0 && !columns.Contains(nameof(UserAccount.StorageUsedBytes)))
            {
                await db.Database.ExecuteSqlRawAsync("ALTER TABLE Users ADD COLUMN StorageUsedBytes INTEGER NOT NULL DEFAULT 0", cancellationToken);
            }
            await transaction.CommitAsync(cancellationToken);
        }
        finally
        {
            await db.Database.CloseConnectionAsync();
        }
        await db.Database.MigrateAsync(cancellationToken);
    }
}
