"""Deployment configuration tests; never contact SSH, Docker or live services."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import manage

spec = importlib.util.spec_from_file_location("deploy_compose", Path(__file__).resolve().parents[1] / "scripts/deploy-compose.py")
deploy_compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy_compose)


class ServiceConfigTests(unittest.TestCase):
    def test_rejects_unsupported_and_unsafe_values(self):
        for config in ({"Jwt__Secret": "replacement"}, [], {"ObjectStorage__Bucket": None},
                       {"ObjectStorage__Bucket": {}}, {"ObjectStorage__Bucket": []}):
            with self.subTest(config=config), self.assertRaises(ValueError):
                manage.validate_service_config(config)
        for value in ("line\nbreak", "line\rbreak", "${SECRET}", "value #comment", "'quoted'", '"quoted"', "back\\slash", "nul\0", float("nan")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                manage.validate_service_config({"ObjectStorage__Bucket": value})
        self.assertEqual(manage.validate_service_config({"ObjectStorage__Region": "auto", "Products__Premium": 123}),
                         {"ObjectStorage__Region": "auto", "Products__Premium": "123"})

    def test_requires_owner_only_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "service.json"
            path.write_text('{"ObjectStorage__Bucket":"private-bucket"}')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                deploy_compose.read_service_config(path)
            path.chmod(0o600)
            self.assertEqual(deploy_compose.read_service_config(path), {"ObjectStorage__Bucket": "private-bucket"})
            with patch.object(os, "geteuid", return_value=os.geteuid() + 1), self.assertRaises(ValueError):
                deploy_compose.read_service_config(path)
            link = Path(temp) / "link"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                deploy_compose.read_service_config(link)

    def test_invalid_config_rejected_before_deployment(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "service.json"
            path.write_text('{"Jwt__Secret":"must-not-be-printed"}')
            path.chmod(0o600)
            with patch.object(sys, "argv", ["deploy-compose.py", "--service-config", str(path)]), \
                 patch.object(deploy_compose, "run") as run, patch.object(deploy_compose, "remote") as remote:
                with self.assertRaises(SystemExit) as error:
                    deploy_compose.main()
                self.assertNotIn("must-not-be-printed", str(error.exception))
                run.assert_not_called()
                remote.assert_not_called()

    def test_install_backs_up_then_patches_only_supplied_service_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            directory = home / "dev/lifenizer-next"
            (directory / "data").mkdir(parents=True)
            (directory / ".lifenizer-compose").touch()
            (directory / "compose.yaml").write_text("old-compose")
            original = "Jwt__Secret=keep-secret\nPairing__BootstrapTokenHash=same\nObjectStorage__Bucket=old-bucket\nPayments__BaseUrl=https://payments.example\n"
            (directory / ".env").write_text(original)
            request = {"action": "install", "image": "api:test", "proxy": "192.0.2.1", "bootstrapHash": "same",
                       "expiresAt": "2026-10-23T00:00:00Z", "compose": "new-compose",
                       "serviceConfig": {"ObjectStorage__Bucket": "new-bucket", "ObjectStorage__Region": "auto"}}
            previous_cwd, previous_umask = Path.cwd(), os.umask(0o077)
            try:
                with patch.object(manage.Path, "home", return_value=home), patch.object(manage, "run"), \
                     patch("sys.stdin", io.StringIO(json.dumps(request))), contextlib.redirect_stdout(io.StringIO()) as output:
                    manage.main()
                updated = (directory / ".env").read_text()
                self.assertIn("Jwt__Secret=keep-secret\n", updated)
                self.assertIn("Payments__BaseUrl=https://payments.example\n", updated)
                self.assertIn("ObjectStorage__Bucket=new-bucket\n", updated)
                self.assertEqual((directory / ".env").stat().st_mode & 0o777, 0o600)
                with tarfile.open(next((directory / "backups").glob("*.tar.gz"))) as backup:
                    self.assertEqual(backup.extractfile(".env").read().decode(), original)
                self.assertNotIn("keep-secret", output.getvalue())
                self.assertNotIn("new-bucket", output.getvalue())
            finally:
                os.chdir(previous_cwd)
                os.umask(previous_umask)


if __name__ == "__main__":
    unittest.main()
