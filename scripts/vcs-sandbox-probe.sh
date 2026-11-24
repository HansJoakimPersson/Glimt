#!/usr/bin/env bash
# End-to-end check that the sandboxed Debug host reads Git state with no folder setup (ADR-038).
#
#   scripts/vcs-sandbox-probe.sh [--no-build]
#
# Builds the signed Debug app in Xcode's default DerivedData, creates fixture repositories inside the
# home folder (docs/plans/.runs/vcs-sandbox-probe/) and outside it (a private temporary directory),
# and launches the app through LaunchServices with the Debug-only GLIMT_VCS_PROBE_FILE seam. Nothing
# is granted beyond the entitlements. Prints VCS_PROBE PASS/FAIL lines.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONED_PACKAGES="${GLIMT_CLONED_SOURCE_PACKAGES_DIR:-$ROOT/build/SourcePackages}"
RUN_DIR="$ROOT/docs/plans/.runs/vcs-sandbox-probe/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

pass() { printf 'VCS_PROBE PASS %s\n' "$1"; }
fail() { printf 'VCS_PROBE FAIL %s\n' "$1" >&2; exit 1; }

XCODE_ARGS=(-project "$ROOT/Glimt.xcodeproj" -scheme Glimt -configuration Debug -destination 'platform=macOS'
    -clonedSourcePackagesDirPath "$CLONED_PACKAGES")
if [[ "${1:-}" != "--no-build" ]]; then
    osascript -e 'tell application "Glimt" to quit' >/dev/null 2>&1 || true
    xcodebuild "${XCODE_ARGS[@]}" build >"$RUN_DIR/build.log" 2>&1 || { tail -n 30 "$RUN_DIR/build.log" >&2; fail "build"; }
fi
PRODUCTS="$(xcodebuild "${XCODE_ARGS[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
APP="$PRODUCTS/Glimt.app"
[[ -d "$APP" ]] || fail "app not found"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS" || fail "app is not sandboxed"
grep -q "com.apple.security.temporary-exception.files.absolute-path.read-only" <<<"$ENTITLEMENTS" \
    || fail "app lacks read-only repository access"
pass "sandboxed Debug app with read-only repository access"

make_repository() {
    local repository="$1"
    mkdir -p "$repository"
    # One modified, one deleted and two added lines, so every gutter marker kind is exercised.
    printf 'let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5\nlet f = 6\n' >"$repository/main.swift"
    git -C "$repository" init -q
    git -C "$repository" add main.swift
    git -C "$repository" -c user.name=Glimt -c user.email=glimt@example.invalid commit -q -m base
    printf 'let a = 1\nlet b = 20\nlet c = 3\nlet e = 5\nlet f = 6\nlet g = 7\nlet h = 8\n' >"$repository/main.swift"
}
# Git's own zero-context hunks in the probe's notation: kind@first working line (zero-based).
# A deletion sits at the insertion boundary, which `git diff` names as the line before it.
git_changes() {
    git -C "$1" diff -U0 --no-color main.swift | python3 -c '
import re, sys
out = []
for old, old_count, new, new_count in re.findall(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", sys.stdin.read(), re.M):
    old_count = 1 if old_count == "" else int(old_count)
    new_count = 1 if new_count == "" else int(new_count)
    kind = "added" if old_count == 0 else "deleted" if new_count == 0 else "modified"
    out.append("%s@%d" % (kind, int(new) if new_count == 0 else int(new) - 1))
print(",".join(out))'
}
HOME_REPO="$RUN_DIR/home-repo"
OUTSIDE_ROOT="$(mktemp -d /private/tmp/glimt-vcs-probe.XXXXXX)"
trap 'rm -rf "$OUTSIDE_ROOT"' EXIT
OUTSIDE_REPO="$OUTSIDE_ROOT/outside-repo"
make_repository "$HOME_REPO"
make_repository "$OUTSIDE_REPO"

# Launches the app once for one file and returns its single GLIMT_VCS_PROBE line.
probe() {
    local name="$1" output="$RUN_DIR/probe-$1.txt"
    # `open --stdout` refuses to launch (-10810) when the output file already exists.
    rm -f "$output" "$RUN_DIR/probe-stderr.txt"
    open -W -n --stdout "$output" --stderr "$RUN_DIR/probe-stderr.txt" --env GLIMT_VCS_PROBE_FILE="$2" "$APP" \
        --args -ApplePersistenceIgnoreState YES 2>>"$RUN_DIR/open-errors.txt" || true
    grep -m1 '^GLIMT_VCS_PROBE_IMAGE ' "$output" | cut -d' ' -f2 | base64 -D >"$RUN_DIR/preview-$name.png" 2>/dev/null || true
    grep -m1 '^GLIMT_VCS_PROBE ' "$output" || printf 'GLIMT_VCS_PROBE missing\n'
}
expect() {
    local name="$1" line="$2" pattern="$3"
    printf '%s: %s\n' "$name" "$line" >>"$RUN_DIR/results.txt"
    [[ "$line" =~ $pattern ]] || fail "$name: expected /$pattern/, got '$line'"
    pass "$name"
}

expect_git() {
    local name="$1" repository="$2" expected commit
    expected="$(git_changes "$repository")"
    [[ "$expected" == "modified@1,deleted@3,added@5" ]] || fail "git diff fixture changed: $expected"
    commit="$(git -C "$repository" log -1 --format=%H -- main.swift)"
    # The app reads HEAD from the repository files, diffs the working file with VCSLineDiff, draws the result in
    # the preview gutter and names the last commit; each must match Git itself.
    expect "$name" "$(probe "$(basename "$repository")" "$repository/main.swift")" \
        "result=git status=modified changes=$expected commit=$commit diagnostics= gutter=$expected\$"
}
expect_git "repository in the home folder shows Git's own changes and last commit" "$HOME_REPO"
expect_git "repository outside the home folder shows Git's own changes and last commit" "$OUTSIDE_REPO"
printf 'VCS_PROBE evidence %s\n' "$RUN_DIR"
