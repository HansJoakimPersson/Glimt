from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LINT = ROOT / "scripts" / "lint.sh"
PROJECT = ROOT / "Glimt.xcodeproj" / "project.pbxproj"


def run_swift_lint(source):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "Sample.swift"
        path.write_text(source)
        return subprocess.run(["bash", str(LINT), "--swift", temporary], capture_output=True, text=True)


class SwiftFormatRuleTests(unittest.TestCase):
    # The filter drops swift-format's layout findings; these guard against it dropping everything.
    def test_force_unwrap_is_reported_as_an_xcode_error(self):
        result = run_swift_lint("func f(_ value: Int?) -> Int {\n    return value!\n}\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"Sample\.swift:2:\d+: error: \[NeverForceUnwrap\]")

    def test_force_try_is_reported(self):
        result = run_swift_lint("func f() throws -> Int { 1 }\nfunc g() -> Int {\n    return try! f()\n}\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[NeverUseForceTry]", result.stdout)

    def test_layout_that_differs_from_swift_format_does_not_fail(self):
        result = run_swift_lint("func f(_ value: Int?) -> Int {\n  return value ?? 0\n}\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("LINT PASS swift-format", result.stdout)


class LintWiringTests(unittest.TestCase):
    def test_app_target_runs_the_swift_lint_build_phase(self):
        content = PROJECT.read_text()
        self.assertIn("B10000000000000000000040 /* Lint */,", content)
        self.assertIn('shellScript = "\\"${SRCROOT}/scripts/lint.sh\\" --swift\\n";', content)

    def test_release_treats_swift_warnings_as_errors(self):
        content = PROJECT.read_text()
        release = content.split("A0000000000000000000001B /* Release */ = {", 1)[1].split("};", 1)[0]
        self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;", release)

    def test_safe_gate_runs_the_full_lint(self):
        content = (ROOT / "scripts" / "ql-safe-smoke.sh").read_text()
        self.assertIn('bash "$ROOT/scripts/lint.sh" --sanitize', content)


if __name__ == "__main__":
    unittest.main()
