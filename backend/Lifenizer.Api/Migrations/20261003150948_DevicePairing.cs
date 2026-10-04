using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Lifenizer.Api.Migrations
{
    /// <inheritdoc />
    public partial class DevicePairing : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "PairedDevices",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    DeviceName = table.Column<string>(type: "TEXT", nullable: false),
                    RefreshTokenHash = table.Column<string>(type: "TEXT", nullable: false),
                    ExpiresAtUnixSeconds = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PairedDevices", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "PairingRequests",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    DeviceName = table.Column<string>(type: "TEXT", nullable: false),
                    PublicKey = table.Column<string>(type: "TEXT", nullable: false),
                    Nonce = table.Column<string>(type: "TEXT", nullable: false),
                    Proof = table.Column<string>(type: "TEXT", nullable: false),
                    RefreshTokenHash = table.Column<string>(type: "TEXT", nullable: false),
                    RequestTokenHash = table.Column<string>(type: "TEXT", nullable: false),
                    ExpiresAtUnixSeconds = table.Column<long>(type: "INTEGER", nullable: false),
                    Status = table.Column<string>(type: "TEXT", nullable: false),
                    TransferCipherText = table.Column<string>(type: "TEXT", nullable: true),
                    TransferNonce = table.Column<string>(type: "TEXT", nullable: true),
                    SenderPublicKey = table.Column<string>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PairingRequests", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "PairingStates",
                columns: table => new
                {
                    Id = table.Column<int>(type: "INTEGER", nullable: false),
                    BootstrapDeviceId = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PairingStates", x => x.Id);
                    table.CheckConstraint("CK_PairingState_Singleton", "Id = 1");
                });

            migrationBuilder.CreateIndex(
                name: "IX_PairedDevices_UserId",
                table: "PairedDevices",
                column: "UserId");

            migrationBuilder.CreateIndex(
                name: "IX_PairingRequests_UserId_ExpiresAtUnixSeconds",
                table: "PairingRequests",
                columns: new[] { "UserId", "ExpiresAtUnixSeconds" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "PairedDevices");

            migrationBuilder.DropTable(
                name: "PairingRequests");

            migrationBuilder.DropTable(
                name: "PairingStates");
        }
    }
}
