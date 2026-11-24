#!/usr/bin/env bash
# Builds the Release app from the committed checkout, signs, audits and archives it:
#
#   dist/Glimt-<semver>-macOS.zip          the app, archived with ditto
#   dist/Glimt-<semver>-SHA256SUMS.txt     its SHA-256 checksum (`shasum -a 256 -c` format)
#
# Names and Info.plist versions come from Config/Version.xcconfig (scripts/version.sh).
#
# Signing is ad-hoc unless GLIMT_SIGN_IDENTITY names a "Developer ID Application" identity in the
# keychain (with GLIMT_DEVELOPMENT_TEAM). A Developer ID build is notarized and stapled when
# GLIMT_NOTARY_PROFILE (a notarytool keychain profile) or GLIMT_NOTARY_KEY_PATH,
# GLIMT_NOTARY_KEY_ID and GLIMT_NOTARY_ISSUER (an App Store Connect API key) are set.
#
# A dirty working tree is refused so every artifact maps to one commit; GLIMT_ALLOW_DIRTY=1
# allows a local experiment, and the app's GlimtBuildProvenance.plist then records it as unclean.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/bundle-lifecycle.sh"

fail() { printf 'PACKAGE FAIL stage=%s details=%s\n' "$1" "$2" >&2; exit 1; }
pass() { printf 'PACKAGE %s\n' "$1"; }

# MARK: Inputs

VERSION_FIELDS="$(bash "$ROOT/scripts/version.sh")" || fail version "Config/Version.xcconfig is invalid"
field() { printf '%s\n' "$VERSION_FIELDS" | sed -n "s/^$1=//p"; }
SEMVER="$(field SEMVER)"
ARCHIVE_NAME="$(field ARCHIVE_NAME)"
CHECKSUMS_NAME="$(field CHECKSUMS_NAME)"
DIST_DIR="${GLIMT_DIST_DIR:-$ROOT/dist}"
CLONED_PACKAGES="${GLIMT_CLONED_SOURCE_PACKAGES_DIR:-$ROOT/build/SourcePackages}"

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || fail source "a Git commit is required for build provenance"
if [[ -n "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" && "${GLIMT_ALLOW_DIRTY:-0}" != 1 ]]; then
    fail source "the working tree has uncommitted changes; commit them or set GLIMT_ALLOW_DIRTY=1"
fi

IDENTITY="${GLIMT_SIGN_IDENTITY:--}"
# Distribution builds never get Xcode's injected debugging entitlement (get-task-allow).
SIGN_SETTINGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=${GLIMT_DEVELOPMENT_TEAM:-}"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
AUDIT_MODE=--adhoc
if [[ "$IDENTITY" != "-" ]]; then
    [[ "$IDENTITY" == "Developer ID Application"* ]] || fail signing "GLIMT_SIGN_IDENTITY must be a Developer ID Application identity"
    [[ -n "${GLIMT_DEVELOPMENT_TEAM:-}" ]] || fail signing "GLIMT_DEVELOPMENT_TEAM is required with GLIMT_SIGN_IDENTITY"
    SIGN_SETTINGS+=("OTHER_CODE_SIGN_FLAGS=--timestamp")
    AUDIT_MODE=--signed
fi
NOTARIZE=()
if [[ -n "${GLIMT_NOTARY_PROFILE:-}" ]]; then
    NOTARIZE=(--keychain-profile "$GLIMT_NOTARY_PROFILE")
elif [[ -n "${GLIMT_NOTARY_KEY_PATH:-}" ]]; then
    NOTARIZE=(--key "$GLIMT_NOTARY_KEY_PATH" --key-id "${GLIMT_NOTARY_KEY_ID:?}" --issuer "${GLIMT_NOTARY_ISSUER:?}")
fi
[[ ${#NOTARIZE[@]} -eq 0 || "$IDENTITY" != "-" ]] || fail notarization "notarization requires GLIMT_SIGN_IDENTITY"

# MARK: Build

# Xcode registers what it builds with LaunchServices; the scope unregisters it before deletion.
trap glimt_finish EXIT
glimt_exit_on_signals
glimt_claim_scope package
DERIVED_DATA="$GLIMT_SCOPE_DIR/DerivedData"
STAGING="$GLIMT_SCOPE_DIR/staging"
BUILD_LOG="$GLIMT_SCOPE_DIR/xcodebuild-release.log"

printf 'PACKAGE Glimt %s from %s (signing: %s)\n' "$SEMVER" "$COMMIT" "$([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "Developer ID")"
if ! xcodebuild \
    -project "$ROOT/Glimt.xcodeproj" \
    -scheme Glimt \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$CLONED_PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    "${SIGN_SETTINGS[@]}" \
    build >"$BUILD_LOG" 2>&1; then
    tail -n 60 "$BUILD_LOG" >&2
    fail build "xcodebuild Release build failed"
fi
pass build

mkdir -p "$STAGING"
APP="$STAGING/Glimt.app"
ditto "$DERIVED_DATA/Build/Products/Release/Glimt.app" "$APP"
codesign --verify --deep --strict "$APP" || fail signing "codesign verification failed"
pass "signature verified"

# MARK: Notarize

if [[ ${#NOTARIZE[@]} -gt 0 ]]; then
    ditto -c -k --keepParent "$APP" "$STAGING/notarize.zip"
    xcrun notarytool submit "$STAGING/notarize.zip" "${NOTARIZE[@]}" --wait || fail notarization "notarytool submission failed"
    xcrun stapler staple "$APP" || fail notarization "stapling failed"
    spctl --assess --type execute -vv "$APP" || fail notarization "Gatekeeper rejected the notarized app"
    pass notarized
fi

# MARK: Audit

bash "$ROOT/scripts/rc-check-bundle.sh" "$AUDIT_MODE" "$APP" || fail audit "bundle audit failed"
PROVENANCE="$APP/Contents/Resources/GlimtBuildProvenance.plist"
[[ "$(plutil -extract GitCommit raw "$PROVENANCE")" == "$COMMIT" ]] || fail audit "provenance commit differs from HEAD"
pass "provenance commit=$COMMIT clean=$(plutil -extract WorkingTreeClean raw "$PROVENANCE")"

# MARK: Archive

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$CHECKSUMS_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_DIR/$ARCHIVE_NAME"
(cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" >"$CHECKSUMS_NAME")
pass "artifact $(cat "$DIST_DIR/$CHECKSUMS_NAME")"
