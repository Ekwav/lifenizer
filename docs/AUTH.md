# Native device connection

Install the Android or KDE app and open the private setup link/QR. To add a device, open **Sync → Add device** on an unlocked connected app: it shows the QR and **Copy connection link**. On Android, select **Scan connection QR** in the login screen and allow camera access; scanning a valid connection QR starts pairing automatically. You can also paste the link into **Connection link** and select **Connect this device**. The first device creates the encrypted vault automatically. No email, account password, or vault passphrase needs typing.

Keep that device unlocked while connecting the other device. For the original one-hour setup window, requests possessing the link connect automatically. Afterwards, open **Sync** on a connected, unlocked device, compare the displayed verification code on both devices, and select **Approve** or **Deny**. Approvals require the connected app to be running and unlocked. The link is a private enrollment capability; do not publish it or paste it into shared chat, shell history, or logs. Manual email/password registration and login remain available, including the optional invitation field.

Paired credentials are stored only through `flutter_secure_storage` in Android Keystore protected storage or Linux libsecret/KDE Wallet. Linux requires an available Secret Service and an unlocked wallet. There is no plaintext or web-storage fallback; one-link pairing is native only. **Unlock this device** reads the device keyring without asking for a vault password. Startup uses the same mechanism. Locking clears the in-memory vault key and pairing secrets; OS keyring access is governed by the device's own login/security settings. Cached conversations and queued changes remain encrypted and can unlock offline.

Paired access tokens expire after one hour. The app refreshes them on startup/resume, before expiry while open, and retries an authenticated request once after a 401. The random refresh token stays in the device keyring; the server keeps only its SHA-256 hash. Refresh validity slides for 90 days. After a refresh expires or the keyring is lost, reconnect using the link and approve from another unlocked device. If every device's vault key is lost, encrypted conversations cannot be recovered. The first bootstrap request and generated vault key are saved to the keyring before enrollment; a lost response can be retried with the same identity during the original bootstrap window, or recovered afterwards using the initial device refresh secret while its 90-day validity remains. Recovery does not extend automatic approval. Pending approval exchange private keys stay in memory: restarting a pending device begins a new exchange.

# Pairing wire contract (v1)

The native URI is `lifenizer://connect?server=<percent-encoded HTTPS API base>#v=1&secret=<base64url 32 bytes>&until=<Unix UTC seconds>`. The fragment secret `S` never reaches the API. Base URL path prefixes such as `/lifenizer` are preserved.

* `bootstrapToken`: unpadded base64url HMAC-SHA256(S, UTF-8 `lifenizer:enroll:v1`).
* Request `publicKey`: X25519 public key (32 bytes, standard base64); `nonce`: random 32 bytes (standard base64). `refreshTokenHash`: lowercase hexadecimal SHA-256 of the UTF-8 random base64url refresh token.
* Request `proof`: standard base64 HMAC-SHA256(S, UTF-8 `lifenizer:device:v1\n<publicKey>\n<nonce>\n<deviceName>\n<refreshTokenHash>`). An unlocked device validates this proof before any approval. Verification code is the first four bytes of SHA-256(public-key bytes concatenated with request-nonce bytes), rendered as eight uppercase hexadecimal digits grouped `XXXX-XXXX`.
* Transfer key: ephemeral sender X25519 shared secret with the requester; HKDF-SHA256, 32 bytes, info UTF-8 `lifenizer:pairing:v1`, salt HMAC-SHA256(S, UTF-8 `lifenizer:transfer:v1\n<request nonce standard-base64 string>`). Binding S prevents the relay inventing a sender key and supplying its own vault key.
* AES-GCM-256 transfer plaintext JSON: `{vaultPassphrase, approvalUntil}`. The deadline is supplied by the approving client inside the authenticated ciphertext. `cipherText` is standard base64 of UTF-8 JSON `{c:<base64 ciphertext>,m:<base64 16-byte tag>}`; transfer `nonce` is standard base64 of 12 bytes; `senderPublicKey` is standard base64 of 32 bytes. The receiver uses the earliest of the source deadline, link deadline and server deadline. A new local enrollment additionally caps automatic approval to one hour.

For recovery of a lost initial bootstrap response, `/api/pairing/refresh` accepts a null/omitted `deviceId` and still requires the original random refresh token; other pending devices cannot use this recovery route.

Unauthenticated API: `POST /api/pairing/request`, `POST /api/pairing/{id}/poll`, and `POST /api/pairing/refresh`. Authenticated API: `GET /api/pairing/pending`, `POST /api/pairing/{id}/approve`, and `POST /api/pairing/{id}/deny` (the last two return 204). The relay stores ciphertext transfers and public request metadata. It never receives S or the vault passphrase. Automatic approval is a client decision based on the locally authorized deadline.

# Manual account login

The optional manual sign-in flow uses your Lifenizer server, with no Google dependency.
The **account password** authenticates to that server. The **vault passphrase**
derives the local encryption key and never goes to the authentication API. Use
the same vault passphrase on KDE and Android to decrypt the same synced vault.
The server returns the same vault ID and salt on every successful account login.

## API

`POST /api/auth/register` accepts:

```json
{"email":"alice@example.org","password":"a long account password","displayName":"Alice"}
```

`POST /api/auth/login` accepts:

```json
{"email":"alice@example.org","password":"a long account password"}
```

Both return the existing authentication response:

```json
{"authToken":"...","userId":"...","vaultId":"...","vaultSalt":"...","tokenType":"Bearer"}
```

Registration requires a valid email and a password of 12–1024 characters.
Passwords are stored using the ASP.NET Core Identity password hasher with
PBKDF2-HMAC-SHA512, 220,000 iterations and a random salt, following the
[OWASP work factor guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2). Existing accounts,
including development accounts, cannot be claimed by registering their email;
registration returns `409 account_exists`. Invalid credentials return `401`.
Registration and login share a per-IP limit of ten requests per minute (`429`).
Manual account bearer tokens expire after 30 days; sign in again to renew the session. Account
password reset and email verification are not provided by this self-hosted flow.

## Host configuration

Set a private `Jwt__Secret` of at least 32 characters before running in
production; the shipped development example is rejected there. Persist the
SQLite database and artifact directory, and expose the API through HTTPS.
Configure `Cors__AllowedOrigins__0` (and subsequent indices) for web clients.

`Auth__AllowDevLogin=false` is the default outside the development environment.
The development login endpoint is intended only for local tests and demos.
Firebase requires explicit `Auth__EnableFirebase=true`; ambient Google
credentials alone never enable or initialize it. If enabled, Firebase verifies
ID tokens with Google and imports the token's email/name into the account.
