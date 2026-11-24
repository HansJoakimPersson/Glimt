#!/usr/bin/env python3
"""Write Git/build provenance into an already assembled Glimt app or extension bundle."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


def git_value(source_root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source_root), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def write_provenance(
    source_root: Path,
    bundle_path: Path,
    configuration: str,
    code_sign_identity: str,
) -> Path:
    source_root = source_root.resolve(strict=True)
    bundle_path = bundle_path.resolve(strict=True)
    info_path = bundle_path / "Contents" / "Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)

    status = git_value(source_root, "status", "--porcelain=v1", "--untracked-files=all")
    provenance = {
        "SchemaVersion": 1,
        "GitCommit": git_value(source_root, "rev-parse", "HEAD"),
        "WorkingTreeClean": not bool(status),
        "BuildConfiguration": configuration,
        "CodeSignIdentity": code_sign_identity,
        "BundleIdentifier": info.get("CFBundleIdentifier", ""),
        "MarketingVersion": info.get("CFBundleShortVersionString", ""),
        "BuildVersion": info.get("CFBundleVersion", ""),
    }
    if not all(provenance[key] for key in ("GitCommit", "BuildConfiguration", "BundleIdentifier", "BuildVersion")):
        raise ValueError("source revision or built bundle metadata is incomplete")

    resources = bundle_path / "Contents" / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    destination = resources / "GlimtBuildProvenance.plist"
    payload = plistlib.dumps(provenance, fmt=plistlib.FMT_XML, sort_keys=True)
    if destination.is_file() and destination.read_bytes() == payload:
        return destination
    descriptor, temporary_name = tempfile.mkstemp(prefix=".GlimtBuildProvenance.", dir=resources)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, destination)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return destination


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--bundle-path", required=True, type=Path)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--code-sign-identity", default="")
    arguments = parser.parse_args()
    path = write_provenance(
        arguments.source_root,
        arguments.bundle_path,
        arguments.configuration,
        arguments.code_sign_identity,
    )
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
