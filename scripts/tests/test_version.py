from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "version.sh"


def xcconfig(marketing="0.1.0", build="1", prerelease="beta.1"):
    return (
        "// test\n"
        f"MARKETING_VERSION = {marketing}\n"
        f"CURRENT_PROJECT_VERSION = {build}\n"
        f"GLIMT_PRERELEASE = {prerelease}\n"
    )


PUBLISHED = "\n".join([
    "v0.1.0-beta.1", "v0.1.0-beta.2", "v0.1.0-rc.1", "v0.1.0", "v0.1.1", "v0.2.0-alpha.1",
    "v0.10.0-beta.1", "not-a-release", "v0.3.0-preview.1",
]) + "\n"


class VersionScriptTests(unittest.TestCase):
    def run_script(self, config, *arguments, stdin=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Version.xcconfig"
            path.write_text(config)
            environment = dict(os.environ, GLIMT_VERSION_CONFIG=str(path))
            return subprocess.run(
                ["bash", str(SCRIPT), *arguments], capture_output=True, text=True, env=environment, input=stdin
            )

    def previous_tag(self, config, published=PUBLISHED):
        result = self.run_script(config, "--previous-tag", stdin=published)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def fields(self, config):
        result = self.run_script(config)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def test_beta_derives_semver_tag_title_and_artifact_names(self):
        self.assertEqual(self.fields(xcconfig()), {
            "MARKETING_VERSION": "0.1.0",
            "BUILD_NUMBER": "1",
            "PRERELEASE": "beta.1",
            "SEMVER": "0.1.0-beta.1",
            "TAG": "v0.1.0-beta.1",
            "DISPLAY_VERSION": "0.1.0 Beta 1",
            "RELEASE_TITLE": "Glimt 0.1.0 Beta 1",
            "IS_PRERELEASE": "true",
            "ARCHIVE_NAME": "Glimt-0.1.0-beta.1-macOS.zip",
            "CHECKSUMS_NAME": "Glimt-0.1.0-beta.1-SHA256SUMS.txt",
        })

    def test_alpha_and_release_candidate_labels(self):
        self.assertEqual(self.fields(xcconfig("0.2.0", "5", "alpha.2"))["DISPLAY_VERSION"], "0.2.0 Alpha 2")
        candidate = self.fields(xcconfig("1.0.0", "12", "rc.1"))
        self.assertEqual(candidate["SEMVER"], "1.0.0-rc.1")
        self.assertEqual(candidate["RELEASE_TITLE"], "Glimt 1.0.0 RC 1")
        self.assertEqual(candidate["IS_PRERELEASE"], "true")

    def test_stable_release_has_no_prerelease_suffix(self):
        fields = self.fields(xcconfig("1.0.0", "13", ""))
        self.assertEqual(fields["SEMVER"], "1.0.0")
        self.assertEqual(fields["TAG"], "v1.0.0")
        self.assertEqual(fields["RELEASE_TITLE"], "Glimt 1.0.0")
        self.assertEqual(fields["IS_PRERELEASE"], "false")
        self.assertEqual(fields["ARCHIVE_NAME"], "Glimt-1.0.0-macOS.zip")

    def test_single_field_lookup(self):
        result = self.run_script(xcconfig(), "--get", "TAG")
        self.assertEqual((result.returncode, result.stdout), (0, "v0.1.0-beta.1\n"))

    def test_tag_check_accepts_only_the_configured_tag(self):
        self.assertEqual(self.run_script(xcconfig(), "--check-tag", "v0.1.0-beta.1").returncode, 0)
        mismatch = self.run_script(xcconfig(), "--check-tag", "v0.1.0-beta.2")
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("does not match", mismatch.stderr)

    def test_prerelease_notes_start_at_the_closest_earlier_release_of_any_stage(self):
        self.assertEqual(self.previous_tag(xcconfig("0.1.0", "3", "beta.3")), "v0.1.0-beta.2\n")
        self.assertEqual(self.previous_tag(xcconfig("0.1.0", "5", "rc.2")), "v0.1.0-rc.1\n")
        self.assertEqual(self.previous_tag(xcconfig("0.2.0", "9", "alpha.2")), "v0.2.0-alpha.1\n")
        self.assertEqual(self.previous_tag(xcconfig("0.2.0", "9", "beta.1")), "v0.2.0-alpha.1\n")
        self.assertEqual(self.previous_tag(xcconfig("0.11.0", "20", "alpha.1")), "v0.10.0-beta.1\n")

    def test_stable_notes_start_at_the_previous_stable_release(self):
        self.assertEqual(self.previous_tag(xcconfig("0.2.0", "10", "")), "v0.1.1\n")
        self.assertEqual(self.previous_tag(xcconfig("0.1.1", "8", "")), "v0.1.0\n")

    def test_first_release_has_no_previous_tag(self):
        self.assertEqual(self.previous_tag(xcconfig()), "")
        self.assertEqual(self.previous_tag(xcconfig("0.1.0", "4", ""), "v0.1.0-beta.1\nv0.1.0-rc.1\n"), "")
        self.assertEqual(self.previous_tag(xcconfig(), ""), "")

    def test_rejects_invalid_versions(self):
        for config in (
            xcconfig(marketing="0.1"),
            xcconfig(marketing="01.0.0"),
            xcconfig(build="0"),
            xcconfig(build="1.2"),
            xcconfig(prerelease="beta"),
            xcconfig(prerelease="beta.0"),
            xcconfig(prerelease="preview.1"),
            "MARKETING_VERSION = 1.0.0\n",
        ):
            result = self.run_script(config)
            self.assertNotEqual(result.returncode, 0, config)
            self.assertIn("error:", result.stderr, config)

    def test_repository_version_is_valid(self):
        result = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SEMVER=", result.stdout)


if __name__ == "__main__":
    unittest.main()
