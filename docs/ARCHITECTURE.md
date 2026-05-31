# Lifenizer Next Architecture

Lifenizer Next is a Flutter + ASP.NET Core rewrite of the original prototype. The legacy `api`, `core`, and Angular `frontend` folders remain as reference code while the new implementation lives under `next`.

## Goals

- Local-first personal archive for life data.
- End-to-end encrypted sync across devices.
- Search over decrypted local data, including participants and relation facts.
- Hosted backend for account login, encrypted sync relay, and explicit opt-in compute tasks.
- Revenue-ready backend boundaries for usage tracking and plans.

## Backend

The backend lives in `backend/`:

- `Lifenizer.Core`: DTOs and domain contracts shared by API/tests.
- `Lifenizer.Api`: ASP.NET Core API, SQLite persistence, JWT auth, sync relay, import execution, TAP/Coflnet transcription connector, IMAP/HTTP provider connectors, and relation extraction endpoint.
- `Lifenizer.Tests`: API integration tests.

Auth follows the AneApi/Coflnet pattern without importing CoflnetCore: `/api/auth/firebase` targets Firebase ID token exchange, while `/api/auth/dev-login` is enabled only by configuration for local development and e2e tests.

## E2EE Model

The backend stores `SyncEnvelopeRecord` rows as ciphertext. It scopes records by authenticated user and vault, but it does not decrypt payloads.

Clients derive a vault key from user passphrase plus backend-provided vault salt, encrypt normalized entities, then push envelopes through `/api/sync/push`. Other devices pull envelopes from `/api/sync/pull`, decrypt locally, and rebuild the local search index.

## Compute Compromise

Transcription, OCR, remote imports, and relation extraction cannot be fully backend-hosted and fully opaque at the same time. Backend compute/import endpoints are therefore explicit opt-in plaintext lanes. Results must be encrypted by the client before sync storage.

`/api/analysis/relations/extract` currently implements a rule-based extractor and returns `plaintextCompute: true` to mark that compromise.

`POST /api/imports/{source}` also returns `plaintextCompute: true`. It normalizes provider data into conversations and participants, but it does not persist provider secrets or imported plaintext.

## Import Shape

`/api/imports/capabilities` advertises all intended import routes. `POST /api/imports/{source}` normalizes these sources:

- IMAP email using request-scoped host/user/password metadata.
- Paperless document metadata/content using request-scoped base URL and token metadata.
- WhatsApp, Telegram, Signal, Discord, Slack, Teams, Facebook Messenger, Instagram, and iMessage/SMS exports from pasted text/JSON/CSV/zip payloads.
- Local `mbox` email exports without live IMAP credentials.
- Git history imports from plaintext logs or JSON commit snapshots.
- Browser extension capture payloads for consumed URLs/content (`browser-capture`).
- Google search history imports from JSON/CSV exports.
- Bookmark imports from JSON and Netscape HTML exports.
- Lifenizer backup imports from portable JSON bundles.
- Discord channel messages from a configured API URL and bot token.
- Browser history CSV/JSON.
- YouTube transcript JSON/XML/text from pasted content or a configured transcript URL/base URL.
- Audio transcript text directly, or audio payloads through the configurable TAP/Coflnet transcription API (`Tap:BaseUrl`, `Tap:TranscriptionPath`, `Tap:ApiKey`).
- Scanned PDF/OCR text through supplied OCR text metadata or text body.

Concrete request examples and accepted metadata keys are documented in `docs/IMPORTERS.md`.

The Flutter client consumes normalized import results, creates local participants/conversations, encrypts them with the vault key, and pushes ciphertext sync envelopes.

## Data Flow

1. User logs in with Firebase or dev auth.
2. Backend returns JWT, user id, vault id, and vault salt.
3. Flutter derives a vault key locally.
4. User records/imports/searches data locally.
5. Flutter encrypts each normalized entity into sync envelopes.
6. Backend stores envelopes as ciphertext.
7. Other devices pull, decrypt, and index locally.