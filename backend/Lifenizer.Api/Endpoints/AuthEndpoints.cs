using System.Net.Mail;
using FirebaseAdmin.Auth;
using Lifenizer.Api.Data;
using Lifenizer.Api.Services;
using Lifenizer.Core;
using Microsoft.AspNetCore.Mvc;

namespace Lifenizer.Api.Endpoints;

public static class AuthEndpoints
{
    public static IEndpointRouteBuilder MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/auth").WithTags("Auth");

        group.MapPost("/register", async (
            [FromBody] RegisterAccountRequest request,
            UserAccountService users,
            AuthTokenService tokens,
            CancellationToken cancellationToken) =>
        {
            if (!ValidEmail(request.Email)) return Results.BadRequest(new { error = "valid_email_required" });
            if (request.Password is null || request.Password.Length is < 12 or > 1024)
                return Results.BadRequest(new { error = "password_length_12_to_1024" });
            if (request.DisplayName?.Length > 256) return Results.BadRequest(new { error = "display_name_too_long" });
            var user = await users.RegisterAsync(request.Email, request.Password, request.DisplayName, cancellationToken);
            return user is null ? Results.Conflict(new { error = "account_exists" }) : Results.Ok(ToAuthResponse(user, tokens));
        }).AllowAnonymous().RequireRateLimiting("account-auth");

        group.MapPost("/login", async (
            [FromBody] AccountLoginRequest request,
            UserAccountService users,
            AuthTokenService tokens,
            CancellationToken cancellationToken) =>
        {
            if (!ValidEmail(request.Email) || request.Password is null || request.Password.Length is < 1 or > 1024)
                return Results.Unauthorized();
            var user = await users.LoginAsync(request.Email, request.Password, cancellationToken);
            return user is null ? Results.Unauthorized() : Results.Ok(ToAuthResponse(user, tokens));
        }).AllowAnonymous().RequireRateLimiting("account-auth");

        group.MapPost("/dev-login", async (
            [FromBody] DevLoginRequest request,
            IWebHostEnvironment environment,
            IConfiguration configuration,
            UserAccountService users,
            AuthTokenService tokens,
            CancellationToken cancellationToken) =>
        {
            var allowDevLogin = configuration.GetValue("Auth:AllowDevLogin", environment.IsDevelopment());
            if (!allowDevLogin)
            {
                return Results.NotFound();
            }

            if (string.IsNullOrWhiteSpace(request.Email))
            {
                return Results.BadRequest(new { error = "email_required" });
            }

            var providerId = request.ProviderId ?? $"dev:{request.Email.Trim().ToLowerInvariant()}";
            var user = await users.GetOrCreateExternalUserAsync(
                providerId,
                request.Email,
                request.DisplayName,
                cancellationToken);

            return Results.Ok(ToAuthResponse(user, tokens));
        }).AllowAnonymous();

        group.MapPost("/firebase", async (
            [FromBody] TokenContainer request,
            IConfiguration configuration,
            UserAccountService users,
            AuthTokenService tokens,
            CancellationToken cancellationToken) =>
        {
            if (!configuration.GetValue<bool>("Auth:EnableFirebase")) return Results.NotFound();

            if (string.IsNullOrWhiteSpace(request.AuthToken))
            {
                return Results.BadRequest(new { error = "auth_token_required" });
            }

            FirebaseToken decoded;
            try
            {
                decoded = await FirebaseAuth.DefaultInstance.VerifyIdTokenAsync(request.AuthToken, cancellationToken);
            }
            catch (Exception ex)
            {
                return Results.Problem(
                    title: "Firebase token verification failed",
                    detail: ex.Message,
                    statusCode: StatusCodes.Status401Unauthorized);
            }

            decoded.Claims.TryGetValue("email", out var email);
            decoded.Claims.TryGetValue("name", out var name);
            var user = await users.GetOrCreateExternalUserAsync(
                $"firebase:{decoded.Subject}",
                email?.ToString(),
                name?.ToString(),
                cancellationToken);

            return Results.Ok(ToAuthResponse(user, tokens));
        }).AllowAnonymous();

        return app;
    }

    private static bool ValidEmail(string? email) => !string.IsNullOrWhiteSpace(email) && email.Length <= 320
        && MailAddress.TryCreate(email.Trim(), out var address) && address.Address == email.Trim();

    private static AuthResponse ToAuthResponse(UserAccount user, AuthTokenService tokens)
    {
        return new AuthResponse(tokens.CreateToken(user.Id), user.Id, user.VaultId, user.VaultSalt);
    }
}