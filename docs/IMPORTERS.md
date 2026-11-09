# Importers Guide

This page describes all currently supported import sources in Lifenizer Next, including accepted payload formats and metadata keys for provider-backed routes.

For Telegram, WhatsApp and Lifenizer exports, use **Imports → Choose backup or export** or share the file to Lifenizer on Android. See [the share and file-picker guide](#android-share-target-and-file-picker) below.

The Imports page starts with automatic file selection and drag/drop. Use **Find an
importer** to search available sources; selecting an adapter opens its setup steps
and configuration instead of mounting every form at once. **Browser extension** lists
YouTube, TikTok, WhatsApp Web and Discord Web separately, with installation and pairing
instructions for each. File-based exports remain separate from extension capture.

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
- `photo`
- `youtube-watch-history`
- `tiktok-watch-history`
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
- `youtube-transcript` (remote fetch mode when `metadata.videoId` is supplied; built-in YouTube caption fetcher or configured `Imports:YouTube:BaseUrl`)

## Metadata Keys by Source

### email (IMAP)

Use **Imports → Email (IMAP)** in the app. See the [email setup guide](EMAIL.md)
for credentials, automatic checks and TLS configuration. Supported attachment
text (PDF, TXT, CSV, HTML, DOCX and ODT) is indexed alongside the message body.
Skipped or failed attachments preserve the body and appear in the import status;
**Reindex attachments** can retry temporary failures.

Required:

- Server config `Imports:Imap:Host`
- `username`
- `password`

Optional:

- Server config `Imports:Imap:Port` (default `993`)
- `mailbox` (default `INBOX`)
- Server config `Imports:Imap:UseTls` (default `true`); certificate validation cannot be disabled by a request
- `limit` (1..25)

### PDF and scan folders

Use **Imports → Choose backup or export** or the source file picker for a PDF,
PNG or JPEG scan. Native desktop users can also drag the document onto Imports.
The `scanned-pdf` API source accepts a binary `payloadBase64` with `mimeType`
`application/pdf`, `image/png` or `image/jpeg`; supplied `text` or
`metadata.ocrText` remains supported. Optional `metadata.documentId` gives a
stable thread and message ID for repeated imports of the same document.

On the native desktop, select a scan folder or Downloads folder to watch PDFs,
PNG and JPEG files. Only files directly in the selected folder are indexed;
subdirectories are not traversed. Checks run while the app is open and unlocked.
The saved folder path and file stamps stay in the OS credential store. Changed
files are reimported into the existing document; unchanged files are skipped.
Unreadable documents report their filename and remain retryable while other
files continue importing. Each check attempts at most 100 changed documents.
Locking pauses imports. Restarting the app restores the saved watch after unlock.

The API extracts digital PDF text with Poppler and OCRs pages without text with
Tesseract, including mixed PDFs. Scanned pages render sequentially to at most
2,000 pixels on the long side. Standalone PNG/JPEG images are limited to 25
megapixels and 10,000 pixels per side. Documents are limited to 25 MiB, PDFs to
100 pages, extracted text to 4 MiB and processing to two minutes per document.
Invalid, encrypted, oversized or unreadable documents report a failure instead
of indexing their binary bytes or claiming that extraction succeeded.

The Docker API image supplies `poppler-utils`, `tesseract-ocr`,
`tesseract-ocr-data-deu` and `tesseract-ocr-data-eng`. Bare installations need the
equivalent native tools and language data on PATH. OCR uses installed German and
English models, with a single-language fallback when only one is installed.
Documents are processed in private temporary directories and removed afterward.
The app stores and syncs the extracted text encrypted; original PDF/image bytes
are not retained as vault artifacts. [Poppler text extraction](https://manpages.debian.org/bullseye/poppler-utils/pdftotext.1.en.html)
and [Tesseract usage](https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html)
describe the underlying native tools.

### photo

One camera image per request (JPEG, PNG, WebP, HEIC/HEIF; at most 25 MiB, 25
megapixels, 10,000 px per side), sent like `scanned-pdf` as `payloadBase64`:

```json
{
  "originalFileName": "IMG_0001.jpg",
  "mimeType": "image/jpeg",
  "payloadBase64": "<base64 image bytes>",
  "metadata": { "capturedAt": "2024-05-06T07:08:09Z", "utcOffsetMinutes": "120" }
}
```

`metadata.capturedAt` (ISO 8601) and `metadata.utcOffsetMinutes` are optional.
Capture time is EXIF `DateTimeOriginal` (then `DateTimeDigitized`/`DateTime`), with the EXIF
`OffsetTimeOriginal` when present, else `utcOffsetMinutes`, else UTC; if the image has no EXIF date
the client `capturedAt` is used, else the import time (`metadata.capturedAtSource` is
`exif`, `client` or `import`). The response contains ONE conversation with `source: "photo"`,
`sourceThreadId: "photo:<sha256 of the bytes>"` (re-importing the same image updates the same
conversation, which is how the client de-duplicates), `sourceUrl` unset, title = first meaningful
OCR line (max 80 chars) or `Photo yyyy-MM-dd HH:mm`, one segment per OCR paragraph (max 200, each
with `createdAt = capturedAt` and `sourceMessageId = <sha256>:<n>`), or a single segment holding the
file name when no text was found. Metadata: `capturedAt`, `capturedAtSource`, `fileName`, `mimeType`,
`cameraMake`, `cameraModel` (when present), `width`, `height`, `ocr` (`tesseract` or `none`),
`hasGps` (`true`/`false`) and `contentSha256`. GPS coordinates are read only to set `hasGps` and are
never returned or stored. OCR reuses the PDF Tesseract setup (German + English models already in the
Docker image, no new packages). HEIC/HEIF: metadata is read but no decoder exists, so `ocr` is
`none`; convert to JPEG on the device first if text search is wanted. WebP OCR depends on the
installed Leptonica build and silently falls back to `ocr: none`. EXIF is parsed with
[MetadataExtractor](https://github.com/drewnoakes/metadata-extractor-dotnet) 2.9.3 (Apache-2.0).

### youtube-watch-history and tiktok-watch-history

Send the export file as `text` (or `payloadBase64`; a zip uses the existing first-text-entry rule,
so extract `watch-history.json` / `watch-history.html` first for multi-file Takeout archives):

```json
{ "originalFileName": "watch-history.json", "mimeType": "application/json", "text": "<file contents>" }
```

Capabilities list `fileNameHints` (`watch-history.json|html`, `user_data*.json`,
`Video Browsing History.txt`, `Browsing History.txt`) for client-side detection; the server does no
content-based source detection.

Model: ONE conversation per distinct video, `source` = the import source, `sourceThreadId` =
`youtube:<videoId>` / `tiktok:<videoId>`, `sourceUrl` = video URL, one segment per watch
(`createdAt` = watch time, `sourceMessageId` = `<platform>:<videoId>@<unix seconds>`). Repeated
watches in one export, and overlapping later exports, therefore merge into the same conversation
and never duplicate a watch. Metadata: `platform`, `videoId`, `videoUrl`, `channel`, `channelUrl`
(YouTube), `watchCount`, `firstWatchedAt`, `lastWatchedAt`, `watchedAt` (= last watch) and
`transcript: "none"`. Response `diagnostics` report `entries`, `videos` and skipped counts.

YouTube: JSON items `{title, titleUrl, subtitles[0].{name,url}, time}` and the HTML `content-cell`
variant are supported. Titles lose the known "Watched "/"Angesehen: " style prefixes only when
present. Entries without a video URL (removed videos, community posts) are skipped and counted in
`skippedWithoutVideoUrl`; removed videos whose title is just the URL are kept as
`YouTube video <id>`. The channel becomes the conversation participant with identifier
`youtube:<channelUrl or name>`. JSON/ISO times are converted to UTC from their offset; HTML times use
the zone abbreviation (UTC, GMT, CET/CEST, MEZ/MESZ, EST..PDT, `GMT+1` ...) and are assumed UTC when
the zone is unknown (`diagnostics.assumedUtcTimes`).

TikTok: JSON `Activity > Video Browsing History > VideoList[{Date,Link}]` (other lists such as
likes are ignored) and the `Date:`/`Link:` text variant. Times are UTC. Exports contain no titles or
channels: title is `TikTok video <id>` and there are no participants.

Enrichment (not part of this import): the client may fetch a transcript for one YouTube video later
with `POST /api/imports/youtube-transcript` and body
`{"title":"<video title>","metadata":{"videoId":"<videoId>","language":"de"}}` (`language` optional).
The response is a separate `youtube-transcript` conversation; the client may link it via
`metadata.videoId`. TikTok has no equivalent: transcripts or OCR are not possible server-side because
there is no video download or frame pipeline.

#### youtube-transcript remote mode

Precedence: (1) request `text` is parsed locally; (2) if `Imports:YouTube:BaseUrl` is set, that external
service (`GET /api/transcripts/{videoId}`) is used; (3) otherwise, if `Imports:YouTube:BuiltInCaptions`
is true (default), the built-in fetcher below; (4) otherwise the call fails with `invalid_import_request`.
`GET /api/imports/capabilities` appends the effective "Remote mode" state to the `youtube-transcript` status.

Built-in fetcher (`YouTubeCaptionFetcher`), best effort and unofficial: it GETs
`https://www.youtube.com/watch?v=<id>` (desktop User-Agent, `CONSENT`/`SOCS` cookies, retried once if the
EU consent page appears), reads `captionTracks` from the embedded `ytInitialPlayerResponse`, picks a track
(request `metadata.language`, then manual de/en, then any manual, then ASR) and downloads its `baseUrl`
with `fmt=json3`. If the page has no tracks or the download is empty (web caption URLs may require a PO
token), it falls back once to the innertube `youtubei/v1/player` endpoint with the ANDROID client, the
approach youtube-transcript-api uses today. Result: `source: youtube-transcript`, one segment per caption
event (`offsetMs`, `endMs`, HTML entities decoded) and metadata `videoId`, `videoUrl`, `language`, `kind`
(`asr`|`manual`), `transcriptSource: youtube-captions`; the title is the request title or YouTube's
`videoDetails.title`.

Limits and errors: `videoId` must match `^[A-Za-z0-9_-]{11}$` (`invalid_import_request`, 400); 10 s HTTP
timeout, redirects only within youtube.com/googlevideo.com, watch page <= 4 MB, transcript <= 2 MB
(`response_too_large`, 502); `transcript_unavailable` (404, no public captions), `video_unavailable`
(404, private/removed/age-gated), `provider_blocked` (429 + `Retry-After`, YouTube rate limiting or bot
check), `rate_limited` (429 + `Retry-After`: one fetch at a time per vault and 30 fetches per 10 minutes
per vault, in memory). This reads public captions from the server, so YouTube sees the server IP and the
video id, not the user. It may break whenever YouTube changes its page or APIs.

### Client detection of photos and viewing history

The app (not the server) decides the source for files it imports (file picker,
drag and drop, Android share target, folder watch):

- Images (`.jpg`, `.jpeg`, `.png`, `.webp`, `.heic`, `.heif`, or an `image/*` type
  of those formats) are sent to `photo`, with `metadata.capturedAt` = the file's
  last-modified time (fallback only; EXIF wins on the server) and
  `metadata.utcOffsetMinutes` = the device's offset. PDFs stay `scanned-pdf`. Other
  image formats (GIF, BMP, TIFF, AVIF) still go to `scanned-pdf`.
- Watch histories are recognised by content first: a JSON array whose items have
  header `YouTube*` and a `titleUrl` is `youtube-watch-history`; JSON containing a
  `Video Browsing History` key, or text with `Date:`/`Link:` lines, is
  `tiktok-watch-history`; HTML containing `watch-history` or YouTube "Watched"
  `content-cell`s is `youtube-watch-history`. Otherwise the capability
  `fileNameHints` (cached from `GET /api/imports/capabilities`, with built-in
  defaults) are matched against the file name (`watch-history.json|html`,
  `user_data*.json`, `Video Browsing History.txt`, `Browsing History.txt`).
- A dropped ZIP is searched for the right entry (`watch-history.json` preferred over
  `.html`, then the TikTok files; shallowest path wins) instead of the first text
  entry; only that entry is uploaded.

**Imports → Browser & watch history files** explains the exports (Google Takeout → "YouTube and
YouTube Music" → History → JSON; TikTok → Settings → Download your data → JSON),
offers a file picker and summarises videos imported / already present / entries
without a video link. Watched videos are category **Consumed** (see SEARCH.md).

#### Transcript enrichment (client)

`enrichWatchedVideo(conversationId)` calls `youtube-transcript` with the video id and
merges the returned timed segments into the existing `youtube-watch-history`
conversation (`sourceMessageId transcript:<videoId>:<n>`, replaced on a repeat) instead
of keeping a second conversation. Metadata then holds `transcript=youtube-captions`,
`language`, `kind`. A 404 stores `transcript=unavailable` so the video is not retried;
re-importing the history keeps either marker. Result cards of YouTube videos without a
transcript have **Fetch transcript**; the Viewing history panel has **Fetch transcripts
for the 25 most recent videos**: sequential, cancellable, skips videos already enriched
or unavailable, waits the `Retry-After` of each 429 and continues, and stops after three
consecutive `provider_blocked` answers. TikTok shows "No transcript available for
TikTok": there is no video download or speech/OCR pipeline.

#### Keeping viewing history updated from the browser (desktop)

Neither the YouTube Data API (watch history was removed in 2016) nor TikTok offers a
watch-history API, so OAuth is not possible. After an initial Takeout / TikTok export, the
desktop app can instead read the **local browser history database**:
**Imports → Browser & watch history files → Keep updated from browser history**.

- **Platforms**: Linux, macOS, Windows. Android, iOS and web show a note: they cannot read
  browser history, and videos watched in the YouTube or TikTok phone apps cannot be read at all
  (re-import a Takeout or TikTok export for those).
- **Profiles**: Firefox (`places.sqlite`, also Snap, Flatpak and `~/.config/mozilla`) and the
  Chromium family (Chrome, Chromium, Brave, Edge, Vivaldi, incl. Flatpak/Snap; `History`) are
  detected and listed with checkboxes; macOS and Windows locations are best effort. A history
  file can also be picked by hand. Newly selected profiles import from now on (optionally the
  last 30 days).
- **Reading**: browsers lock their database, so the file (and its `-wal`) is copied to a temp
  directory, opened with `query_only`, queried and the copy deleted. Firefox: `moz_places` ×
  `moz_historyvisits` (`visit_date`, µs since 1970); Chromium: `urls` × `visits` (`visit_time`,
  µs since 1601-01-01). Only rows whose URL contains `youtube.com/`, `youtu.be/` or `tiktok.com/`
  newer than the profile's stamp are selected; nothing else is read or uploaded.
- **Mapping**: YouTube `watch?v=`, `youtu.be/<id>`, `m.`/`music.` hosts and `/shorts/<id>` become
  Takeout-shaped entries `{header, title (" - YouTube" suffix removed), titleUrl:
  "https://www.youtube.com/watch?v=<id>", time: "yyyy-MM-ddTHH:mm:ssZ"}`; TikTok
  `tiktok.com/@user/video/<id>` becomes `{"Activity":{"Video Browsing History":{"VideoList":
  [{"Date":"yyyy-MM-dd HH:mm:ss","Link":…}]}}}` (UTC). `vm.tiktok.com` short links cannot be
  resolved and are skipped. The payloads go through the normal `youtube-watch-history` /
  `tiktok-watch-history` import in batches of at most 500 entries, so the existing parsers and
  merge by `sourceThreadId` fold browser visits and Takeout imports into the same conversations
  (same video id: one conversation, one segment per watch, deduplicated by watch second). No
  backend change was needed.
- **Polling**: on enable, on app resume and every interval (default 60 minutes, 15 minutes to
  24 hours) while the app is in the foreground; there is no background service. The per-profile
  stamp advances only after all its batches were imported; a failure leaves it so the visits are
  retried (the merge makes that idempotent). Settings, stamps and counters are kept per vault
  identity in the OS credential store.
- **Auto transcripts** (default off): "Fetch transcripts for new videos automatically (max N per
  day)", N defaults to 20. After a check that imported videos it fetches captions for up to
  `min(new videos, N − fetched today)` newest videos with the normal `enrichWatchedVideo` flow
  (honours `Retry-After`; after three consecutive `provider_blocked` answers automatic fetching
  pauses for 6 hours).
- **Library**: `package:sqlite3` (v3) bundles SQLite through Dart build hooks, so no system
  `libsqlite3` is required at runtime, including for the Linux/KDE build. Building native
  targets needs a C toolchain (clang or gcc), which Flutter desktop builds already require.

#### Camera photo auto-import

**Imports → Camera photos → Auto-import camera photos** imports new photos through the
`photo` source (OCR conversation) and, with **Keep photo in vault** (default on), also
uploads the compressed, encrypted image to the image vault linked to the created
conversation so it appears in its gallery. If the storage quota is exhausted the OCR
import still succeeds and a note is shown. Files over 25 MiB are skipped; hidden
(`.trashed-*`, `.pending-*`) files are ignored; files modified in the last 5 seconds wait.

- **Android**: watches `DCIM/Camera` (and `DCIM/OpenCamera`) via the `com.lifenizer/media`
  MethodChannel (`cameraFolders`, `hasImagesPermission`, `requestImagesPermission`),
  requesting `READ_MEDIA_IMAGES` (API 33+) or `READ_EXTERNAL_STORAGE` (up to API 32).
- **Desktop**: the user picks a folder (for example a synced camera folder).
- iOS and web: not available.

inotify is unreliable on shared storage, so the app polls: when enabled, when the app
resumes, and every 10 minutes while it is in the foreground. **There is no background
service**: photos taken while the app is closed or locked are imported at the next
resume. Only photos modified after the stored stamp are imported; the stamp starts at the
time of enabling (or 7 days earlier with "Also import photos from the last 7 days") and
advances only after the encrypted vault save succeeded. Failed photos stay pending and are
retried. Settings, stamp and counters are stored per vault identity in the OS credential
store, like the document folder watch.

### paperless

For an exported library, open **Imports → Paperless → Import Paperless ZIP**.
Choose an official Paperless backup ZIP (including its manifest and extracted
document text) or a ZIP of documents, up to 25 MiB. This works without a Paperless
address or API token. You can also drop the ZIP onto Imports or use its top file
picker; document ZIPs are detected automatically, while Discord and watch-history
exports retain their existing routes. ZIP entries remain compressed on the client
and are parsed on the server. Imported text is encrypted into your vault.

Exporter `manifest.json` and split `*-manifest.json` files preserve titles, OCR,
correspondents, tags and dates; unrelated exported accounts and settings are
ignored. Documents without OCR keep a searchable title. A document-only ZIP
extracts PDF text or OCRs PNG/JPEG scans. Reimporting the same document uses its
stable checksum identity. Export imports use their own identities and do not
merge with existing API imports. Original document bytes are not kept or synced.
See the [Paperless exporter documentation](https://docs.paperless-ngx.com/administration/#exporter).

Use standard, unencrypted Deflate ZIPs. Imports reject unsafe/duplicate paths and
symlinks, more than 2000 entries, entries over 25 MiB, total expansion over 100
MiB, and compression ratios over 200 for entries larger than 1 MiB. Selected
entries are read with an actual-output limit and CRC check; nested archives are
never opened. Paperless imports also cap extracted text at 8 MiB, documents at
1000, and processing at two minutes. Split larger selections and retry.

Open **Imports → Paperless**. In the installed app, enter your Paperless address.
Desktop setup defaults to `http://127.0.0.1:8002` when no server address is configured;
change it if Paperless runs elsewhere. On a phone, enter the address reachable
from that phone. The installed app reads directly from Paperless when you enter
an address different from the server default; no Lifenizer server administrator
is needed. Imported documents sync through the encrypted vault. Remembered direct
connections retain their address and token in the device OS credential store.

An API token is an account access key that lets Lifenizer read your Paperless
documents without asking for your Paperless password.

1. Select **Open Paperless** and sign in to the account whose documents you want
   to import.
2. Open the account menu in the top-right corner, then **My Profile**.
3. Copy the **API token**. If there is no token yet, use the circular-arrow button
   to create one. Reuse an existing token: regenerating it replaces the token used
   by other integrations too.
4. Return to Lifenizer, paste the token and select **Connect & import**. Leave
   **Remember on this device** enabled to check for updates every five minutes
   while the vault is unlocked.

The link opens your configured Paperless installation, including any deployment
subpath. My Profile is a dialog rather than a separate page, so follow the menu
steps after opening Paperless. If a connection attempt fails, the token stays in
the field so you can correct it and retry. After a successful connection, setup
is replaced by update and disconnect controls.

In the web app, if no Paperless address is configured, token setup stays hidden.
If you run the Lifenizer server, you are its administrator: set the environment variable
`Imports__Paperless__BaseUrl` to your trusted Paperless address and restart the
server, then select **Retry Paperless setup**. An API token alone cannot configure
the server address.

Set server configuration `Imports:Paperless:BaseUrl` to the trusted Paperless
installation. Compose maps `LIFENIZER_PAPERLESS_URL` to that setting; no guessed
server URL is used. Server request endpoint overrides and HTTP redirects are
rejected. Native direct connections support HTTPS, or HTTP for local/private hosts, and reject credentials
in addresses, query strings, fragments, and redirects.
`GET /api/imports/paperless/settings` requires authentication and returns
`{configured,baseUrl}` without credentials. The backend uses the API token only
for the current request; optional remembered credentials remain in
the device OS credential store.

Required for server imports:

- Server config `Imports:Paperless:BaseUrl` (no request override)
- `metadata.token` or config `Imports:Paperless:Token`

Optional metadata:

- `limit` (page size 1..50, default 10)
- `page` (positive page number, default 1)
- `modifiedAfter` (ISO date-time; inclusive `modified__gte` filter)

Documents are ordered by stable `id`, so edits during a paginated import do not
move already-seen documents between pages. The response diagnostics contain
`hasMore`, `nextPage` and `nextModifiedAfter`. Keep the same `modifiedAfter`
through a page loop and save cursor progress only after encrypting/persisting
that page. The client maintains a modification watermark after a completed
cycle and replays its overlap; stable document/thread IDs merge updated text.
Offset pagination is not a transactional snapshot of the Paperless database.
Provider `next` URLs are never followed: subsequent requests use the trusted
configured base and the next page number.

Imported records include Paperless OCR/text content, original document links,
filenames and available metadata. Missing list content triggers a detail fetch;
if still blank, direct connections index the title and metadata and report the
missing text without blocking other documents. Later OCR updates replace the
same document's empty text. Server-proxied imports instead extract/OCR the PDF
download with the limits above. Numeric correspondent IDs are resolved to their
names. Request failures retain the page for retry. Original document files are
not stored in the vault.
See the [Paperless REST API](https://docs.paperless-ngx.com/api/) for token access,
document content and pagination.

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
Conversation and message details provide **Open Discord chat** and **Open message** links.
They use the original channel/message IDs and the exported guild ID. For a
guild/thread whose guild ID is absent, the app leaves the link unavailable.
DM/group links use the original DM channel ID. The Discord account opening
the link must still have access. Guild/thread member lists and other people's
replies are absent from the package, so the app does not infer membership from
message mentions or thread titles. Known DM/group recipients use exported IDs.

Enable **Watch this Discord export for changes** to import again when you
replace the chosen ZIP with a newer export, while the desktop app is open and
unlocked. Stop watching from **Imports → Discord data package**. The watched path is stored in the OS
keyring, scoped to the account; message content stays in the encrypted vault.
This watches a local export and does not fetch new messages from Discord.

Continuous Discord access requires a separately authorized integration.
[Discord RPC](https://docs.discord.com/developers/topics/rpc) uses OAuth and
[restricted scopes](https://docs.discord.com/developers/topics/oauth2);
personal-token [self-bot automation is prohibited](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots).
A bot can ingest channels it is permitted to access, with the required gateway
intents and permissions. **Imports → Discord bot**
connects an authorized bot on a native client, reads channel history, and indexes
live messages and their real authors. See [Discord bot setup](DISCORD.md) for
server/channel selection, counterpart identities, credentials and limitations.

For visible new messages in open chats, **Imports → Browser extension → Discord Web**
offers a separate opt-in DOM observer; it does not fetch channel history or use a bot token.

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

#### Chunked transcription

WAV (PCM16) and Ogg Opus recordings longer than 28 s (or `Whisper:MaxChunkSeconds` when that is smaller) are cut at long pauses (silence of at least
`Whisper:MinPauseSeconds`, default 10 s; short non-silent blips up to 300 ms do not break a pause). The pause itself is
dropped (0.5 s of padding stays on each side). A blip is only bridged when at least 1 s
of silence precedes and follows it, so syllable gaps in noisy speech never form a pause. Silence is relative to the recording's
noise floor only when there is at least 1 s of clearly louder audio and the floor is plausibly silence (RMS up to
250, or a tenth of the recording is clearly louder, as in a loud room); otherwise only the absolute level (RMS 120) counts, so quiet or steady recordings are not cut at pauses. A stretch between
pauses with less than 0.2 s of non-silent audio is dropped (judged on the whole stretch, before the cap split below, so a
piece of quiet but audible talk is never dropped; a cap piece is only dropped when it is entirely below RMS 120). The ASR request sets `vad_filter=true` as a second line of defence. A stretch without a pause longer than
`Whisper:MaxChunkSeconds` (default 28 s) is split into contiguous pieces of at most that length (nothing is dropped at
these cuts). Each cut is searched in the last 10 s of the piece (at most half the cap when the cap is configured
smaller), with the window's end pulled in so the remaining audio keeps at least 2 s (no sub-second request, no last word
split off): the cut goes into the middle of the longest gap (silent run, measured in full even where it crosses the window edge,
e.g. a 0.3-1 s sentence break); without one, at the quietest frame if it is at most half the window's median level (speech gaps
in a noisy room where the adaptive threshold is not trusted); otherwise it is a hard cut at the window's end. Recordings up to
min(28 s, `Whisper:MaxChunkSeconds`) are sent whole.

Why 28 s: the production whisper (`whisper-trained`, faster_whisper with a fine-tuned model) decodes in 30 s windows
and drops the text at the end of a window whenever one request is longer than 30 s. With requests over 30 s, word
recall was 60-72%; the same speech cut at natural gaps into pieces of 28 s or less reached 99.1%. Do not raise
`Whisper:MaxChunkSeconds` above 30 for that model; startup logs a warning when it is (values up to 3600 stay
accepted for a whisper model that handles long audio). Each chunk is one whisper request (about 10 s overhead each, served
one at a time), so the plan is logged at Information once per file (`Planned N audio chunks (start+length in s): #1
0.0+27.4, ...`, at most 50 entries then `… N more`) followed by one line per finished chunk with the time spent in
whisper and, separately, the time queued for a global request slot, summed over attempts. Chunks are
transcribed in parallel and merged (segment times shifted by the chunk offset; language is the most
frequent chunk language). Entirely silent recordings fail with "no usable text" without calling whisper.
Other formats (mp3, m4a, webm, float WAV) are sent whole as before, with no duration check (pre-existing behaviour). Config:

- `Whisper:MaxParallelChunks` (default 4) — parallel chunks per import
- `Whisper:MaxConcurrentRequests` (default 4) — global cap on whisper requests across all imports
  (chunk requests and whole-file requests alike)
- `Imports:MaxAudioSeconds` (default 14400 = 4 h, clamped 1..36000) — applies to WAV (from its header) and Ogg Opus
  (duration summed from every packet's TOC; the Ogg granule is untrusted and compared as a raw sample count). Longer
  audio is a 400 and is never forwarded. WAV sample rates outside 8000-192000 Hz are a 400.
- `Imports:AudioMemoryBudgetMb` (default 600) — process-wide budget for decoded PCM (or the raw WAV bytes) held while
  an import is transcribed. Imports queue for budget; one needing more than the whole budget is a 400.
- `Imports:MaxConcurrentAudioImportsPerUser` (default 2) and `Imports:MaxConcurrentAudioImports` (default 3, all
  users) — concurrent audio imports (`/api/imports/audio` and `/api/imports/audio/upload`, matched by route, so
  trailing slashes and casing do not bypass them); extra ones get 429. Other import routes are not limited.
- `Whisper:MinPauseSeconds` (default 10, clamped 2..3600) and `Whisper:MaxChunkSeconds` (default 28, clamped 10..3600;
  the cut search window and the whole-file limit shrink with it, so every accepted value is valid) — see above
- `Whisper:ChunkTimeoutSeconds` (default 180) — minimum per chunk request timeout, excluding queue time for the global
  slot; the effective timeout is `max(this, chunk audio seconds × Whisper:ChunkTimeoutPerAudioSecond × Whisper:MaxConcurrentRequests)`
  (factor default 2.0, clamped 0..20; capped at 6 h), because whisper serves requests one at a time per replica and
  queued requests wait inside whisper. For a 28 s chunk with 4 concurrent requests that is 224 s, above the ~152 s that
  4 queued requests need even at real-time speed with ~10 s overhead each. Timeouts are not retried (connection errors and 5xx are retried once).
- `Whisper:WholeFileTimeoutSeconds` (default 600) — bound for whole-file (unchunked) requests
- Non-numeric, NaN or infinite values of these keys fall back to their defaults.

#### Multipart upload: `POST /api/imports/audio/upload`

Same result and errors as `POST /api/imports/audio`, but takes `multipart/form-data` instead of base64 JSON:
a `metadata` part (JSON of the import request, `payloadBase64` ignored) and an `audio` part (file bytes,
`audio/ogg` Opus or `audio/wav`). Anything starting with `OggS` must be a clean single-stream Ogg Opus file (mono or stereo, mapping family 0,
every page checksum valid, one stream serial, all packets decodable); otherwise the request is a 400
("Unsupported or damaged Ogg audio - export as WAV or Opus mono/stereo") and nothing is forwarded to whisper. This
covers Vorbis, chained or interleaved streams, bad checksums, more than two channels and corrupt packets. Clean Opus is
decoded in-process (Concentus, managed) to 16 kHz mono with pre-skip, output gain and trailing padding honoured; clean
Opus of 30 s or less is sent to whisper whole after the scan. Malformed multipart bodies, repeated `audio`/`metadata`
parts and Opus packets over 128 KB return 400. The body is limited by
`Imports:MaxRequestBytes` (413 when exceeded). The JSON endpoint keeps working for older clients.

### audio playback and saved originals

**Capture** offers play/pause and seeking for a stopped draft. **Save recording to
library** retains the original as an audio conversation without requiring
transcription. New transcribed audio imports also keep their original file bytes.
Open an audio conversation to play or seek the original. Native originals are
encrypted in the app's private application-support `audio/` directory; web originals
are encrypted in the `lifenizer-audio` IndexedDB database, outside the search snapshot.

Playback uses the local copy first. Another device can request an encrypted live
transfer while the main device holding the original is running and unlocked in the
same vault. This relay does not persist the recording online. If that device is
unavailable and no online copy exists, playback reports unavailable audio.

The per-recording **Store encrypted recording online** switch explicitly uploads
ciphertext so other devices can play when the main device is offline. Online storage
counts toward the account quota. Turning it off deletes the server copy and retains
local originals. Conversation metadata and transcripts sync normally; original audio
is not uploaded persistently by default. Transcription still sends plaintext audio
to the configured Whisper service.

### correcting transcription for TAB

Open an audio conversation and choose **Correct for TAB** beside a transcript sentence.
First edit the sentence while keeping the previous text visible and replaying just
that sentence. Choose **Next** for a separate, compact privacy step. Confirm both
**My voice; no confidential content** and **I allow Coflnet speech-recognition
training**, then **Share correction**. Full notice and terms remain available through
the link. Nothing is shared while editing or replaying. A successful submission
updates the encrypted transcript and search index; failures keep your edits for retry.

To keep the original out of training, choose **Record a replacement**. Type a new,
non-private sentence using the corrected word, record it, replay it, and choose
**Use this recording**. Only the new audio and its exact typed sentence are sent;
the original audio and original/corrected private text are excluded. The replacement
stays in memory and is not added to the library. The correction to your actual
transcript remains separate and is stored encrypted after a successful submission.

New audio imports retain the original recording in a separate encrypted device-local
cache, outside the search snapshot. Persistent online storage is opt-in; playback can also retrieve an original from
an unlocked live device. For older imports or when no original is available, use
**Audio options → Attach original WAV** (16 kHz mono PCM, up to 64 MiB). Segment
end timestamps from Whisper are preserved; missing ends use the next segment's start,
or the recording's end. Unusable sentence boundaries require re-transcription before
contributing. Each contribution is limited to two minutes.

The **Full notice & terms** view also offers **Withdraw training consent** for the receipts
created on this device. Receipt capabilities are encrypted locally. The authenticated
`/api/training/tab` proxy uses `Training:Tab:BaseUrl` (default `https://tab.coflnet.com`)
and never forwards vault login credentials to TAB. Correction failures leave the
original transcript unchanged and keep the edited text in the dialog for retry.

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

On Android, share one or several files to **Lifenizer** from another app's share
sheet, unlock the vault, and Imports opens automatically. The share target accepts
single/multiple files of any MIME type, including exported chats/backups, PDFs,
photos/scans and audio. Provider filenames and MIME types feed the same automatic
source detection as the file picker: PDF and images go to document/photo import;
audio MIME types or recognized audio extensions go to transcription. Generic
`application/octet-stream` shares still work when the filename identifies a supported
file type. Unknown JSON/CSV still requires choosing its adapter explicitly. On Android, KDE and the web app, use
**Imports → Choose backup or export** to select a file directly.

The app detects these readable exports from their contents:

- Telegram Desktop JSON: one chat's `result.json`, or a full export containing
  `chats.list`. Chats, speakers, rich text and historical message dates stay separate.
- WhatsApp **Export chat** text, including bracketed and dash-separated timestamps.
  A ZIP with a WhatsApp filename uses its exported chat text; ZIPs should contain
  one chat. Media inside ZIPs is not imported as attachments.
- Lifenizer JSON with `conversations` and `segments`. Snapshots that also include
  a top-level participant list resolve participant IDs to names.

For a ZIP with an ambiguous name, or another supported format, search for its
adapter and use **Choose file for this source**. **Other source / pasted export**
also accepts an explicit source adapter name. Unknown JSON and CSV require
an explicit source; they are not silently stored as chat text. The import result
shows the detected source, added conversation count, and duplicate count.

Importing an identical export again skips its conversations, even if the file is
renamed, the app restarts, or another synced device imports it. Fingerprints live
inside encrypted conversation records and encrypted local snapshots. Historical
imports made before duplicate protection have no fingerprints. For formats without stable thread/message IDs, changed exports
are new imports. Discord data packages and paginated email imports use stable
IDs to merge updates. The optional Discord export watch is described above. Avoid importing the same changed export on two
devices simultaneously before they sync.

Shared URI references wait in memory while locked or busy; file bytes are read from
Android content grants after unlock, with no app-created plaintext share cache. A
lock during reading keeps the URI queued for a later unlock. Empty/unreadable files
report an actionable error and do not stop later shared items from importing. Closing/restarting
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

## Browser extension: watch history and new web messages

`integrations/browser-extension/` is a Manifest V3 extension for Chromium and Firefox.
Open **Imports → Browser extension**, select YouTube, TikTok, WhatsApp Web or Discord
Web, and follow its installation and pairing steps. The desktop receiver is disabled
by default. Enable it, enter its port/token in extension Settings and test the connection.
Keep the desktop app open and unlocked. See the [extension guide](../integrations/browser-extension/README.md)
for browser installation and supported layouts; live logged-in browser validation
remains outstanding.

YouTube and TikTok sync requires an expected account ID or `@handle` in extension
Settings. Collection verifies signed-in self-account context and fails closed when it
is unavailable or differs. Queued visits are account-bound; changing account settings
holds prior pending data, and legacy unverified visits remain unsent with a warning.
The fallback **Download export** writes Takeout `watch-history.json` and TikTok
`user_data.json` for the existing file importers.

WhatsApp Web and Discord Web capture are separate opt-ins. A visible-DOM observer
baselines the existing conversation on attachment/navigation and captures newly
rendered incoming/outgoing messages with stable provider IDs, timestamps, visible
author information and source links where available. It does not scrape old history,
auto-scroll, read cookies/authentication tokens or send messages. Unsupported layouts
report an error instead of claiming a successful import. WhatsApp requires supported
numeric timestamps and a declared UI locale; its own-account phone identity is not
reliably exposed in chat DOM, so use separate browser profiles when switching accounts.

Unacknowledged messages remain in the extension's deduplicated local outbox when the
app is offline or locked. New captures, browser startup, settings changes or **Sync
now** retry delivery. Disabling a provider stops its queued message delivery. Extension
storage contains collected plaintext; **Delete collected data** clears the outboxes.

Loopback requests use default port 47615, `Authorization: Bearer <token>` and an
extension origin. Runtime sender/type/frame validation prevents ordinary pages from
instructing background requests. The receiver checks Host/Origin, caps streamed bodies
at 8 MB, and rejects locked-vault imports.

- `GET http://127.0.0.1:<port>/v1/ping` returns `{"app":"lifenizer","unlocked":true|false}`.
- `POST /v1/watch-history`, at most 2000 visits per request:

```json
{"source":"lifenizer-extension","version":1,"visits":[
  {"url":"https://www.youtube.com/watch?v=ID","title":"...","channel":"optional","time":"2026-10-05T10:42:00.000Z","timePrecision":"exact"}
]}
```

`timePrecision` is `exact` or `day`; YouTube day headers use local noon. Successful
responses are `{"accepted":N,"imported":M}`.

- `POST /v1/messages`, receiver limit 500 messages; the extension delivers batches of 25:

```json
{"source":"lifenizer-extension","version":1,"messages":[
  {"platform":"discord","threadId":"123","threadTitle":"Friends","id":"456","text":"Hello","createdAt":"2026-10-23T12:00:00Z","authorName":"Alice","sourceUrl":"https://discord.com/channels/@me/123/456"}
]}
```

`platform` is `whatsapp` or `discord`; `authorId`, `authorName` and `sourceUrl` are
optional. Raw provider thread/message IDs preserve stable import identities. A
successful message response is `{"ok":true,"imported":N}`, where `N` counts changed
conversations. Both import routes return 401 for a bad token, 503 while locked or
busy, and 413 for oversized bodies. Failed batches remain unsent.

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
