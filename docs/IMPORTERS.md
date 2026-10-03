# Importers Guide

This page describes all currently supported import sources in Lifenizer Next, including accepted payload formats and metadata keys for provider-backed routes.

## Endpoints

- `GET /api/imports/capabilities`
- `POST /api/imports/{source}`

All importer responses are normalized and include `plaintextCompute: true`. The client is responsible for encrypting normalized entities before sync.

## Request Shape

`POST /api/imports/{source}` expects this JSON body:

```json
{
  "title": "Optional title",
  "text": "Optional source payload as plaintext",
  "originalFileName": "optional.ext",
  "mimeType": "text/plain",
  "participantNames": ["Alice", "Bob"],
  "metadata": {
    "key": "value"
  },
  "payloadBase64": "optional base64 payload"
}
```

Notes:

- `text` is the simplest route for manual/imported content.
- `payloadBase64` is supported for binary/export payloads.
- If `mimeType` or `originalFileName` indicates zip, the importer extracts text-like entries from the archive.

## Supported Sources

### Local / Export Parsers (no provider credentials required)

- `manual-text`
- `scanned-pdf`
- `live-recording`
- `whatsapp`
- `telegram`
- `signal`
- `discord` (local export mode)
- `slack`
- `teams`
- `facebook-messenger`
- `instagram`
- `imessage`
- `mbox`
- `git`
- `browser-capture`
- `google-search-history`
- `bookmarks`
- `lifenizer-backup`
- `browser-history`
- `youtube-transcript` (local payload mode)

### Provider-backed (credentials or provider config required)

- `email` (IMAP)
- `paperless`
- `discord` (API mode when `metadata.channelId` is set)
- `audio` (whisper-trained transcription mode when using a base64 payload)
- `youtube-transcript` (remote fetch mode when `metadata.videoId` is supplied)

## Metadata Keys by Source

### email (IMAP)

Required:

- Server config `Imports:Imap:Host`
- `username`
- `password`

Optional:

- Server config `Imports:Imap:Port` (default `993`)
- `mailbox` (default `INBOX`)
- Server config `Imports:Imap:UseTls` (default `true`); certificate validation cannot be disabled by a request
- `limit` (1..25)

### paperless

Required:

- Server config `Imports:Paperless:BaseUrl` (no request override)
- `token` or config `Imports:Paperless:Token`

Optional:

- `limit` (1..50)

### discord API mode

Required:

- Server config `Imports:Discord:BaseUrl` (no request override)
- `channelId`
- `token` or config `Imports:Discord:Token`

Optional:

- `limit` (1..100)

### audio transcription mode

Either provide `text` directly, or a `payloadBase64` audio payload with `mimeType`/`originalFileName`
for the backend to transcribe through the self-hosted whisper-trained service
(`onerahmet/openai-whisper-asr-webservice`, `faster_whisper` engine, CPU).

Config (server-side only; the transcription base URL is intentionally **not** overridable from
request metadata to prevent SSRF):

- `Whisper:BaseUrl` (default `http://whisper-trained.tab:9000`)
- `Whisper:Language` (optional; default unset = auto-detect)

Optional request metadata:

- `metadata.language` — per-request ISO language code. Empty or `auto` means auto-detect.
- `metadata.recordedAt` — ISO 8601 date-time (e.g. `2025-10-14T18:05:00Z`) marking when the audio
  was actually recorded. When set, each transcribed segment's `createdAt` is `recordedAt +
  offsetMs` instead of `null`, so the conversation is dated by when it happened rather than when
  it was imported. A value without a UTC offset is assumed to be UTC. Unparseable values, or
  values more than 1 day in the future, are rejected with a 400 naming `metadata.recordedAt`.
  Applies to both the base64 audio payload path and the direct-`text` transcript path.

### youtube-transcript remote mode

Set server config `Imports:YouTube:BaseUrl` and send `metadata.videoId`.
Request `baseUrl` and `transcriptUrl` overrides are rejected, and redirects are disabled.
Pasted transcript text does not require a remote service.

### browser-capture

Optional:

- `metadata.url`
- `metadata.title`
- `metadata.referrer`

Recommended payload shape:

```json
{
  "events": [
    {
      "title": "Importer docs",
      "url": "https://example.test/page",
      "content": "Page text or summary",
      "timestamp": "2026-06-01T10:00:00Z"
    }
  ]
}
```

### google-search-history

Supported forms:

- JSON exports (Google activity style)
- CSV (`query,url,time` or similar)

### bookmarks

Supported forms:

- Browser JSON exports (`roots` / `children` trees)
- Netscape bookmark HTML export (`<A HREF=...>`)

### git

Supported forms:

- Plaintext `git log` style output
- JSON commit arrays (`commits`, `items`, `history`)

Optional:

- `metadata.repository`
- `metadata.repoUrl`

### lifenizer-backup

Supported forms:

- JSON backup bundles with `conversations` array
- Optional zip payload containing backup JSON

## Examples

### WhatsApp text export

```json
{
  "title": "Family chat",
  "text": "[20.05.2026, 10:00] Alice: hello\n[20.05.2026, 10:01] Bob: hi"
}
```

### Slack JSON export

```json
{
  "source": "slack",
  "text": "[{\"user_profile\":{\"display_name\":\"Nina\"},\"text\":\"Standup done\",\"ts\":\"1716206400.0\"}]",
  "mimeType": "application/json",
  "originalFileName": "general.json"
}
```

### Teams JSON export with HTML content

```json
{
  "source": "teams",
  "text": "{\"messages\":[{\"fromDisplayName\":\"Jon\",\"content\":\"<p>Review merged</p>\",\"createdDateTime\":\"2026-05-20T13:10:00Z\"}]}",
  "mimeType": "application/json"
}
```

### mbox local export

```json
{
  "source": "mbox",
  "text": "From sender@example.test Tue May 20 10:15:00 2026\nFrom: Sender <sender@example.test>\nTo: Receiver <receiver@example.test>\nSubject: Hello\nDate: Tue, 20 May 2026 10:15:00 +0000\n\nBody"
}
```

### Browser extension capture payload

```json
{
  "source": "browser-capture",
  "title": "Captured content",
  "text": "{\"events\":[{\"title\":\"Article\",\"url\":\"https://news.example.test/a\",\"content\":\"...\",\"timestamp\":\"2026-06-01T09:00:00Z\"}]}",
  "mimeType": "application/json"
}
```

### Google search history CSV

```json
{
  "source": "google-search-history",
  "text": "query,url,time\nflutter receive sharing intent,https://www.google.com/search?q=flutter+receive+sharing+intent,2026-06-01T09:10:00Z",
  "mimeType": "text/csv"
}
```

### Lifenizer backup import

```json
{
  "source": "lifenizer-backup",
  "text": "{\"conversations\":[{\"title\":\"Recovered\",\"source\":\"manual-text\",\"participantNames\":[\"Alice\"],\"segments\":[{\"text\":\"Recovered from backup\",\"participantName\":\"Alice\",\"offsetMs\":0}]}]}",
  "mimeType": "application/json"
}
```

## Browser Extension Integration

Recommended browser extension flow:

1. Capture page URL/title + extracted content in the extension.
2. POST to `POST /api/imports/browser-capture` with an authenticated bearer token.
3. Use `events[]` JSON shape from this document.
4. Encrypt normalized results client-side before sync (already done by app).

This works for custom extensions and automation scripts alike.

## Android Share Target

The Android app is configured as a share target for text and files (`SEND` / `SEND_MULTIPLE`).

Behavior:

- Shared URLs/text route to `browser-capture` or `manual-text`.
- Shared backups route to `lifenizer-backup` (filename heuristics + JSON).
- Shared audio routes to Whisper with a transcription timeout; text and URLs are captured locally. Other exports use supported importer routes. Binary PDFs/images require extracted OCR text or an image attachment; importing them does not pretend to perform OCR.

The app queues incoming share intents and ingests them once the vault is unlocked.

### IMAP provider import

```json
{
  "metadata": {
    "username": "alice@example.com",
    "password": "secret",
    "mailbox": "INBOX"
  }
}
```

## Security Notes

- Request-scoped provider credentials are not persisted by the backend.
- Provider destinations are server configuration only. Request endpoint/TLS overrides are rejected, and HTTP redirects are disabled.
- Keep production secrets in secure environment configuration, not in repository files.

## Validation

Importer coverage is exercised by integration tests in:

- `backend/Lifenizer.Tests/ImportIntegrationTests.cs`
