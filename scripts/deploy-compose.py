#!/usr/bin/env python3
"""Build, scan and deploy the private mail.coflnet.com Compose service, then print its pairing QR."""
import argparse
import base64
import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = Path(__file__).resolve().parents[1]
SERVER = "https://mail.coflnet.com/lifenizer"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def remote(host, payload, capture=False):
    code = (REPO / "deploy/manage.py").read_text()
    return run("ssh", "-o", "BatchMode=yes", host, "python3 -c " + shlex.quote(code),
               input=json.dumps(payload), capture_output=capture)


def base64url(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def print_link(state, directory):
    secret = state["secret"]
    deadline = int(datetime.datetime.fromisoformat(state["expiresAt"]).timestamp())
    link = "lifenizer://connect?" + urllib.parse.urlencode({"server": SERVER}) + "#" + urllib.parse.urlencode(
        {"v": "1", "secret": secret, "until": deadline})
    (directory / "connect.txt").write_text(link + "\n")
    print(f"\nPaste this link into Lifenizer on desktop or phone:\n{link}", flush=True)
    print(f"Automatic pairing until {state['expiresAt']}; keep the first device unlocked while connecting the next.\n"
          "Later connections require approval on an already connected device. Keep this link private.", flush=True)
    if shutil.which("qrencode"):
        run("qrencode", "-t", "ANSIUTF8", input=link)
        run("qrencode", "-t", "PNG", "-o", str(directory / "connect.png"), input=link)
        print(f"QR image: {directory / 'connect.png'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="mail.coflnet.com", help="SSH host/alias for the mail server")
    parser.add_argument("--show-link", action="store_true", help="Show the existing link without extending its deadline")
    parser.add_argument("--backup-only", action="store_true", help="Back up the server database, artifacts and configuration")
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "lifenizer/compose"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_file = directory / "pairing.json"
    if args.backup_only:
        remote(args.host, {"action": "backup"})
        return
    state = json.loads(state_file.read_text()) if state_file.exists() else None
    if args.show_link:
        if not state or not state.get("expiresAt"):
            raise SystemExit("No completed installation found")
        print_link(state, directory)
        return
    for command in ("git", "docker", "ssh", "gzip", "trivy", "qrencode"):
        if not shutil.which(command):
            raise SystemExit(f"Required command missing: {command}")
    if run("git", "status", "--porcelain", cwd=REPO, capture_output=True).stdout:
        raise SystemExit("Commit reviewed changes before deploying")
    info = json.loads(remote(args.host, {"action": "inspect"}, capture=True).stdout)
    if not state:
        if info["bootstrapHash"]:
            raise SystemExit("Restore the original private pairing.json before redeploying; server identity preserved")
        state = {"secret": secrets.token_urlsafe(32)}
        state_file.write_text(json.dumps(state))
    secret = base64.urlsafe_b64decode(state["secret"] + "==")
    proof = base64url(hmac.digest(secret, b"lifenizer:enroll:v1", "sha256"))
    bootstrap_hash = hashlib.sha256(proof.encode()).hexdigest()
    if info["bootstrapHash"] not in (None, bootstrap_hash):
        raise SystemExit("Local pairing identity differs from server; refusing to replace it")
    revision = run("git", "rev-parse", "--short=12", "HEAD", cwd=REPO, capture_output=True).stdout.strip()
    tag = f"lifenizer-api:{revision}"
    run("docker", "build", "--pull", "--tag", tag, str(REPO / "backend"))
    run("trivy", "image", "--scanners", "vuln", "--severity", "HIGH,CRITICAL", "--ignore-unfixed", "--exit-code", "1", tag)
    digest = run("docker", "image", "inspect", "--format", "{{.Id}}", tag, capture_output=True).stdout.strip()[7:19]
    image = f"{tag}-{digest}"
    run("docker", "tag", tag, image)
    print("Sending verified image to the mail server…", flush=True)
    with subprocess.Popen(["docker", "save", image], stdout=subprocess.PIPE) as export:
        with subprocess.Popen(["gzip", "-1"], stdin=export.stdout, stdout=subprocess.PIPE) as compress:
            export.stdout.close()
            run("ssh", "-o", "BatchMode=yes", args.host, "docker load", stdin=compress.stdout)
            compress.stdout.close()
            if compress.wait() or export.wait():
                raise SystemExit("Image transfer failed")
    # Start the one-hour window after the build and upload, and never renew it on redeploy.
    state["expiresAt"] = info["expiresAt"] or state.get("expiresAt") or (
        datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).isoformat()
    state_file.write_text(json.dumps(state))
    remote(args.host, {"action": "install", "image": image, "proxy": info["proxy"],
                       "bootstrapHash": bootstrap_hash, "expiresAt": state["expiresAt"],
                       "compose": (REPO / "deploy/compose.yaml").read_text()})
    # Docker health can pass before Traefik has discovered the new container.
    deadline = time.monotonic() + 60
    while True:
        try:
            with urllib.request.urlopen(SERVER + "/health", timeout=10) as response:
                if json.load(response).get("app") == "lifenizer-next":
                    break
        except (urllib.error.URLError, ValueError, TimeoutError):
            pass
        if time.monotonic() >= deadline:
            raise SystemExit("Public HTTPS route is not ready; check Traefik before connecting devices")
        time.sleep(2)
    print_link(state, directory)


if __name__ == "__main__":
    main()
