import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "e4-acceptance.py"
spec = importlib.util.spec_from_file_location("e4_acceptance", SCRIPT)
e4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e4)

class PreflightTests(unittest.TestCase):
    """The only preflight boundary is the exact settings and debug-log sandbox grants."""

    def make_entitlements(self, directory, filename, key, include_group=False):
        path = directory / filename
        data = {"com.apple.security.app-sandbox": True, **e4.expected_file_exceptions(key)}
        if include_group:
            data["com.apple.security.application-groups"] = ["group.invalid"]
        path.write_bytes(plistlib.dumps(data))
        return path

    def test_exact_host_and_extension_entitlements_are_ready_without_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "App").mkdir(); (root / "PreviewExtension").mkdir(); (root / "ThumbnailExtension").mkdir()
            self.make_entitlements(root / "App", "GlimtHost.entitlements", e4.HOST_ENTITLEMENT)
            self.make_entitlements(root / "PreviewExtension", "GlimtPreview.entitlements", e4.EXTENSION_ENTITLEMENT)
            self.make_entitlements(root / "ThumbnailExtension", "GlimtThumbnail.entitlements", e4.EXTENSION_ENTITLEMENT)
            checks = e4.preflight(root)
            self.assertTrue(e4.ready(checks))

    def test_broader_path_or_app_group_fails_preflight(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "App").mkdir(); (root / "PreviewExtension").mkdir(); (root / "ThumbnailExtension").mkdir()
            self.make_entitlements(root / "App", "GlimtHost.entitlements", e4.HOST_ENTITLEMENT)
            self.make_entitlements(root / "PreviewExtension", "GlimtPreview.entitlements", e4.EXTENSION_ENTITLEMENT)
            self.make_entitlements(root / "ThumbnailExtension", "GlimtThumbnail.entitlements", e4.EXTENSION_ENTITLEMENT)
            preview = root / "PreviewExtension/GlimtPreview.entitlements"
            data = plistlib.loads(preview.read_bytes())
            data[e4.EXTENSION_ENTITLEMENT] = ["/Library/Application Support/Glimt/"]
            data["com.apple.security.application-groups"] = ["group.invalid"]
            preview.write_bytes(plistlib.dumps(data))
            self.assertFalse(e4.ready(e4.preflight(root)))

    def test_host_limited_to_settings_file_fails_preflight(self):
        # The host must be able to create the settings directory on first save.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "App").mkdir(); (root / "PreviewExtension").mkdir(); (root / "ThumbnailExtension").mkdir()
            host = self.make_entitlements(root / "App", "GlimtHost.entitlements", e4.HOST_ENTITLEMENT)
            self.make_entitlements(root / "PreviewExtension", "GlimtPreview.entitlements", e4.EXTENSION_ENTITLEMENT)
            self.make_entitlements(root / "ThumbnailExtension", "GlimtThumbnail.entitlements", e4.EXTENSION_ENTITLEMENT)
            data = plistlib.loads(host.read_bytes())
            data[e4.HOST_ENTITLEMENT] = [e4.LOG_EXCEPTION, e4.SETTINGS_EXCEPTION]
            host.write_bytes(plistlib.dumps(data))
            self.assertFalse(e4.ready(e4.preflight(root)))

    def test_repository_entitlements_pass_preflight(self):
        self.assertTrue(e4.ready(e4.preflight()))


class InstallRestoreTests(unittest.TestCase):
    """Runs the command line against a temporary Applications folder with stubbed system tools."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.applications = base / "Applications"; self.applications.mkdir()
        self.run_dir = base / "run"
        self.log = base / "pluginkit.log"
        stub = base / "pluginkit"
        stub.write_text(f'#!/bin/sh\necho "$@" >> "{self.log}"\n'); stub.chmod(0o755)
        self.ls_log = base / "lsregister.log"
        lsregister = base / "lsregister"
        lsregister.write_text(f'#!/bin/sh\necho "$@" >> "{self.ls_log}"\n'); lsregister.chmod(0o755)
        self.env = dict(os.environ, GLIMT_E4_PLUGINKIT=str(stub), GLIMT_E4_LSREGISTER=str(lsregister),
                        GLIMT_E4_BUNDLE_CHECK="true")
        self.candidate = self.make_app(base / "build/Glimt.app", b"candidate")

    def tearDown(self):
        self.temporary.cleanup()

    def make_app(self, path, marker):
        (path / "Contents/PlugIns/GlimtPreview.appex").mkdir(parents=True)
        (path / "Contents/PlugIns/GlimtThumbnail.appex").mkdir(parents=True)
        (path / "Contents/marker").write_bytes(marker)
        return path

    def run_command(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env or self.env)

    def install(self, env=None):
        return self.run_command("install", str(self.candidate), "--run-dir", str(self.run_dir),
                                "--applications", str(self.applications), "--allow-system-mutation", env=env)

    def marker(self):
        return (self.applications / "Glimt.app/Contents/marker").read_bytes()

    def test_install_and_restore_round_trip_keeps_the_previous_app(self):
        self.make_app(self.applications / "Glimt.app", b"previous")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(), b"candidate")
        self.assertIn("-a " + str(self.applications / "Glimt.app/Contents/PlugIns/GlimtPreview.appex"), self.log.read_text())
        result = self.run_command("restore", "--run-dir", str(self.run_dir), "--allow-system-mutation")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(), b"previous")
        self.assertEqual((self.run_dir / "removed/Glimt-1.app/Contents/marker").read_bytes(), b"candidate")
        self.assertTrue((self.run_dir / "e4-install.restored.json").is_file())
        self.assertIn("-r ", self.log.read_text())

    def test_launch_services_records_follow_every_move(self):
        target = str(self.applications / "Glimt.app")
        self.make_app(self.applications / "Glimt.app", b"previous")
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.ls_log.read_text().splitlines(), [f"-u {target}", f"-f -R -trusted {target}"],
                         "the previous app is unregistered before it moves, the candidate registered after")
        self.assertEqual(self.run_command("restore", "--run-dir", str(self.run_dir),
                                          "--allow-system-mutation").returncode, 0)
        self.assertEqual(self.ls_log.read_text().splitlines()[2:], [f"-u {target}", f"-f -R -trusted {target}"],
                         "the test install is unregistered before it moves, the restored app registered after")

    def test_restore_without_previous_app_leaves_applications_empty_without_deleting(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.run_command("restore", "--run-dir", str(self.run_dir),
                                          "--allow-system-mutation").returncode, 0)
        self.assertFalse((self.applications / "Glimt.app").exists())
        self.assertTrue((self.run_dir / "removed/Glimt-1.app/Contents/marker").is_file())

    def test_failed_audit_installs_nothing_and_keeps_previous_app(self):
        self.make_app(self.applications / "Glimt.app", b"previous")
        result = self.install(env=dict(self.env, GLIMT_E4_BUNDLE_CHECK="false"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nothing was installed", result.stderr)
        self.assertEqual(self.marker(), b"previous")
        self.assertFalse((self.run_dir / "e4-install.json").exists())

    def test_second_install_is_refused_until_restore(self):
        self.assertEqual(self.install().returncode, 0)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restore it first", result.stderr)

    def test_restore_without_install_is_refused(self):
        result = self.run_command("restore", "--run-dir", str(self.run_dir), "--allow-system-mutation")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No recorded test install", result.stderr)

    def test_default_audit_is_the_signed_bundle_gate(self):
        result = self.install(env={k: v for k, v in self.env.items() if k != "GLIMT_E4_BUNDLE_CHECK"})
        self.assertNotEqual(result.returncode, 0, "An unsigned synthetic bundle must fail the signed audit")
        self.assertIn("nothing was installed", result.stderr)
        self.assertFalse((self.applications / "Glimt.app").exists())


if __name__ == "__main__":
    unittest.main()
