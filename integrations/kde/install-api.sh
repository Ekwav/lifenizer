#!/usr/bin/env bash
set -euo pipefail

with_whisper=false
start_services=true
for argument in "$@"; do
  case "$argument" in
    --with-whisper-forward) with_whisper=true ;;
    --no-start) start_services=false ;;
    *) echo 'Usage: integrations/kde/install-api.sh [--with-whisper-forward] [--no-start]' >&2; exit 2 ;;
  esac
done
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo 'A user systemd session is required. Run this installer from a KDE terminal.' >&2
  exit 1
fi
unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
mkdir -p "$unit_dir"
unit_temp=$(mktemp -d)
trap 'rm -rf -- "$unit_temp"' EXIT
# WorkingDirectory is a path; ExecStart uses command-line quoting.
unit_working_dir=${repo_dir//%/%%}
unit_repo_dir=${repo_dir//\\/\\\\}
unit_repo_dir=${unit_repo_dir//\"/\\\"}
unit_repo_dir=${unit_repo_dir//%/%%}
unit_repo_dir=${unit_repo_dir//\$/\$\$}
cat > "$unit_temp/lifenizer-api.service" <<UNIT
[Unit]
Description=Lifenizer private local API
After=network.target

[Service]
Type=simple
WorkingDirectory=$unit_working_dir
ExecStart="$unit_repo_dir/scripts/run-api.sh" --configuration Release
Environment=LIFENIZER_BIND_URL=http://127.0.0.1:5075
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
units=(lifenizer-api.service)
if "$with_whisper"; then
  kubectl_path=$(command -v kubectl)
  sed -i '/Environment=LIFENIZER_BIND_URL=/a Environment=Whisper__BaseUrl=http://127.0.0.1:19000' "$unit_temp/lifenizer-api.service"
  cat > "$unit_temp/lifenizer-whisper-forward.service" <<UNIT
[Unit]
Description=Lifenizer private Whisper tunnel through existing Rancher session
After=network.target

[Service]
Type=simple
ExecStart=$kubectl_path --context rancher --server=https://rancher.coflnet.com:8443/k8s/clusters/c-m-qgtbrsgz -n tab port-forward --address 127.0.0.1 svc/whisper-trained 19000:9000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
  units+=(lifenizer-whisper-forward.service)
fi
# Inspect every existing service before writing any unit. Preserve custom setups.
for unit in "${units[@]}"; do
  systemd-analyze --user verify "$unit_temp/$unit"
  configured_path=$(systemctl --user show "$unit" -p FragmentPath --value)
  destination="$unit_dir/$unit"
  if [[ -n "$configured_path" && "$configured_path" != "$destination" ]]; then
    echo "Existing service at $configured_path preserved; review it before installing." >&2
    exit 1
  fi
  if [[ -e "$destination" ]] && ! cmp -s "$unit_temp/$unit" "$destination"; then
    echo "Existing configured service $destination preserved; review it before updating." >&2
    exit 1
  fi
done
for unit in "${units[@]}"; do
  install -m644 "$unit_temp/$unit" "$unit_dir/$unit"
done
systemctl --user daemon-reload
systemctl --user enable "${units[@]}"
if "$start_services"; then
  systemctl --user start "${units[@]}"
  echo 'Started Lifenizer API at http://127.0.0.1:5075. Create your account in the app.'
else
  printf 'Installed. Start when ports are free: systemctl --user start'
  printf ' %s' "${units[@]}"
  printf '\n'
fi
