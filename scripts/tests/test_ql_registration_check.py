from pathlib import Path
import importlib.util
from unittest.mock import patch
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ql-registration-check.py"
SPEC = importlib.util.spec_from_file_location("ql_registration_check", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class QuickLookRegistrationCheckTests(unittest.TestCase):
    def setUp(self):
        self.path = Path("/tmp/Glimt candidate.app/Contents/PlugIns/GlimtPreview.appex")
        self.identifier = "com.glimt.app.preview"
        self.point = "com.apple.quicklook.preview"

    def listing(self, records):
        return "\n\n".join(records)

    def record(self, state, path, point=None, identifier=None):
        identifier = identifier or self.identifier
        return f"{state}    {identifier}(1.0.0)\n     Path = {path}\n     SDK = {point or self.point}"

    def check(self, output):
        return MODULE.check_registration(output, self.path, self.identifier, self.point)

    def test_accepts_exact_enabled_record_among_duplicates(self):
        output = self.listing([
            self.record("+", "/tmp/old copy/GlimtPreview.appex"),
            self.record("+", str(self.path)),
            self.record("-", "/tmp/stale/GlimtPreview.appex"),
        ])
        self.assertEqual(self.check(output), (True, "candidate-registered-enabled"))

    def test_rejects_other_identity_even_when_path_matches(self):
        output = self.record("+", str(self.path), identifier="com.other.preview")
        self.assertEqual(self.check(output)[1], "extension-not-registered")

    def test_rejects_candidate_on_wrong_extension_point(self):
        output = self.record("+", str(self.path), point="com.apple.quicklook.thumbnail")
        self.assertEqual(self.check(output)[1], "candidate-extension-point-mismatch")

    def test_rejects_disabled_candidate_even_if_another_copy_is_enabled(self):
        output = self.listing([
            self.record("+", "/tmp/other/GlimtPreview.appex"),
            self.record("-", str(self.path)),
        ])
        self.assertEqual(self.check(output)[1], "candidate-extension-disabled")

    def test_rejects_missing_candidate_path(self):
        self.assertEqual(self.check(self.record("+", "/tmp/other/GlimtPreview.appex"))[1], "candidate-path-not-registered")

    @patch.object(MODULE.subprocess, "run")
    def test_query_combines_stdout_and_stderr_when_exit_succeeds(self, run):
        run.return_value.returncode = 0
        run.return_value.stdout = self.record("+", str(self.path))
        run.return_value.stderr = "PlugInKit diagnostic\n"
        self.assertEqual(
            MODULE.inspect_registration(self.path, self.identifier, self.point),
            (True, "candidate-registered-enabled", 0),
        )

    @patch.object(MODULE.subprocess, "run")
    def test_query_does_not_treat_records_as_success_when_command_fails(self, run):
        run.return_value.returncode = 1
        run.return_value.stdout = self.record("+", str(self.path))
        run.return_value.stderr = "unavailable\n"
        ok, reason, status = MODULE.inspect_registration(self.path, self.identifier, self.point)
        self.assertFalse(ok)
        self.assertTrue(reason.startswith("pluginkit-command-failed exit=1"))
        self.assertEqual(status, 20)

    @patch.object(MODULE.subprocess, "run")
    def test_query_distinguishes_successful_empty_output_from_command_failure(self, run):
        run.return_value.returncode = 0
        run.return_value.stdout = ""
        run.return_value.stderr = ""
        self.assertEqual(
            MODULE.inspect_registration(self.path, self.identifier, self.point),
            (False, "extension-not-registered", 10),
        )


if __name__ == "__main__":
    unittest.main()
