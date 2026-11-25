#!/usr/bin/env bash
# Reads Config/Version.xcconfig, validates it and derives Glimt's release names from it.
#
#   scripts/version.sh                    KEY=VALUE lines (SEMVER, TAG, RELEASE_TITLE, ARCHIVE_NAME, …)
#   scripts/version.sh --get KEY          one value
#   scripts/version.sh --check-tag TAG    fails unless TAG is the configured release tag
#   scripts/version.sh --previous-tag     reads published release tags on stdin and prints the one
#                                         the configured release's notes start from, or nothing
#
# GLIMT_VERSION_CONFIG overrides the configuration path (tests).
# shellcheck disable=SC2034 # The derived values are printed through ${!key}.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${GLIMT_VERSION_CONFIG:-$ROOT/Config/Version.xcconfig}"

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ -f "$CONFIG" ]] || fail "missing version configuration: $CONFIG"

# Prints the value of one `KEY = value` line; a missing key is an error, an empty value is not.
setting() {
    local line
    line="$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" | tail -n 1)" || fail "$1 is not set in $CONFIG"
    line="${line#*=}"
    line="${line#"${line%%[![:space:]]*}"}"
    printf '%s' "${line%"${line##*[![:space:]]}"}"
}

MARKETING_VERSION="$(setting MARKETING_VERSION)"
BUILD_NUMBER="$(setting CURRENT_PROJECT_VERSION)"
PRERELEASE="$(setting GLIMT_PRERELEASE)"

[[ "$MARKETING_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || fail "MARKETING_VERSION must be MAJOR.MINOR.PATCH, got '$MARKETING_VERSION'"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "CURRENT_PROJECT_VERSION must be a positive integer, got '$BUILD_NUMBER'"

SEMVER="$MARKETING_VERSION"
DISPLAY_VERSION="$MARKETING_VERSION"
IS_PRERELEASE=false
if [[ -n "$PRERELEASE" ]]; then
    [[ "$PRERELEASE" =~ ^(alpha|beta|rc)\.([1-9][0-9]*)$ ]] \
        || fail "GLIMT_PRERELEASE must be empty, alpha.N, beta.N or rc.N, got '$PRERELEASE'"
    case "${BASH_REMATCH[1]}" in
        alpha) stage="Alpha" ;;
        beta) stage="Beta" ;;
        rc) stage="RC" ;;
    esac
    SEMVER="$MARKETING_VERSION-$PRERELEASE"
    DISPLAY_VERSION="$MARKETING_VERSION $stage ${BASH_REMATCH[2]}"
    IS_PRERELEASE=true
fi

TAG="v$SEMVER"
RELEASE_TITLE="Glimt $DISPLAY_VERSION"
ARCHIVE_NAME="Glimt-$SEMVER-macOS.zip"
CHECKSUMS_NAME="Glimt-$SEMVER-SHA256SUMS.txt"
KEYS=(MARKETING_VERSION BUILD_NUMBER PRERELEASE SEMVER TAG DISPLAY_VERSION RELEASE_TITLE IS_PRERELEASE
    ARCHIVE_NAME CHECKSUMS_NAME)

# Prints a key that sorts release tags in SemVer precedence: MAJOR, MINOR, PATCH as ten digits each,
# then the stage (0 alpha, 1 beta, 2 rc, 3 stable) and its number. Fails for other tags.
tag_key() {
    [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.([1-9][0-9]*))?$ ]] || return 1
    local rank=3
    case "${BASH_REMATCH[5]}" in
        alpha) rank=0 ;;
        beta) rank=1 ;;
        rc) rank=2 ;;
    esac
    printf '%010d%010d%010d%d%010d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
        "$rank" "${BASH_REMATCH[6]:-0}"
}

case "${1:-}" in
    "")
        for key in "${KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}"; done
        ;;
    --get)
        key="${2:-}"
        [[ " ${KEYS[*]} " == *" $key "* ]] || fail "unknown key '$key'"
        printf '%s\n' "${!key}"
        ;;
    --check-tag)
        [[ "${2:-}" == "$TAG" ]] || fail "tag '${2:-}' does not match Config/Version.xcconfig ($TAG)"
        ;;
    --previous-tag)
        # A pre-release lists the changes since the closest earlier release of any stage; a stable
        # release lists everything since the previous stable release.
        current="$(tag_key "$TAG")"
        previous="" previous_key=""
        while IFS= read -r candidate; do
            key="$(tag_key "$candidate")" || continue
            [[ "$IS_PRERELEASE" == true || "${key:30:1}" == 3 ]] || continue
            if [[ "$key" < "$current" && "$key" > "$previous_key" ]]; then
                previous="$candidate" previous_key="$key"
            fi
        done
        [[ -z "$previous" ]] || printf '%s\n' "$previous"
        ;;
    *)
        printf 'usage: %s [--get KEY | --check-tag TAG | --previous-tag]\n' "$0" >&2
        exit 2
        ;;
esac
