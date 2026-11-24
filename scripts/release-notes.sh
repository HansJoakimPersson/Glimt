#!/usr/bin/env bash
# Prints the GitHub Release body for the configured version: release-notes/<tag>.md followed by the
# build identity and the SHA-256 checksums that package-release.sh wrote to <dist-dir>.
#
#   scripts/release-notes.sh <dist-dir>
#
# GLIMT_RELEASE_NOTES_DIR overrides the notes directory (tests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES_DIR="${GLIMT_RELEASE_NOTES_DIR:-$ROOT/release-notes}"
DIST_DIR="${1:?usage: release-notes.sh <dist-dir>}"

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
value() { bash "$ROOT/scripts/version.sh" --get "$1"; }

TAG="$(value TAG)"
NOTES="$NOTES_DIR/$TAG.md"
CHECKSUMS="$DIST_DIR/$(value CHECKSUMS_NAME)"
[[ -f "$NOTES" ]] || fail "missing release notes release-notes/$TAG.md"
[[ -f "$CHECKSUMS" ]] || fail "missing $(basename "$CHECKSUMS"); run scripts/package-release.sh first"

cat "$NOTES"
printf '\n## Build\n\nVersion %s (build %s), SemVer `%s`, tag `%s`.\n' \
    "$(value MARKETING_VERSION)" "$(value BUILD_NUMBER)" "$(value SEMVER)" "$TAG"
printf '\n## SHA-256 checksums\n\n```\n%s\n```\n' "$(cat "$CHECKSUMS")"
