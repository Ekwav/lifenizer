using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

namespace Lifenizer.Api.Endpoints;

public static class PairingEndpoints
{
    private static string Hash(string token) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
    private static bool HashMatches(string token, string expected) => CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(token)), Convert.FromHexString(expected));
    private static bool ValidHash(string? value) => value is { Length: 64 } && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static bool Base64Bytes(string? value, int length)
    {
        if (value is null || value.Length != ((length + 2) / 3) * 4) return false;
        try { return Convert.FromBase64String(value).Length == length; }
        catch (FormatException) { return false; }
    }
    private static bool ConfigurationReady(IConfiguration configuration) => ValidHash(configuration["Pairing:BootstrapTokenHash"])
        && DateTimeOffset.TryParse(configuration["Pairing:BootstrapExpiresAt"], CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _);
    private static AuthResponse Session(UserAccount user, AuthTokenService tokens) => new(tokens.CreateToken(user.Id, TimeSpan.FromHours(1)), user.Id, user.VaultId, user.VaultSalt);
    private static IResult Expired() => Results.Ok(new { status = "expired" });

    public static IEndpointRouteBuilder MapPairingEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/pairing").WithTags("Pairing");
        group.AddEndpointFilter(async (context, next) => ConfigurationReady(context.HttpContext.RequestServices.GetRequiredService<IConfiguration>())
            ? await next(context) : Results.NotFound());

        group.MapPost("/request", async (PairingEnrollmentRequest request, IConfiguration configuration, LifenizerDbContext db, AuthTokenService tokens, CancellationToken cancellationToken) =>
        {
            if (request.BootstrapToken is null || request.BootstrapToken.Length > 128 || !HashMatches(request.BootstrapToken, configuration["Pairing:BootstrapTokenHash"]!))
                return Results.Json(new { error = "invalid_bootstrap_token" }, statusCode: 403);
            // Only the approving device holds S and can verify this opaque device HMAC.
            if (string.IsNullOrWhiteSpace(request.DeviceName) || request.DeviceName.Length > 128
                || !Base64Bytes(request.PublicKey, 32) || !Base64Bytes(request.Nonce, 32) || !Base64Bytes(request.Proof, 32) || !ValidHash(request.RefreshTokenHash))
                return Results.BadRequest(new { error = "invalid_pairing_request" });
            var now = DateTimeOffset.UtcNow;
            var bootstrapExpiresAt = DateTimeOffset.Parse(configuration["Pairing:BootstrapExpiresAt"]!, CultureInfo.InvariantCulture);
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var state = await db.PairingStates.SingleOrDefaultAsync(cancellationToken);
            now = DateTimeOffset.UtcNow;
            if (state is null)
            {
                if (now >= bootstrapExpiresAt) return Results.Json(new { error = "bootstrap_expired" }, statusCode: 410);
                var id = Guid.NewGuid();
                var user = new UserAccount
                {
                    Id = id, VaultId = Guid.NewGuid(), VaultSalt = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)),
                    AuthProviderId = $"pairing:{id}", Email = $"{id:N}@lifenizer.invalid", DisplayName = request.DeviceName,
                    CreatedAt = now, LastSeenAt = now
                };
                var device = new PairedDevice { Id = Guid.NewGuid(), UserId = id, DeviceName = request.DeviceName, RefreshTokenHash = request.RefreshTokenHash, ExpiresAtUnixSeconds = now.AddDays(90).ToUnixTimeSeconds() };
                db.Users.Add(user);
                db.PairingStates.Add(new PairingState { UserId = id, BootstrapDeviceId = device.Id });
                db.PairedDevices.Add(device);
                await db.SaveChangesAsync(cancellationToken);
                await transaction.CommitAsync(cancellationToken);
                return Results.Ok(new { status = "bootstrap", session = Session(user, tokens), user.Email, deviceId = device.Id, bootstrapExpiresAt });
            }
            if (now < bootstrapExpiresAt)
            {
                var firstDevice = await db.PairedDevices.SingleOrDefaultAsync(device => device.Id == state.BootstrapDeviceId && device.RefreshTokenHash == request.RefreshTokenHash, cancellationToken);
                if (firstDevice is not null && firstDevice.ExpiresAtUnixSeconds > now.ToUnixTimeSeconds())
                {
                    var owner = await db.Users.SingleAsync(user => user.Id == state.UserId, cancellationToken);
                    return Results.Ok(new { status = "bootstrap", session = Session(owner, tokens), owner.Email, deviceId = firstDevice.Id, bootstrapExpiresAt });
                }
            }
            await db.PairingRequests.Where(pending => pending.ExpiresAtUnixSeconds <= now.ToUnixTimeSeconds()).ExecuteDeleteAsync(cancellationToken);
            if (await db.PairingRequests.CountAsync(cancellationToken) >= 32)
                return Results.Json(new { error = "pairing_queue_full" }, statusCode: 429);
            var requestToken = Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(32));
            var pending = new PairingRequest
            {
                Id = Guid.NewGuid(), UserId = state.UserId, DeviceName = request.DeviceName, PublicKey = request.PublicKey,
                Nonce = request.Nonce, Proof = request.Proof, RefreshTokenHash = request.RefreshTokenHash,
                RequestTokenHash = Hash(requestToken), ExpiresAtUnixSeconds = now.AddMinutes(10).ToUnixTimeSeconds()
            };
            db.PairingRequests.Add(pending);
            await db.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            return Results.Ok(new { status = "pending", requestId = pending.Id, requestToken, expiresAt = DateTimeOffset.FromUnixTimeSeconds(pending.ExpiresAtUnixSeconds) });
        }).AllowAnonymous().RequireRateLimiting("pairing-request");

        group.MapGet("/pending", async (ClaimsPrincipalUser user, LifenizerDbContext db, CancellationToken cancellationToken) =>
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var pending = await db.PairingRequests.Where(request => request.UserId == user.UserId && request.Status == "pending" && request.ExpiresAtUnixSeconds > now).ToListAsync(cancellationToken);
            return Results.Ok(pending.Select(request => new { request.Id, request.DeviceName, request.PublicKey, request.Nonce, request.Proof, request.RefreshTokenHash, expiresAt = DateTimeOffset.FromUnixTimeSeconds(request.ExpiresAtUnixSeconds) }));
        }).RequireAuthorization();

        group.MapPost("/{id:guid}/approve", async (Guid id, PairingTransfer transfer, ClaimsPrincipalUser user, LifenizerDbContext db, CancellationToken cancellationToken) =>
        {
            if (!Base64Bytes(transfer.Nonce, 12) || !Base64Bytes(transfer.SenderPublicKey, 32) || string.IsNullOrEmpty(transfer.CipherText) || transfer.CipherText.Length > 65536)
                return Results.BadRequest(new { error = "invalid_pairing_transfer" });
            try { if (Convert.FromBase64String(transfer.CipherText).Length == 0) return Results.BadRequest(new { error = "invalid_pairing_transfer" }); }
            catch (FormatException) { return Results.BadRequest(new { error = "invalid_pairing_transfer" }); }
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var pending = await db.PairingRequests.SingleOrDefaultAsync(request => request.Id == id && request.UserId == user.UserId, cancellationToken);
            if (pending is null) return Results.NotFound();
            if (pending.ExpiresAtUnixSeconds <= DateTimeOffset.UtcNow.ToUnixTimeSeconds()) return Results.StatusCode(410);
            if (pending.Status != "pending") return Results.Conflict(new { error = "pairing_already_decided" });
            pending.Status = "approved";
            pending.TransferCipherText = transfer.CipherText;
            pending.TransferNonce = transfer.Nonce;
            pending.SenderPublicKey = transfer.SenderPublicKey;
            db.PairedDevices.Add(new PairedDevice { Id = pending.Id, UserId = pending.UserId, DeviceName = pending.DeviceName, RefreshTokenHash = pending.RefreshTokenHash, ExpiresAtUnixSeconds = DateTimeOffset.UtcNow.AddDays(90).ToUnixTimeSeconds() });
            await db.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            return Results.NoContent();
        }).RequireAuthorization();

        group.MapPost("/{id:guid}/deny", async (Guid id, ClaimsPrincipalUser user, LifenizerDbContext db, CancellationToken cancellationToken) =>
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var changed = await db.PairingRequests.Where(request => request.Id == id && request.UserId == user.UserId && request.Status == "pending" && request.ExpiresAtUnixSeconds > now)
                .ExecuteUpdateAsync(setters => setters.SetProperty(request => request.Status, "denied"), cancellationToken);
            return changed == 0 ? Results.NotFound() : Results.NoContent();
        }).RequireAuthorization();

        group.MapPost("/{id:guid}/poll", async (Guid id, PairingPollRequest request, LifenizerDbContext db, AuthTokenService tokens, IConfiguration configuration, CancellationToken cancellationToken) =>
        {
            if (request.RequestToken is null || request.RequestToken.Length != 43) return Results.Json(new { error = "invalid_request_token" }, statusCode: 403);
            var pending = await db.PairingRequests.SingleOrDefaultAsync(pending => pending.Id == id, cancellationToken);
            if (pending is null) return Expired();
            if (!HashMatches(request.RequestToken, pending.RequestTokenHash)) return Results.Json(new { error = "invalid_request_token" }, statusCode: 403);
            if (pending.ExpiresAtUnixSeconds <= DateTimeOffset.UtcNow.ToUnixTimeSeconds()) return Expired();
            if (pending.Status != "approved") return Results.Ok(new { status = pending.Status });
            var device = await db.PairedDevices.SingleOrDefaultAsync(device => device.Id == id, cancellationToken);
            if (device is null) return Results.Ok(new { status = "denied" });
            var account = await db.Users.SingleAsync(user => user.Id == pending.UserId, cancellationToken);
            return Results.Ok(new { status = "approved", session = Session(account, tokens), account.Email, deviceId = device.Id, bootstrapExpiresAt = DateTimeOffset.Parse(configuration["Pairing:BootstrapExpiresAt"]!, CultureInfo.InvariantCulture), transfer = new PairingTransfer(pending.TransferCipherText!, pending.TransferNonce!, pending.SenderPublicKey!) });
        }).AllowAnonymous().RequireRateLimiting("pairing-poll");

        group.MapPost("/refresh", async (PairingRefreshRequest request, LifenizerDbContext db, AuthTokenService tokens, IConfiguration configuration, CancellationToken cancellationToken) =>
        {
            if (request.RefreshToken is null || request.RefreshToken.Length != 43) return Results.Unauthorized();
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var deviceId = request.DeviceId ?? await db.PairingStates.Select(state => (Guid?)state.BootstrapDeviceId).SingleOrDefaultAsync(cancellationToken);
            var device = await db.PairedDevices.SingleOrDefaultAsync(device => device.Id == deviceId, cancellationToken);
            var now = DateTimeOffset.UtcNow;
            if (device is null || device.ExpiresAtUnixSeconds <= now.ToUnixTimeSeconds() || !HashMatches(request.RefreshToken, device.RefreshTokenHash)) return Results.Unauthorized();
            var account = await db.Users.SingleAsync(user => user.Id == device.UserId, cancellationToken);
            device.ExpiresAtUnixSeconds = now.AddDays(90).ToUnixTimeSeconds();
            account.LastSeenAt = now;
            await db.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            return Results.Ok(new { session = Session(account, tokens), account.Email, deviceId = device.Id, bootstrapExpiresAt = DateTimeOffset.Parse(configuration["Pairing:BootstrapExpiresAt"]!, CultureInfo.InvariantCulture) });
        }).AllowAnonymous().RequireRateLimiting("pairing-refresh");

        group.MapDelete("/devices/{id:guid}", async (Guid id, ClaimsPrincipalUser user, LifenizerDbContext db, CancellationToken cancellationToken) =>
        {
            var deleted = await db.PairedDevices.Where(device => device.Id == id && device.UserId == user.UserId).ExecuteDeleteAsync(cancellationToken);
            return deleted == 0 ? Results.NotFound() : Results.NoContent();
        }).RequireAuthorization();
        return app;
    }
}
