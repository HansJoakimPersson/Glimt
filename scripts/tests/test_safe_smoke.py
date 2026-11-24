from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ql-safe-smoke.sh"
ROOT = SCRIPT.parent.parent


class SafeSmokeTests(unittest.TestCase):
    def test_safe_smoke_does_not_install_or_register_extensions(self):
        content = SCRIPT.read_text()
        for forbidden in ("/Applications", "pluginkit", "lsregister", "qlmanage -p", "xattr -w", "xattr -d"):
            self.assertNotIn(forbidden, content)

    def test_safe_smoke_executes_tests_instead_of_only_compiling_them(self):
        content = SCRIPT.read_text()
        self.assertIn("swift test --package-path", content)
        self.assertIn("-resultBundlePath", content)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", content)
        self.assertRegex(content, r"\n\s+test >")
        self.assertNotIn("build-for-testing", content)

    def test_safe_smoke_audits_the_release_bundle(self):
        content = SCRIPT.read_text()
        self.assertIn('rc-check-bundle.sh" --unsigned "$APP"', content)
        self.assertLess(content.index('APP="$DERIVED_DATA/Build/Products/Release/Glimt.app"'), content.index("rc-check-bundle.sh"))

    def test_safe_smoke_builds_in_a_released_scope_instead_of_a_unique_temporary_folder(self):
        content = SCRIPT.read_text()
        self.assertNotIn("mktemp", content)
        self.assertIn('source "$ROOT/scripts/lib/bundle-lifecycle.sh"', content)
        self.assertIn("glimt_claim_scope safe-smoke", content)
        self.assertIn('DERIVED_DATA="$WORK_DIR/DerivedData"', content)
        self.assertIn("trap glimt_finish EXIT", content)
        self.assertLess(content.index("trap glimt_finish EXIT"), content.index("glimt_claim_scope"))

    def test_safe_smoke_replaces_the_previous_runs_result_bundles(self):
        content = SCRIPT.read_text()
        removal = content.index('rm -rf "$WORK_DIR/Glimt-Debug.xcresult" "$WORK_DIR/Glimt-Release.xcresult"')
        self.assertLess(removal, content.index('-resultBundlePath "$WORK_DIR/Glimt-Debug.xcresult"'))

    def test_quick_look_api_probes_require_an_existing_bundle_and_do_not_install_or_register(self):
        for name in ("ql-smoke.sh", "ql-thumbnail-smoke.sh"):
            content = (ROOT / "scripts" / name).read_text()
            self.assertIn('"$1" != "--app-bundle"', content, name)
            self.assertIn("never builds, installs, registers", content, name)
            for forbidden in (
                "/Applications", "xcodebuild", "CODE_SIGNING_ALLOWED", "pluginkit -a",
                "pluginkit -r", "pluginkit -e", "lsregister -f", "lsregister -u",
                "ditto", "STAGING_APP=", "BACKUP_APP=",
            ):
                self.assertNotIn(forbidden, content, f"{name}: {forbidden}")

if __name__ == "__main__":
    unittest.main()
