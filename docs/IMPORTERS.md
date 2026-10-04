# Importers Guide

This page describes all currently supported import sources in Lifenizer Next, including accepted payload formats and metadata keys for provider-backed routes.

For Telegram, WhatsApp and Lifenizer exports, use **Imports → Choose backup or export** or share the file to Lifenizer on Android. See [the share and file-picker guide](#android-share-target-and-file-picker) below.

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
- If `mimeType` or `originalFileName` indicates ZIP, the importer extracts the first preferred text-like entry. It does not merge several chats or import archived media.

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

Use **Imports → Connect email** in the app. See the [email setup guide](EMAIL.md)
for credentials, automatic checks and TLS configuration.

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

### Discord data package (local desktop import)

In the native desktop app, open **Imports → Choose backup or export**, or drag
Discord's `package.zip` onto Imports. The reader opens the ZIP directory and
inflates only `Account/user.json`, the message channel index, `channel.json` and
`messages.json` under `Messages/` or German `Nachrichten/`. Activity files and
media remain compressed; the whole package is never loaded or uploaded, and no
plaintext extraction directory is created. Selected JSON is bounded to 8 MiB per
entry and 256 MiB per import. Large packages use this local route rather than the
64 MiB general upload route.

[Discord's official data package](https://support.discord.com/hc/en-us/articles/360004957991-Your-Discord-Data-Package)
contains your **own sent messages**, not other people's replies. Imports retain
channel/message IDs, dates and attachment links. Account/recipient IDs identify
people without guessing from shared display names; account email and Discord ID
can identify the same person. Deleted recipients without IDs remain unlinked.
Repeat exports merge appended messages and edits into existing threads while
retaining older history and your favorites/tags. IDs are stable across devices.

Enable **Watch this Discord export for changes** to import again when you
replace the chosen ZIP with a newer export, while the desktop app is open and
unlocked. Stop watching from Imports. The watched path is stored in the OS
keyring, scoped to the account; message content stays in the encrypted vault.
This watches a local export and does not fetch new messages from Discord.

Continuous Discord access requires a separately authorized integration.
[Discord RPC](https://docs.discord.com/developers/topics/rpc) uses OAuth and
[restricted scopes](https://docs.discord.com/developers/topics/oauth2);
personal-token [self-bot automation is prohibited](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots).
A bot can ingest channels it is permitted to access, with the required gateway
intents and permissions; no such bot is configured by this importer.

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

## Android Share Target and File Picker

On Android, share an exported file to **Lifenizer**, unlock the vault, and the
Imports page opens automatically. On Android, KDE and the web app, use
**Imports → Choose backup or export** to select a file directly.

The app detects these readable exports from their contents:

- Telegram Desktop JSON: one chat's `result.json`, or a full export containing
  `chats.list`. Chats, speakers, rich text and historical message dates stay separate.
- WhatsApp **Export chat** text, including bracketed and dash-separated timestamps.
  A ZIP with a WhatsApp filename uses its exported chat text; ZIPs should contain
  one chat. Media inside ZIPs is not imported as attachments.
- Lifenizer JSON with `conversations` and `segments`. Snapshots that also include
  a top-level participant list resolve participant IDs to names.

For a ZIP with an ambiguous name, or another supported format, enter its source
in the form and use **Choose file for this source**. Unknown JSON and CSV require
an explicit source; they are not silently stored as chat text. The import result
shows the detected source, added conversation count, and duplicate count.

Importing an identical export again skips its conversations, even if the file is
renamed, the app restarts, or another synced device imports it. Fingerprints live
inside encrypted conversation records and encrypted local snapshots. Historical
imports made before duplicate protection have no fingerprints. For formats without stable thread/message IDs, changed exports
are new imports. Discord data packages and paginated email imports use stable
IDs to merge updates. The optional Discord export watch is described above. Avoid importing the same changed export on two
devices simultaneously before they sync.

Shared files wait in memory while locked, are read from Android content grants
after unlock, and leave no app-created plaintext share cache. Closing/restarting
before import completes requires sharing again. Native sharing and the general
file picker accept files up to 64 MiB; native desktop Discord ZIP
imports selectively read larger packages as described above. The configured server processes readable
exports in plaintext, then the app encrypts the results before storage and sync.
Encrypted WhatsApp/Signal database backups and encrypted Lifenizer cache files
are not readable chat exports; use the messenger's chat export or connect the
original Lifenizer vault instead.

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
- `backend/Lifenizer.Tests/BackupParserTests.cs`
- `app/test/backup_import_test.dart`
- `app/test/share_intent_test.dart`
