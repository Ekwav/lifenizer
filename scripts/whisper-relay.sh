#!/usr/bin/env bash
set -euo pipefail
# This socket is private to the operator and the Lifenizer container. SSH never
# publishes Whisper on a TCP port on the mail server.
ssh -o BatchMode=yes mail.coflnet.com 'python3 -c '\''from pathlib import Path
import stat
directory = Path.home() / "dev/lifenizer-next/whisper"
if not (directory.parent / ".lifenizer-compose").exists():
    raise SystemExit("Deploy Lifenizer Compose before starting its relay")
directory.mkdir(mode=0o700, exist_ok=True)
socket = directory / "asr.sock"
if socket.exists():
    if not stat.S_ISSOCK(socket.lstat().st_mode):
        raise SystemExit("Refusing to replace a non-socket file")
    socket.unlink()
'\'''
remote_home=$(ssh -o BatchMode=yes mail.coflnet.com 'printf "%s" "$HOME"')
exec ssh -NT -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -R "$remote_home/dev/lifenizer-next/whisper/asr.sock:127.0.0.1:19000" mail.coflnet.com
