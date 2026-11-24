#!/usr/bin/env python3
"""Validate a specific enabled PlugInKit record for an exact Glimt extension bundle."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


class Registration:
    def __init__(self, enabled: bool, bundle_identifier: str):
        self.enabled = enabled
        self.bundle_identifier = bundle_identifier
        self.path = ""
        self.extension_point = ""


HEADER = re.compile(r"^\s*([+-])\s+(\S+?)(?:\([^)]*\))?\s*$")


def parse_registrations(output: str) -> list[Registration]:
    records: list[Registration] = []
    current: Registration | None = None
    for line in output.splitlines():
        match = HEADER.match(line)
        if match:
            current = Registration(match.group(1) == "+", match.group(2))
            records.append(current)
            continue
        if current is None:
            continue
        stripped = line.strip()
        if stripped.startswith("Path = "):
            current.path = stripped.removeprefix("Path = ").strip()
        elif stripped.startswith("SDK = "):
            current.extension_point = stripped.removeprefix("SDK = ").strip()
    return records


def check_registration(
    output: str, expected_path: Path, bundle_identifier: str, extension_point: str
) -> tuple[bool, str]:
    records = parse_registrations(output)
    identified = [record for record in records if record.bundle_identifier == bundle_identifier]
    if not identified:
        return False, "extension-not-registered"

    expected = str(expected_path.resolve())
    exact_path = [record for record in identified if record.path and str(Path(record.path).resolve()) == expected]
    if not exact_path:
        return False, "candidate-path-not-registered"
    exact_point = [record for record in exact_path if record.extension_point == extension_point]
    if not exact_point:
        return False, "candidate-extension-point-mismatch"
    if not any(record.enabled for record in exact_point):
        return False, "candidate-extension-disabled"
    return True, "candidate-registered-enabled"


def inspect_registration(
    bundle_path: Path, bundle_identifier: str, extension_point: str
) -> tuple[bool, str, int]:
    try:
        result = subprocess.run(
            ["pluginkit", "-m", "-A", "-D", "-vv", "-i", bundle_identifier],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return False, "pluginkit-command-unavailable", 20
    if result.returncode != 0:
        return (
            False,
            "pluginkit-command-failed "
            f"exit={result.returncode} stdoutBytes={len(result.stdout.encode())} "
            f"stderrBytes={len(result.stderr.encode())}",
            20,
        )
    # PlugInKit diagnostics can appear on either stream; preserve both while never exposing
    # their path-bearing text in user-facing failure output.
    ok, reason = check_registration(
        result.stdout + "\n" + result.stderr,
        bundle_path,
        bundle_identifier,
        extension_point,
    )
    return ok, reason, 0 if ok else 10


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--listing", type=Path)
    source.add_argument("--query", action="store_true")
    parser.add_argument("--bundle-path", required=True, type=Path)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--extension-point", required=True)
    arguments = parser.parse_args()
    if arguments.query:
        ok, reason, status = inspect_registration(
            arguments.bundle_path,
            arguments.bundle_identifier,
            arguments.extension_point,
        )
    else:
        try:
            output = arguments.listing.read_text()
        except OSError:
            print("pluginkit-list-unreadable", file=sys.stderr)
            return 20
        ok, reason = check_registration(
            output,
            arguments.bundle_path,
            arguments.bundle_identifier,
            arguments.extension_point,
        )
        status = 0 if ok else 10
    print(reason)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
