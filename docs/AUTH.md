# Self-hosted accounts

The normal sign-in flow uses your Lifenizer server, with no Google dependency.
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
PBKDF2-HMAC-SHA512, 210,000 iterations and a random salt. Existing accounts,
including development accounts, cannot be claimed by registering their email;
registration returns `409 account_exists`. Invalid credentials return `401`.
Registration and login share a per-IP limit of ten requests per minute (`429`).
Bearer tokens expire after 30 days; sign in again to renew the session. Account
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
