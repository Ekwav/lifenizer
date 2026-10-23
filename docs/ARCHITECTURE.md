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

Clients derive a vault key from user passphrase plus backend-provided vault salt, encrypt normalized entities, then push envelopes through `/api/sync/push`. Other devices pull envelopes from `/api/sync/pull`, decrypt locally, and update the local search index.

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

Desktop only: `BrowserHistoryWatchService` keeps YouTube/TikTok viewing history current without any provider API. It copies the local Firefox/Chromium history database to a temp file, reads only YouTube/TikTok video visits (via `package:sqlite3`), maps them to Takeout/TikTok-shaped JSON on the client and sends them through the normal `youtube-watch-history` / `tiktok-watch-history` imports, so no backend change is involved. See IMPORTERS.md, "Keeping viewing history updated from the browser".

## Data Flow

1. User logs in with the self-hosted account password.
2. Backend returns JWT, user id, vault id, and vault salt.
3. Flutter derives a vault key locally.
4. User records/imports/searches data locally.
5. Flutter encrypts each normalized entity into sync envelopes.
6. Backend stores envelopes as ciphertext.
7. Other devices pull, decrypt, and index locally.

## Local persistence and sync

The local vault uses an AES-GCM-encrypted core plus conversation buckets. Sembast
stores the core in the native application support directory or browser IndexedDB;
native conversation buckets use separate atomic files where supported. The core
contains participants, relations, pending ciphertext envelopes, the last successfully
pulled cursor, an encrypted session token and optional microphone-draft metadata.
Draft audio has its own encrypted record. Connection preferences, storage
format/count/nonce metadata and the KDF salt sit outside encrypted entity payloads.

A compressed, encrypted prepared search snapshot stores conversation summaries,
previews and search postings. Cached unlock restores searchable results without
decrypting conversation bodies. Opening a conversation decrypts its bucket on demand;
concurrent requests share that load. Saves hydrate dirty buckets before rewriting
them, preserving unloaded neighbors. Missing, stale or corrupt search snapshots fall
back to authenticated bucket loading and index rebuilding; the cache is disposable.
Core nonce references and two-phase bucket saves protect crash recovery. Remote sync
continues in the background after a valid cached unlock.

Manual unlock still derives and validates the vault key from the passphrase. Paired
native devices may retain the derived key and its salt alongside their paired
passphrase in the existing protected OS keyring, password-wrapped or biometric
credential store. This enables local unlock before remote access refresh; it does not
write keys to ordinary preferences or vault snapshots. Lock clears decrypted state,
search indexes and decoded image/audio playback caches.

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

## Recording storage and details

A stopped microphone recording is an encrypted local draft: the core stores its
metadata and a separate encrypted record stores the WAV payload. The user can play
and seek the draft, transcribe it, or **Save recording to library** without
transcription. Library audio conversations retain encrypted original bytes separately
from conversation/search data: native files live under the application-support
`audio/` directory; web originals use the `lifenizer-audio` IndexedDB database. New
transcribed imports retain their originals too.

Playback loads local audio first. If absent, authenticated `/api/recordings` endpoints
serve an explicitly stored encrypted copy or request a live encrypted transfer from
another open, unlocked device holding the original. The main device can therefore
supply playback without persistent online audio storage. The backend routes opaque
ciphertext within the authenticated vault; the receiving device decrypts and caches
it locally. Live relay is temporary and stops when the supplying device locks or
changes vault. **Store encrypted recording online** explicitly enables persistent
server storage with quota accounting; disabling it removes the server copy while
preserving local originals. Transcription remains a separate plaintext compute lane.

Stored recording envelopes are limited to 200 MB and count toward vault quota. Live
relay waits up to 20 seconds for an unlocked provider and currently requires both
devices to reach the same backend instance. Playback decodes in memory without
plaintext temporary files; WAV, MP3, Ogg and FLAC are supported by the bundled decoder.

Right after "Stop and save" (or when Capture opens with a restored draft whose `detailsPrompted` is false, for example after stopping from the Android notification) a bottom sheet asks for a title and people. The details live in the draft (`title`, `participantNames`, `detailsPrompted`, written by `updateAudioDraftDetails`), so they survive navigation, restarts and lock/unlock and are the single source for `importAudioBytes`. Suggestions come from `RecordingSuggestionService` (pure Dart): people are ranked from the last eight weeks by weekday and time-of-day proximity to the recording (same slot last week scores highest, with recency decay), titles from similar earlier audio recordings, and both fields autocomplete case- and diacritic-insensitively over display names, aliases and past titles. Names that match no existing participant are created by the import.

## Import setup and browser extension

Imports starts with an automatic file picker/drop target and a searchable adapter
catalogue. Numbered setup instructions and existing configuration panels open only
for the selected adapter. Local Discord packages remain available without provider
credentials. YouTube, TikTok, WhatsApp Web and Discord Web each have a separate
extension setup entry with installation, pairing and provider-specific instructions.

Desktop only, opt-in: `BrowserExtensionReceiverService` listens on loopback
(127.0.0.1, default port 47615) for the extension in `integrations/browser-extension/`.
A regenerable random bearer token, Host/extension-Origin checks and an 8 MB streaming
body limit protect `GET /v1/ping`, `POST /v1/watch-history` and `POST /v1/messages`.
A locked vault rejects imports. Watch-history batches reuse the local browser-history
classification path. Message batches normalize stable platform thread/message IDs
and merge through the usual encrypted import path.

YouTube/TikTok collection requires configured account IDs or handles verified against
signed-in self-account context. Account-bound pending history is held after account
changes; legacy unverified records stay unsent. Separately opted-in WhatsApp/Discord
observers use visible DOM only and baseline existing messages on attachment/navigation.
They collect newly rendered messages in open conversations, without history scrolling,
cookie/token access or send actions. The extension validates runtime senders and keeps
a deduplicated local outbox until delivery succeeds. Unsupported layouts fail visibly;
logged-in live-site validation remains outstanding. See [IMPORTERS.md](IMPORTERS.md)
and the [extension guide](../integrations/browser-extension/README.md).
