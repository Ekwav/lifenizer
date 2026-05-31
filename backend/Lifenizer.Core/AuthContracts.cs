namespace Lifenizer.Core;

public sealed record TokenContainer(string AuthToken);

public sealed record DevLoginRequest(
    string Email,
    string? DisplayName = null,
    string? ProviderId = null);

public sealed record AuthResponse(
    string AuthToken,
    Guid UserId,
    Guid VaultId,
    string VaultSalt,
    string TokenType = "Bearer");

public enum SubscriptionPlan
{
    Personal = 0,
    Hosted = 1,
    Team = 2
}