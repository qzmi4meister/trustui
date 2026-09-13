import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
import warnings
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
import backend


CONFIG = '''# Keep this comment in the backup.
vpn_mode = "general"
killswitch_enabled = true
dns_upstreams = []
exclusions = []
future_option = { enabled = true, values = [1, 2] }
[endpoint]
hostname = "test.invalid"
addresses = ["127.0.0.1:443"]
username = "test-user"
password = "test-password"
upstream_protocol = "http2"
certificate = """line one
line two"""
[listener.tun]
mtu_size = 1280
included_routes = ["0.0.0.0/0"]
'''


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trustui test ' ")
        self.root = Path(self.temp.name)
        self.config = self.root / "trusttunnel_client.toml"
        self.config.write_text(CONFIG)
        self.support = self.root / "state"
        self.support.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def test_save_preserves_unknown_fields_and_original_backup(self):
        original, revision = backend.read_config(self.config)
        changed = copy.deepcopy(original["endpoint"])
        changed["password"] = 'quotes " slash \\ newline\nЮникод'
        result = backend.save(self.root, {"revision": revision, "edits": {
            "endpoint": changed, "exclusions": ["*.example.com", "10.0.0.0/8"]}})
        saved, _ = backend.read_config(self.config)
        self.assertEqual(saved["listener"], original["listener"])
        self.assertEqual(saved["future_option"], original["future_option"])
        self.assertEqual(saved["endpoint"], changed)
        self.assertEqual(Path(result["backup"]).read_text(), CONFIG)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(Path(result["backup"]).stat().st_mode & 0o777, 0o600)

    def test_external_change_and_invalid_input_never_overwrite(self):
        _, revision = backend.read_config(self.config)
        with self.assertRaises(ValueError):
            backend.save(self.root, {"revision": revision, "edits": {"vpn_mode": "bad"}})
        self.assertEqual(self.config.read_text(), CONFIG)
        self.config.write_text(CONFIG + "# external edit\n")
        with self.assertRaisesRegex(ValueError, "другим приложением"):
            backend.save(self.root, {"revision": revision, "edits": {}})
        self.assertTrue(self.config.read_text().endswith("# external edit\n"))
        self.assertEqual(list(self.root.glob("*.bak")), [])

    def test_profiles_and_malformed_profile(self):
        (self.root / "server.toml").write_text('hostname="server.invalid"\naddresses=["127.0.0.2:443"]')
        (self.root / "broken.toml").write_text('hostname = "unfinished')
        result = backend.load(self.root)
        self.assertEqual([p["name"] for p in result["profiles"]], ["server"])
        self.assertEqual(len(result["warnings"]), 1)

    def test_no_session_and_log_redaction(self):
        self.assertEqual(backend.read_state(self.support), {})
        (self.support / "client.log").write_text("test-user: test-password")
        self.assertNotIn("test-password", backend.log_tail(self.support))
        (self.support / "session.toml").write_text(CONFIG)
        self.assertEqual(backend.log_tail(self.support), "••••: ••••")

    def test_stale_pid_and_unrelated_process_are_not_signalled(self):
        fake = {"pid": os.getpid(), "identity": "wrong identity"}
        (self.support / "run.json").write_text(json.dumps(fake))
        with patch.object(os, "kill") as kill:
            self.assertTrue(backend.stop(self.support, os.getuid())["stopped"])
            kill.assert_not_called()
        fake["identity"] = backend.identity(os.getpid())
        (self.support / "run.json").write_text(json.dumps(fake))
        with patch.object(os, "kill") as kill, self.assertRaisesRegex(ValueError, "не принадлежит"):
            backend.stop(self.support, os.getuid())
            kill.assert_not_called()

    def test_fake_client_launch_log_and_graceful_stop(self):
        binary = self.root / "trusttunnel_client"
        binary.write_text(f'''#!{sys.executable}
import signal, time
signal.signal(signal.SIGINT, lambda *_: exit(0))
print("started test-user test-password", flush=True)
while True: time.sleep(0.05)
''')
        binary.chmod(0o700)
        child = None
        try:
            with patch.object(backend, "external_pids", return_value=[]):
                # The production bridge intentionally detaches the child; this test reaps it below.
                with warnings.catch_warnings():
                    warnings.filterwarnings("ignore", category=ResourceWarning, message="subprocess .* is still running")
                    state = backend.start(self.root, self.support, os.getuid())
                child = state["pid"]
                self.assertTrue(backend.running(state))
                self.assertEqual(backend.status(self.support)["pid"], child)
                self.assertIn("started •••• ••••", backend.log_tail(self.support))
                self.assertEqual((self.support / "session.toml").stat().st_mode & 0o777, 0o600)
                with self.assertRaisesRegex(ValueError, "уже запущен"):
                    backend.start(self.root, self.support, os.getuid())
                self.assertTrue(backend.stop(self.support, os.getuid())["stopped"])
        finally:
            if child:
                try:
                    os.kill(child, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.waitpid(child, 0)

    def test_early_exit_leaves_no_running_session(self):
        binary = self.root / "trusttunnel_client"
        binary.write_text("#!/bin/sh\necho simulated-failure\nexit 2\n")
        binary.chmod(0o700)
        original_popen = subprocess.Popen

        def already_exited(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            child.wait(timeout=10)
            return child

        # Make the early-exit case deterministic even when macOS delays the first execution.
        with patch.object(backend, "external_pids", return_value=[]), \
             patch.object(backend.subprocess, "Popen", side_effect=already_exited), \
             self.assertRaisesRegex(ValueError, "завершился"):
            backend.start(self.root, self.support, os.getuid())
        self.assertEqual(backend.read_state(self.support), {})
        self.assertIn("simulated-failure", backend.log_tail(self.support))


if __name__ == "__main__":
    unittest.main()
