# Lifenizer History Sync (browser extension)

Manifest V3 extension for Chromium-family browsers (Chrome, Edge, Brave, Vivaldi) and Firefox (140+).
It reads your YouTube and TikTok watch history from the history pages you are logged in to and hands
it to the Lifenizer desktop app on the same computer. It replaces the Google Takeout round trip.

**Status: not verified against the live sites.** Page structures were taken from public write-ups, not
from a logged-in session (see "Unverified" below). Expect to adjust once tried.

## Install

- Chromium: `chrome://extensions`, enable Developer mode, "Load unpacked", pick this directory.
- Firefox: `about:debugging#/runtime/this-firefox`, "Load Temporary Add-on", pick `manifest.json`.
- Zips: `node scripts/build.js` writes `dist/lifenizer-history-sync-{chromium,firefox}.zip` (needs the `zip` CLI).
- Lint: `npx web-ext lint --source-dir . --ignore-files 'dist/**' 'test/**' 'scripts/**'` (0 errors; one
  expected warning that `service_worker` is ignored in Firefox, which uses `background.scripts`).

## Pair with the desktop app

Open Lifenizer, Viewing history panel: it shows a port (default 47615) and a token. Enter both on the
extension's Settings page and press "Test connection". Requests go only to `http://127.0.0.1:<port>`,
sent from the extension background with `Authorization: Bearer <token>`.

## Use

Popup, "Sync now": opens the YouTube history page and the TikTok watch-history page in background tabs,
scrolls them (bounded), collects entries, closes the tabs and posts the new ones to the app in chunks of
at most 2000. Status per platform: found / new / sent / undated, plus clear errors (not logged in, layout
not recognized, app not reachable, vault locked). Unsent visits stay in the extension's local storage and
are retried on the next sync.

"Download export" (works without the app): saves `watch-history.json` (Takeout shape) and `user_data.json`
(TikTok export shape) that the app's existing importers read.

Optional: Settings, "Sync automatically once a day" (`chrome.alarms`, off by default; the browser must run).
First sync looks back 30 days (configurable); later syncs stop at the last-synced marker (newest 200
`video@day` keys). Item count (default 3000) and wall time (default 90 s per platform) are capped.

## What is collected

Per video: URL, title, channel (YouTube), time. Stored locally in `storage.local` until you use
"Delete collected data" (Settings). Nothing goes anywhere except 127.0.0.1 or the file you download. No
cookies or credentials are read, stored or sent; the page's own requests are only observed.

## How it works

- `src/content/hook.js` (page world, document_start) wraps `fetch`/XHR to copy the JSON of the page's own
  history requests (YouTube `youtubei/v1/browse`, TikTok history API) and exposes `window.ytInitialData`.
  It issues no requests itself.
- `src/content/collector.js` scrolls the page so the site loads more entries, and parses the JSON.
- `src/lib/*.js` are pure modules (header-date resolution, renderer extraction, TikTok mapping, payload and
  export builders, chunking, markers, delivery); tests: `node --test test/` (no dependencies).

## Limitations

- YouTube's history page only shows day headers, so YouTube visits have `timePrecision: "day"` (local noon).
  Headers are resolved locale-independently with `Intl` for the last ~400 days; unresolvable headers inherit
  the previous day, and entries before any resolved day are counted as "undated" and skipped.
- `myactivity.google.com` shows exact times but is not used: its page is rendered by Google's internal
  batchexecute/Wiz framework with obfuscated class names and no documented or confirmed stable JSON, so no
  reliably parseable structure was found. Takeout JSON remains the exact-time path.
- TikTok: the web only offers watch history if the account/region has it (Settings, Activity center, Watch
  history; roughly 180 days). If the page has none, the popup reports "page layout not recognized" instead of
  inventing data. Without a watch time in the response, TikTok items are stamped with the sync day (day
  precision) and deduped per video, so a re-watch is not recorded again.
- Phone-app views appear only if the platform's own history page shows them.
- Background tabs are throttled and usually stop loading older entries, so a manual sync opens the history tabs in the foreground by default (Settings can turn that off). The daily sync always runs in the background and may only see the newest entries.
- A vault that is locked answers 503; unlock Lifenizer and sync again.

## Unverified without a logged-in browser

- Exact `ytInitialData` / continuation shapes of `/feed/history` today (both `videoRenderer` and
  `lockupViewModel` are handled; section header location is guessed from the older renderer layout).
- TikTok: the watch-history page URL (default `https://www.tiktok.com/setting/watch-history` is a guess,
  editable in Settings; the collector also tries to click a "Watch history" entry), the API path
  (matched by regex on `watch|view|browsing history`) and the item fields.
- Behaviour of infinite scroll in background tabs; Firefox `world: "MAIN"` content scripts.
