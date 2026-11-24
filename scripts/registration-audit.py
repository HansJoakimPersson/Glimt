#!/usr/bin/env python3
"""Glimt's macOS registration audit: read-only snapshot, compare, and orphan listing.

Reads three separate system registries and never resets any of them:
LaunchServices (`lsregister -dump`), PlugInKit (`pluginkit -m`) and Background Task Management
(`sfltool dumpbtm`). Only records whose identifier starts with `com.glimt.app`, or BTM items named
for Glimt, are kept. This tool is read-only and never changes any registry. `lsregister` and
`sfltool` are undocumented tools whose output format is version-specific; an unreadable source is
reported as NOT_VERIFIED, never as a pass.
"""
import argparse
import glob
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
IDENTIFIER_PREFIX = "com.glimt.app"
EXTENSION_IDS = ("com.glimt.app.preview", "com.glimt.app.thumbnail")
ROOT = Path(__file__).resolve().parents[1]
SCOPED_BUILDS = ROOT / "build/scoped.noindex"


# MARK: Parsing

def normal(path):
    """Compares /private/var and /var (and /private/tmp and /tmp) as the same location."""
    path = path.rstrip("/") or "/"
    for alias in ("/private/var/", "/private/tmp/"):
        if path.startswith(alias):
            path = path[len("/private"):]
    return path


def parse_launch_services(text):
    records = []
    for block in re.split(r"\n-{80}\n", text):
        head = block.lstrip("\n").split("\n", 1)[0]
        kind = "bundle" if head.startswith("bundle id:") else "plugin" if head.startswith("plugin id:") else None
        identifier = re.search(r"^identifier:\s+(\S+)", block, re.M)
        path = re.search(r"^path:\s+(.*?)(?: \(0x[0-9a-f]+\))?$", block, re.M)
        if not (kind and identifier and path) or not identifier.group(1).startswith(IDENTIFIER_PREFIX):
            continue
        records.append({"kind": kind, "identifier": identifier.group(1), "path": path.group(1),
                        "missingOnDisk": "Bundle node not found on disk" in block})
    return records


def parse_background_tasks(text):
    items = []
    for block in re.split(r"\n\s*#\d+:\n", text):
        fields = {m.group(1).strip(): m.group(2).strip()
                  for m in re.finditer(r"^\s*([A-Za-z][A-Za-z ]*):\s(.*)$", block, re.M)}
        glimt = (fields.get("Name", "").startswith("Glimt") or fields.get("Parent Identifier", "").endswith(".Glimt")
                 or fields.get("Bundle Identifier", "").startswith(IDENTIFIER_PREFIX))
        if glimt and "Identifier" in fields:
            items.append({"identifier": fields["Identifier"], "type": fields.get("Type", "").split(" ")[0],
                          "url": fields.get("URL", ""), "parent": fields.get("Parent Identifier")})
    return items


def parse_pluginkit(text, identifier):
    plugins, current = [], None
    for line in text.splitlines():
        match = re.match(r"^\s*([+\-=!?]?)\s*" + re.escape(identifier) + r"\(", line)
        if match:
            current = {"identifier": identifier, "path": None, "enabled": match.group(1) == "+"}
            plugins.append(current)
        elif current is not None:
            path = re.match(r"^\s*[Pp]ath = (.*)$", line)
            if path:
                current["path"] = path.group(1)
    return [p for p in plugins if p["path"]]


# MARK: Snapshot

def run(command):
    result = subprocess.run(command, capture_output=True, text=True, errors="replace")
    return result.returncode, result.stdout


def work_directories():
    roots = {os.environ.get("TMPDIR") or tempfile.gettempdir(), "/private/tmp"}
    found = set()
    for root in roots:
        found.update(normal(p) for p in glob.glob(os.path.join(root, "glimt-*")) if os.path.isdir(p))
    found.update(normal(p) for p in glob.glob(str(SCOPED_BUILDS / "*/DerivedData")) if os.path.isdir(p))
    return sorted(found)


def take_snapshot(background_tasks=True):
    """`background_tasks=False` skips `sfltool dumpbtm`; BTM items are keyed by app identity and
    updated in place, so a before/after pair around a whole run is enough to see growth."""
    status, dump = run([os.environ.get("GLIMT_LSREGISTER", LSREGISTER), "-dump"])
    if status:
        raise RuntimeError("lsregister -dump failed; LaunchServices state is unknown")
    plugins = []
    for identifier in EXTENSION_IDS:
        status, listing = run([os.environ.get("GLIMT_PLUGINKIT", "pluginkit"), "-m", "-A", "-D", "-vv", "-i", identifier])
        if status:
            raise RuntimeError("pluginkit -m failed; PlugInKit state is unknown")
        plugins += parse_pluginkit(listing, identifier)
    if background_tasks:
        status, btm = run([os.environ.get("GLIMT_SFLTOOL", "sfltool"), "dumpbtm"])
        btm_state = {"status": "ok" if status == 0 and "#" in btm else "unavailable",
                     "items": parse_background_tasks(btm) if status == 0 else []}
    else:
        btm_state = {"status": "skipped", "items": []}
    applications = Path(os.environ.get("GLIMT_APPLICATIONS", "/Applications"))
    return {"launchServices": parse_launch_services(dump), "pluginKit": plugins,
            "backgroundTasks": btm_state,
            "applicationsHidden": sorted(str(p) for p in applications.glob(".Glimt.app*")),
            "workDirectories": work_directories()}


# MARK: Comparison

def counts(records, key):
    tally = {}
    for record in records:
        tally[key(record)] = tally.get(key(record), 0) + 1
    return tally


def background_task_changes(before, after, inside, residual):
    """Sorts BTM identities that are new since `before`: for the intended install, residue of a
    removed intended install (no per-item removal exists), or unwanted. Duplicates are unwanted."""
    known = {item["identifier"] for item in before}
    urls = {item["identifier"]: item["url"] for item in after if item["url"].startswith("/")}
    tally = counts(after, lambda item: item["identifier"])
    changes = {"allowedBackgroundTasks": [], "residualBackgroundTasks": [], "newBackgroundTasks": [],
               "duplicateBackgroundTasks": sorted(i for i, n in tally.items() if n > 1)}
    for item in after:
        if item["identifier"] in known:
            continue
        app = item["url"] if item["url"].startswith("/") else urls.get(item.get("parent"), "")
        key = ("allowedBackgroundTasks" if app and inside(app) else
               "residualBackgroundTasks" if app and residual(app) else "newBackgroundTasks")
        if item["identifier"] not in changes[key]:
            changes[key].append(item["identifier"])
    return changes


def compare(before, after, allowed=(), expect_installed=None, residual=()):
    allowed = [normal(a) for a in allowed]
    residual = [normal(r) for r in residual]
    within = lambda path, roots: any(normal(path) == r or normal(path).startswith(r + "/") for r in roots)
    inside = lambda path: within(path, allowed)
    key = lambda r: (r["kind"], normal(r["path"]))
    old, new = counts(before["launchServices"], key), counts(after["launchServices"], key)
    report = {
        "newLaunchServices": sorted({p for (k, p), n in new.items() if n > old.get((k, p), 0) and not inside(p)}),
        "duplicateLaunchServices": sorted({p for (k, p), n in new.items() if n > 1 and inside(p)}),
        "newPluginKit": sorted({normal(p["path"]) for p in after["pluginKit"]
                                if not inside(p["path"]) and normal(p["path"]) not in {normal(q["path"]) for q in before["pluginKit"]}}),
        "newApplicationsHidden": sorted(set(after["applicationsHidden"]) - set(before["applicationsHidden"])),
        "newWorkDirectories": sorted(set(after["workDirectories"]) - set(before["workDirectories"])),
        "backgroundTaskItems": {"before": len(before["backgroundTasks"]["items"]), "after": len(after["backgroundTasks"]["items"])},
        **background_task_changes(before["backgroundTasks"]["items"], after["backgroundTasks"]["items"],
                                  inside, lambda path: within(path, residual)),
        "installProblems": install_problems(after, expect_installed) if expect_installed else [],
        "launchServicesTotal": {"before": len(before["launchServices"]), "after": len(after["launchServices"])},
    }
    btm_skipped = after["backgroundTasks"]["status"] == "skipped"
    btm_known = before["backgroundTasks"]["status"] == after["backgroundTasks"]["status"] == "ok"
    report["backgroundTasksChecked"] = btm_known
    btm_failed = btm_known and bool(report["newBackgroundTasks"] or report["duplicateBackgroundTasks"])
    failed = btm_failed or any(report[k] for k in ("newLaunchServices", "duplicateLaunchServices", "newPluginKit",
                                                      "newApplicationsHidden", "newWorkDirectories", "installProblems"))
    report["verdict"] = "FAIL" if failed else "PASS" if btm_known or btm_skipped else "NOT_VERIFIED"
    return report


def install_problems(snapshot, app):
    app = normal(app)
    problems = []
    if not any(r["kind"] == "bundle" and normal(r["path"]) == app for r in snapshot["launchServices"]):
        problems.append(f"{app} is not registered with LaunchServices")
    for identifier in EXTENSION_IDS:
        mine = [p for p in snapshot["pluginKit"] if p["identifier"] == identifier and normal(p["path"]).startswith(app + "/")]
        if not mine or not all(p["enabled"] for p in mine):
            problems.append(f"{identifier} is not registered and enabled from {app}")
    return problems


# MARK: Orphans

def containing_app(path):
    match = re.match(r"^(.*?\.app)(/|$)", path)
    return match.group(1) if match else path


def orphan_bundles(records):
    """Glimt registrations whose bundle no longer exists, reduced to the containing app path."""
    found = []
    for record in records:
        app = containing_app(record["path"])
        if not os.path.exists(record["path"]) and app not in found:
            found.append(app)
    return found


# MARK: Command line

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    shot = sub.add_parser("snapshot", help="write the current Glimt registration state as JSON")
    shot.add_argument("--out", required=True)
    diff = sub.add_parser("compare", help="fail on Glimt registrations added after a baseline snapshot")
    diff.add_argument("before"); diff.add_argument("after")
    diff.add_argument("--allow", action="append", default=[], help="an intended install path (may appear once)")
    diff.add_argument("--expect-installed", help="an app that must be registered with both extensions enabled")
    diff.add_argument("--residual", action="append", default=[],
                      help="a removed intended install whose BTM item may remain (reported, not failed)")
    diff.add_argument("--out")
    sub.add_parser("orphans", help="list Glimt registrations whose bundle is gone")
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            Path(args.out).write_text(json.dumps(take_snapshot(), indent=1) + "\n")
            return 0
        if args.command == "compare":
            report = compare(json.loads(Path(args.before).read_text()), json.loads(Path(args.after).read_text()),
                             args.allow, args.expect_installed, args.residual)
            if args.out:
                Path(args.out).write_text(json.dumps(report, indent=1) + "\n")
            for name in ("newLaunchServices", "duplicateLaunchServices", "newPluginKit", "newApplicationsHidden",
                         "newWorkDirectories", "installProblems", "newBackgroundTasks", "duplicateBackgroundTasks",
                         "residualBackgroundTasks"):
                for entry in report[name]:
                    print(f"REGISTRATION {name}: {entry}")
            totals, btm = report["launchServicesTotal"], report["backgroundTaskItems"]
            print(f"REGISTRATION {report['verdict']} launchServices={totals['before']}->{totals['after']} "
                  f"backgroundTasks={btm['before']}->{btm['after']}")
            return {"PASS": 0, "FAIL": 1}.get(report["verdict"], 2)
        status, dump = run([os.environ.get("GLIMT_LSREGISTER", LSREGISTER), "-dump"])
        if status:
            raise RuntimeError("lsregister -dump failed")
        paths = orphan_bundles(parse_launch_services(dump))
        for path in paths:
            print("orphan " + path)
        print(f"{len(paths)} orphaned Glimt bundle path(s)")
        return 0
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"registration-audit: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
