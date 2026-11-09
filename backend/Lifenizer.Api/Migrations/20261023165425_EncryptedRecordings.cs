using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Lifenizer.Api.Migrations
{
    /// <inheritdoc />
    public partial class EncryptedRecordings : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "Recordings",
                columns: table => new
                {
                    VaultId = table.Column<Guid>(type: "TEXT", nullable: false),
                    ConversationId = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    BlobName = table.Column<string>(type: "TEXT", nullable: false),
                    SizeBytes = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Recordings", x => new { x.VaultId, x.ConversationId });
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "Recordings");
        }
    }
}
