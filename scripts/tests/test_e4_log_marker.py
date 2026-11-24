import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("e4_log_marker", ROOT / "scripts/e4-log-marker.py")
marker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(marker)


TOKEN = "01234567-89ab-cdef-0123-456789abcdef"
PREVIEW_PATH = "/tmp/Glimt.app/Contents/PlugIns/GlimtPreview.appex/Contents/MacOS/GlimtPreview"
THUMBNAIL_PATH = "/tmp/Glimt.app/Contents/PlugIns/GlimtThumbnail.appex/Contents/MacOS/GlimtThumbnail"


class MarkerCorrelationTests(unittest.TestCase):
    def test_runtime_provenance_extracts_only_the_token_and_provider(self):
        expected = (
            f"GLIMT_PROVIDER_PROVENANCE_V1 token={TOKEN} provider=preview "
            "phase=request-received extensionID=com.glimt.app.preview "
            "appID=com.glimt.app appVersion=1.0.0 appBuild=1 "
            "extensionURL=file:///tmp/candidate/GlimtPreview.appex"
        )
        events = [
            {"eventMessage": expected},
            {"eventMessage": expected.replace(TOKEN, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")},
            {"eventMessage": expected.replace("provider=preview", "provider=thumbnail")},
        ]
        self.assertEqual(marker.runtime_provenance(events, TOKEN, "preview"), [expected])

    def test_observed_executable_requires_a_correlated_provider_marker(self):
        other_path = "/tmp/another copy/GlimtPreview.appex/Contents/MacOS/GlimtPreview"
        events = [
            {"eventMessage": f"FR005_PROVIDER_V1 token={TOKEN} provider=preview phase=display-prepared",
             "processImagePath": other_path},
            {"eventMessage": f"FR005_PROVIDER_V1 token={TOKEN} provider=thumbnail phase=reply-prepared",
             "processImagePath": "/tmp/GlimtThumbnail"},
            {"eventMessage": "unrelated user text", "processImagePath": "/tmp/ignored"},
        ]
        self.assertEqual(marker.observed_provider_executables(events, TOKEN, "preview"), [other_path])

    def test_preview_requires_correlated_begin_render_and_final_events_from_exact_bundle(self):
        events = [
            {"eventMessage": f"GLIMT_PREVIEW_BEGIN token={TOKEN}", "processImagePath": PREVIEW_PATH},
            {"eventMessage": "FR002_RENDER type=PlainText", "processImagePath": PREVIEW_PATH},
            {"eventMessage": f"FR005_PROVIDER_V1 token={TOKEN} provider=preview phase=display-prepared type=json ",
             "processImagePath": PREVIEW_PATH},
        ]

        result = marker.inspect_events(events, TOKEN, PREVIEW_PATH, "preview", "json")

        self.assertEqual(result[:6], (True, True, True, True, False, True))
        self.assertEqual(result[6], events[-1]["eventMessage"])

    def test_marker_from_another_provider_copy_is_not_accepted(self):
        events = [{"eventMessage": f"FR005_PROVIDER_V1 token={TOKEN} provider=thumbnail phase=reply-prepared type=yaml ",
                   "processImagePath": "/other/Glimt.app/Contents/PlugIns/GlimtThumbnail.appex/Contents/MacOS/GlimtThumbnail"}]

        result = marker.inspect_events(events, TOKEN, THUMBNAIL_PATH, "thumbnail", "yaml")

        self.assertEqual(result[:6], (False, False, False, False, True, False))
        self.assertEqual(result[6], "")

    def test_exact_provider_marker_reports_a_type_mismatch(self):
        events = [{"eventMessage": f"FR005_PROVIDER_V1 token={TOKEN} provider=thumbnail phase=reply-prepared type=xml ",
                   "processImagePath": THUMBNAIL_PATH}]

        result = marker.inspect_events(events, TOKEN, THUMBNAIL_PATH, "thumbnail", "yaml")

        self.assertTrue(result[3])
        self.assertFalse(result[5])
        self.assertEqual(result[6], events[0]["eventMessage"])


if __name__ == "__main__":
    unittest.main()
