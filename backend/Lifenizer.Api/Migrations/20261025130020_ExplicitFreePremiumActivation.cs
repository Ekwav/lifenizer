using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Lifenizer.Api.Migrations
{
    /// <inheritdoc />
    public partial class ExplicitFreePremiumActivation : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "FreePremiumActivatedAt",
                table: "Users",
                type: "TEXT",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "FreePremiumActivatedAt",
                table: "Users");
        }
    }
}
