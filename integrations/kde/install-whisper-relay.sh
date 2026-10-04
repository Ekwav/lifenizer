#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
unit=lifenizer-whisper-relay.service
unit_temp=$(mktemp)
trap 'rm -f -- "$unit_temp"' EXIT
escaped_dir=${repo_dir//\\/\\\\}
escaped_dir=${escaped_dir//\"/\\\"}
escaped_dir=${escaped_dir//%/%%}
escaped_dir=${escaped_dir//\$/\$\$}
cat > "$unit_temp" <<UNIT
[Unit]
Description=Lifenizer private Whisper relay to mail.coflnet.com
Wants=lifenizer-whisper-forward.service
After=network.target lifenizer-whisper-forward.service

[Service]
Type=simple
ExecStart="$escaped_dir/scripts/whisper-relay.sh"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
mkdir -p "$unit_dir"
configured_path=$(systemctl --user show "$unit" -p FragmentPath --value)
if [[ -n "$configured_path" && "$configured_path" != "$unit_dir/$unit" ]]; then
  echo "Preserving existing service at $configured_path" >&2
  exit 1
fi
if [[ -e "$unit_dir/$unit" ]] && ! cmp -s "$unit_temp" "$unit_dir/$unit"; then
  echo "Preserving customized service at $unit_dir/$unit" >&2
  exit 1
fi
install -m644 "$unit_temp" "$unit_dir/$unit"
systemd-analyze --user verify "$unit_dir/$unit"
systemctl --user daemon-reload
systemctl --user enable --now "$unit"
echo 'Private Whisper relay installed. Transcription requires this desktop and its Rancher tunnel to remain online.'
