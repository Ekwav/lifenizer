# KDE and Android quick access

Both devices use the same Lifenizer account, vault salt and passphrase against
one API endpoint. Conversations, participants, relations and saved searches sync
as encrypted envelopes. Configure the endpoint on each device's login screen;
`localhost` on Android refers to the phone, so use an HTTPS hostname accessible
from both devices (or a private network/tunnel). Unlock once per app session.
Local changes queue while offline and sync on reconnect, app resume, and every
30 seconds while the app is active. The passphrase is never stored.

## KDE Plasma

Build and install the native desktop app:

```sh
cd app
flutter pub get
flutter build linux --release
cd ..
./integrations/kde/install.sh
```

The installer copies the complete bundle to
`${XDG_DATA_HOME:-$HOME/.local/share}/lifenizer`, adds desktop actions and the
`lifenizer://` URL handler, and installs a user D-Bus KRunner plugin. Launch
Lifenizer from the application menu and unlock the vault. The installed D-Bus
activation entry can also start the app when KRunner first needs it. In KRunner type
`life Alice holiday` (or `lifenizer Alice holiday`). Up to eight ranked results
appear; selecting one presents the app and opens the conversation transcript.
`life` by itself shows recent conversations. `Ctrl+K` focuses app search from any
page; desktop actions also open Capture and Imports. If the plugin is absent,
restart KRunner and enable **Lifenizer conversations** in System Settings →
Search → Plasma Search.

The runner is served directly from the unlocked app over the user's session
D-Bus, using the same search ranking as app search. There is no exported
plaintext index, HTTP listening port, or background vault key. While locked,
KRunner offers only an unlock action. Close the app to stop its D-Bus service.
KRunner and other processes in the same desktop session can see results while
the vault is unlocked; query text is subject to the desktop's usual query history.

Protocol smoke check while the app is running:

```sh
gdbus call --session --dest com.lifenizer.Search --object-path /runner \
  --method org.kde.krunner1.Match 'life Alice'
```

Metadata and transport follow KDE's
[D-Bus runner protocol](https://develop.kde.org/docs/plasma/krunner/metadata/).
The installation script may be rerun after rebuilding; it needs no root access.
Remove `lifenizer`, `krunner/dbusplugins/lifenizer.desktop`, and
`applications/com.lifenizer.app.desktop`, and
`dbus-1/services/com.lifenizer.Search.service` from the same data directory to uninstall.

## Android and Nova Launcher

```sh
cd app
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Long-press Lifenizer in the launcher for **Find a conversation**, **Capture a
memory**, or **Import conversations**. These standard Android static app
shortcuts work in supporting launchers, including Nova; they can be pinned to
the home screen. Launchers that index app shortcuts may surface them in their
search. Select text in another app and choose **Search Lifenizer** in Android's
text selection menu to search it immediately. Share text, audio or supported
export files to Lifenizer to import them after unlock. Shared files are read
from granted content URIs into memory; the app creates no plaintext share cache.
The native share reader accepts up to 64 MiB per file; larger files can be
selected in Imports. Android backups are disabled for app-local vault data.

Android `ACTION_SEARCH` is registered with a searchable configuration. The
launcher/OS decides whether to dispatch search queries to third-party apps.
This is a search entry point and shortcut integration; it does not expose
conversation previews to Android's global suggestion or AppSearch index.

Deep links accept `search`, `capture` and `imports` actions. A search defaults to
all sources and people, resets existing filters, and focuses the search field.
An action received while locked waits in memory until unlock.

```sh
adb shell am start -a android.intent.action.SEARCH \
  -n com.lifenizer.app/.MainActivity --es query 'Alice holiday'
adb shell am start -a android.intent.action.VIEW \
  -d 'lifenizer://search?q=Alice%20holiday' com.lifenizer.app
adb shell am start -a android.intent.action.PROCESS_TEXT -t text/plain \
  -n com.lifenizer.app/.MainActivity \
  --es android.intent.extra.PROCESS_TEXT 'Alice holiday'
```

Web app quick access uses `/?action=search&q=Alice%20holiday` or
`/?action=capture`. Native links use `lifenizer://search?q=...` and optionally
`&conversation=<id>` to open a specific locally synced conversation.

Android behavior follows the official [search activity](https://developer.android.com/develop/ui/views/search/search-dialog),
[static shortcuts](https://developer.android.com/develop/ui/compose/system/shortcuts/creating-shortcuts),
and [selected text intent](https://developer.android.com/reference/android/content/Intent#ACTION_PROCESS_TEXT)
contracts. Real launcher discovery and device installation require testing on
the user's Android launcher; an APK build verifies manifest and native code.

## Repeatable verification

Run `./scripts/verify.sh` for backend tests, strict Flutter analysis, Flutter
unit/widget tests, and the browser encryption/sync workflow. It builds a web
bundle with the explicitly enabled test bridge before running Playwright.
The default command excludes the external Whisper audio test. To require the
real audio → transcript → search → second-device sync workflow, run
`WHISPER_URL=http://127.0.0.1:19000 ./scripts/verify.sh --live-whisper` after
port-forwarding the service; an unreachable Whisper endpoint fails verification.

The native KDE path is tested separately with
`cd app && flutter test integration_test/quick_actions_test.dart -d linux`
inside the desktop session, with the normal app closed so the test can own its
D-Bus name. The test uses a synthetic in-memory vault and exercises KRunner
result selection, transcript display, and `Ctrl+K` focus.

## Local desktop API service

`./integrations/kde/install-api.sh` installs and enables a `systemd --user`
service that runs `scripts/run-api.sh` from this checkout. The API binds only
`http://127.0.0.1:5075`, disables development login, and keeps its signing key,
SQLite database and artifacts in the private
`${XDG_STATE_HOME:-$HOME/.local/state}/lifenizer` directory. Start the app and
create your account with your chosen credentials. Existing custom user services
are inspected and preserved; the installer refuses to replace different units.

Add `--with-whisper-forward` to also install a private localhost tunnel to the
existing `whisper-trained` service using the configured Rancher context and
bastion session. This points the API's Whisper endpoint to
`http://127.0.0.1:19000`; it does not bootstrap or alter the bastion. The tunnel
retries if disconnected, and requires the existing Rancher session to work.
Without the flag, the API uses its configured default Whisper endpoint, which
may be unreachable from a desktop outside the cluster. Capture and encrypted
recording drafts remain available while transcription is unavailable.

`--no-start` installs/enables units without starting them, useful while tests own
ports 5075 or 19000. Once those ports are free:

```sh
systemctl --user start lifenizer-api.service lifenizer-whisper-forward.service
systemctl --user status lifenizer-api.service lifenizer-whisper-forward.service
```

Stop them with `systemctl --user stop lifenizer-api.service
lifenizer-whisper-forward.service`. Disable automatic startup with
`systemctl --user disable lifenizer-api.service lifenizer-whisper-forward.service`.
To uninstall the runtime, disable/stop both units, remove their files from
`~/.config/systemd/user/` (or `$XDG_CONFIG_HOME/systemd/user/`), and run
`systemctl --user daemon-reload`. Keep the private state directory to preserve
your account and encrypted vault.

The local API is accessible from this KDE machine. Android still needs a
separately configured private network/tunnel or HTTPS API address reachable
from the phone; this installer creates no LAN/public listener.
