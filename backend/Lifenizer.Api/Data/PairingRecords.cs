namespace Lifenizer.Api.Data;

public sealed class PairingState
{
    public int Id { get; set; } = 1;
    public Guid UserId { get; set; }
    public Guid BootstrapDeviceId { get; set; }
}

public sealed class PairingRequest
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string DeviceName { get; set; } = string.Empty;
    public string PublicKey { get; set; } = string.Empty;
    public string Nonce { get; set; } = string.Empty;
    public string Proof { get; set; } = string.Empty;
    public string RefreshTokenHash { get; set; } = string.Empty;
    public string RequestTokenHash { get; set; } = string.Empty;
    public long ExpiresAtUnixSeconds { get; set; }
    public string Status { get; set; } = "pending";
    public string? TransferCipherText { get; set; }
    public string? TransferNonce { get; set; }
    public string? SenderPublicKey { get; set; }
}

public sealed class PairedDevice
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string DeviceName { get; set; } = string.Empty;
    public string RefreshTokenHash { get; set; } = string.Empty;
    public long ExpiresAtUnixSeconds { get; set; }
}
