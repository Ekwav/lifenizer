using Microsoft.EntityFrameworkCore.Migrations;

namespace Lifenizer.Api.Migrations;

public partial class Baseline : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        // IF NOT EXISTS adopts databases created by pre-migration releases.
        migrationBuilder.Sql("""
            CREATE TABLE IF NOT EXISTS "Images" (
                "Id" TEXT NOT NULL CONSTRAINT "PK_Images" PRIMARY KEY,
                "UserId" TEXT NOT NULL,
                "FileName" TEXT NOT NULL,
                "ContentType" TEXT NOT NULL,
                "SizeBytes" INTEGER NOT NULL,
                "BlobPath" TEXT NOT NULL,
                "ConversationId" TEXT NULL,
                "UploadedAt" TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS "SyncEnvelopes" (
                "Sequence" INTEGER NOT NULL CONSTRAINT "PK_SyncEnvelopes" PRIMARY KEY AUTOINCREMENT,
                "Id" TEXT NOT NULL,
                "UserId" TEXT NOT NULL,
                "VaultId" TEXT NOT NULL,
                "DeviceId" TEXT NOT NULL,
                "EntityType" TEXT NOT NULL,
                "EntityId" TEXT NOT NULL,
                "Operation" TEXT NOT NULL,
                "Revision" INTEGER NOT NULL,
                "CipherText" TEXT NOT NULL,
                "Nonce" TEXT NOT NULL,
                "KeyId" TEXT NOT NULL,
                "ClientCreatedAt" TEXT NOT NULL,
                "ServerReceivedAt" TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS "UsageEvents" (
                "Id" TEXT NOT NULL CONSTRAINT "PK_UsageEvents" PRIMARY KEY,
                "UserId" TEXT NOT NULL,
                "VaultId" TEXT NOT NULL,
                "Kind" TEXT NOT NULL,
                "Quantity" REAL NOT NULL,
                "Unit" TEXT NOT NULL,
                "MetadataJson" TEXT NOT NULL,
                "CreatedAt" TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS "Users" (
                "Id" TEXT NOT NULL CONSTRAINT "PK_Users" PRIMARY KEY,
                "VaultId" TEXT NOT NULL,
                "VaultSalt" TEXT NOT NULL,
                "AuthProviderId" TEXT NOT NULL,
                "Email" TEXT NULL,
                "DisplayName" TEXT NULL,
                "Plan" INTEGER NOT NULL,
                "StorageUsedBytes" INTEGER NOT NULL,
                "CreatedAt" TEXT NOT NULL,
                "LastSeenAt" TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS "IX_Images_UserId_UploadedAt" ON "Images" ("UserId", "UploadedAt");

            CREATE UNIQUE INDEX IF NOT EXISTS "IX_SyncEnvelopes_Id" ON "SyncEnvelopes" ("Id");

            CREATE INDEX IF NOT EXISTS "IX_SyncEnvelopes_UserId_Sequence" ON "SyncEnvelopes" ("UserId", "Sequence");

            CREATE INDEX IF NOT EXISTS "IX_SyncEnvelopes_VaultId_EntityType_EntityId" ON "SyncEnvelopes" ("VaultId", "EntityType", "EntityId");

            CREATE INDEX IF NOT EXISTS "IX_UsageEvents_UserId_CreatedAt" ON "UsageEvents" ("UserId", "CreatedAt");

            CREATE UNIQUE INDEX IF NOT EXISTS "IX_Users_AuthProviderId" ON "Users" ("AuthProviderId");

            CREATE INDEX IF NOT EXISTS "IX_Users_Email" ON "Users" ("Email");

            """);
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        throw new NotSupportedException("The adopted baseline cannot be rolled back without losing user data.");
    }
}
