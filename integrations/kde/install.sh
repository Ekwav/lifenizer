#!/usr/bin/env bash
set -euo pipefail
# Installs for the current user; does not export a plaintext search index.
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
bundle_dir=${1:-"$repo_dir/app/build/linux/x64/release/bundle"}
if [[ ! -x "$bundle_dir/lifenizer" ]]; then
  echo 'Build first: cd app && flutter build linux --release' >&2
  exit 1
fi
install_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/lifenizer
runner_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/krunner/dbusplugins
application_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/applications
service_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/dbus-1/services
mkdir -p "$install_dir" "$runner_dir" "$application_dir" "$service_dir"
cp -a --remove-destination "$bundle_dir/." "$install_dir/"
install -m644 "$repo_dir/integrations/kde/lifenizer.desktop" "$runner_dir/lifenizer.desktop"
# The quoted path in Exec follows the freedesktop desktop-entry quoting rules.
escaped_dir=${install_dir//\\/\\\\}
escaped_dir=${escaped_dir//\"/\\\"}
escaped_dir=${escaped_dir//\$/\\\$}
escaped_dir=${escaped_dir//\`/\\\`}
cat > "$install_dir/open" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
uri=${1:-lifenizer://search}
if gdbus call --session --dest com.lifenizer.Search --object-path /runner --method org.kde.krunner1.Open "$uri" >/dev/null 2>&1; then
  exit 0
fi
exec "$(dirname -- "$0")/lifenizer" "$uri"
LAUNCH
chmod 755 "$install_dir/open"
cat > "$application_dir/com.lifenizer.app.desktop" <<ENTRY
[Desktop Entry]
Type=Application
Name=Lifenizer
Comment=Private conversation search and capture
Icon=system-search
Exec="$escaped_dir/open" %u
Terminal=false
Categories=Utility;
MimeType=x-scheme-handler/lifenizer;
Actions=Search;Capture;Imports;

[Desktop Action Search]
Name=Find a conversation
Exec="$escaped_dir/open" lifenizer://search

[Desktop Action Capture]
Name=Capture a memory
Exec="$escaped_dir/open" lifenizer://capture

[Desktop Action Imports]
Name=Import conversations
Exec="$escaped_dir/open" lifenizer://imports
ENTRY
cat > "$service_dir/com.lifenizer.Search.service" <<SERVICE
[D-BUS Service]
Name=com.lifenizer.Search
Exec="$escaped_dir/lifenizer" lifenizer://search
SERVICE
if [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] && command -v gdbus >/dev/null; then
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ReloadConfig >/dev/null
fi
if command -v update-desktop-database >/dev/null; then update-desktop-database "$application_dir"; fi
if command -v kbuildsycoca6 >/dev/null; then kbuildsycoca6 --noincremental; fi
echo 'Installed. Open or restart Lifenizer, unlock, then type "life <query>" in KRunner.'
