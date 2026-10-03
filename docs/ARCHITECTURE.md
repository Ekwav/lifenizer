# Lifenizer Next Architecture

Lifenizer Next is a Flutter + ASP.NET Core rewrite of the original prototype. The legacy `api`, `core`, and Angular `frontend` folders remain as reference code while the new implementation lives under `app/` and `backend/`.

## Goals

- Local-first personal archive for life data.
- End-to-end encrypted sync across devices.
- Search over decrypted local data, including participants and relation facts.
- Hosted backend for account login, encrypted sync relay, and explicit opt-in compute tasks.
- Revenue-ready backend boundaries for usage tracking and plans.

## Backend

The backend lives in `backend/`:

- `Lifenizer.Core`: DTOs and domain contracts shared by API/tests.
- `Lifenizer.Api`: ASP.NET Core API, SQLite persistence, JWT auth, sync relay, import execution, whisper-trained transcription connector, IMAP/HTTP provider connectors, and relation extraction endpoint.
- `Lifenizer.Tests`: API integration tests.

Self-hosted `/api/auth/register` and `/api/auth/login` use a salted server-side password hash. The account password is separate from the vault passphrase. Firebase requires `Auth:EnableFirebase=true`; ambient Google credentials alone do not enable it. Development login remains for explicitly enabled test environments. See `AUTH.md`.

## E2EE Model

The backend stores `SyncEnvelopeRecord` rows as ciphertext. It scopes records by authenticated user and vault, but it does not decrypt payloads.

Clients derive a vault key from user passphrase plus backend-provided vault salt, encrypt normalized entities, then push envelopes through `/api/sync/push`. Other devices pull envelopes from `/api/sync/pull`, decrypt locally, and rebuild the local search index.

## Compute Compromise

Transcription, OCR, remote imports, and relation extraction cannot be fully backend-hosted and fully opaque at the same time. Backend compute/import endpoints are therefore explicit opt-in plaintext lanes. Results must be encrypted by the client before sync storage.

`/api/analysis/relations/extract` currently implements a rule-based extractor and returns `plaintextCompute: true` to mark that compromise.

`POST /api/imports/{source}` also returns `plaintextCompute: true`. It normalizes provider data into conversations and participants, but it does not persist provider secrets or imported plaintext.

## Import Shape

`/api/imports/capabilities` advertises all intended import routes. `POST /api/imports/{source}` normalizes these sources:

- IMAP email using a configured host/TLS policy and request-scoped username/password.
- Paperless document metadata/content using a configured base URL and request-scoped token.
- WhatsApp, Telegram, Signal, Discord, Slack, Teams, Facebook Messenger, Instagram, and iMessage/SMS exports from pasted text/JSON/CSV/zip payloads.
- Local `mbox` email exports without live IMAP credentials.
- Git history imports from plaintext logs or JSON commit snapshots.
- Browser extension capture payloads for consumed URLs/content (`browser-capture`).
- Google search history imports from JSON/CSV exports.
- Bookmark imports from JSON and Netscape HTML exports.
- Lifenizer backup imports from portable JSON bundles.
- Discord channel messages from a configured API URL and bot token.
- Browser history CSV/JSON.
- YouTube transcript JSON/XML/text from pasted content or a configured transcript base URL.
- Audio transcript text directly, or audio payloads transcribed through the self-hosted whisper-trained service (`Whisper:BaseUrl`, optional `Whisper:Language`).
- Scanned PDF/OCR text through supplied OCR text metadata or text body.

Concrete request examples and accepted metadata keys are documented in `docs/IMPORTERS.md`.

The Flutter client consumes normalized import results, creates local participants/conversations, encrypts them with the vault key, and pushes ciphertext sync envelopes.

## Data Flow

1. User logs in with the self-hosted account password.
2. Backend returns JWT, user id, vault id, and vault salt.
3. Flutter derives a vault key locally.
4. User records/imports/searches data locally.
5. Flutter encrypts each normalized entity into sync envelopes.
6. Backend stores envelopes as ciphertext.
7. Other devices pull, decrypt, and index locally.

## Local persistence and sync

Sembast stores an AES-GCM-encrypted snapshot in the native application support directory
or browser IndexedDB. The snapshot includes entities, pending ciphertext envelopes,
last successfully pulled cursor, encrypted session token and an optional microphone draft.
Only connection preferences and the KDF salt sit outside encryption. Passwords and vault
keys are never persisted. Lock clears decrypted state, search indexes and decoded image caches.

The client persists outgoing envelopes before attempting a push. Retry IDs are idempotent.
Push responses never advance the pull cursor; pulls drain 500-envelope pages and advance
the cursor only after successful decryption. Pending local edits take precedence until
acknowledged; later server sequence wins on conflicting acknowledged updates. This is
whole-entity last-writer-wins, not collaborative text merging. Sessions sync periodically
while active and on resume; offline unlock uses the encrypted local snapshot.

New image uploads encrypt bytes, filename and MIME inside an opaque envelope. The server
stores a random filename and ciphertext, with quota accounting based on encrypted size.
Old plaintext image uploads remain readable and must be re-uploaded for encryption.
Manual captures and shared plain text/URLs can stay entirely on-device until encrypted sync.
Provider normalization and audio transcription remain explicit plaintext compute operations.
