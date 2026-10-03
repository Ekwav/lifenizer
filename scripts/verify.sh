#!/usr/bin/env bash
set -euo pipefail
# --live-whisper requires a reachable real Whisper service; there is no skip fallback.
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"
live_whisper=false
if [[ ${1:-} == --live-whisper && $# == 1 ]]; then
  live_whisper=true
elif [[ $# != 0 ]]; then
  echo 'Usage: scripts/verify.sh [--live-whisper]' >&2
  exit 2
fi
if "$live_whisper"; then
  export LIFENIZER_REQUIRE_WHISPER=true
  export WHISPER_URL=${WHISPER_URL:-http://127.0.0.1:19000}
  curl --fail --silent --show-error --max-time 10 "$WHISPER_URL/docs" >/dev/null
fi
dotnet restore backend/LifenizerNext.slnx
dotnet test backend/LifenizerNext.slnx -c Release --no-restore
(
  cd app
  flutter pub get
  flutter analyze
  flutter test
  flutter build web --release --dart-define=LIFENIZER_E2E=true
)
(
  cd e2e
  export CI=true
  npm ci
  npx playwright install chromium
  if "$live_whisper"; then
    npx playwright test
  else
    npx playwright test '^(?!.*audio-search\.spec\.ts$).*'
  fi
)
# Leave a normal production bundle after the instrumented browser checks.
(cd app && flutter build web --release)
