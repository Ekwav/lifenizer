using System.Text.Json;
using Lifenizer.Api.Data;
using Lifenizer.Api.Security;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Endpoints;

public static class ImageEndpoints
{
    private static readonly HashSet<string> AllowedContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "application/octet-stream"
    };

    /// <summary>Maximum file size per upload: 25 MB.</summary>
    private const long MaxFileSizeBytes = 25L * 1024 * 1024;

    private static async Task<bool> ValidEncryptedEnvelopeAsync(IFormFile file, CancellationToken cancellationToken)
    {
        try
        {
            await using var stream = file.OpenReadStream();
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 3) return false;
            foreach (var key in new[] { "cipherText", "nonce", "keyId" })
                if (!root.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString())) return false;
            return root.GetProperty("keyId").GetString()!.Length <= 128
                && Convert.FromBase64String(root.GetProperty("nonce").GetString()!).Length == 12
                && Convert.FromBase64String(root.GetProperty("cipherText").GetString()!).Length > 0;
        }
        catch (JsonException) { return false; }
        catch (FormatException) { return false; }
    }

    public static IEndpointRouteBuilder MapImageEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/images").WithTags("Images").RequireAuthorization();

        // -----------------------------------------------------------------------
        // POST /api/images  — upload a single image
        // -----------------------------------------------------------------------
        group.MapPost(string.Empty, async (
            HttpRequest request,
            ClaimsPrincipalUser currentUser,
            LifenizerDbContext db,
            PremiumService premium,
            IConfiguration config,
            CancellationToken cancellationToken) =>
        {
            if (!request.HasFormContentType)
                return Results.BadRequest(new { error = "multipart_required" });

            var form = await request.ReadFormAsync(cancellationToken);
            var file = form.Files.GetFile("file");
            if (file is null)
                return Results.BadRequest(new { error = "missing_file_field" });

            if (file.Length > MaxFileSizeBytes)
                return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);

            var contentType = file.ContentType;
            if (!AllowedContentTypes.Contains(contentType))
                return Results.BadRequest(new { error = "unsupported_content_type", contentType });

            if (contentType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase) && !await ValidEncryptedEnvelopeAsync(file, cancellationToken))
                return Results.BadRequest(new { error = "invalid_encrypted_image_envelope" });

            var userId = currentUser.UserId;

            // Quota check via payments service.
            var quota = await premium.GetQuotaStatusAsync(userId, cancellationToken);
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var reserved = await db.Users.Where(user => user.Id == userId && user.StorageUsedBytes <= quota.LimitBytes - file.Length)
                .ExecuteUpdateAsync(setters => setters.SetProperty(user => user.StorageUsedBytes, user => user.StorageUsedBytes + file.Length), cancellationToken);
            if (reserved == 0)
            {
                return Results.Json(new
                {
                    error = "quota_exceeded",
                    usedBytes = await db.Users.Where(user => user.Id == userId).Select(user => user.StorageUsedBytes).SingleAsync(cancellationToken),
                    limitBytes = quota.LimitBytes,
                    plan = quota.PlanName,
                }, statusCode: StatusCodes.Status402PaymentRequired);
            }

            // Persist the file.
            var blobRoot = config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts";
            var userDir = Path.Combine(blobRoot, userId.ToString());
            Directory.CreateDirectory(userDir);

            var id = Guid.NewGuid();
            var safeFileName = contentType.Equals("application/octet-stream", StringComparison.OrdinalIgnoreCase)
                ? $"{id}.bin" : Path.GetFileName(file.FileName).Replace("..", string.Empty);
            if (string.IsNullOrWhiteSpace(safeFileName)) safeFileName = "image";
            var ext = Path.GetExtension(safeFileName).ToLowerInvariant();
            var blobName = $"{id}{ext}";
            var blobPath = Path.Combine(userId.ToString(), blobName);
            var fullPath = Path.Combine(blobRoot, blobPath);

            await using (var stream = File.Create(fullPath))
            {
                await file.CopyToAsync(stream, cancellationToken);
            }

            var record = new ImageRecord
            {
                Id = id,
                UserId = userId,
                FileName = safeFileName,
                ContentType = contentType,
                SizeBytes = file.Length,
                BlobPath = blobPath,
                ConversationId = form["conversationId"].FirstOrDefault(),
                UploadedAt = DateTimeOffset.UtcNow,
            };

            db.Images.Add(record);
            await db.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);

            return Results.Created($"/api/images/{id}", new
            {
                id,
                fileName = record.FileName,
                contentType = record.ContentType,
                sizeBytes = record.SizeBytes,
                conversationId = record.ConversationId,
                uploadedAt = record.UploadedAt,
            });
        }).DisableAntiforgery();

        // -----------------------------------------------------------------------
        // GET /api/images/{id}  — download an image
        // -----------------------------------------------------------------------
        group.MapGet("{id:guid}", async (
            Guid id,
            ClaimsPrincipalUser currentUser,
            LifenizerDbContext db,
            IConfiguration config,
            CancellationToken cancellationToken) =>
        {
            var record = await db.Images.FirstOrDefaultAsync(
                img => img.Id == id && img.UserId == currentUser.UserId,
                cancellationToken);
            if (record is null) return Results.NotFound();

            var blobRoot = config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts";
            var fullPath = Path.Combine(blobRoot, record.BlobPath);
            if (!File.Exists(fullPath)) return Results.NotFound();

            return Results.File(fullPath, record.ContentType, record.FileName);
        });

        // -----------------------------------------------------------------------
        // DELETE /api/images/{id}
        // -----------------------------------------------------------------------
        group.MapDelete("{id:guid}", async (
            Guid id,
            ClaimsPrincipalUser currentUser,
            LifenizerDbContext db,
            UserAccountService accounts,
            IConfiguration config,
            CancellationToken cancellationToken) =>
        {
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var record = await db.Images.FirstOrDefaultAsync(
                img => img.Id == id && img.UserId == currentUser.UserId,
                cancellationToken);
            if (record is null) return Results.NotFound();

            var blobRoot = config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts";
            var fullPath = Path.Combine(blobRoot, record.BlobPath);
            db.Images.Remove(record);
            await db.SaveChangesAsync(cancellationToken);
            await accounts.AdjustStorageUsageAsync(currentUser.UserId, -record.SizeBytes, cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            if (File.Exists(fullPath)) File.Delete(fullPath);

            return Results.NoContent();
        });

        // -----------------------------------------------------------------------
        // GET /api/images  — list images for the current user
        // -----------------------------------------------------------------------
        group.MapGet(string.Empty, async (
            [FromQuery] string? conversationId,
            ClaimsPrincipalUser currentUser,
            LifenizerDbContext db,
            CancellationToken cancellationToken) =>
        {
            var query = db.Images.Where(img => img.UserId == currentUser.UserId);
            if (!string.IsNullOrWhiteSpace(conversationId))
                query = query.Where(img => img.ConversationId == conversationId);

            var list = await query
                .Select(img => new
                {
                    img.Id,
                    img.FileName,
                    img.ContentType,
                    img.SizeBytes,
                    img.ConversationId,
                    img.UploadedAt,
                })
                .ToListAsync(cancellationToken);

            // SQLite cannot translate DateTimeOffset ordering; filter and project before sorting.
            return Results.Ok(list.OrderByDescending(img => img.UploadedAt));
        });

        return app;
    }
}
