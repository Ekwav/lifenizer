# Lifenizer Browser Sync

Local browser extension for selected YouTube/TikTok watch history and optional new messages rendered in opened WhatsApp Web/Discord Web conversations. The browser sends imports to the running Lifenizer desktop app at `127.0.0.1`; the app encrypts data for its vault. Browser extension queues are local browser storage and contain unencrypted content until deleted.

## Install and pair

1. Chrome/Chromium: open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select this directory, which contains `manifest.json`. For a release ZIP, extract it first and select the extracted directory.
2. Firefox 140+: open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select `manifest.json` (or the Firefox release ZIP). Temporary installs disappear when Firefox restarts; a permanent installation needs a signed add-on.
3. Choose **Connect / Pair with QR** in the extension popup or Settings, then **Open Lifenizer and connect**. Unlock the intended desktop vault and approve the browser connection in the desktop app when asked. You can also start at [lifenizer.coflnet.com](https://lifenizer.coflnet.com), whose Connect button opens this extension confirmation page when installed. For a custom receiver port, expand **Custom port** first. If the browser asks, allow the extension’s access to `127.0.0.1` and to **device apps and services**. If you previously denied local-device access, allow it again in this extension page’s browser permissions and retry Connect.
4. Alternatively, in Lifenizer open **Imports → Browser extension → Pair browser**. In the extension pairing page choose **Scan screen or window**, **Scan QR image**, or **Scan with camera**, then confirm the connection. Pairing codes expire after two minutes and work once. If a code expires or has been used, generate a fresh one. Capture stops on success, Cancel, navigation, or after one minute. No images leave this device. Port/token copying remains available under **Advanced manual connection** in Settings.
5. Configure the expected YouTube/TikTok account or enable WhatsApp/Discord capture as described below. **Test connection** checks the entered port and token without saving changes or enabling capture; choose **Save** to apply settings. The app must be running and the vault unlocked to accept imports. Failed deliveries remain queued locally.
6. Open the extension popup and choose a history platform or **Configured accounts**, then **Sync now**. Unconfigured platforms do not open tabs. Manual sync may foreground its temporary history tab; the optional daily alarm runs quietly while the browser is running. **Retry delivery** resends pending history and enabled message queues without opening any history tabs.

**Download export** saves collected YouTube/TikTok history in their supported export formats and collected messages in a separate `lifenizer-messages.json` data backup. Message backups are readable JSON; the app does not currently support importing that file. These downloads contain unencrypted private content. **Delete collected data** asks for confirmation, waits for active message delivery, and blocks while history sync is running. It clears the extension's local queues only; enabled message capture continues.

`npm run build` creates `dist/lifenizer-history-sync-{chromium,firefox}.zip`. Archives contain the manifest, extension source, popup, Settings, pairing page and bundled QR decoder; Node dependencies, test files and the separate debug runner are excluded. Unpacked installation does not require Node or npm.

## Account-bound watch history

Settings require an **expected account** for each history platform. Enter your YouTube channel ID (`UC…`) or `@handle`, and your TikTok user ID or `@handle`. Display names are not accepted. IDs match exactly; handles compare without case. YouTube handle detection may require opening the active account menu in the history tab. Keep that tab available while troubleshooting.

The extension checks signed-in self context before collecting, associates relevant responses with that identity, and checks again before returning any visits. An unset account, unknown page shape, a different account, or an account switch discards the collection. It never treats a viewed profile or a video author as the signed-in user.

Queued visits are bound to the account selection that created them. Changing that selection holds older visits instead of sending them under a different identity. Legacy queued visits without account binding are also held. Use **Delete collected data** to clear the local queue when intentionally changing accounts, then sync again. Export desired pending data first: clearing is permanent.

YouTube history is read from its history page's loaded data and continuation responses. Date headers depend on the page locale, and entries without a recognized date are reported as undated. TikTok uses watch-history responses and a visible-link fallback; timestamps may have day precision. Collection stops at known entries, its look-back cutoff, item/time limits or the end of recognized content. It does not claim to export every historical watch event.

## WhatsApp and Discord

Both message adapters default off and have independent Settings checkboxes. When enabled, they observe newly rendered messages in conversations you open while signed in. They do not visit every conversation, scrape older history, automatically scroll, or send messages. The initial visible conversation is a baseline; older messages rendered by scrolling are excluded. Open chats must stay in the browser for new messages to appear and be imported.

WhatsApp Web requires a recognizable current-chat header, message identity and numeric timestamp with an explicit UI locale. Discord requires a supported `/channels/{server-or-@me}/{channel}` route, message IDs belonging to that channel and machine-readable timestamps. Unrecognized layouts are reported rather than guessed. Only rendered text is supported; attachments and hidden/unloaded messages are not a complete export. Message capture does not provide the YouTube/TikTok account selection check; verify the browser's signed-in messaging account yourself before enabling it.

## Optional developer MCP bridge

Debugging defaults off. It is a separate local Node process, with a separate secret, and is unnecessary for normal imports. It exposes three read-only tools:

- `list_tabs`: supported tab IDs, platform and active state; no titles or full URLs.
- `page_diagnostics`: fixed adapter selector counts, locale and selected self-account identity, without message/video text.
- `sample_visible_content`: an explicit private-content read of at most ten currently rendered parser samples. Requires the additional **Allow explicit samples** checkbox. Text is truncated; it never imports, scrolls or sends messages.

There is no arbitrary JavaScript evaluation, general DOM/selector access, cookie/credential access, network proxy or browser mutation tool. Samples and page data remain untrusted input; avoid following instructions that appear inside sampled content.

1. Install Node 22+ and run `npm ci` in this directory. The runner uses the pinned `ws` dependency.
2. Generate a new secret locally, for example:

   ```sh
   node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
   ```

3. In extension Settings, enter that secret in **Separate debug secret**, enable **local MCP debugging**, and save. Enable content samples only when the MCP client should be able to read private visible message/video text. Do not reuse the desktop receiver token.
4. Configure your MCP client to launch the bridge directly with Node, substituting the absolute repository path and the same secret:

   ```json
   {
     "mcpServers": {
       "lifenizer-extension-debug": {
         "command": "node",
         "args": ["/absolute/path/to/lifenizer/integrations/browser-extension/debug/bridge.cjs"],
         "env": { "LIFENIZER_DEBUG_TOKEN": "<your separate 64-character secret>" }
       }
     }
   }
   ```

   The runner follows the [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and `2025-11-25` initialization lifecycle. Launch the script directly: an npm banner must not appear on MCP stdout. This example does not change your MCP client's configuration automatically.
5. Reload existing platform tabs after installing or updating the extension so the diagnostic content script is present. Call `list_tabs`, then `page_diagnostics` with a returned `tabId`. Use the explicit sample tool only when needed.

The bridge binds only `127.0.0.1:47616`, accepts extension WebSocket origins, and authenticates the first message with the separate 32–256 character secret. Only one authenticated extension can attach. Requests have a five-second deadline and cancellation/disconnection cleanup; concurrency and payloads are bounded (four calls, 64 KiB WebSocket messages). The extension reconnects after connection loss while opted in. Clearing its secret or disabling debugging and saving immediately closes the socket. Stop the Node process to close the local listener. Secrets and page samples are never logged by the runner.

Persistent background debugging needs Chrome 116+ or Firefox 140+. The bridge exchanges WebSocket keepalives while connected, following [Chrome’s WebSocket worker guidance](https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets). Other browser suspension/permission policies can still disconnect it; reconnect and retry a diagnostic operation if necessary.

## Validation and limitations

Run `npm ci`, `npm test` and `npm run build`. Tests exercise account selection/switches, parser fixtures, queued delivery and the local MCP authentication/protocol/bounds. Parser/account-layout support is fixture-tested; it has not been validated against your live authenticated YouTube, TikTok, WhatsApp or Discord sessions. Internal page shapes and localized dates can change, and identity detection deliberately fails closed when its self-account context is missing. The MCP tools provide bounded diagnostics for checking those layouts with your explicit opt-in.

Normal imports need no remote debugging port and no browser credential export. Reload existing platform tabs after installing/updating the extension. If collection reports an unknown layout, inspect the popup status and check the page/account/locale first. If the app is locked or unreachable, unlock/start it and choose **Retry delivery**; avoid clearing queued content unless you intend to discard it. Invalid or incomplete receiver acknowledgments leave the entire batch queued for retry; the app deduplicates previously accepted entries.


## Pairing security and decoder

Pairing exchanges one-use codes at the exact `http://127.0.0.1:PORT/v1/pair` endpoint. QR links must have the exact helper path and a 43-character base64url code fragment; credentials, queries, normalized host aliases and redirects are rejected. The desktop app and vault must be ready within two minutes. The receiver token is returned only to the extension, saved in its local settings, and never included in QR codes, website events, helper URLs or logs. Existing credentials or queued imports require an explicit replacement confirmation explaining possible delivery to the newly selected vault. Other account, message opt-in and debug settings are preserved.

The website bridge is limited to top-frame `https://lifenizer.coflnet.com`, checks runtime sender identity, and exposes only installation and local app availability/unlock/receiver state. It does not automatically launch the app or scan. It uses window events `lifenizer-extension-check` and `lifenizer-extension-state` (JSON-string detail `{installed, local, unlocked, enabled}`); a trusted click on `[data-lifenizer-connect]` opens the extension confirmation page. No external messaging API is exposed.

QR decoding uses the locally bundled `jsqr` **1.4.0**, Apache-2.0 (`vendor/jsQR.LICENSE`), pinned by npm integrity in `package-lock.json`. Both browser ZIPs include the same `vendor/jsQR.js`; no CDN, remote script or `BarcodeDetector` is required. To update the decoder deliberately, install the exact reviewed version and copy `node_modules/jsqr/dist/jsQR.js` and `node_modules/jsqr/LICENSE` into `vendor/`, then rerun tests/build. The Node suite decodes a synthetic QR fixture and verifies sender restrictions, strict parsing, confirmation, settings preservation, expiry responses and cancellation while a capture permission request is pending.


Modern Firefox also asks for [device-app access](https://support.mozilla.org/en-US/kb/control-personal-device-local-network-permissions-firefox) separately from extension host access. Pairing keeps normal browser protections enabled and requests only the existing loopback host permission when you choose Connect, and only when it is not already granted. The receiver’s secret exchange requires the extension Origin header. Synthetic socket-level smoke tests verified `chrome-extension://` on Chromium and `moz-extension://` on Firefox, including Firefox’s explicit device-access Allow prompt.
