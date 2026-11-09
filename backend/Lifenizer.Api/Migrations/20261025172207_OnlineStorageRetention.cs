using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Lifenizer.Api.Migrations
{
    /// <inheritdoc />
    public partial class OnlineStorageRetention : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<long>(
                name: "OnlineStorageDeleteAtUnixSeconds",
                table: "Users",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_Users_OnlineStorageDeleteAtUnixSeconds",
                table: "Users",
                column: "OnlineStorageDeleteAtUnixSeconds");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Users_OnlineStorageDeleteAtUnixSeconds",
                table: "Users");

            migrationBuilder.DropColumn(
                name: "OnlineStorageDeleteAtUnixSeconds",
                table: "Users");
        }
    }
}
