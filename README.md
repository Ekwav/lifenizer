# Lifenizer Next

New Flutter + ASP.NET Core implementation. The legacy prototype remains in the repository root folders.

## Backend

```bash
cd backend
dotnet restore LifenizerNext.slnx --ignore-failed-sources
dotnet test LifenizerNext.slnx --no-restore
ASPNETCORE_URLS=http://127.0.0.1:5075 dotnet run --project Lifenizer.Api/Lifenizer.Api.csproj
```

The backend exposes:

- `POST /api/auth/firebase`
- `POST /api/auth/dev-login` for local/e2e when enabled
- `POST /api/sync/push`
- `GET /api/sync/pull?since=0`
- `GET /api/imports/capabilities`
- `POST /api/imports/{source}` for normalized plaintext import previews
- `POST /api/analysis/relations/extract`
- `POST /api/usage/events`

Provider imports currently cover IMAP email, Paperless, WhatsApp, Telegram, Signal, Discord export/API, browser history, YouTube transcripts, scanned OCR text, and TAP/Coflnet-backed audio transcription. Production secrets are supplied through request metadata or configuration, while tests use placeholder secrets and mock servers.

## Flutter

```bash
cd app
flutter analyze
flutter test
flutter build web
flutter build apk --debug
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5174
```

The app derives a vault key locally from the passphrase and backend-provided vault salt, encrypts entities with AES-GCM, and syncs ciphertext envelopes through the backend.

Local organization features run after decryption in the client: imported conversations receive searchable tags, Search supports source/participant/tag facets, saved searches sync as encrypted entities, and the Insights tab summarizes timeline, source, participant, artifact, segment, and tag coverage without exposing plaintext to the backend.

## Landing Pages

Static landing pages live in `landing/` and can be served by any static web server.

## Notes

See `docs/ARCHITECTURE.md` and `docs/PLACEHOLDERS.md` for the security model and current provider placeholders.
