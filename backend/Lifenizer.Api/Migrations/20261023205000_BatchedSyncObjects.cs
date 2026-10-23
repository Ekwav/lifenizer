using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Lifenizer.Api.Migrations
{
    /// <inheritdoc />
    public partial class BatchedSyncObjects : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "BlobKey",
                table: "SyncEnvelopes",
                type: "TEXT",
                maxLength: 512,
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // A downgrade cannot put remote ciphertext back into SQLite. Abort
            // before dropping its references; restore the pre-upgrade backup instead.
            migrationBuilder.Sql("""
                CREATE TEMP TABLE SyncDowngradeGuard (Count INTEGER CHECK (Count = 0));
                INSERT INTO SyncDowngradeGuard SELECT COUNT(*) FROM SyncEnvelopes WHERE BlobKey IS NOT NULL;
                DROP TABLE SyncDowngradeGuard;
                """);
            migrationBuilder.DropColumn(
                name: "BlobKey",
                table: "SyncEnvelopes");
        }
    }
}
