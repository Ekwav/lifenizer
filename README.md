# Lifenizer Next

New Flutter + ASP.NET Core implementation. The legacy prototype remains in the repository root folders.

## Backend

```bash
cd backend
dotnet restore LifenizerNext.slnx --ignore-failed-sources
dotnet test LifenizerNext.slnx --no-restore
../scripts/run-api.sh
```

The backend exposes:

- `POST /api/auth/register` and `POST /api/auth/login`
- `POST /api/auth/firebase` (explicit opt-in only)
- `POST /api/auth/dev-login` for local/e2e when enabled
- `/api/pairing/*` for one-link enrollment, device approval and session refresh
- `POST /api/sync/push`
- `GET /api/sync/pull?since=0`
- `GET /api/imports/capabilities`
- `POST /api/imports/{source}` for normalized plaintext import previews
- `POST /api/analysis/relations/extract`
- `POST /api/usage/events`

Provider imports currently cover IMAP email, Paperless, WhatsApp, Telegram, Signal, Discord export/API, Slack, Teams, Facebook Messenger, Instagram DM, iMessage/SMS text exports, local mbox exports, git history, browser extension capture payloads, Google search history, bookmarks, browser history, YouTube transcripts, scanned OCR text, Lifenizer backup bundles, and self-hosted whisper-trained audio transcription. Production secrets are supplied through request metadata or configuration, while tests use placeholder secrets and mock servers.

## Flutter

```bash
cd app
flutter analyze
flutter test
flutter build web
flutter build apk --release
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5174
```

The app derives a vault key locally from the passphrase and backend-provided vault salt, encrypts entities with AES-GCM, and syncs ciphertext envelopes through the backend.

Android builds are configured as a share target for text/files/backups, so users can share content directly into importer routes once the vault is unlocked.

Local organization features run after decryption in the client: imported conversations receive searchable tags, Search supports source/participant/tag facets, saved searches sync as encrypted entities, and the Insights tab summarizes timeline, source, participant, artifact, segment, and tag coverage without exposing plaintext to the backend.

## Landing Pages

Static landing pages live in `landing/` and can be served by any static web server.

## Notes

See `docs/ARCHITECTURE.md`, `docs/IMPORTERS.md`, and `docs/PLACEHOLDERS.md` for architecture, importer setup examples, and current provider placeholders.

## Daily use on KDE and Android

Deploy the mail server with `./scripts/deploy-compose.py`, following
[deployment](docs/DEPLOYMENT.md). Installation prints a connection link and QR code.
Open that link on KDE and Android: it configures the server, account and encrypted
vault without typing passwords. Keep the first device unlocked while adding the next.
Connections are automatic for one hour, then require approval in **Sync** on a
connected device. Native credentials stay in Android secure storage or KDE Wallet.

For local development, `./scripts/run-api.sh` keeps its database, artifacts and
signing key under `~/.local/state/lifenizer/`; development login is disabled.
The optional manual account flow uses a separate account password and vault
passphrase, with the latter staying on-device.

Build `app/` with `flutter build linux --release`, then run
`./integrations/kde/install.sh` from the repository root. Open Lifenizer and unlock it.
Use KRunner `life Alice holiday` to find conversations, or Ctrl+K inside the app.
Android builds provide launcher Search/Capture/Imports shortcuts, selected-text search,
`ACTION_SEARCH`, and share targets. See [integration setup](docs/INTEGRATIONS.md).

Drag backups onto **Imports**, or choose a file there. Discord data packages are
read locally, including large ZIPs; enable **Watch this Discord export for changes**
to import replacements automatically while the desktop app is open and unlocked.
This does not fetch messages from Discord. See [supported imports](docs/IMPORTERS.md).
For IMAP, use **Imports → Connect email** with your email username and app password;
[email setup](docs/EMAIL.md) explains remembered credentials and automatic checks.

People are detected from provider IDs and email addresses. In **People**, use
**Link identity** or **Merge people** to connect a Discord account with an email
contact. Matching names alone do not merge two known identities. Linked identities,
aliases and conversation references sync encrypted; future imports reuse the person.

Encrypted local snapshots and an encrypted retry queue survive app restarts. Paired
devices unlock from their OS keyring, including offline. Manual accounts provide
**Unlock this device offline** after an initial online unlock.
Sync runs on resume and every 30 seconds while active. Capture typed text offline;
recordings are saved encrypted locally until you explicitly send them to Whisper.
Provider imports, transcription and relation extraction require the configured server;
local Discord ZIP imports can be saved offline and synced later.
New image attachments are encrypted; historical plaintext image uploads require
re-uploading to encrypt them. Image downloads currently require a connection.

Search handles German/Unicode names, partial words, spelling mistakes, combined
person/topic queries and local-calendar date phrases. [Search details and the
repeatable 10,000-conversation benchmark](docs/SEARCH.md) explain ranking and limits.

Run `./scripts/verify.sh` for the normal checks. With the real Whisper service forwarded,
run `./scripts/verify.sh --live-whisper`; this requires the service and cannot silently
skip the audio test. [Database upgrades](docs/DATABASE.md), [account authentication](docs/AUTH.md),
and [remaining provider boundaries](docs/PLACEHOLDERS.md) cover deployment details.
