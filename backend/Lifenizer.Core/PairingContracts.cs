namespace Lifenizer.Core;

public sealed record PairingEnrollmentRequest(string BootstrapToken, string DeviceName, string PublicKey, string Nonce, string Proof, string RefreshTokenHash);
public sealed record PairingPollRequest(string RequestToken);
public sealed record PairingTransfer(string CipherText, string Nonce, string SenderPublicKey);
public sealed record PairingRefreshRequest(Guid? DeviceId, string RefreshToken);
