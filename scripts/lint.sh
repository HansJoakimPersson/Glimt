#!/usr/bin/env bash
# Static checks for Glimt. Findings are reported as Xcode-style `file:line:col: error:` lines.
#
#   scripts/lint.sh                    swift-format rules, ShellCheck, InspectorCore warnings-as-errors build
#   scripts/lint.sh --swift [paths…]   swift-format rules only (the Xcode build phase); default: all Swift sources
#   scripts/lint.sh --sanitize         also run the InspectorCore tests under Address and Undefined Behavior Sanitizer
#
# Read-only for the source tree: SwiftPM builds go to InspectorCore/.build/lint-* scratch directories.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/.swift-format"
SWIFT_ONLY=0
SANITIZE=0
SWIFT_PATHS=()

case "${1:-}" in
    --swift) SWIFT_ONLY=1; shift; SWIFT_PATHS=("$@") ;;
    --sanitize) SANITIZE=1 ;;
    "") ;;
    *) printf 'usage: %s [--swift [paths…] | --sanitize]\n' "$0" >&2; exit 2 ;;
esac
if [[ "${#SWIFT_PATHS[@]}" -eq 0 ]]; then
    SWIFT_PATHS=("$ROOT/Glimt" "$ROOT/GlimtPreviewTests" "$ROOT/InspectorCore/Sources" "$ROOT/InspectorCore/Tests")
fi

pass() { printf 'LINT PASS %s\n' "$1"; }
fail() { printf 'LINT FAIL %s\n' "$1" >&2; exit 1; }

# MARK: swift-format

# Reports only the rules enabled in .swift-format. The pretty-printer's layout findings cannot be
# disabled in the configuration, and the codebase does not follow its layout.
swift_format_rules() {
    local rules output findings
    rules="$(grep -oE '"[A-Z][A-Za-z]+" *: *true' "$CONFIG" | cut -d'"' -f2 | paste -sd'|' -)"
    [[ -n "$rules" ]] || fail "swift-format: no rules enabled in $CONFIG"
    output="$(swift format lint --configuration "$CONFIG" --recursive --parallel "${SWIFT_PATHS[@]}" 2>&1)" \
        || [[ -n "$output" ]] || fail "swift-format could not run"
    if grep -q 'unrecognized rule' <<<"$output"; then
        grep 'unrecognized rule' <<<"$output" | sort -u >&2
        fail "swift-format: $CONFIG names a rule this toolchain does not know"
    fi
    findings="$(grep -E ": warning: \[($rules)\]" <<<"$output" || true)"
    if [[ -n "$findings" ]]; then
        printf '%s\n' "${findings//: warning: /: error: }"
        fail "swift-format"
    fi
    pass "swift-format"
}

swift_format_rules
[[ "$SWIFT_ONLY" -eq 0 ]] || exit 0

# MARK: ShellCheck

command -v shellcheck >/dev/null || fail "shellcheck is not installed (brew install shellcheck)"
shellcheck -x -S warning "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh || fail "shellcheck"
pass "shellcheck"

# MARK: Compiler warnings

# The Xcode targets treat warnings as errors in Release; Xcode does not apply that to the local
# package, so InspectorCore and its tests are checked here.
WERROR_LOG="$ROOT/InspectorCore/.build/lint-werror.log"
mkdir -p "$ROOT/InspectorCore/.build"
if ! swift build --package-path "$ROOT/InspectorCore" --scratch-path "$ROOT/InspectorCore/.build/lint-werror" \
    --build-tests -Xswiftc -warnings-as-errors >"$WERROR_LOG" 2>&1; then
    grep -E ': error: ' "$WERROR_LOG" | sort -u >&2 || tail -n 30 "$WERROR_LOG" >&2
    fail "InspectorCore warnings-as-errors build"
fi
pass "InspectorCore warnings-as-errors build"

# MARK: Sanitizers

[[ "$SANITIZE" -eq 1 ]] || exit 0
# The unfiltered run includes GitInspectionTests under this scratch path.
SANITIZE_LOG="$ROOT/InspectorCore/.build/lint-sanitize.log"
if ! swift test --package-path "$ROOT/InspectorCore" --scratch-path "$ROOT/InspectorCore/.build/lint-sanitize" \
    --sanitize=address --sanitize=undefined >"$SANITIZE_LOG" 2>&1; then
    tail -n 40 "$SANITIZE_LOG" >&2
    fail "InspectorCore tests under ASan/UBSan"
fi
pass "InspectorCore tests under ASan/UBSan"
