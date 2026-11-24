import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "glimt-cleanup.sh"
APP_ID = "com.glimt.app"
PREVIEW_ID = "com.glimt.app.preview"
THUMBNAIL_ID = "com.glimt.app.thumbnail"
PREVIEW_POINT = "com.apple.quicklook.preview"
THUMBNAIL_POINT = "com.apple.quicklook.thumbnail"


class CleanupFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glimt cleanup ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home = self.base / "home"
        self.home.mkdir()
        (self.home / ".Trash").mkdir()
        self.root = self.base / "candidate root with spaces"
        self.root.mkdir()
        self.keep = self.make_app(self.root / "Glimt Canonical.app")
        self.duplicate = self.make_app(self.root / "Glimt Duplicate Copy.app")
        self.state = self.base / "registries.json"
        self.log = self.base / "calls.jsonl"
        self.bin = self.base / "mock bin"
        self.bin.mkdir()
        self.write_mock("lsregister", self.lsregister_source())
        self.write_mock("pluginkit", self.pluginkit_source())
        self.write_mock("PlistBuddy", self.plistbuddy_source())
        self.write_mock("mdfind", self.mdfind_source())
        self.write_mock("qlmanage", self.log_only_source())
        self.write_mock("pgrep", "#!/bin/sh\nexit 1\n")
        self.set_state(
            [str(self.keep), str(self.duplicate)],
            [self.plugin(self.keep, "preview"), self.plugin(self.keep, "thumbnail"),
             self.plugin(self.duplicate, "preview"), self.plugin(self.duplicate, "thumbnail")],
        )
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home),
            "TMPDIR": str(self.base),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "GLIMT_CLEANUP_LSREGISTER": str(self.bin / "lsregister"),
            "GLIMT_CLEANUP_PLUGINKIT": str(self.bin / "pluginkit"),
            "GLIMT_CLEANUP_PLISTBUDDY": str(self.bin / "PlistBuddy"),
            "GLIMT_CLEANUP_MDFIND": str(self.bin / "mdfind"),
            "GLIMT_CLEANUP_QLMANAGE": str(self.bin / "qlmanage"),
            "GLIMT_CLEANUP_PGREP": str(self.bin / "pgrep"),
            "GLIMT_CLEANUP_TEST_MODE": "1",
            "GLIMT_TEST_REGISTRIES": str(self.state),
            "GLIMT_TEST_CALL_LOG": str(self.log),
        })

    def write_mock(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)
        return path

    def make_app(self, path, app_id=APP_ID, preview_id=PREVIEW_ID, thumbnail_id=THUMBNAIL_ID,
                 preview_point=PREVIEW_POINT, thumbnail_point=THUMBNAIL_POINT):
        path.mkdir(parents=True)
        self.write_plist(path / "Contents/Info.plist", {"CFBundleIdentifier": app_id,
                                                           "CFBundleShortVersionString": "9.1",
                                                           "CFBundleVersion": "901"})
        self.write_extension(path / "Contents/PlugIns/GlimtPreview.appex", preview_id, preview_point)
        self.write_extension(path / "Contents/PlugIns/GlimtThumbnail.appex", thumbnail_id, thumbnail_point)
        return path

    @staticmethod
    def write_plist(path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(contents))

    def write_extension(self, path, identifier, point):
        self.write_plist(path / "Contents/Info.plist", {
            "CFBundleIdentifier": identifier,
            "NSExtension": {"NSExtensionPointIdentifier": point},
        })

    @staticmethod
    def plugin(app, kind, enabled=True, identifier=None, point=None):
        preview = kind == "preview"
        return {
            "identifier": identifier or (PREVIEW_ID if preview else THUMBNAIL_ID),
            "path": str(app / "Contents/PlugIns" / ("GlimtPreview.appex" if preview else "GlimtThumbnail.appex")),
            "point": point or (PREVIEW_POINT if preview else THUMBNAIL_POINT),
            "enabled": enabled,
        }

    def set_state(self, launch_services, plugins):
        self.state.write_text(json.dumps({"launchServices": launch_services, "plugins": plugins}))

    def state_value(self):
        return json.loads(self.state.read_text())

    def call_log(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def run_script(self, *arguments, input_text=None, cwd=None, shell="bash"):
        return subprocess.run(
            [shell, str(SCRIPT), *map(str, arguments)], cwd=cwd or self.base, env=self.env,
            input=input_text, text=True, capture_output=True,
        )

    def lsregister_source(self):
        return r'''#!/usr/bin/env python3
import json, os, sys
state_path=os.environ["GLIMT_TEST_REGISTRIES"]
log_path=os.environ["GLIMT_TEST_CALL_LOG"]
args=sys.argv[1:]
state=json.load(open(state_path))
with open(log_path,"a") as log: log.write(json.dumps(["lsregister",*args])+"\n")
if args == ["-dump"]:
    for path in state["launchServices"]:
        print("-"*80); print("bundle id: Glimt (0x1)")
        print("identifier: com.glimt.app"); print("path: %s (0x1)" % path)
elif len(args)==2 and args[0]=="-u":
    if os.environ.get("GLIMT_TEST_FAIL_LS_UNREGISTER")==args[1]: sys.exit(9)
    state["launchServices"]=[p for p in state["launchServices"] if p!=args[1]]
    json.dump(state,open(state_path,"w"))
elif len(args)==2 and args[0]=="-f":
    if args[1] not in state["launchServices"]: state["launchServices"].append(args[1])
    json.dump(state,open(state_path,"w"))
else: sys.exit(2)
'''

    def pluginkit_source(self):
        return r'''#!/usr/bin/env python3
import json, os, sys
state_path=os.environ["GLIMT_TEST_REGISTRIES"]
log_path=os.environ["GLIMT_TEST_CALL_LOG"]
args=sys.argv[1:]
state=json.load(open(state_path))
with open(log_path,"a") as log: log.write(json.dumps(["pluginkit",*args])+"\n")
if "-m" in args:
    identifier=args[args.index("-i")+1]
    for item in state["plugins"]:
        if item["identifier"]==identifier:
            print("%s %s(9.1)" % ("+" if item["enabled"] else "-", identifier))
            print("    Path = %s" % item["path"])
            print("    Identifier = %s" % identifier)
            print("    SDK = %s" % item["point"])
elif len(args)==2 and args[0]=="-r":
    if os.environ.get("GLIMT_TEST_FAIL_PLUGIN_UNREGISTER")==args[1]: sys.exit(9)
    state["plugins"]=[p for p in state["plugins"] if p["path"]!=args[1]]
    json.dump(state,open(state_path,"w"))
    if os.environ.get("GLIMT_TEST_FAIL_PLUGIN_UNREGISTER_AFTER_REMOVE")==args[1]: sys.exit(9)
elif len(args)==2 and args[0]=="-a":
    path=args[1]
    if path.endswith("GlimtPreview.appex"):
        identifier="com.glimt.app.preview"; point="com.apple.quicklook.preview"
    else:
        identifier="com.glimt.app.thumbnail"; point="com.apple.quicklook.thumbnail"
    if not any(p["path"]==path for p in state["plugins"]):
        state["plugins"].append({"identifier":identifier,"point":point,"path":path,"enabled":True})
    json.dump(state,open(state_path,"w"))
else: sys.exit(2)
'''

    @staticmethod
    def plistbuddy_source():
        return r'''#!/usr/bin/env python3
import os, plistlib, sys
command, path=sys.argv[2], sys.argv[3]
denied=os.environ.get("GLIMT_TEST_DENY_PLIST_PREFIX","")
if denied and path.startswith(denied): sys.exit(1)
try: value=plistlib.loads(open(path,"rb").read())
except Exception: sys.exit(1)
for key in command.removeprefix("Print :").split(":"):
    if isinstance(value,dict) and key in value: value=value[key]
    else: sys.exit(1)
if isinstance(value,(str,int,float)): print(value)
else: sys.exit(1)
'''

    @staticmethod
    def mdfind_source():
        return r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["GLIMT_TEST_CALL_LOG"],"a") as log:
    log.write(json.dumps(["mdfind",*sys.argv[1:]])+"\n")
path=os.environ.get("GLIMT_TEST_MDFIND_OUTPUT","")
if path and os.path.exists(path): print(open(path).read(),end="")
'''

    @staticmethod
    def log_only_source():
        return r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["GLIMT_TEST_CALL_LOG"],"a") as log:
    log.write(json.dumps([os.path.basename(sys.argv[0]),*sys.argv[1:]])+"\n")
'''


class GlimtCleanupTests(CleanupFixture):
    def test_scan_includes_spotlight_candidates_without_trusting_unrelated_ids(self):
        indexed = self.make_app(self.base / "Indexed Copy with spaces.app")
        output = self.base / "mdfind output.txt"
        output.write_text(str(indexed) + "\n")
        self.env["GLIMT_TEST_MDFIND_OUTPUT"] = str(output)

        result = self.run_script("--scan", "--root", self.root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(indexed), result.stdout)
        self.assertTrue(any(call[0] == "mdfind" for call in self.call_log()))
        self.assertEqual(self.state_value()["launchServices"], [str(self.keep), str(self.duplicate)])

    def test_scan_without_roots_runs_on_the_macos_system_bash(self):
        # /bin/bash 3.2 treats an empty array as unbound under `set -u`; the shebang uses it.
        result = self.run_script("--scan", shell="/bin/bash")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unbound variable", result.stderr)

    def test_default_scan_is_read_only_and_handles_spaces_and_duplicate_records(self):
        state = self.state_value()
        state["launchServices"].append(str(self.duplicate))
        state["plugins"].append(self.plugin(self.duplicate, "preview"))
        self.state.write_text(json.dumps(state))
        result = self.run_script("--root", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.keep), result.stdout)
        self.assertIn(str(self.duplicate), result.stdout)
        self.assertIn("SCAN ONLY", result.stdout)
        self.assertEqual(self.state_value(), state)
        self.assertFalse(any(call[0] in {"pluginkit", "lsregister"} and call[1] in {"-r", "-u", "-f", "-a"}
                             for call in self.call_log()))
        self.assertFalse(any(call[0] == "qlmanage" for call in self.call_log()))

    def test_clean_unregisters_only_verified_noncanonical_glimt_records(self):
        other_app = self.root / "Not Glimt.app"
        self.make_app(other_app, app_id="com.example.other")
        state = self.state_value()
        state["launchServices"].append(str(other_app))
        state["plugins"].append({"identifier": "com.example.other.preview", "path": str(other_app),
                                  "point": PREVIEW_POINT, "enabled": True})
        self.state.write_text(json.dumps(state))
        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        final = self.state_value()
        self.assertEqual(final["launchServices"], [str(self.keep), str(other_app)])
        self.assertEqual([p["path"] for p in final["plugins"]], [
            str(self.keep / "Contents/PlugIns/GlimtPreview.appex"),
            str(self.keep / "Contents/PlugIns/GlimtThumbnail.appex"), str(other_app)])
        self.assertIn(str(self.keep), result.stdout)
        self.assertIn(str(self.duplicate), result.stdout)
        self.assertTrue(self.duplicate.exists(), "--clean unregisters only; it never moves or deletes app files")

    def test_clean_all_unregisters_every_verified_glimt_record_including_applications_copy(self):
        other_app = self.root / "Not Glimt.app"
        self.make_app(other_app, app_id="com.example.other")
        state = self.state_value()
        state["launchServices"].append(str(other_app))
        self.state.write_text(json.dumps(state))
        result = self.run_script("--clean", "--all", "--root", self.root, shell="/bin/bash")
        self.assertEqual(result.returncode, 0, result.stderr)
        final = self.state_value()
        self.assertEqual(final["launchServices"], [str(other_app)])
        self.assertEqual(final["plugins"], [])
        self.assertTrue(self.keep.exists() and self.duplicate.exists(), "--all unregisters only; it never deletes")

    def test_clean_unregisters_registered_bundle_shell_without_info_plist(self):
        # macOS purges old /tmp files but leaves folders, so a registered build can lose its plists.
        shell = self.make_app(self.base / "purged tmp/Glimt.app")
        for plist in shell.rglob("Info.plist"):
            plist.unlink()
        state = self.state_value()
        state["launchServices"].append(str(shell))
        state["plugins"].extend([self.plugin(shell, "preview"), self.plugin(shell, "thumbnail")])
        self.state.write_text(json.dumps(state))
        result = self.run_script("--clean", "--all", shell="/bin/bash")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(str(shell), self.state_value()["launchServices"])
        self.assertFalse(any(str(shell) in p["path"] for p in self.state_value()["plugins"]))
        self.assertTrue(shell.exists(), "an emptied bundle is unregistered, never deleted")

    def test_all_is_only_valid_with_clean_and_without_keep(self):
        both = self.run_script("--clean", "--all", "--keep", self.keep)
        trash = self.run_script("--trash", "--all", input_text="TRASH\n")
        scan = self.run_script("--scan", "--all")
        for result in (both, trash, scan):
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.state_value()["launchServices"], [str(self.keep), str(self.duplicate)])

    def test_clean_removes_stale_exact_plugin_and_launchservices_records(self):
        stale_app = self.root / "Glimt Removed Copy.app"
        stale_preview = str(stale_app / "Contents/PlugIns/GlimtPreview.appex")
        state = self.state_value()
        state["launchServices"].append(str(stale_app))
        state["plugins"].append({"identifier": PREVIEW_ID, "path": stale_preview,
                                  "point": PREVIEW_POINT, "enabled": False})
        self.state.write_text(json.dumps(state))
        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(str(stale_app), self.state_value()["launchServices"])
        self.assertFalse(any(p["path"] == stale_preview for p in self.state_value()["plugins"]))
        self.assertFalse(stale_app.exists())

    def test_mutating_mode_requires_existing_explicit_keep_bundle(self):
        absent = self.root / "missing Glimt.app"
        without_keep = self.run_script("--clean")
        missing = self.run_script("--clean", "--keep", absent)
        mismatch = self.make_app(self.root / "Other.app", app_id="com.example.other")
        wrong_id = self.run_script("--clean", "--keep", mismatch)
        bad_extension = self.make_app(self.root / "Glimt Bad Extension.app", preview_id="com.example.preview")
        wrong_extension = self.run_script("--clean", "--keep", bad_extension)
        self.assertNotEqual(without_keep.returncode, 0)
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotEqual(wrong_id.returncode, 0)
        self.assertNotEqual(wrong_extension.returncode, 0)
        self.assertEqual(self.state_value()["launchServices"], [str(self.keep), str(self.duplicate)])

    def test_symlinked_keep_or_candidate_is_never_followed_or_unregistered(self):
        link = self.root / "Glimt Symlink.app"
        link.symlink_to(self.duplicate, target_is_directory=True)
        state = self.state_value()
        state["launchServices"].append(str(link))
        state["plugins"].extend([self.plugin(link, "preview"), self.plugin(link, "thumbnail")])
        self.state.write_text(json.dumps(state))
        symlink_keep_result = self.run_script("--clean", "--keep", link, "--root", self.root)
        self.assertNotEqual(symlink_keep_result.returncode, 0, symlink_keep_result.stderr)
        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(link), self.state_value()["launchServices"])
        self.assertTrue(any("SYMLINK/SKIP" in line for line in result.stdout.splitlines()))

    def test_inaccessible_bundle_metadata_is_not_an_actionable_identity(self):
        self.env["GLIMT_TEST_DENY_PLIST_PREFIX"] = str(self.duplicate)
        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("unverified identity", result.stdout)
        self.assertIn(str(self.duplicate), self.state_value()["launchServices"])
        self.assertFalse(any(call[0] == "lsregister" and call[1] == "-u" for call in self.call_log()))

    def test_mismatched_extension_bundle_identity_is_not_unregistered(self):
        self.write_extension(self.duplicate / "Contents/PlugIns/GlimtPreview.appex", "com.example.foreign", PREVIEW_POINT)
        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("changed/unverified identity", result.stdout)
        self.assertIn(self.plugin(self.duplicate, "preview")["path"],
                      [p["path"] for p in self.state_value()["plugins"]])

    def test_failed_unregistration_returns_failure_and_keeps_failed_record(self):
        failed_path = self.plugin(self.duplicate, "preview")["path"]
        self.env["GLIMT_TEST_FAIL_PLUGIN_UNREGISTER"] = failed_path
        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(failed_path, [p["path"] for p in self.state_value()["plugins"]])

    def test_nonzero_pluginkit_exit_is_warning_only_when_exact_record_remains(self):
        resolved_path = self.plugin(self.duplicate, "preview")["path"]
        self.env["GLIMT_TEST_FAIL_PLUGIN_UNREGISTER_AFTER_REMOVE"] = resolved_path

        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(resolved_path, [p["path"] for p in self.state_value()["plugins"]])
        self.assertIn("exact Glimt record is absent", result.stdout)

    def test_failed_launchservices_unregister_returns_failure_and_keeps_exact_record(self):
        self.env["GLIMT_TEST_FAIL_LS_UNREGISTER"] = str(self.duplicate)

        result = self.run_script("--clean", "--keep", self.keep, "--root", self.root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.duplicate), self.state_value()["launchServices"])

    def test_trash_moves_only_directly_eligible_verified_copy_and_respects_keep(self):
        downloads = self.home / "Downloads"
        downloads.mkdir()
        keep = self.make_app(downloads / "Glimt Canonical.app")
        duplicate = self.make_app(downloads / "Glimt Duplicate.app")
        backup = self.make_app(downloads / "Backups" / "Glimt Backup.app")
        development = self.make_app(self.base / "repo/.worktrees/dev/Build/Glimt.app")
        self.set_state([str(keep), str(duplicate), str(backup), str(development)],
                       [self.plugin(keep, "preview"), self.plugin(keep, "thumbnail"),
                        self.plugin(duplicate, "preview"), self.plugin(duplicate, "thumbnail")])
        result = self.run_script("--trash", "--keep", keep, "--root", self.base, input_text="TRASH\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(keep.exists())
        self.assertFalse(duplicate.exists())
        self.assertTrue(backup.exists())
        self.assertTrue(development.exists())
        trashed = list((self.home / ".Trash").glob("Glimt Duplicate-glimt-cleanup-*.app"))
        self.assertEqual(len(trashed), 1)
        self.assertTrue(any("MOVED TO TRASH" in line for line in result.stdout.splitlines()))

    def test_user_selected_canonical_app_in_downloads_is_preserved(self):
        downloads = self.home / "Downloads"
        downloads.mkdir()
        keep = self.make_app(downloads / "Glimt Home.app")
        self.set_state([str(keep)], [self.plugin(keep, "preview"), self.plugin(keep, "thumbnail")])
        result = self.run_script("--trash", "--keep", keep, "--root", downloads, input_text="TRASH\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(keep.exists())
        self.assertEqual(list((self.home / ".Trash").iterdir()), [])

    def test_trash_preserves_duplicate_copies_in_separate_backup_directories(self):
        downloads = self.home / "Downloads"
        downloads.mkdir()
        keep = self.make_app(downloads / "Glimt Canonical.app")
        backups = [
            self.make_app(downloads / "Backups 1" / "Glimt Backup.app"),
            self.make_app(downloads / "Backups 2" / "Glimt Backup.app"),
        ]
        self.set_state(
            [str(keep), *(str(backup) for backup in backups)],
            [self.plugin(keep, "preview"), self.plugin(keep, "thumbnail")],
        )

        result = self.run_script("--trash", "--keep", keep, "--root", downloads, input_text="TRASH\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(keep.exists())
        self.assertTrue(all(backup.exists() for backup in backups))
        self.assertEqual(list((self.home / ".Trash").glob("*.app")), [])

    def test_failed_scan_of_explicit_inaccessible_root_is_reported(self):
        inaccessible = self.base / "unreadable root"
        inaccessible.mkdir()
        inaccessible.chmod(0)
        try:
            result = self.run_script("--root", inaccessible)
        finally:
            inaccessible.chmod(0o700)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not readable", result.stdout.lower())


if __name__ == "__main__":
    unittest.main()
