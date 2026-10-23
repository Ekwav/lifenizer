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

Set server configuration `Imports:Paperless:BaseUrl` to the trusted Paperless
installation. Compose maps `LIFENIZER_PAPERLESS_URL` to that setting; no guessed
server URL is used. Request endpoint overrides and HTTP redirects are rejected.
`GET /api/imports/paperless/settings` requires authentication and returns
`{configured,baseUrl}` without credentials. In Imports, connect Paperless using
its API token after checking this configured endpoint. The backend uses that
token only for the current request; optional remembered credentials remain in
the device OS credential store.

Required:

- Server config `Imports:Paperless:BaseUrl` (no request override)
- `metadata.token` or config `Imports:Paperless:Token`

Optional metadata:

- `limit` (page size 1..50, default 10)
- `page` (positive page number, default 1)
- `modifiedAfter` (ISO date-time; inclusive `modified__gte` filter)

Documents are ordered by `modified,id`. The response diagnostics contain
`hasMore`, `nextPage` and `nextModifiedAfter`. Keep the same `modifiedAfter`
through a page loop and save cursor progress only after encrypting/persisting
that page. The client maintains a modification watermark after a completed
cycle and replays its overlap; stable document/thread IDs merge updated text.
Offset pagination is not a transactional snapshot of the Paperless database.
Provider `next` URLs are never followed: subsequent requests use the trusted
configured base and the next page number.

Imported records include Paperless OCR/text content, original document links,
filenames and available metadata. Missing list content triggers a detail fetch;
if still blank, the PDF download is extracted/OCRed with the same limits above.
Numeric correspondent IDs are resolved to their names. Unreadable documents
fail the page explicitly. Original document files are not stored in the vault.
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
Enter the corrected text and confirm that it is your own voice without confidential
information. The dialog loads TAB's current notice and requires explicit training
consent. Anonymous contributions need no email account. Only the selected sentence's
WAV clip and corrected text are submitted for validation and training; this does not
immediately retrain the model. A successful submission updates the encrypted transcript
and its search index, retaining the provider contribution reference.

New audio imports retain the original recording in a separate encrypted device-local
cache, outside the search snapshot. Persistent online storage is opt-in; playback can also retrieve an original from
an unlocked live device. For older imports or when no original is available, use
**Attach original WAV** (16 kHz mono PCM, up to 64 MiB). Segment
end timestamps from Whisper are preserved; missing ends use the next segment's start,
or the recording's end. Unusable sentence boundaries require re-transcription before
contributing. Each contribution is limited to two minutes.

The correction dialog also offers **Withdraw TAB training consent** for the receipts
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
