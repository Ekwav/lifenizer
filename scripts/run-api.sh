#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/lifenizer"
env_file="$state_dir/api.env"
mkdir -p -- "$state_dir/artifacts"
chmod 700 -- "$state_dir"

# Persist one private signing key so tokens survive server restarts.
if [[ ! -f "$env_file" ]]; then
    secret_temp="$(mktemp "$state_dir/.api.env.XXXXXX")"
    trap 'rm -f -- "$secret_temp"' EXIT
    printf 'Jwt__Secret=%s\n' "$(openssl rand -hex 32)" > "$secret_temp"
    mv -n -- "$secret_temp" "$env_file"
    rm -f -- "$secret_temp"
    trap - EXIT
fi
chmod 600 -- "$env_file"
read -r secret_line < "$env_file"
if [[ "$secret_line" != Jwt__Secret=* || ${#secret_line} -lt 44 ]]; then
    printf '%s\n' "Invalid signing key file: $env_file" >&2
    exit 1
fi
export Jwt__Secret="${Jwt__Secret:-${secret_line#Jwt__Secret=}}"
export ConnectionStrings__Lifenizer="Data Source=$state_dir/vault.db"
export Artifacts__StorePath="$state_dir/artifacts"
export ASPNETCORE_URLS="${LIFENIZER_BIND_URL:-http://127.0.0.1:5075}"
export ASPNETCORE_ENVIRONMENT=Production
export DOTNET_ENVIRONMENT=Production
export Auth__AllowDevLogin=false

exec dotnet run --project "$repo_root/backend/Lifenizer.Api/Lifenizer.Api.csproj" --no-launch-profile "$@"
