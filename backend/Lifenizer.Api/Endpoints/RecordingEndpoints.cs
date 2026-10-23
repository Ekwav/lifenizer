using System.Buffers.Text;
using System.Text.Json;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;

namespace Lifenizer.Api.Endpoints;

public static class RecordingEndpoints
{
    public const long MaxEnvelopeBytes = 200_000_000;
    private static string Root(IConfiguration config) => Path.Combine(config["Artifacts:StorePath"] ?? "/tmp/lifenizer-artifacts", "recordings");
    private static string BlobPath(IConfiguration config, Guid vault, string name) => Path.Combine(Root(config), vault.ToString("N"), name);
    private static bool ValidId(string id) => !string.IsNullOrWhiteSpace(id) && id.Length <= 128;

    private static async Task<byte[]> ReadEnvelopeAsync(HttpRequest request, IConfiguration config, CancellationToken token)
    {
        var limit = Math.Clamp(config.GetValue<long?>("Recordings:MaxRequestBytes") ?? MaxEnvelopeBytes, 1, MaxEnvelopeBytes);
        var feature = request.HttpContext.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (feature is { IsReadOnly: false }) feature.MaxRequestBodySize = limit;
        if (request.ContentLength > limit) throw new BadHttpRequestException("Recording too large", 413);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromMinutes(2));
        using var stream = new MemoryStream();
        var buffer = new byte[81920];
        int count;
        try
        {
            while ((count = await request.Body.ReadAsync(buffer, deadline.Token)) > 0)
            {
                if (stream.Length + count > limit) throw new BadHttpRequestException("Recording too large", 413);
                await stream.WriteAsync(buffer.AsMemory(0, count), deadline.Token);
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new BadHttpRequestException("Recording upload timed out", 408); }
        var bytes = stream.ToArray();
        try
        {
            if (!ValidEnvelope(bytes)) throw new FormatException();
        }
        catch (Exception error) when (error is JsonException or FormatException)
        { throw new BadHttpRequestException("Invalid encrypted recording envelope", 400); }
        return bytes;
    }

    // Validate ciphertext in place: decoding a 200 MB envelope just to validate
    // base64 would allocate another full copy of the recording.
    private static bool ValidEnvelope(ReadOnlySpan<byte> bytes)
    {
        var reader = new Utf8JsonReader(bytes);
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return false;
        var fields = 0;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            if (reader.TokenType != JsonTokenType.PropertyName) return false;
            var field = reader.ValueTextEquals("cipherText") ? 1 : reader.ValueTextEquals("nonce") ? 2 : reader.ValueTextEquals("keyId") ? 4 : 0;
            if (field == 0 || (fields & field) != 0 || !reader.Read() || reader.TokenType != JsonTokenType.String) return false;
            fields |= field;
            if (field == 1 && (reader.ValueIsEscaped || reader.ValueSpan.IsEmpty || !Base64.IsValid(reader.ValueSpan, out var decodedLength) || decodedLength == 0)) return false;
            if (field == 2 && (reader.ValueSpan.Length > 32 || Convert.FromBase64String(reader.GetString()!).Length != 12)) return false;
            if (field == 4 && (reader.ValueSpan.Length > 768 || string.IsNullOrWhiteSpace(reader.GetString()) || reader.GetString()!.Length > 128)) return false;
        }
        return fields == 7 && reader.TokenType == JsonTokenType.EndObject && !reader.Read();
    }

    public static IEndpointRouteBuilder MapRecordingEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/recordings").RequireAuthorization().WithTags("Recordings");
        group.MapGet("/requests", async (HttpContext context, ClaimsPrincipalUser current, LifenizerDbContext db, RecordingRelay relay) =>
        {
            var user = await db.Users.FindAsync([current.UserId], context.RequestAborted);
            if (user is null) { context.Response.StatusCode = 401; return; }
            var subscription = relay.Subscribe(user.VaultId);
            if (subscription is null) { context.Response.StatusCode = 429; return; }
            context.Response.ContentType = "text/event-stream";
            context.Response.Headers.CacheControl = "no-store";
            context.Response.Headers["X-Accel-Buffering"] = "no";
            try
            {
                await context.Response.WriteAsync(": ready\n\n", context.RequestAborted);
                await context.Response.Body.FlushAsync(context.RequestAborted);
                await foreach (var request in subscription.Value.Reader.ReadAllAsync(context.RequestAborted))
                {
                    var data = JsonSerializer.Serialize(new { requestId = request.RequestId, conversationId = request.ConversationId });
                    await context.Response.WriteAsync($"event: request\ndata: {data}\n\n", context.RequestAborted);
                    await context.Response.Body.FlushAsync(context.RequestAborted);
                }
            }
            catch (Exception error) when (error is OperationCanceledException or IOException) { }
            finally { relay.Unsubscribe(subscription.Value.Id); }
        });

        group.MapPost("/requests/{requestId:guid}", async (Guid requestId, HttpRequest request, ClaimsPrincipalUser current, LifenizerDbContext db, RecordingRelay relay, IConfiguration config, CancellationToken token) =>
        {
            var user = await db.Users.FindAsync([current.UserId], token);
            if (user is null) return Results.Unauthorized();
            if (!relay.TryClaim(user.VaultId, requestId)) return Results.NotFound();
            if (!relay.Transfers.Wait(0)) { relay.Release(user.VaultId, requestId); return Results.StatusCode(429); }
            try
            {
                var bytes = await ReadEnvelopeAsync(request, config, token);
                return relay.Complete(user.VaultId, requestId, bytes) ? Results.NoContent() : Results.NotFound();
            }
            catch (BadHttpRequestException error) { return Results.StatusCode(error.StatusCode); }
            finally { relay.Release(user.VaultId, requestId); relay.Transfers.Release(); }
        });

        group.MapGet("/{conversationId}", async (string conversationId, HttpContext context, ClaimsPrincipalUser current, LifenizerDbContext db, RecordingRelay relay, IConfiguration config) =>
        {
            if (!ValidId(conversationId)) return Results.BadRequest();
            var token = context.RequestAborted;
            var user = await db.Users.FindAsync([current.UserId], token);
            if (user is null) return Results.Unauthorized();
            var record = await db.Recordings.FindAsync([user.VaultId, conversationId], token);
            context.Response.Headers.CacheControl = "no-store";
            if (record is not null && File.Exists(BlobPath(config, user.VaultId, record.BlobName)))
                return Results.File(BlobPath(config, user.VaultId, record.BlobName), "application/json");
            if (!relay.Downloads.Wait(0)) return Results.StatusCode(429);
            try
            {
                var timeout = TimeSpan.FromSeconds(Math.Clamp(config.GetValue<double?>("Recordings:RelayTimeoutSeconds") ?? 20, 0.05, 20));
                var bytes = await relay.RequestAsync(user.VaultId, conversationId, timeout, token);
                if (bytes is null) return Results.NotFound();
                context.Response.ContentType = "application/json";
                await context.Response.Body.WriteAsync(bytes, token);
                return Results.Empty;
            }
            catch (TimeoutException) { return Results.StatusCode(504); }
            catch (IOException) { return Results.NotFound(); }
            catch (InvalidOperationException) { return Results.StatusCode(429); }
            finally { relay.Downloads.Release(); }
        });

        group.MapPut("/{conversationId}", async (string conversationId, HttpRequest request, ClaimsPrincipalUser current, LifenizerDbContext db, RecordingRelay relay, PremiumService premium, IConfiguration config, CancellationToken token) =>
        {
            if (!ValidId(conversationId)) return Results.BadRequest();
            var user = await db.Users.FindAsync([current.UserId], token);
            if (user is null) return Results.Unauthorized();
            if (!relay.Transfers.Wait(0)) return Results.StatusCode(429);
            string? newPath = null;
            var committed = false;
            try
            {
                var bytes = await ReadEnvelopeAsync(request, config, token);
                await using var transaction = await db.Database.BeginTransactionAsync(token);
                var record = await db.Recordings.FindAsync([user.VaultId, conversationId], token);
                var owner = record?.UserId ?? user.Id;
                var quota = await premium.GetQuotaStatusAsync(owner, token);
                var delta = bytes.LongLength - (record?.SizeBytes ?? 0);
                var reserved = await db.Users.Where(account => account.Id == owner && (delta <= 0 || account.StorageUsedBytes <= quota.LimitBytes - delta))
                    .ExecuteUpdateAsync(setters => setters.SetProperty(account => account.StorageUsedBytes, account => account.StorageUsedBytes + delta), token);
                if (reserved == 0) return Results.Json(new { error = "quota_exceeded" }, statusCode: 402);
                var name = $"{Guid.NewGuid():N}.bin";
                newPath = BlobPath(config, user.VaultId, name);
                Directory.CreateDirectory(Path.GetDirectoryName(newPath)!);
                await File.WriteAllBytesAsync(newPath, bytes, token);
                var oldPath = record is null ? null : BlobPath(config, user.VaultId, record.BlobName);
                if (record is null)
                {
                    record = new RecordingRecord { VaultId = user.VaultId, ConversationId = conversationId, UserId = owner };
                    db.Recordings.Add(record);
                }
                record.BlobName = name;
                record.SizeBytes = bytes.LongLength;
                await db.SaveChangesAsync(token);
                await transaction.CommitAsync(token);
                committed = true;
                if (oldPath is not null) File.Delete(oldPath);
                return Results.NoContent();
            }
            catch (BadHttpRequestException error) { return Results.StatusCode(error.StatusCode); }
            finally
            {
                if (!committed && newPath is not null) File.Delete(newPath);
                relay.Transfers.Release();
            }
        });

        group.MapDelete("/{conversationId}", async (string conversationId, ClaimsPrincipalUser current, LifenizerDbContext db, UserAccountService accounts, IConfiguration config, CancellationToken token) =>
        {
            if (!ValidId(conversationId)) return Results.BadRequest();
            var user = await db.Users.FindAsync([current.UserId], token);
            if (user is null) return Results.Unauthorized();
            await using var transaction = await db.Database.BeginTransactionAsync(token);
            var record = await db.Recordings.FindAsync([user.VaultId, conversationId], token);
            if (record is null) return Results.NotFound();
            db.Recordings.Remove(record);
            await db.SaveChangesAsync(token);
            await accounts.AdjustStorageUsageAsync(record.UserId, -record.SizeBytes, token);
            await transaction.CommitAsync(token);
            File.Delete(BlobPath(config, user.VaultId, record.BlobName));
            return Results.NoContent();
        });
        return app;
    }
}
