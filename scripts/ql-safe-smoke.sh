#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/bundle-lifecycle.sh"
# Xcode registers what it builds with LaunchServices; the scope unregisters it before deletion.
trap glimt_finish EXIT
glimt_exit_on_signals
glimt_claim_scope safe-smoke
WORK_DIR="$GLIMT_SCOPE_DIR"
DERIVED_DATA="$WORK_DIR/DerivedData"
CLONED_PACKAGES="${GLIMT_CLONED_SOURCE_PACKAGES_DIR:-$ROOT/build/SourcePackages}"
# The scope keeps the previous run's result bundles as evidence; xcodebuild refuses to overwrite them.
rm -rf "$WORK_DIR/Glimt-Debug.xcresult" "$WORK_DIR/Glimt-Release.xcresult"

pass() { printf 'SAFE_SMOKE %s\n' "$1"; }
# The tail of an xcodebuild log lists failing tests by name only; their assertion messages come earlier.
show_failures() { grep -E ': error: ' "$1" | head -n 40 >&2 || true; tail -n 50 "$1" >&2; }
fail() { printf 'SAFE_SMOKE FAIL stage=%s details=%s\n' "$1" "$2" >&2; exit 1; }

bash "$ROOT/scripts/lint.sh" --sanitize || fail lint "scripts/lint.sh reported findings"
pass lint

CORE_LOG="$WORK_DIR/swift-test.log"
if ! swift test --package-path "$ROOT/InspectorCore" >"$CORE_LOG" 2>&1; then
    tail -n 35 "$CORE_LOG" >&2
    fail InspectorCore "swift test failed"
fi
CORE_SUMMARY="$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ tests? skipped and 0 failures?' "$CORE_LOG" | tail -n 1 || true)"
[[ -n "$CORE_SUMMARY" ]] || fail InspectorCore "could not read executed test summary"
printf 'SAFE_SMOKE InspectorCore %s\n' "$CORE_SUMMARY"

PYTHON_LOG="$WORK_DIR/python-tests.log"
if ! python3 -m unittest discover -s "$ROOT/scripts/tests" -p 'test_*.py' >"$PYTHON_LOG" 2>&1; then
    cat "$PYTHON_LOG" >&2
    fail tooling-tests "Python test suite failed"
fi
cat "$PYTHON_LOG"

if ! bash "$ROOT/scripts/ql-smoke.sh" --test-classification; then
    fail ql-classification "classifier/correlation regression failed"
fi

XCODE_LOG="$WORK_DIR/xcode-test.log"
if ! xcodebuild \
    -project "$ROOT/Glimt.xcodeproj" \
    -scheme Glimt \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$CLONED_PACKAGES" \
    -resultBundlePath "$WORK_DIR/Glimt-Debug.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    test >"$XCODE_LOG" 2>&1; then
    show_failures "$XCODE_LOG"
    fail xcode-debug-tests "executed Xcode Debug tests failed"
fi
SUMMARY_JSON="$WORK_DIR/xcode-summary.json"
extract_summary() {
    local configuration="$1" result_bundle="$2"
    if ! TMPDIR="$WORK_DIR" xcrun xcresulttool get test-results summary --path "$result_bundle" --compact >"$SUMMARY_JSON"; then
        fail "xcode-$configuration-tests" "tests ran, but xcresult summary could not be extracted"
    fi
    python3 - "$SUMMARY_JSON" "$configuration" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
configuration = sys.argv[2]
print("SAFE_SMOKE Xcode {configuration} result={result} total={totalTestCount} passed={passedTests} failed={failedTests} skipped={skippedTests}".format(configuration=configuration, **summary))
if summary.get("result") != "Passed" or summary.get("failedTests") != 0 or not summary.get("totalTestCount"):
    raise SystemExit("Xcode test execution did not pass")
PY
}
extract_summary Debug "$WORK_DIR/Glimt-Debug.xcresult"

if ! xcodebuild \
    -project "$ROOT/Glimt.xcodeproj" \
    -scheme Glimt \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$CLONED_PACKAGES" \
    -resultBundlePath "$WORK_DIR/Glimt-Release.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    test >"$WORK_DIR/xcode-release-test.log" 2>&1; then
    show_failures "$WORK_DIR/xcode-release-test.log"
    fail xcode-release-tests "executed Xcode Release tests failed"
fi
extract_summary Release "$WORK_DIR/Glimt-Release.xcresult"

APP="$DERIVED_DATA/Build/Products/Release/Glimt.app"
[[ -d "$APP" ]] || fail bundle-inspection "Xcode test did not produce Glimt.app"
for plist in \
    "$APP/Contents/Info.plist" \
    "$APP/Contents/PlugIns/GlimtPreview.appex/Contents/Info.plist" \
    "$APP/Contents/PlugIns/GlimtThumbnail.appex/Contents/Info.plist" \
    "$ROOT/Glimt/PreviewExtension/GlimtPreview.entitlements" \
    "$ROOT/Glimt/ThumbnailExtension/GlimtThumbnail.entitlements"; do
    [[ -f "$plist" ]] || fail bundle-inspection "missing bundle declaration: $plist"
    plutil -lint "$plist" >/dev/null || fail bundle-inspection "invalid plist: $plist"
done
pass "bundle declarations valid; no install, registration, or fixture mutation performed"
RC_LOG="$WORK_DIR/rc-check-bundle.log"
if ! bash "$ROOT/scripts/rc-check-bundle.sh" --unsigned "$APP" >"$RC_LOG" 2>&1; then
    cat "$RC_LOG" >&2
    fail rc-bundle "unsigned Release bundle audit failed"
fi
pass "unsigned Release bundle audit passed (components, resources, dependencies)"
