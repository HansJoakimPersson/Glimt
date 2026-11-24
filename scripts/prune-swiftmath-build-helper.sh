#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?usage: prune-swiftmath-build-helper.sh /path/to/SwiftMath_SwiftMath.bundle}"

signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]] || signing_identity=""

# Xcode signs the resource bundle when it copies it, before this phase changes it. Reseal it with the
# build's identity so the nested signature stays valid; a secure timestamp needs a real identity.
reseal_bundle() {
    local resource_bundle="$1"
    [[ -n "$signing_identity" && -d "$resource_bundle/Contents/_CodeSignature" ]] || return 0
    local timestamp=--timestamp=none
    [[ "$signing_identity" == "-" ]] || timestamp=--timestamp
    /usr/bin/codesign --force --sign "$signing_identity" "$timestamp" "$resource_bundle"
}

prune_bundle() {
    local resource_bundle="$1"
    local fonts="$resource_bundle/Contents/Resources/mathFonts.bundle"
    local helper="$fonts/math_table_to_plist.py"

    if [[ -f "$helper" ]]; then
        /bin/rm -f "$helper"
    fi

    [[ ! -e "$helper" ]]

    if [[ -d "$fonts" ]]; then
        /usr/bin/find "$fonts" -type f -exec /bin/chmod a-x {} +
    fi
    reseal_bundle "$resource_bundle"
}

prune_bundle "$bundle"

# The app's post-embed phase runs after Xcode copies the Preview appex into the app. Clean the
# embedded copy too because that embedding step restores executable bits on its resource files.
if [[ "$bundle" == */Glimt.app/Contents/Resources/SwiftMath_SwiftMath.bundle ]]; then
    app_bundle="${bundle%/Contents/Resources/SwiftMath_SwiftMath.bundle}"
    embedded_preview="$app_bundle/Contents/PlugIns/GlimtPreview.appex/Contents/Resources/SwiftMath_SwiftMath.bundle"
    if [[ -d "$embedded_preview" ]]; then
        prune_bundle "$embedded_preview"
    fi
fi
