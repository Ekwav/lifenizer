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
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"
    };

    /// <summary>Maximum file size per upload: 25 MB.</summary>
    private const long MaxFileSizeBytes = 25L * 1024 * 1024;

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
            UserAccountService accounts,
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

            var userId = currentUser.UserId;

            // Quota check via payments service.
            var quota = await premium.GetQuotaStatusAsync(userId, cancellationToken);
            if (quota.UsedBytes + file.Length > quota.LimitBytes)
            {
                return Results.Json(new
                {
                    error = "quota_exceeded",
                    usedBytes = quota.UsedBytes,
                    limitBytes = quota.LimitBytes,
                    plan = quota.PlanName,
                }, statusCode: StatusCodes.Status402PaymentRequired);
            }

            // Persist the file.
            var blobRoot = config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts";
            var userDir = Path.Combine(blobRoot, userId.ToString());
            Directory.CreateDirectory(userDir);

            var id = Guid.NewGuid();
            var safeFileName = Path.GetFileName(file.FileName).Replace("..", string.Empty);
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
            await accounts.AdjustStorageUsageAsync(userId, file.Length, cancellationToken);

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
            var record = await db.Images.FirstOrDefaultAsync(
                img => img.Id == id && img.UserId == currentUser.UserId,
                cancellationToken);
            if (record is null) return Results.NotFound();

            var blobRoot = config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts";
            var fullPath = Path.Combine(blobRoot, record.BlobPath);
            if (File.Exists(fullPath)) File.Delete(fullPath);

            db.Images.Remove(record);
            await db.SaveChangesAsync(cancellationToken);
            await accounts.AdjustStorageUsageAsync(currentUser.UserId, -record.SizeBytes, cancellationToken);

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
                .OrderByDescending(img => img.UploadedAt)
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

            return Results.Ok(list);
        });

        return app;
    }
}
