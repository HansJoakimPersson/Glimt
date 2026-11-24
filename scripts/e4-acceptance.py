#!/usr/bin/env python3
"""E4 integration helpers: exact-settings-entitlement preflight, audited test install and restore.

Nothing here registers identifiers, downloads profiles or changes signing settings. Output never
contains team IDs or account names. Restore moves the test install into the run directory; it
never deletes an app bundle. Every bundle is unregistered from PlugInKit and LaunchServices before
it moves, so the run directory keeps evidence without keeping registrations.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = ("GlimtPreview.appex", "GlimtThumbnail.appex")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SETTINGS_EXCEPTION = "/Library/Application Support/Glimt/settings.json"
# The host needs the directory so its first save can create it; extensions stay limited to the file.
HOST_SETTINGS_EXCEPTION = "/Library/Application Support/Glimt/"
LOG_EXCEPTION = "/Library/Logs/Glimt/"
HOST_ENTITLEMENT = "com.apple.security.temporary-exception.files.home-relative-path.read-write"
EXTENSION_ENTITLEMENT = "com.apple.security.temporary-exception.files.home-relative-path.read-only"


# MARK: Preflight inputs

# MARK: Preflight decision

def expected_file_exceptions(settings_key):
    """Host: settings directory plus log directory read/write; extensions: settings file read-only plus logs."""
    if settings_key == HOST_ENTITLEMENT:
        return {HOST_ENTITLEMENT: sorted([HOST_SETTINGS_EXCEPTION, LOG_EXCEPTION])}
    return {EXTENSION_ENTITLEMENT: [SETTINGS_EXCEPTION], HOST_ENTITLEMENT: [LOG_EXCEPTION]}


def file_exceptions(data):
    return {key: sorted(data[key]) for key in (HOST_ENTITLEMENT, EXTENSION_ENTITLEMENT) if key in data}


def preflight(entitlement_directory=ROOT / "Glimt"):
    """Checks the three versioned entitlement plists without reading signing accounts or profiles."""
    targets = (("host", entitlement_directory / "App/GlimtHost.entitlements", HOST_ENTITLEMENT),
               ("preview", entitlement_directory / "PreviewExtension/GlimtPreview.entitlements", EXTENSION_ENTITLEMENT),
               ("thumbnail", entitlement_directory / "ThumbnailExtension/GlimtThumbnail.entitlements", EXTENSION_ENTITLEMENT))
    checks = []
    for name, path, expected_key in targets:
        data = plistlib.loads(path.read_bytes())
        sandbox_ok = data.get("com.apple.security.app-sandbox") is True
        no_group = "com.apple.security.application-groups" not in data
        exact_path = file_exceptions(data) == expected_file_exceptions(expected_key)
        ok = sandbox_ok and no_group and exact_path
        checks.append((f"{name} sandbox settings access", "OK" if ok else "MISSING",
                       "sandbox enabled, no App Group, exact settings and log exceptions"))
    return checks


def ready(checks):
    return all(state != "MISSING" for _, state, _ in checks)


# MARK: Install and restore

def running(target):
    return subprocess.run(["pgrep", "-f", str(target / "Contents/MacOS/")], capture_output=True).returncode == 0


def pluginkit(*arguments):
    command = os.environ.get("GLIMT_E4_PLUGINKIT", "pluginkit")
    return subprocess.run([command, *arguments], capture_output=True, text=True).returncode


def lsregister(*arguments):
    command = os.environ.get("GLIMT_E4_LSREGISTER", LSREGISTER)
    return subprocess.run([command, *arguments], capture_output=True, text=True).returncode


def unregister(target):
    for extension in EXTENSIONS:
        pluginkit("-r", str(target / "Contents/PlugIns" / extension))
    lsregister("-u", str(target))


def register(target):
    lsregister("-f", "-R", "-trusted", str(target))
    for extension in EXTENSIONS:
        pluginkit("-a", str(target / "Contents/PlugIns" / extension))


def install(app, run_dir, applications):
    app, run_dir = Path(app).resolve(), Path(run_dir).resolve()
    target = Path(applications) / "Glimt.app"
    state = run_dir / "e4-install.json"
    if state.exists():
        raise ValueError("A test install is already recorded; restore it first")
    if running(target):
        raise ValueError("Quit Glimt before installing")
    check = os.environ.get("GLIMT_E4_BUNDLE_CHECK")
    command = check.split() + [str(app)] if check else ["bash", str(ROOT / "scripts/rc-check-bundle.sh"), str(app)]
    if subprocess.run(command).returncode:
        raise ValueError("Signed bundle audit failed; nothing was installed")
    run_dir.mkdir(parents=True, exist_ok=True)
    backup = run_dir / "backup/Glimt.app"
    had_previous = target.exists()
    if had_previous:
        if backup.exists():
            raise ValueError("A backup already exists in this run directory")
        backup.parent.mkdir(parents=True)
        unregister(target)
        shutil.move(str(target), str(backup))
    state.write_text(json.dumps({"target": str(target), "backup": str(backup) if had_previous else None}, indent=2) + "\n")
    subprocess.run(["ditto", str(app), str(target)], check=True)
    register(target)
    print(f"E4 INSTALL: installed; previous app {'kept in run directory' if had_previous else 'absent'}")


def restore(run_dir):
    run_dir = Path(run_dir).resolve()
    state_path = run_dir / "e4-install.json"
    if not state_path.is_file():
        raise ValueError("No recorded test install in this run directory")
    state = json.loads(state_path.read_text())
    target = Path(state["target"])
    if running(target):
        raise ValueError("Quit Glimt before restoring")
    if target.exists():
        unregister(target)
        removed = run_dir / "removed"
        removed.mkdir(exist_ok=True)
        shutil.move(str(target), str(removed / f"Glimt-{len(list(removed.iterdir())) + 1}.app"))
    if state["backup"]:
        shutil.move(state["backup"], str(target))
        register(target)
    state_path.rename(run_dir / "e4-install.restored.json")
    print(f"E4 RESTORE: {'previous app restored' if state['backup'] else 'test install removed; no previous app'}")


# MARK: Command line

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("preflight")
    put = sub.add_parser("install")
    put.add_argument("app"); put.add_argument("--run-dir", required=True)
    put.add_argument("--applications", default="/Applications")
    put.add_argument("--allow-system-mutation", action="store_true", required=True,
                     help="required: installs a test app and changes LaunchServices/PlugInKit registrations")
    back = sub.add_parser("restore")
    back.add_argument("--run-dir", required=True)
    back.add_argument("--allow-system-mutation", action="store_true", required=True,
                      help="required: restores an app and changes LaunchServices/PlugInKit registrations")
    args = parser.parse_args()
    try:
        if args.command == "preflight":
            checks = preflight()
            for check, state, detail in checks:
                print(f"E4 PREFLIGHT {check}: {state} — {detail}")
            print("E4 PREFLIGHT: " + ("READY" if ready(checks) else "BLOCKED"))
            sys.exit(0 if ready(checks) else 1)
        elif args.command == "install":
            install(args.app, args.run_dir, args.applications)
        else:
            restore(args.run_dir)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"e4-acceptance: {error}\n")


if __name__ == "__main__":
    main()
