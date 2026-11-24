#!/usr/bin/env python3
"""Correlate a Quick Look debug marker with the exact registered extension bundle."""

import argparse
import json
import os
from pathlib import Path


def inspect_events(events, token, provider_path, kind, expected_type=None):
    expected_path = os.path.realpath(provider_path)
    begin = final = render = matching = wrong_provider = type_match = False
    active = False
    marker_prefix = f"FR005_PROVIDER_V1 token={token} provider={kind} "
    matched_marker = ""
    for event in events:
        message = event.get("eventMessage", "")
        image_path = os.path.realpath(event.get("processImagePath", ""))
        carries_token = token in message
        if carries_token and image_path != expected_path and ("GLIMT_PREVIEW_BEGIN" in message or "FR005_PROVIDER_V1" in message):
            wrong_provider = True
        if image_path != expected_path:
            continue
        if carries_token and f"GLIMT_PREVIEW_BEGIN token={token}" in message and kind == "preview":
            begin = True
            active = True
        elif kind == "preview" and active and "FR002_RENDER" in message:
            render = True
        elif carries_token and message.startswith(marker_prefix):
            final = True
            matching = True
            type_match = expected_type is None or f" type={expected_type} " in message
            matched_marker = message
            active = False
    return begin, final, render, matching, wrong_provider, type_match, matched_marker


def runtime_provenance(events, token, kind):
    prefix = f"GLIMT_PROVIDER_PROVENANCE_V1 token={token} provider={kind} "
    return [
        event.get("eventMessage", "")
        for event in events
        if event.get("eventMessage", "").startswith(prefix)
    ]


def observed_provider_executables(events, token, kind):
    prefixes = (
        f"GLIMT_PREVIEW_BEGIN token={token} " if kind == "preview" else "",
        f"FR005_PROVIDER_V1 token={token} provider={kind} ",
        f"GLIMT_PROVIDER_PROVENANCE_V1 token={token} provider={kind} ",
    )
    paths = []
    for event in events:
        message = event.get("eventMessage", "")
        path = event.get("processImagePath", "")
        if path and any(prefix and message.startswith(prefix) for prefix in prefixes) and path not in paths:
            paths.append(path)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log_json", type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--provider-path")
    parser.add_argument("--kind", choices=("preview", "thumbnail"), required=True)
    parser.add_argument("--expected-type")
    parser.add_argument("--emit-marker", action="store_true")
    parser.add_argument("--emit-runtime-provenance", action="store_true")
    parser.add_argument("--emit-observed-provider", action="store_true")
    args = parser.parse_args()
    try:
        events = json.loads(args.log_json.read_text())
    except (OSError, json.JSONDecodeError) as error:
        parser.error(f"could not read unified log JSON: {error}")
    if args.emit_runtime_provenance:
        for value in runtime_provenance(events, args.token, args.kind):
            print(value)
        return
    if args.emit_observed_provider:
        for value in observed_provider_executables(events, args.token, args.kind):
            print(value)
        return
    if not args.provider_path:
        parser.error("--provider-path is required unless emitting runtime provenance")
    values = inspect_events(events, args.token, args.provider_path, args.kind, args.expected_type)
    if args.emit_marker:
        print(values[-1])
    else:
        print(" ".join("1" if value else "0" for value in values[:-1]))


if __name__ == "__main__":
    main()
