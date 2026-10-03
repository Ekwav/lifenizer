# Current Provider Status And Compromises

These are intentional boundaries after the provider import implementation pass.

## Implemented Import Paths

- Email: IMAP login/select/search/fetch with request-scoped credentials. Tests use a mock IMAP server.
- Paperless: document metadata/content fetch from a configured base URL and token. Tests use a mock HTTP API.
- WhatsApp, Telegram, Signal, Discord exports: text/JSON/CSV parsers.
- Slack and Microsoft Teams exports: JSON/text/zip parsers.
- Facebook Messenger and Instagram exports: JSON/text/zip parsers.
- iMessage/SMS exports: text and JSON parsers.
- Local mbox exports: text parser for offline email archive imports.
- Git history imports: plaintext log and JSON commit parsers.
- Browser extension capture imports: URL/content event payload parser.
- Google search history imports: JSON/CSV parser.
- Bookmark imports: browser JSON and Netscape HTML parser.
- Lifenizer backup imports: portable JSON bundle parser.
- Discord API: channel message fetch from a configured base URL and bot token. Tests use a mock HTTP API.
- Browser history: CSV/JSON parser.
- YouTube transcripts: JSON/XML/text parser plus configured transcript URL/base URL fetch. Tests use a mock HTTP API.
- Audio: supplied transcript text, or a base64 payload transcribed through the self-hosted whisper-trained service. Tests use a mock ASR endpoint; the base URL is configuration-only (never request-scoped) to prevent SSRF.
- Scanned PDFs: supplied OCR text is normalized; real OCR engines can feed the same route.
- Full metadata keys and request examples are documented in `docs/IMPORTERS.md`.

## Secrets

- Production IMAP passwords, Paperless tokens, and Discord tokens are intentionally not committed. The whisper-trained transcription service requires no API key (in-cluster only).
- Tests and docs use placeholder secrets only.
- Provider credentials are request-scoped in the current implementation and are not persisted by the backend.

## Remaining Provider Work

- OAuth flows for Gmail/Microsoft mail, Discord OAuth/bot provisioning, and Paperless instance setup are deployment work, not committed secrets.
- Signal live import still depends on export tooling availability; current support targets CSV/text exports.
- Full OCR for images/PDFs needs a provider or on-device engine; the backend route already accepts OCR text.

## Hosted Compute

- Relation extraction is rule-based and receives plaintext by explicit user action.
- Whisper-trained transcription is implemented as a configurable connector (`Whisper:BaseUrl`); the exact in-cluster deployment path must be configured outside source control.
- Any hosted compute result should be encrypted by the client before sync.

## Crypto

- The intended app model is real client-side encryption before sync.
- Backend tests use opaque test strings as ciphertext because the backend must not know encryption internals.
- Production key backup/recovery, device invite flows, and passphrase rotation are not finished yet.

## Billing

- `SubscriptionPlan` and `/api/usage/events` exist to prepare for hosted revenue.
- Payment provider integration is not implemented.

## Recording

- The Flutter app should use DiaFlutter as reference for VAD behavior.
- Browser e2e tests may use simulated recording chunks because automated browsers cannot reliably provide microphone/VAD input without additional fixtures.