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
            UserAccountService users,
            AuthTokenService tokens,
            CancellationToken cancellationToken) =>
        {
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

    private static AuthResponse ToAuthResponse(UserAccount user, AuthTokenService tokens)
    {
        return new AuthResponse(tokens.CreateToken(user.Id), user.Id, user.VaultId, user.VaultSalt);
    }
}