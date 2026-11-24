from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "scripts" / "lib" / "bundle-lifecycle.sh"
SHELLS = [shell for shell in ("/bin/bash", "/opt/homebrew/bin/bash") if Path(shell).exists()]


class BundleLifecycleTests(unittest.TestCase):
    """Drives the sourced library against a temporary Applications folder with logged system tools."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.applications = self.base / "Applications"; self.applications.mkdir()
        self.destination = self.applications / "Glimt.app"
        self.scopes = self.base / "scoped.noindex"
        self.log = self.base / "system.log"
        for tool in ("lsregister", "pluginkit"):
            stub = self.base / tool
            stub.write_text(f'#!/bin/sh\necho "{tool} $*" >> "{self.log}"\n')
            stub.chmod(0o755)
        ps_stub = self.base / "ps"
        ps_stub.write_text('#!/bin/sh\n[ "${GLIMT_TEST_PS_LIVE:-}" = YES ]\n')
        ps_stub.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def make_app(self, path, marker):
        for extension in ("GlimtPreview.appex", "GlimtThumbnail.appex"):
            (path / "Contents/PlugIns" / extension).mkdir(parents=True)
        (path / "Contents/marker").write_text(marker)
        return path

    def run_library(self, body, shell=None, extra_env=None):
        script = f'set -euo pipefail\nsource "{LIBRARY}"\n{body}\n'
        env = dict(os.environ, GLIMT_LSREGISTER=str(self.base / "lsregister"),
                   GLIMT_PLUGINKIT=str(self.base / "pluginkit"), GLIMT_SCOPE_ROOT=str(self.scopes),
                   PATH=str(self.base) + os.pathsep + os.environ.get("PATH", ""))
        env.update(extra_env or {})
        return subprocess.run([shell or SHELLS[0], "-c", script], capture_output=True, text=True, env=env)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def make_derived_data(self, name):
        products = self.scopes / name / "DerivedData/Build/Products"
        debug = self.make_app(products / "Debug/Glimt.app", "debug")
        release = self.make_app(products / "Release/Glimt.app", "release")
        record = self.scopes / name / "DerivedData/Build/Intermediates.noindex/XCBuildData/registered-launchservices.txt"
        record.parent.mkdir(parents=True)
        record.write_text(f"{debug}\n{debug}\n/elsewhere/Gone.app\n")
        return debug, release

    # MARK: Scoped build locations

    def test_release_unregisters_every_recorded_and_built_bundle_before_deleting(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                scope = self.scopes / "flow"
                scope.mkdir(parents=True, exist_ok=True)
                user_data = scope / "keep.txt"
                user_data.write_text("unrecognized scope data")
                debug, release = self.make_derived_data("flow")
                self.log.unlink(missing_ok=True)
                result = self.run_library('glimt_claim_scope flow\nglimt_release_scope', shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()
                for app in (debug, release, Path("/elsewhere/Gone.app")):
                    self.assertIn(f"lsregister -u {app}", calls)
                self.assertIn(f"pluginkit -r {debug}/Contents/PlugIns/GlimtPreview.appex", calls)
                self.assertEqual(sum(c == f"lsregister -u {debug}" for c in calls), 1, "recorded twice and built once, released once")
                self.assertFalse((self.scopes / "flow/DerivedData").exists())
                self.assertFalse((self.scopes / "flow.lock").exists())
                self.assertEqual(user_data.read_text(), "unrecognized scope data")

    def test_scope_name_cannot_escape_the_claimed_root(self):
        escaped = self.scopes.parent / "escaped"
        result = self.run_library('glimt_claim_scope ../escaped')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(escaped.exists())

    def test_custom_scope_root_outside_temporary_directories_is_refused(self):
        env = dict(os.environ, GLIMT_LSREGISTER=str(self.base / "lsregister"),
                   GLIMT_PLUGINKIT=str(self.base / "pluginkit"),
                   GLIMT_SCOPE_ROOT="/etc/scoped.noindex")
        result = subprocess.run([SHELLS[0], "-c", f'set -euo pipefail; source "{LIBRARY}"; glimt_claim_scope flow'],
                                capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("allowed only below the system temporary directory", result.stderr)

    def test_unregister_failure_stops_scope_deletion(self):
        _, release = self.make_derived_data("flow")
        plugin = self.base / "pluginkit"
        plugin.write_text('#!/bin/sh\nexit 1\n')
        plugin.chmod(0o755)
        # The production EXIT trap calls cleanup from a conditional context, where errexit alone
        # cannot protect build products if unregistering fails.
        result = self.run_library('glimt_claim_scope flow\nglimt_release_scope || true')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(release.exists(), "registered build products remain when unregistration fails")
        self.assertTrue((self.scopes / "flow.lock").exists(), "scope lock remains for manual recovery")

    def test_already_unregistered_bundles_do_not_block_scope_deletion(self):
        _, release = self.make_derived_data("flow")
        plugin = self.base / "pluginkit"
        plugin.write_text('#!/bin/sh\necho "remove: no plugin at $2" >&2\nexit 1\n')
        plugin.chmod(0o755)
        register = self.base / "lsregister"
        register.write_text('#!/bin/sh\necho "failed to scan $2: -10814" >&2\nexit 1\n')
        register.chmod(0o755)
        result = self.run_library('glimt_claim_scope flow\nglimt_release_scope')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(release.exists())
        self.assertFalse((self.scopes / "flow.lock").exists())

    def test_claim_uses_a_stable_path_and_refuses_a_live_owner(self):
        result = self.run_library('glimt_claim_scope flow\necho "$GLIMT_SCOPE_DIR"\nglimt_claim_scope flow',
                                  extra_env={"GLIMT_TEST_PS_LIVE": "YES"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), str(self.scopes / "flow"))
        self.assertIn("in use", result.stderr)

    def test_claim_takes_over_a_dead_owner_and_releases_its_registrations(self):
        debug, _ = self.make_derived_data("flow")
        (self.scopes / "flow.lock").mkdir()
        (self.scopes / "flow.lock/pid").write_text("999999\n")
        result = self.run_library('glimt_claim_scope flow\n[[ ! -e "$GLIMT_SCOPE_DIR/DerivedData" ]]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"lsregister -u {debug}", self.calls())

    # MARK: Install, commit and rollback

    def test_install_keeps_no_backup_in_applications_and_commit_removes_the_rollback_copy(self):
        self.make_app(self.destination, "previous")
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        result = self.run_library(f'glimt_claim_scope install\nglimt_install_app "{candidate}" "{self.destination}"\n'
                                  'ls -a "$(dirname "$GLIMT_INSTALLED_APP")"\nglimt_commit_install\nglimt_release_scope')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "candidate")
        self.assertEqual(sorted(os.listdir(self.applications)), ["Glimt.app"])
        self.assertNotIn(".Glimt", result.stdout)
        self.assertFalse((self.scopes / "install").exists() and any((self.scopes / "install").iterdir()))
        calls = self.calls()
        unregister_old, register_new = calls.index(f"lsregister -u {self.destination}"), calls.index(f"lsregister -f -R -trusted {self.destination}")
        self.assertLess(unregister_old, register_new, "old app must be unregistered before it is moved aside")
        self.assertIn(f"pluginkit -a {self.destination}/Contents/PlugIns/GlimtThumbnail.appex", calls)

    def test_rollback_restores_and_reregisters_the_previous_app(self):
        self.make_app(self.destination, "previous")
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        result = self.run_library(f'glimt_claim_scope install\nglimt_install_app "{candidate}" "{self.destination}"\n'
                                  'glimt_rollback_install\nglimt_release_scope')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "previous")
        self.assertEqual(os.listdir(self.applications), ["Glimt.app"])
        self.assertEqual(self.calls()[-1].split()[0:2], ["pluginkit", "-a"])
        self.assertIn(f"lsregister -f -R -trusted {self.destination}", self.calls()[-4:])

    def test_rollback_without_previous_app_unregisters_and_removes_the_new_one(self):
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        result = self.run_library(f'glimt_claim_scope install\nglimt_install_app "{candidate}" "{self.destination}"\n'
                                  'glimt_rollback_install\nglimt_release_scope')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.listdir(self.applications), [])
        self.assertEqual(self.calls()[-1], f"lsregister -u {self.destination}")

    def test_exit_trap_rolls_back_an_uncommitted_install(self):
        self.make_app(self.destination, "previous")
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        result = self.run_library('trap glimt_finish EXIT\nglimt_claim_scope install\n'
                                  f'glimt_install_app "{candidate}" "{self.destination}"\nfalse')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "previous")
        self.assertFalse((self.scopes / "install.lock").exists())

    def test_interrupted_install_rollback_copy_is_restored_by_the_next_claim(self):
        rollback = self.make_app(self.scopes / "install/rollback/Glimt.app", "previous")
        result = self.run_library(f'GLIMT_INSTALL_DESTINATION="{self.destination}" glimt_claim_scope install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(rollback.exists())
        self.assertEqual((self.destination / "Contents/marker").read_text(), "previous")

    def test_rollback_copy_beside_a_present_install_is_left_for_the_owner(self):
        self.make_app(self.scopes / "install/rollback/Glimt.app", "previous")
        self.make_app(self.destination, "current")
        result = self.run_library(f'GLIMT_INSTALL_DESTINATION="{self.destination}" glimt_claim_scope install')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback copy", result.stderr)
        self.assertTrue((self.scopes / "install/rollback/Glimt.app").exists())

    def test_install_refuses_a_destination_owned_by_another_app(self):
        other = self.make_app(self.destination, "other")
        (other / "Contents/Info.plist").write_bytes(
            b'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>')
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        result = self.run_library(f'glimt_claim_scope install\nglimt_install_app "{candidate}" "{self.destination}"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "other")
        self.assertEqual(self.calls(), [])

    def test_failed_unregistration_before_move_preserves_the_existing_app(self):
        self.make_app(self.destination, "previous")
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        plugin = self.base / "pluginkit"
        plugin.write_text('#!/bin/sh\nexit 1\n')
        plugin.chmod(0o755)
        result = self.run_library(f'trap glimt_finish EXIT\nglimt_claim_scope install\n'
                                  f'glimt_install_app "{candidate}" "{self.destination}"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "previous")
        self.assertFalse((self.scopes / "install/rollback/Glimt.app").exists())

    def test_failed_rollback_unregistration_preserves_both_apps_and_keeps_the_scope_locked(self):
        self.make_app(self.destination, "previous")
        candidate = self.make_app(self.base / "build/Glimt.app", "candidate")
        plugin = self.base / "pluginkit"
        plugin.write_text(
            f'#!/bin/sh\n'
            f'echo "pluginkit $*" >> "{self.log}"\n'
            f'if [ "$1" = -r ]; then\n'
            f'  count=$(grep -c "pluginkit -r" "{self.log}")\n'
            f'  [ "$count" -lt 3 ] || exit 1\n'
            f'fi\n'
        )
        plugin.chmod(0o755)
        result = self.run_library(
            'trap glimt_finish EXIT\nglimt_claim_scope install\n'
            f'glimt_install_app "{candidate}" "{self.destination}"\n'
            'glimt_rollback_install\nglimt_release_scope'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "candidate")
        self.assertEqual((self.scopes / "install/rollback/Glimt.app/Contents/marker").read_text(), "previous")
        self.assertTrue((self.scopes / "install.lock").exists())


if __name__ == "__main__":
    unittest.main()
