import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "registration-audit.py"
spec = importlib.util.spec_from_file_location("registration_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

SEPARATOR = "-" * 80


def ls_block(kind, identifier, path, missing=False):
    lines = [f"{kind}:                  {identifier if kind == 'plugin id' else 'Glimt'} (0x1)"]
    if missing:
        lines.append("Bundle node not found on disk: Error Domain=NSOSStatusErrorDomain Code=-43")
    lines += [f"path:                       {path} (0x2)", f"identifier:                 {identifier}"]
    return "\n".join(lines)


def ls_dump(*blocks):
    return f"\n{SEPARATOR}\n".join(["Checking data integrity......done.", *blocks, "bundle id: Other (0x9)\npath: /Applications/Other.app (0x3)\nidentifier: com.example.other"]) + "\n"


BTM_DUMP = """
 #1:
                 UUID: A
                 Name: Glimt
                 Type: app (0x2)
           Identifier: 2.Glimt
                  URL: /Applications/Glimt.app

 #2:
                 UUID: B
                 Name: GlimtPreview.appex
                 Type: quicklook (0x800)
           Identifier: 2048.GlimtPreview
                  URL: Contents/PlugIns/GlimtPreview.appex
    Parent Identifier: 2.Glimt

 #3:
                 UUID: C
                 Name: Other
                 Type: app (0x2)
           Identifier: 2.Other
                  URL: /Applications/Other.app
"""

PLUGINKIT_LISTING = """
+    com.glimt.app.preview(1.0)
            Path = /Applications/Glimt.app/Contents/PlugIns/GlimtPreview.appex
             SDK = com.apple.quicklook.preview
"""


def snapshot(ls=(), plugins=(), btm=None, hidden=(), work=()):
    return {"launchServices": [dict(r) for r in ls], "pluginKit": [dict(p) for p in plugins],
            "backgroundTasks": btm if btm is not None else {"status": "ok", "items": []},
            "applicationsHidden": list(hidden), "workDirectories": list(work)}


APP = "/Applications/Glimt.app"
PREVIEW = APP + "/Contents/PlugIns/GlimtPreview.appex"


class ParseTests(unittest.TestCase):
    def test_launch_services_dump_keeps_only_glimt_records_with_path_and_existence(self):
        text = ls_dump(ls_block("bundle id", "com.glimt.app", "/tmp/a/Glimt.app", missing=True),
                       ls_block("plugin id", "com.glimt.app.preview", "/tmp/a/Glimt.app/Contents/PlugIns/GlimtPreview.appex"),
                       ls_block("bundle id", "com.glimt.app.probe", "/x/Probe.app"))
        records = audit.parse_launch_services(text)
        self.assertEqual([(r["kind"], r["identifier"], r["path"]) for r in records], [
            ("bundle", "com.glimt.app", "/tmp/a/Glimt.app"),
            ("plugin", "com.glimt.app.preview", "/tmp/a/Glimt.app/Contents/PlugIns/GlimtPreview.appex"),
            ("bundle", "com.glimt.app.probe", "/x/Probe.app")])
        self.assertTrue(records[0]["missingOnDisk"])
        self.assertFalse(records[1]["missingOnDisk"])

    def test_background_task_dump_keeps_glimt_items_and_their_children(self):
        items = audit.parse_background_tasks(BTM_DUMP)
        self.assertEqual([(i["identifier"], i["type"]) for i in items],
                         [("2.Glimt", "app"), ("2048.GlimtPreview", "quicklook")])
        self.assertEqual(items[0]["url"], APP)

    def test_pluginkit_listing_reads_enabled_state_and_paths(self):
        plugins = audit.parse_pluginkit(PLUGINKIT_LISTING, "com.glimt.app.preview")
        self.assertEqual(plugins, [{"identifier": "com.glimt.app.preview", "path": PREVIEW, "enabled": True}])

    def test_paths_under_private_alias_compare_equal(self):
        self.assertEqual(audit.normal("/private/var/folders/x/Glimt.app"), "/var/folders/x/Glimt.app")
        self.assertEqual(audit.normal("/private/tmp/a/"), "/tmp/a")


class CompareTests(unittest.TestCase):
    def test_unchanged_state_passes(self):
        before = snapshot(ls=[{"kind": "bundle", "identifier": "com.glimt.app", "path": "/old/Glimt.app"}])
        result = audit.compare(before, before, allowed=[APP])
        self.assertEqual(result["verdict"], "PASS", result)

    def test_new_registration_from_temporary_build_fails(self):
        before = snapshot()
        after = snapshot(ls=[{"kind": "bundle", "identifier": "com.glimt.app", "path": "/var/folders/T/glimt-x/Glimt.app"}])
        result = audit.compare(before, after, allowed=[APP])
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(result["newLaunchServices"], ["/var/folders/T/glimt-x/Glimt.app"])

    def test_allowed_install_and_its_extensions_may_appear_once(self):
        after = snapshot(ls=[{"kind": "bundle", "identifier": "com.glimt.app", "path": APP},
                             {"kind": "plugin", "identifier": "com.glimt.app.preview", "path": PREVIEW}])
        self.assertEqual(audit.compare(snapshot(), after, allowed=[APP])["verdict"], "PASS")
        doubled = snapshot(ls=after["launchServices"] * 2)
        result = audit.compare(snapshot(), doubled, allowed=[APP])
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn(APP, result["duplicateLaunchServices"])

    def test_hidden_application_backup_and_leftover_work_directory_fail(self):
        after = snapshot(hidden=["/Applications/.Glimt.app.backup.1"], work=["/var/folders/T/glimt-ql-smoke.1"])
        result = audit.compare(snapshot(), after, allowed=[APP])
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(result["newApplicationsHidden"], ["/Applications/.Glimt.app.backup.1"])
        self.assertEqual(result["newWorkDirectories"], ["/var/folders/T/glimt-ql-smoke.1"])

    def test_new_pluginkit_path_outside_install_fails(self):
        after = snapshot(plugins=[{"identifier": "com.glimt.app.preview", "path": "/tmp/b/GlimtPreview.appex", "enabled": False}])
        self.assertEqual(audit.compare(snapshot(), after, allowed=[APP])["verdict"], "FAIL")

    def test_background_task_growth_fails_but_in_place_update_passes(self):
        one = {"status": "ok", "items": [{"identifier": "2.Glimt", "type": "app", "url": "/a/Glimt.app"}]}
        moved = {"status": "ok", "items": [{"identifier": "2.Glimt", "type": "app", "url": APP}]}
        two = {"status": "ok", "items": one["items"] + moved["items"]}
        self.assertEqual(audit.compare(snapshot(btm=one), snapshot(btm=moved), allowed=[APP])["verdict"], "PASS")
        self.assertEqual(audit.compare(snapshot(btm=one), snapshot(btm=two), allowed=[APP])["verdict"], "FAIL")

    def test_new_background_task_identity_is_allowed_only_for_the_intended_install(self):
        old = {"identifier": "2.Glimt", "type": "app", "url": "/old/Glimt.app", "parent": None}
        def items(app_url):
            return {"status": "ok", "items": [old,
                    {"identifier": "2.com.glimt.app", "type": "app", "url": app_url, "parent": None},
                    {"identifier": "2048.com.glimt.app.preview", "type": "quicklook",
                     "url": "Contents/PlugIns/GlimtPreview.appex", "parent": "2.com.glimt.app"}]}
        before = snapshot(btm={"status": "ok", "items": [old]})
        result = audit.compare(before, snapshot(btm=items(APP)), allowed=[APP])
        self.assertEqual(result["verdict"], "PASS", result)
        self.assertEqual(result["allowedBackgroundTasks"], ["2.com.glimt.app", "2048.com.glimt.app.preview"])
        result = audit.compare(before, snapshot(btm=items("/var/folders/T/glimt-x/Glimt.app")), allowed=[APP])
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(result["newBackgroundTasks"], ["2.com.glimt.app", "2048.com.glimt.app.preview"])

    def test_background_task_residue_of_a_removed_install_is_reported_separately(self):
        residue = {"status": "ok", "items": [{"identifier": "2.com.glimt.app", "type": "app", "url": APP, "parent": None}]}
        result = audit.compare(snapshot(), snapshot(btm=residue), allowed=[], residual=[APP])
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["residualBackgroundTasks"], ["2.com.glimt.app"])

    def test_skipped_background_tasks_defer_to_the_final_check(self):
        result = audit.compare(snapshot(), snapshot(btm={"status": "skipped", "items": []}), allowed=[APP])
        self.assertEqual(result["verdict"], "PASS")
        self.assertFalse(result["backgroundTasksChecked"])

    def test_unreadable_background_tasks_is_not_verified_rather_than_pass(self):
        after = snapshot(btm={"status": "unavailable", "items": []})
        result = audit.compare(snapshot(), after, allowed=[APP])
        self.assertEqual(result["verdict"], "NOT_VERIFIED")

    def test_expected_install_requires_registration_and_enabled_extensions(self):
        installed = snapshot(ls=[{"kind": "bundle", "identifier": "com.glimt.app", "path": APP}],
                             plugins=[{"identifier": "com.glimt.app.preview", "path": PREVIEW, "enabled": True},
                                      {"identifier": "com.glimt.app.thumbnail", "path": APP + "/Contents/PlugIns/GlimtThumbnail.appex", "enabled": True}])
        self.assertEqual(audit.compare(snapshot(), installed, allowed=[APP], expect_installed=APP)["verdict"], "PASS")
        disabled = json.loads(json.dumps(installed)); disabled["pluginKit"][1]["enabled"] = False
        result = audit.compare(snapshot(), disabled, allowed=[APP], expect_installed=APP)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("com.glimt.app.thumbnail", " ".join(result["installProblems"]))


class OrphanTests(unittest.TestCase):
    def test_orphans_are_glimt_records_whose_path_is_gone(self):
        with tempfile.TemporaryDirectory() as temporary:
            present = Path(temporary) / "Glimt.app"; present.mkdir()
            records = [{"kind": "bundle", "identifier": "com.glimt.app", "path": str(present)},
                       {"kind": "bundle", "identifier": "com.glimt.app", "path": temporary + "/gone/Glimt.app"},
                       {"kind": "plugin", "identifier": "com.glimt.app.preview", "path": temporary + "/gone/Glimt.app/Contents/PlugIns/GlimtPreview.appex"}]
            self.assertEqual(audit.orphan_bundles(records), [temporary + "/gone/Glimt.app"])

    def test_orphan_command_is_read_only_and_rejects_unregister_option(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            log = base / "lsregister.log"
            stub = base / "lsregister"
            present = base / "Glimt.app"; present.mkdir()
            stub.write_text(f'#!/bin/sh\nif [ "$1" = -dump ]; then cat "{base}/dump"; else echo "$@" >> "{log}"; fi\n')
            stub.chmod(0o755)
            (base / "dump").write_text(ls_dump(ls_block("bundle id", "com.glimt.app", str(present)),
                                               ls_block("bundle id", "com.glimt.app", str(base / "gone/Glimt.app"), missing=True)))
            env = {"GLIMT_LSREGISTER": str(stub), "PATH": "/usr/bin:/bin"}
            listing = subprocess.run([sys.executable, str(SCRIPT), "orphans"], capture_output=True, text=True, env=env)
            self.assertEqual(listing.returncode, 0, listing.stderr)
            self.assertFalse(log.exists(), "listing must not unregister anything")
            cleanup = subprocess.run([sys.executable, str(SCRIPT), "orphans", "--unregister"], capture_output=True, text=True, env=env)
            self.assertNotEqual(cleanup.returncode, 0)
            self.assertFalse(log.exists(), "the audit must not expose a mutating option")


if __name__ == "__main__":
    unittest.main()
