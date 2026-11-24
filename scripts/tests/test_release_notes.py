from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release-notes.sh"


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        root = Path(self.work.name)
        self.config = root / "Version.xcconfig"
        self.config.write_text("MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\nGLIMT_PRERELEASE = beta.1\n")
        self.notes = root / "notes"
        self.notes.mkdir()
        self.dist = root / "dist"
        self.dist.mkdir()

    def run_script(self):
        environment = dict(os.environ, GLIMT_VERSION_CONFIG=str(self.config), GLIMT_RELEASE_NOTES_DIR=str(self.notes))
        return subprocess.run(["bash", str(SCRIPT), str(self.dist)], capture_output=True, text=True, env=environment)

    def test_appends_build_and_checksums_to_the_tag_notes(self):
        (self.notes / "v0.1.0-beta.1.md").write_text("## Highlights\n\nFirst beta.\n")
        (self.dist / "Glimt-0.1.0-beta.1-SHA256SUMS.txt").write_text("abc123  Glimt-0.1.0-beta.1-macOS.zip\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("## Highlights\n\nFirst beta.\n"))
        self.assertIn("Version 0.1.0 (build 1), SemVer `0.1.0-beta.1`", result.stdout)
        self.assertIn("## SHA-256 checksums\n\n```\nabc123  Glimt-0.1.0-beta.1-macOS.zip\n```", result.stdout)

    def test_missing_notes_file_fails(self):
        (self.dist / "Glimt-0.1.0-beta.1-SHA256SUMS.txt").write_text("abc123  Glimt-0.1.0-beta.1-macOS.zip\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v0.1.0-beta.1.md", result.stderr)

    def test_missing_checksums_fail(self):
        (self.notes / "v0.1.0-beta.1.md").write_text("Notes\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256SUMS", result.stderr)

    def test_every_published_release_tag_has_notes(self):
        tag = subprocess.run(["bash", str(ROOT / "scripts" / "version.sh"), "--get", "TAG"],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertTrue((ROOT / "release-notes" / f"{tag}.md").is_file(), tag)


if __name__ == "__main__":
    unittest.main()
