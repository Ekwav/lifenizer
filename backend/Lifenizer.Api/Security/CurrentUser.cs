using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;

namespace Lifenizer.Api.Security;

public static class CurrentUser
{
    public static Guid GetUserId(this ClaimsPrincipal user)
    {
        var value = user.FindFirstValue(JwtRegisteredClaimNames.Sub)
            ?? user.FindFirstValue("sub")
            ?? user.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!Guid.TryParse(value, out var userId))
        {
            throw new InvalidOperationException("Authenticated user is missing a valid sub claim.");
        }

        return userId;
    }
}