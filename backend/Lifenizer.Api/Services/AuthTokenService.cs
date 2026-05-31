using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.IdentityModel.Tokens;

namespace Lifenizer.Api.Services;

public sealed class AuthTokenService(IConfiguration configuration)
{
    public string Issuer => configuration["Jwt:Issuer"] ?? "lifenizer-next";

    public string CreateToken(Guid userId, TimeSpan? lifetime = null, params Claim[] extraClaims)
    {
        var keyBytes = Encoding.UTF8.GetBytes(GetSecret());
        var credentials = new SigningCredentials(new SymmetricSecurityKey(keyBytes), SecurityAlgorithms.HmacSha256);
        var now = DateTime.UtcNow;
        var claims = new List<Claim>
        {
            new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString("N")),
            new(JwtRegisteredClaimNames.Sub, userId.ToString())
        };
        claims.AddRange(extraClaims);

        var token = new JwtSecurityToken(
            Issuer,
            Issuer,
            claims,
            now,
            now.Add(lifetime ?? TimeSpan.FromDays(30)),
            credentials);

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    public SymmetricSecurityKey CreateValidationKey()
    {
        return new SymmetricSecurityKey(Encoding.UTF8.GetBytes(GetSecret()));
    }

    private string GetSecret()
    {
        var secret = configuration["Jwt:Secret"];
        if (string.IsNullOrWhiteSpace(secret) || secret.Length < 32)
        {
            throw new InvalidOperationException("Jwt:Secret must be configured and at least 32 characters long.");
        }

        return secret;
    }
}