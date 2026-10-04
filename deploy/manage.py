#!/usr/bin/env python3
"""Remote half of deploy-compose.py; receives configuration on stdin, never logs it."""
import datetime
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tarfile


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True, capture_output=capture)


def main():
    os.umask(0o077)
    request = json.load(sys.stdin)
    directory = Path.home() / "dev/lifenizer-next"
    marker = directory / ".lifenizer-compose"
    if directory.exists() and any(directory.iterdir()) and not marker.exists():
        raise SystemExit(f"Preserving unmanaged directory: {directory}")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    marker.touch(mode=0o600)
    os.chdir(directory)
    env_file = directory / ".env"
    env = dict(line.split("=", 1) for line in env_file.read_text().splitlines()
               if line and not line.startswith("#")) if env_file.exists() else {}
    action = request["action"]
    if action == "inspect":
        proxy = json.loads(run("docker", "inspect", "traefik", capture=True).stdout)[0]
        address = proxy["NetworkSettings"]["Networks"]["proxy"]["IPAddress"]
        if not address:
            raise SystemExit("Traefik has no address on the proxy network")
        print(json.dumps({"proxy": address, "bootstrapHash": env.get("Pairing__BootstrapTokenHash"),
                          "expiresAt": env.get("Pairing__BootstrapExpiresAt")}))
        return
    if action not in ("install", "backup"):
        raise SystemExit("Unknown action")
    if env_file.exists():
        backup_dir = directory / "backups"
        backup_dir.mkdir(mode=0o700, exist_ok=True)
        backup = backup_dir / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".tar.gz")
        run("docker", "compose", "stop", "api")
        try:
            with tarfile.open(backup, "w:gz") as archive:
                for name in ("data", ".env", "compose.yaml", ".lifenizer-compose"):
                    archive.add(name, arcname=name)
        finally:
            run("docker", "compose", "start", "api")
        print(f"Consistent encrypted-vault backup: {backup}", flush=True)
    if action == "backup":
        return
    if env.get("Pairing__BootstrapTokenHash") not in (None, request["bootstrapHash"]):
        raise SystemExit("Bootstrap identity differs; existing configuration preserved")
    for name in ("data", "data/artifacts", "whisper"):
        (directory / name).mkdir(mode=0o700, exist_ok=True)
    env.update({"LIFENIZER_IMAGE": request["image"], "LIFENIZER_UID": str(os.getuid()),
                "LIFENIZER_GID": str(os.getgid()), "ReverseProxy__KnownProxies__0": request["proxy"]})
    env.setdefault("Jwt__Secret", secrets.token_urlsafe(48))
    env.setdefault("Pairing__BootstrapTokenHash", request["bootstrapHash"])
    env.setdefault("Pairing__BootstrapExpiresAt", request["expiresAt"])
    temp = directory / ".env.next"
    temp.write_text("".join(f"{key}={value}\n" for key, value in env.items()))
    temp.replace(env_file)
    (directory / "compose.yaml").write_text(request["compose"])
    run("docker", "compose", "config", "--quiet")
    run("docker", "compose", "up", "-d", "--wait", "--wait-timeout", "90", "--remove-orphans")
    print(f"Lifenizer is healthy in {directory}")


if __name__ == "__main__":
    main()
