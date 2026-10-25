#!/usr/bin/env python3
"""Package reviewed native builds, then explicitly publish public downloads.

Native builds must be produced from --source before prepare. No signing keys,
repository archive, application data, or credentials are packaged or uploaded.
See --help and the prepare/publish subcommand help for required review inputs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = (
    "lifenizer.apk", "lifenizer-linux-x64.tar.gz",
    "lifenizer-history-sync-chromium.zip", "lifenizer-history-sync-firefox.zip",
)
FILES = (*ARTIFACTS, "release.json", "SHA256SUMS")


def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def source_sha(value):
    require(re.fullmatch(r"[0-9a-f]{40}", value), "Use a full reviewed source SHA")
    return value


def prepare(args):
    source_sha(args.source)
    require(run("git", "rev-parse", "HEAD") == args.source, "Reviewed source must equal HEAD")
    require(not run("git", "status", "--porcelain", "--untracked-files=no"), "Commit tracked source changes before packaging")
    apk = args.apk.resolve(strict=True)
    bundle = args.linux_bundle.resolve(strict=True)
    require(set(p.name for p in bundle.iterdir()) == {"lifenizer", "data", "lib"}, "Unexpected Linux bundle entries")
    require(os.access(bundle / "lifenizer", os.X_OK), "Linux executable missing")
    with (bundle / "lifenizer").open("rb") as stream:
        elf = stream.read(20)
    require(elf[:5] == b"\x7fELF\x02" and elf[18:20] == b"\x3e\x00", "Expected Linux x86-64 ELF executable")
    for path in bundle.rglob("*"):
        require(not path.is_symlink(), f"Unexpected bundle symlink: {path}")
        require(path.is_file() or path.is_dir(), f"Unexpected bundle entry: {path}")
    certificate = run(args.apksigner, "verify", "--print-certs", str(apk))
    signers = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$", certificate, re.M)
    expected_signer = args.apk_signer_sha256.lower().replace(":", "")
    require(re.fullmatch(r"[0-9a-f]{64}", expected_signer) and signers == [expected_signer], "APK signer does not match reviewed stable signer")
    badging = run(args.aapt, "dump", "badging", str(apk))
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
    require(package and package[1] == "com.lifenizer.app", "Unexpected APK package identity")
    subprocess.run(["npm", "test"], cwd=ROOT / "integrations/browser-extension", check=True)
    subprocess.run(["npm", "run", "build"], cwd=ROOT / "integrations/browser-extension", check=True)
    output = args.output.resolve()
    require(not output.exists(), "Output already exists; choose a new release directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".public-release-", dir=output.parent) as temporary:
        stage = Path(temporary)
        shutil.copyfile(apk, stage / ARTIFACTS[0])
        with tarfile.open(stage / ARTIFACTS[1], "w:gz") as archive:
            archive.add(bundle, arcname="lifenizer/app/build/linux/x64/release/bundle")
            for name in ("install.sh", "lifenizer.desktop"):
                archive.add(ROOT / "integrations/kde" / name, arcname=f"lifenizer/integrations/kde/{name}")
            instructions = stage / "README.txt"
            instructions.write_text("Lifenizer for Linux x86-64\n\nExtract this archive and open a terminal in the lifenizer directory, then run:\n  bash integrations/kde/install.sh\nOpen Lifenizer from your applications menu. The installer also registers\nlifenizer:// pairing links and KDE KRunner integration for your user.\nRun without installation: ./app/build/linux/x64/release/bundle/lifenizer\nRequires a glibc Linux desktop with GTK 3, libsecret and an unlocked Secret\nService keyring (for example GNOME Keyring or a compatible KWallet service).\nMicrophone recording requires the record plugin runtime tools, including\nparecord (PulseAudio/PipeWire compatibility) and ffmpeg.\nIf launch fails, inspect missing libraries with:\n  ldd app/build/linux/x64/release/bundle/lifenizer\n")
            archive.add(instructions, arcname="lifenizer/README.txt")
            instructions.unlink()
        for name in ARTIFACTS[2:]:
            original = ROOT / "integrations/browser-extension/dist" / name
            with zipfile.ZipFile(original) as archive:
                require(archive.testzip() is None, "Damaged extension archive")
                for entry in archive.namelist():
                    path = Path(entry)
                    require(not path.is_absolute() and ".." not in path.parts and path.parts[0] in {"manifest.json", "src", "popup", "options", "pair", "vendor"}, "Unexpected extension archive entry")
                    if not entry.endswith("/"):
                        relative = f"integrations/browser-extension/{entry}"
                        require(run("git", "ls-files", "--", relative) == relative, "Untracked extension payload")
                        require(archive.read(entry) == (ROOT / relative).read_bytes(), "Extension payload differs from source")
                manifest = json.loads(archive.read("manifest.json"))
                require(manifest["name"] == "Lifenizer Browser Sync", "Unexpected extension identity")
            shutil.copyfile(original, stage / name)
        metadata = {"source": args.source, "androidPackage": package[1], "androidVersionCode": package[2],
                    "androidVersionName": package[3], "androidSignerSha256": expected_signer,
                    "extensionVersion": manifest["version"], "sha256": {name: digest(stage / name) for name in ARTIFACTS}}
        (stage / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (stage / "SHA256SUMS").write_text("".join(f"{digest(stage / name)}  {name}\n" for name in (*ARTIFACTS, "release.json")))
        os.rename(stage, output)
    print(f"Prepared {output}; review release.json and SHA256SUMS before publish")


def publish(args):
    source_sha(args.source)
    directory = args.directory.resolve(strict=True)
    require(set(p.name for p in directory.iterdir()) == set(FILES), "Release must contain only the public allowlist")
    require(all((directory / name).is_file() and not (directory / name).is_symlink() for name in FILES), "Release files must be regular files")
    metadata = json.loads((directory / "release.json").read_text())
    require(metadata["source"] == args.source, "Release source does not match reviewed source")
    require(metadata["sha256"] == {name: digest(directory / name) for name in ARTIFACTS}, "Artifact hashes changed")
    expected = "".join(f"{digest(directory / name)}  {name}\n" for name in (*ARTIFACTS, "release.json"))
    require((directory / "SHA256SUMS").read_text() == expected, "Checksum manifest changed")
    # Only this fixed allowlist crosses the stream; no local directory recursion.
    remote = '''set -eu
base=/data/downloads
mkdir -p "$base/releases"
stage=$(mktemp -d "$base/.upload.XXXXXX")
link="$base/.current.$$"
trap 'rm -rf "$stage"; rm -f "$link"' EXIT
tar -xf - -C "$stage"
(cd "$stage" && sha256sum -c SHA256SUMS)
release="$base/releases/SOURCE"
if test -e "$release"; then
  cmp "$stage/SHA256SUMS" "$release/SHA256SUMS"
  (cd "$release" && sha256sum -c SHA256SUMS)
else
  chmod -R a+rX "$stage"
  mv "$stage" "$release"
fi
ln -s "releases/SOURCE" "$link"
mv -Tf "$link" "$base/current"
'''.replace("SOURCE", args.source)
    command = ["kubectl", "--context", args.context, "-n", "lifenizer", "exec", "-i", args.pod, "-c", "lifenizer", "--", "sh", "-c", remote]
    with tempfile.TemporaryFile() as stream:
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for name in FILES:
                archive.add(directory / name, arcname=name, recursive=False)
        stream.seek(0)
        subprocess.run(command, stdin=stream, check=True)
    print(f"Published reviewed release {args.source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("prepare", help="Package final native builds produced from a clean reviewed SHA")
    package.add_argument("--source", required=True)
    package.add_argument("--apk", required=True, type=Path)
    package.add_argument("--linux-bundle", required=True, type=Path)
    package.add_argument("--apk-signer-sha256", required=True, help="Reviewed existing stable signing certificate digest")
    package.add_argument("--apksigner", default="apksigner")
    package.add_argument("--aapt", default="aapt")
    package.add_argument("--output", required=True, type=Path)
    upload = commands.add_parser("publish", help="Upload a reviewed prepared release and atomically activate it on the existing PVC")
    upload.add_argument("--source", required=True)
    upload.add_argument("--directory", required=True, type=Path)
    upload.add_argument("--context", required=True)
    upload.add_argument("--pod", required=True, help="Existing Lifenizer API pod; no workload changes are made")
    args = parser.parse_args()
    (prepare if args.command == "prepare" else publish)(args)


if __name__ == "__main__":
    main()
