#!/usr/bin/env python3
"""Prepare locally with PyYAML; apply over SSH using only the standard library."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(source, alias):
    import yaml

    current = yaml.safe_load(source) or {}
    additions = yaml.safe_load(alias)
    for kind, objects in additions['http'].items():
        target = current.setdefault('http', {}).setdefault(kind, {})
        for name, value in objects.items():
            if name in target and target[name] != value:
                raise ValueError(f'Conflicting existing {kind}/{name}; config preserved')
            target[name] = value
    return {'expectedSha256': digest(source), 'desired': yaml.safe_dump(current, sort_keys=False)}


def apply(path, request, backup_dir=None):
    desired = request['desired'].encode()
    if not desired:
        raise ValueError('Empty config refused')
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'r+b') as output:
        fcntl.flock(output, fcntl.LOCK_EX)
        info = os.fstat(output.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('Expected a regular config file')
        before = output.read()
        if digest(before) != request['expectedSha256']:
            raise ValueError('Source config changed; nothing written')
        directory = path.parent if backup_dir is None else Path(backup_dir)
        owner = directory.stat(follow_symlinks=False)
        if backup_dir is not None and (not stat.S_ISDIR(owner.st_mode) or owner.st_mode & 0o077):
            raise ValueError('Backup directory must be private (0700)')
        backup = directory / f'{path.name}.lifenizer-backup-{time.time_ns()}'
        with os.fdopen(os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as saved:
            if backup_dir is not None:
                os.fchown(saved.fileno(), owner.st_uid, owner.st_gid)
            saved.write(before)
            saved.flush()
            os.fsync(saved.fileno())
        if os.stat(path, follow_symlinks=False).st_ino != info.st_ino:
            raise ValueError('Source inode changed; nothing written')
        output.seek(0)
        if digest(output.read()) != request['expectedSha256']:
            raise ValueError('Source config changed; nothing written')
        # Preserve the inode used by Traefik's single-file bind mount.
        output.seek(0)
        output.write(desired)
        output.truncate()
        output.flush()
        os.fsync(output.fileno())
        output.seek(0)
        if output.read() != desired:
            raise ValueError(f'Config readback differs; backup: {backup}')
    return {'backup': str(backup), 'sha256': digest(desired), 'inode': info.st_ino}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('prepare', 'apply'))
    parser.add_argument('config', type=Path)
    parser.add_argument('--alias', type=Path)
    parser.add_argument('--backup-dir', type=Path, help='Existing private directory; backup ownership follows its owner')
    args = parser.parse_args()
    result = (prepare(args.config.read_bytes(), (args.alias or Path(__file__).with_name('cluster-alias.yaml')).read_bytes()) if args.mode == 'prepare'
              else apply(args.config, json.load(sys.stdin), args.backup_dir))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
