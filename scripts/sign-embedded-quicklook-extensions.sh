#!/bin/bash
set -euo pipefail

app_bundle="${TARGET_BUILD_DIR:?}/${FULL_PRODUCT_NAME:?}"
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
[[ -d "$app_bundle/Contents/PlugIns" ]] || exit 0
[[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]] || exit 0
[[ -n "$signing_identity" ]] || {
    printf 'Quick Look extension signing requires Xcode CODE_SIGN_IDENTITY\n' >&2
    exit 1
}

# Match Xcode's own signing of the app: Hardened Runtime when enabled, and a secure timestamp for a
# real identity (required for notarization); ad-hoc signatures cannot be timestamped.
options=(--timestamp=none)
[[ "$signing_identity" == "-" ]] || options=(--timestamp)
[[ "${ENABLE_HARDENED_RUNTIME:-NO}" != "YES" ]] || options+=(--options runtime)

sign_extension() {
    local name="$1" entitlements="$2"
    local extension="$app_bundle/Contents/PlugIns/$name.appex"
    [[ -d "$extension" ]] || {
        printf 'Missing embedded extension: %s\n' "$name" >&2
        return 1
    }
    codesign --force --sign "$signing_identity" --entitlements "$SRCROOT/$entitlements" \
        "${options[@]}" --generate-entitlement-der "$extension"
    codesign --verify --deep --strict "$extension"
}

sign_extension GlimtPreview Glimt/PreviewExtension/GlimtPreview.entitlements
sign_extension GlimtThumbnail Glimt/ThumbnailExtension/GlimtThumbnail.entitlements
