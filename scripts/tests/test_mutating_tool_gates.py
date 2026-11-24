from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MutatingToolGateTests(unittest.TestCase):

    def test_e4_install_and_restore_require_explicit_mutation_flags(self):
        script = str(ROOT / "scripts/e4-acceptance.py")
        with tempfile.TemporaryDirectory() as temporary:
            install = subprocess.run(
                [sys.executable, script, "install", str(Path(temporary) / "candidate.app"),
                 "--run-dir", temporary, "--applications", temporary],
                capture_output=True, text=True,
            )
            restore = subprocess.run(
                [sys.executable, script, "restore", "--run-dir", temporary],
                capture_output=True, text=True,
            )
            self.assertEqual(install.returncode, 2)
            self.assertEqual(restore.returncode, 2)
            self.assertIn("--allow-system-mutation", install.stderr)
            self.assertIn("--allow-system-mutation", restore.stderr)

    def test_cleanup_script_has_no_global_registration_reset_or_automatic_escalation(self):
        script = (ROOT / "scripts/glimt-cleanup.sh").read_text()
        self.assertNotIn("lsregister -kill", script)
        self.assertFalse(any(line.strip().startswith("sudo ") for line in script.splitlines()))
        self.assertIn("--scan", script)
        self.assertIn("--keep", script)


if __name__ == "__main__":
    unittest.main()
