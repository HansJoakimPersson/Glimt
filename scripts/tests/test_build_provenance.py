from pathlib import Path
import importlib.util
import plistlib
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "write-build-provenance.py"
SPEC = importlib.util.spec_from_file_location("build_provenance", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BuildProvenanceTests(unittest.TestCase):
    def test_writes_commit_dirty_state_and_bundle_metadata_into_product(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            import subprocess

            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
            source_file = root / "source.txt"
            source_file.write_text("committed\n")
            (root / ".gitignore").write_text("Products/\n")
            subprocess.run(["git", "-C", str(root), "add", ".gitignore", "source.txt"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-m", "fixture"], check=True, capture_output=True)
            commit = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            bundle = root / "Products" / "Glimt.app"
            info = bundle / "Contents" / "Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.glimt.app",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
            }))

            MODULE.write_provenance(root, bundle, "Debug", "Apple Development")
            original_manifest_time = (bundle / "Contents/Resources/GlimtBuildProvenance.plist").stat().st_mtime_ns
            MODULE.write_provenance(root, bundle, "Debug", "Apple Development")
            self.assertEqual(
                (bundle / "Contents/Resources/GlimtBuildProvenance.plist").stat().st_mtime_ns,
                original_manifest_time,
            )
            manifest = plistlib.loads((bundle / "Contents/Resources/GlimtBuildProvenance.plist").read_bytes())
            self.assertEqual(manifest["GitCommit"], commit)
            self.assertTrue(manifest["WorkingTreeClean"])
            self.assertEqual(manifest["BuildConfiguration"], "Debug")
            self.assertEqual(manifest["CodeSignIdentity"], "Apple Development")
            self.assertEqual(manifest["BundleIdentifier"], "com.glimt.app")
            self.assertEqual(manifest["MarketingVersion"], "1.0.0")
            self.assertEqual(manifest["BuildVersion"], "1")

            source_file.write_text("changed\n")
            MODULE.write_provenance(root, bundle, "Release", "")
            manifest = plistlib.loads((bundle / "Contents/Resources/GlimtBuildProvenance.plist").read_bytes())
            self.assertFalse(manifest["WorkingTreeClean"])


if __name__ == "__main__":
    unittest.main()
