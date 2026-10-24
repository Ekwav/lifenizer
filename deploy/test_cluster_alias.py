"""No SSH, Docker, DNS, credentials or production files are accessed."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cluster_alias', Path(__file__).with_name('cluster_alias.py'))
alias = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alias)


class AliasTests(unittest.TestCase):
    def test_merge_handles_quoted_keys_and_preserves_unrelated_settings(self):
        import yaml
        before = b'"http":\n  "routers":\n    "other": {rule: "Host(`other.example`)"}\ntls: {options: {default: {minVersion: VersionTLS12}}}\n'
        addition = Path(__file__).with_name('cluster-alias.yaml').read_bytes()
        request = alias.prepare(before, addition)
        merged = yaml.safe_load(request['desired'])
        self.assertEqual(merged['tls'], yaml.safe_load(before)['tls'])
        self.assertEqual(merged['http']['routers']['other'], yaml.safe_load(before)['http']['routers']['other'])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.yml'; path.write_bytes(before)
            inode = path.stat().st_ino
            result = alias.apply(path, request)
            backup = Path(result['backup'])
            self.assertEqual(backup.read_bytes(), before)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(path.read_text(), request['desired'])
            path.write_bytes(b'changed: true\n')
            with self.assertRaisesRegex(ValueError, 'Source config changed'):
                alias.apply(path, request)
            self.assertEqual(path.read_bytes(), b'changed: true\n')

    def test_remote_apply_needs_no_yaml_dependency_or_script_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.yml'; path.write_bytes(b'tls: {}\n')
            request = alias.prepare(path.read_bytes(), Path(__file__).with_name('cluster-alias.yaml').read_bytes())
            result = subprocess.run([sys.executable, '-S', '-c', Path(__file__).with_name('cluster_alias.py').read_text(),
                                     'apply', str(path)], input=json.dumps(request), text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.read_text(), request['desired'])

    def test_separate_backup_directory_is_private_and_preserves_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = root / 'config.yml'
            path.write_bytes(b'tls: {}\n'); before = path.read_bytes(); inode = path.stat().st_ino
            backups = root / 'backups'; backups.mkdir(mode=0o700)
            request = alias.prepare(before, Path(__file__).with_name('cluster-alias.yaml').read_bytes())
            result = alias.apply(path, request, backups)
            backup = Path(result['backup'])
            self.assertEqual(backup.parent, backups)
            self.assertEqual(backup.read_bytes(), before)
            self.assertEqual((backup.stat().st_uid, backup.stat().st_gid), (backups.stat().st_uid, backups.stat().st_gid))
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.stat().st_ino, inode)
            path.write_bytes(before); backups.chmod(0o755)
            with self.assertRaisesRegex(ValueError, 'Backup directory must be private'):
                alias.apply(path, request, backups)
            self.assertEqual(path.read_bytes(), before)

    def test_conflicting_route_is_preserved(self):
        with self.assertRaisesRegex(ValueError, 'Conflicting existing routers/lifenizer'):
            alias.prepare(b'http: {routers: {lifenizer: {rule: existing}}}',
                          Path(__file__).with_name('cluster-alias.yaml').read_bytes())


if __name__ == '__main__':
    unittest.main()
