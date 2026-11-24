#!/bin/bash
# Read-only Glimt registration inventory with explicit, identity-checked cleanup modes.
set -u
set -o pipefail

APP_ID='com.glimt.app'
PREVIEW_ID='com.glimt.app.preview'
THUMBNAIL_ID='com.glimt.app.thumbnail'
PREVIEW_POINT='com.apple.quicklook.preview'
THUMBNAIL_POINT='com.apple.quicklook.thumbnail'
LSREGISTER_DEFAULT='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
LSREGISTER="${GLIMT_CLEANUP_LSREGISTER:-$LSREGISTER_DEFAULT}"
PLISTBUDDY="${GLIMT_CLEANUP_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
PLUGINKIT="${GLIMT_CLEANUP_PLUGINKIT:-$(command -v pluginkit 2>/dev/null || true)}"
MDFIND="${GLIMT_CLEANUP_MDFIND:-$(command -v mdfind 2>/dev/null || true)}"
QLMANAGE="${GLIMT_CLEANUP_QLMANAGE:-$(command -v qlmanage 2>/dev/null || true)}"
PGREP="${GLIMT_CLEANUP_PGREP:-$(command -v pgrep 2>/dev/null || true)}"
KEEP=''
KEEP_WAS_SET=0
ALL=0
MODE='scan'
MODE_WAS_SET=0
EXTRA_ROOTS=()
EVIDENCE=''

usage() {
    cat <<'HELP'
Usage: glimt-cleanup.sh [--scan | --clean | --trash] [--keep /absolute/path/Glimt.app | --all] [--root /directory]
  --scan   Read-only inventory (default). No LaunchServices or PlugInKit changes.
  --clean  Unregister verified noncanonical Glimt LaunchServices/PlugInKit records; never deletes files.
  --trash  Same as --clean, then offer to move explicitly eligible duplicate app copies to ~/.Trash.
  --keep   Required for --trash, and for --clean without --all. Existing, non-symlinked com.glimt.app to preserve.
  --all    Only with --clean: unregister every verified Glimt copy, including /Applications. Launch the
           copy you want afterwards to register it again.
  --root   Additional search root; repeat as needed. Search roots never grant Trash eligibility.

--trash only considers direct Glimt*.app children of /Applications, ~/Applications, or ~/Downloads.
Development/build/worktree and backup locations are never moved. No sudo or global LaunchServices reset.
Each successful scan stores before/after registry output in a new evidence folder under TMPDIR.
LaunchServices preference is not evidence of the Quick Look provider Finder selected for a file.
HELP
}

fail() { printf 'glimt-cleanup: %s\n' "$1" >&2; exit "${2:-1}"; }
contains_line() { grep -Fqx -- "$2" "$1" 2>/dev/null; }

while (($#)); do
    case "$1" in
        --scan|--clean|--trash)
            [[ "$MODE_WAS_SET" == 0 ]] || fail 'choose exactly one operation mode' 2
            MODE="${1#--}"
            MODE_WAS_SET=1
            shift ;;
        --keep|--root)
            option="$1"; shift
            (($#)) || fail "missing value for $option" 2
            [[ "$1" == /* ]] || fail "expected an absolute path for $option" 2
            if [[ "$option" == --keep ]]; then KEEP="${1%/}"; KEEP_WAS_SET=1
            else EXTRA_ROOTS+=("${1%/}"); fi
            shift ;;
        --all) ALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" 2 ;;
    esac
done

if [[ "${GLIMT_CLEANUP_TEST_MODE:-0}" != 1 ]]; then
    [[ "$(uname -s)" == Darwin ]] || fail 'this script must run on macOS' 2
fi
[[ -x "$LSREGISTER" ]] || fail 'lsregister is unavailable' 2
[[ -x "$PLISTBUDDY" ]] || fail 'PlistBuddy is unavailable' 2
[[ -n "$PLUGINKIT" && -x "$PLUGINKIT" ]] || fail 'pluginkit is unavailable' 2
[[ -n "$PGREP" && -x "$PGREP" ]] || fail 'pgrep is unavailable' 2

plist_value() {
    local key="$2" plist="$1/Contents/Info.plist"
    [[ -f "$plist" && -r "$plist" ]] || return 1
    "$PLISTBUDDY" -c "Print :$key" "$plist" 2>/dev/null
}
bundle_id() { plist_value "$1" CFBundleIdentifier; }
bundle_value() { plist_value "$1" "$2" || printf '?'; }
extension_is_expected() {
    local path="$1" expected_id="$2" expected_point="$3" actual_id actual_point
    [[ ! -L "$path" && -d "$path" ]] || return 1
    actual_id="$(bundle_id "$path")" || return 1
    actual_point="$(plist_value "$path" NSExtension:NSExtensionPointIdentifier)" || return 1
    [[ "$actual_id" == "$expected_id" && "$actual_point" == "$expected_point" ]]
}
app_bundle_is_expected() {
    [[ ! -L "$1" && -d "$1" ]] || return 1
    [[ "$(bundle_id "$1")" == "$APP_ID" ]]
}
# macOS purges old /tmp files but keeps their folders, leaving registered bundles without any Info.plist.
# Such a shell has no identity of its own, so the exact-ID registry record decides, as for a missing path.
bundle_is_emptied() {
    [[ -d "$1" && ! -L "$1" && ! -e "$1/Contents/Info.plist" && ! -L "$1/Contents/Info.plist" ]]
}
canonical_keep_is_expected() {
    app_bundle_is_expected "$1" \
        && extension_is_expected "$1/Contents/PlugIns/GlimtPreview.appex" "$PREVIEW_ID" "$PREVIEW_POINT" \
        && extension_is_expected "$1/Contents/PlugIns/GlimtThumbnail.appex" "$THUMBNAIL_ID" "$THUMBNAIL_POINT"
}

if [[ "$ALL" == 1 ]]; then
    [[ "$MODE" == clean ]] || fail '--all is only valid with --clean' 2
    [[ "$KEEP_WAS_SET" == 0 ]] || fail 'choose either --keep or --all' 2
fi
if [[ "$MODE" != scan ]]; then
    [[ "$KEEP_WAS_SET" == 1 || "$ALL" == 1 ]] || fail '--keep (or --all with --clean) is required before any registration changes' 2
    [[ "$ALL" == 1 ]] || canonical_keep_is_expected "$KEEP" || fail "--keep must be a readable, non-symlinked $APP_ID app with the expected Preview and Thumbnail bundles: $KEEP" 2
    if "$PGREP" -x Glimt >/dev/null 2>&1; then
        fail 'quit Glimt before changing registrations or moving app bundles' 2
    fi
fi

EVIDENCE_ROOT="${GLIMT_CLEANUP_EVIDENCE_ROOT:-${TMPDIR:-/tmp}}"
[[ -d "$EVIDENCE_ROOT" && -w "$EVIDENCE_ROOT" ]] || fail 'evidence directory is not writable' 2
EVIDENCE="$(mktemp -d "$EVIDENCE_ROOT/glimt-cleanup.$(date +%Y%m%d-%H%M%S).XXXXXX")" || fail 'could not create evidence directory'
printf 'Evidence: %s\n' "$EVIDENCE"

snapshot() {
    local phase="$1"
    "$LSREGISTER" -dump >"$EVIDENCE/launchservices-$phase.txt" 2>"$EVIDENCE/launchservices-$phase.err" || return 1
    "$PLUGINKIT" -m -A -D -vv -i "$PREVIEW_ID" >"$EVIDENCE/preview-$phase.txt" 2>"$EVIDENCE/preview-$phase.err" || return 1
    "$PLUGINKIT" -m -A -D -vv -i "$THUMBNAIL_ID" >"$EVIDENCE/thumbnail-$phase.txt" 2>"$EVIDENCE/thumbnail-$phase.err" || return 1
}

# The registry dump is block based. Keep only bundle records whose own identifier is exact.
parse_ls_apps() {
    awk -v wanted="$APP_ID" '
        function emit() { if (kind == "bundle" && identifier == wanted && path != "") print path }
        /^-{40,}$/ { emit(); kind=""; identifier=""; path=""; next }
        /^bundle id:/ { kind="bundle" }
        /^plugin id:/ { kind="plugin" }
        /^[[:space:]]*identifier:[[:space:]]*/ {
            value=$0; sub(/^[[:space:]]*identifier:[[:space:]]*/, "", value); sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", value); identifier=value
        }
        /^[[:space:]]*path:[[:space:]]*/ {
            value=$0; sub(/^[[:space:]]*path:[[:space:]]*/, "", value); sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", value); path=value
        }
        END { emit() }
    ' "$1" | LC_ALL=C sort -u
}

# PlugInKit is queried by an exact ID, and both its record ID and extension point are checked.
parse_plugin_paths() {
    local listing="$1" wanted="$2" expected_point="$3"
    awk -v wanted="$wanted" -v expected="$expected_point" '
        function emit() {
            if (active && record_id == wanted && point == expected && path != "") print path
        }
        function clear_record() {
            active=0; record_id=""; point=""; path=""
        }
        {
            line=$0; sub(/^[[:space:]]+/, "", line)
            if (line ~ /^-{40,}$/) { emit(); clear_record(); next }
            if (line ~ /^[+?!=~-][[:space:]]+/) {
                emit(); clear_record()
                sub(/^[+?!=~-][[:space:]]+/, "", line)
                header_id=line
                sub(/[[:space:]].*$/, "", header_id)
                sub(/\(.*/, "", header_id)
                active=1
                if (header_id == wanted) record_id=header_id
                next
            }
            if (!active) next
            if ($0 ~ /^[[:space:]]*[Ii]dentifier = /) {
                explicit_id=$0
                sub(/^[[:space:]]*[Ii]dentifier = /, "", explicit_id)
                if (explicit_id != wanted) record_id=""
                next
            }
            if ($0 ~ /^[[:space:]]*[Pp]ath = /) {
                path=$0; sub(/^[[:space:]]*[Pp]ath = /, "", path); next
            }
            if ($0 ~ /^[[:space:]]*SDK = /) {
                point=$0; sub(/^[[:space:]]*SDK = /, "", point); next
            }
        }
        END { emit() }
    ' "$listing" | LC_ALL=C sort -u
}

launchservices_record_remains() {
    local app="$1" dump="$EVIDENCE/check-ls-$$.txt" paths="$EVIDENCE/check-ls-paths-$$.txt"
    "$LSREGISTER" -dump >"$dump" 2>/dev/null || return 0
    parse_ls_apps "$dump" >"$paths" || return 0
    contains_line "$paths" "$app"
}

plugin_record_remains() {
    local kind="$1" extension="$2"
    local listing="$EVIDENCE/check-plugin-$$-$kind.txt"
    local paths="$EVIDENCE/check-plugin-paths-$$-$kind.txt" identifier point
    if [[ "$kind" == preview ]]; then identifier="$PREVIEW_ID"; point="$PREVIEW_POINT"
    else identifier="$THUMBNAIL_ID"; point="$THUMBNAIL_POINT"; fi
    "$PLUGINKIT" -m -A -D -vv -i "$identifier" >"$listing" 2>/dev/null || return 0
    parse_plugin_paths "$listing" "$identifier" "$point" >"$paths" || return 0
    contains_line "$paths" "$extension"
}

snapshot before || fail 'could not capture registry state; no changes made'
parse_ls_apps "$EVIDENCE/launchservices-before.txt" >"$EVIDENCE/ls-apps.txt"
parse_plugin_paths "$EVIDENCE/preview-before.txt" "$PREVIEW_ID" "$PREVIEW_POINT" >"$EVIDENCE/preview-paths.txt"
parse_plugin_paths "$EVIDENCE/thumbnail-before.txt" "$THUMBNAIL_ID" "$THUMBNAIL_POINT" >"$EVIDENCE/thumbnail-paths.txt"

: >"$EVIDENCE/candidates.txt"
cat "$EVIDENCE/ls-apps.txt" "$EVIDENCE/preview-paths.txt" "$EVIDENCE/thumbnail-paths.txt" >>"$EVIDENCE/candidates.txt"
if [[ -n "$MDFIND" && -x "$MDFIND" ]]; then
    "$MDFIND" "kMDItemCFBundleIdentifier == '$APP_ID'" 2>"$EVIDENCE/mdfind.err" \
        | while IFS= read -r path; do [[ "$path" == *.app ]] && printf '%s\n' "$path"; done \
        >>"$EVIDENCE/candidates.txt" || true
fi

if [[ "${GLIMT_CLEANUP_TEST_MODE:-0}" == 1 ]]; then
    SCAN_ROOTS=()
else
    SCAN_ROOTS=(/Applications "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" \
        "$HOME/Library/Developer/Xcode/DerivedData" "$PWD")
fi
# The ${a[@]+...} form keeps empty arrays safe under `set -u` in macOS /bin/bash 3.2.
SCAN_ROOTS+=(${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"})
for root in ${SCAN_ROOTS[@]+"${SCAN_ROOTS[@]}"}; do
    if [[ ! -d "$root" || -L "$root" ]]; then
        printf 'NOTICE search root unavailable or symlinked: %s\n' "$root"
        continue
    fi
    if [[ ! -r "$root" || ! -x "$root" ]]; then
        printf 'NOTICE search root not readable: %s\n' "$root"
        continue
    fi
    find -P "$root" -type d -iname 'glimt*.app' -prune -print 2>>"$EVIDENCE/find.err" \
        >>"$EVIDENCE/candidates.txt" || printf 'NOTICE search incomplete under: %s\n' "$root"
done
[[ -z "$KEEP" ]] || printf '%s\n' "$KEEP" >>"$EVIDENCE/candidates.txt"
LC_ALL=C sort -u "$EVIDENCE/candidates.txt" -o "$EVIDENCE/candidates.txt"

if [[ -n "$KEEP" ]]; then printf '\nCanonical app selected by --keep: %s\n' "$KEEP"
elif [[ "$ALL" == 1 ]]; then printf '\nNo canonical app: --all unregisters every verified Glimt copy.\n'
else printf '\nNo canonical app selected (pass --keep to mark one).\n'; fi
printf '\n%-18s %-10s %-7s %-8s %-8s %s\n' STATUS VERSION LS PREVIEW THUMBNAIL PATH
printf '%s\n' '------------------------------------------------------------------------------------------------'
: >"$EVIDENCE/actionable-apps.txt"
while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    status='not-registered'; version='-'; lsstatus='no'; previewstatus='no'; thumbnailstatus='no'
    if [[ -L "$app" ]]; then
        printf '%-18s %-10s %-7s %-8s %-8s %s\n' 'SYMLINK/SKIP' - - - - "$app"
        continue
    fi
    if [[ -e "$app" ]] && ! bundle_is_emptied "$app"; then
        if [[ ! -d "$app" || ! -r "$app/Contents/Info.plist" ]]; then
            printf '%-18s %-10s %-7s %-8s %-8s %s\n' 'UNREADABLE/SKIP' - - - - "$app"
            continue
        fi
        actual_id="$(bundle_id "$app")" || {
            printf '%-18s %-10s %-7s %-8s %-8s %s\n' 'IDENTITY UNKNOWN' - - - - "$app"
            continue
        }
        if [[ "$actual_id" != "$APP_ID" ]]; then
            printf '%-18s %-10s %-7s %-8s %-8s %s\n' 'ID MISMATCH/SKIP' - - - - "$app"
            continue
        fi
        status='verified-copy'
        version="$(bundle_value "$app" CFBundleShortVersionString)"
    elif contains_line "$EVIDENCE/ls-apps.txt" "$app" \
        || contains_line "$EVIDENCE/preview-paths.txt" "$app/Contents/PlugIns/GlimtPreview.appex" \
        || contains_line "$EVIDENCE/thumbnail-paths.txt" "$app/Contents/PlugIns/GlimtThumbnail.appex"; then
        status='stale-exact-record'
    else
        continue
    fi
    [[ -n "$KEEP" && "$app" == "$KEEP" ]] && status='CANONICAL KEEP'
    contains_line "$EVIDENCE/ls-apps.txt" "$app" && lsstatus='yes'
    contains_line "$EVIDENCE/preview-paths.txt" "$app/Contents/PlugIns/GlimtPreview.appex" && previewstatus='yes'
    contains_line "$EVIDENCE/thumbnail-paths.txt" "$app/Contents/PlugIns/GlimtThumbnail.appex" && thumbnailstatus='yes'
    printf '%s\n' "$app" >>"$EVIDENCE/actionable-apps.txt"
    printf '%-18s %-10s %-7s %-8s %-8s %s\n' "$status" "$version" "$lsstatus" "$previewstatus" "$thumbnailstatus" "$app"
done <"$EVIDENCE/candidates.txt"

printf '\nPlugInKit Preview records (identity and extension point verified):\n'
cat "$EVIDENCE/preview-before.txt"
printf '\nPlugInKit Thumbnail records (identity and extension point verified):\n'
cat "$EVIDENCE/thumbnail-before.txt"

if [[ "$MODE" == scan ]]; then
    printf '\nSCAN ONLY. No changes made.\n'
    exit 0
fi

if [[ "$MODE" == trash ]]; then
    printf '\n--trash moves eligible verified duplicate app bundles to ~/.Trash after unregistering them.\n'
    printf 'Only direct Glimt*.app children of /Applications, ~/Applications or ~/Downloads qualify.\n'
    printf 'Type exactly TRASH to approve, anything else cancels: '
    IFS= read -r confirmation || confirmation=''
    [[ "$confirmation" == TRASH ]] || { printf 'Cancelled; no changes made.\n'; exit 0; }
fi

log_action() { printf '%s\n' "$*" | tee -a "$EVIDENCE/actions.txt"; }
failures=0
: >"$EVIDENCE/failed-apps.txt"

# Remove only LaunchServices records whose registry identifier was exactly com.glimt.app.
while IFS= read -r app; do
    [[ -n "$app" && "$app" != "$KEEP" ]] || continue
    contains_line "$EVIDENCE/ls-apps.txt" "$app" || continue
    if [[ -e "$app" || -L "$app" ]]; then
        bundle_is_emptied "$app" || app_bundle_is_expected "$app" \
            || { log_action "SKIP changed/unverified app identity: $app"; continue; }
    fi
    if "$LSREGISTER" -u "$app" >>"$EVIDENCE/actions.log" 2>&1; then
        log_action "LaunchServices unregistered verified $APP_ID: $app"
    else
        if launchservices_record_remains "$app"; then
            log_action "WARNING LaunchServices unregister failed; record remains: $app"
            printf '%s\n' "$app" >>"$EVIDENCE/failed-apps.txt"
            failures=$((failures + 1))
        else
            log_action "NOTICE LaunchServices reported an error, but the exact Glimt record is absent: $app"
        fi
    fi
done <"$EVIDENCE/ls-apps.txt"

unregister_extensions() {
    local kind="$1" identifier="$2" point="$3" list="$4" extension app
    while IFS= read -r extension; do
        [[ -n "$extension" ]] || continue
        case "$kind:$extension" in
            preview:*/Contents/PlugIns/GlimtPreview.appex) ;;
            thumbnail:*/Contents/PlugIns/GlimtThumbnail.appex) ;;
            *) continue ;;
        esac
        app="${extension%%/Contents/PlugIns/*}"
        [[ "$app" != "$KEEP" ]] || continue
        if { [[ -e "$extension" || -L "$extension" ]]; } && ! bundle_is_emptied "$extension"; then
            extension_is_expected "$extension" "$identifier" "$point" \
                || {
                    log_action "WARNING preserved extension with changed/unverified identity: $extension"
                    printf '%s\n' "$app" >>"$EVIDENCE/failed-apps.txt"
                    failures=$((failures + 1))
                    continue
                }
            if { [[ -e "$app" || -L "$app" ]]; } && ! bundle_is_emptied "$app"; then
                app_bundle_is_expected "$app" \
                    || {
                        log_action "WARNING preserved extension under changed/unverified app: $extension"
                        printf '%s\n' "$app" >>"$EVIDENCE/failed-apps.txt"
                        failures=$((failures + 1))
                        continue
                    }
            fi
        fi
        if "$PLUGINKIT" -r "$extension" >>"$EVIDENCE/actions.log" 2>&1; then
            log_action "PlugInKit unregistered verified $identifier ($point): $extension"
        else
            if plugin_record_remains "$kind" "$extension"; then
                log_action "WARNING PlugInKit unregister failed; record remains: $extension"
                printf '%s\n' "$app" >>"$EVIDENCE/failed-apps.txt"
                failures=$((failures + 1))
            else
                log_action "NOTICE PlugInKit reported an error, but the exact Glimt record is absent: $extension"
            fi
        fi
    done <"$list"
}
unregister_extensions preview "$PREVIEW_ID" "$PREVIEW_POINT" "$EVIDENCE/preview-paths.txt"
unregister_extensions thumbnail "$THUMBNAIL_ID" "$THUMBNAIL_POINT" "$EVIDENCE/thumbnail-paths.txt"

if [[ "$MODE" == trash ]]; then
    while IFS= read -r app; do
        [[ -n "$app" && "$app" != "$KEEP" ]] || continue
        contains_line "$EVIDENCE/failed-apps.txt" "$app" && { log_action "PRESERVED after unregister failure: $app"; continue; }
        app_bundle_is_expected "$app" || continue
        if [[ -d "$app/Contents/PlugIns/GlimtPreview.appex" ]] \
            && ! extension_is_expected "$app/Contents/PlugIns/GlimtPreview.appex" "$PREVIEW_ID" "$PREVIEW_POINT"; then
            log_action "PRESERVED app with unverified Preview extension: $app"; continue
        fi
        if [[ -d "$app/Contents/PlugIns/GlimtThumbnail.appex" ]] \
            && ! extension_is_expected "$app/Contents/PlugIns/GlimtThumbnail.appex" "$THUMBNAIL_ID" "$THUMBNAIL_POINT"; then
            log_action "PRESERVED app with unverified Thumbnail extension: $app"; continue
        fi
        parent="$(dirname "$app")"
        case "$parent" in /Applications|"$HOME/Applications"|"$HOME/Downloads") ;; *) continue ;; esac
        name="$(basename "$app")"
        case "$name" in [Gg][Ll][Ii][Mm][Tt]*.app) ;; *) continue ;; esac
        case "$name" in *[Bb][Aa][Cc][Kk][Uu][Pp]*|*[Aa][Rr][Cc][Hh][Ii][Vv][Ee]*|*[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]*|*[Bb][Uu][Ii][Ll][Dd]*|*[Dd][Ee][Rr][Ii][Vv][Ee][Dd][Dd][Aa][Tt][Aa]*)
            log_action "PRESERVED backup/build-like app name: $app"; continue ;;
        esac
        trash="$HOME/.Trash"
        [[ -d "$trash" && -w "$trash" && -w "$parent" ]] || { log_action "PRESERVED (Trash or source parent is not writable): $app"; continue; }
        base="${name%.app}"
        target="$trash/${base}-glimt-cleanup-$(date +%Y%m%d-%H%M%S)-$$.app"
        suffix=0
        while [[ -e "$target" || -L "$target" ]]; do
            suffix=$((suffix + 1))
            target="$trash/${base}-glimt-cleanup-$(date +%Y%m%d-%H%M%S)-$$-$suffix.app"
        done
        if mv -n "$app" "$target" >>"$EVIDENCE/actions.log" 2>&1 && [[ -d "$target" && ! -e "$app" ]]; then
            log_action "MOVED TO TRASH: $app => $target"
        else
            log_action "WARNING app was not moved to Trash: $app"
            failures=$((failures + 1))
        fi
    done <"$EVIDENCE/actionable-apps.txt"
fi

if [[ -n "$QLMANAGE" && -x "$QLMANAGE" ]]; then
    "$QLMANAGE" -r >>"$EVIDENCE/actions.log" 2>&1 \
        || { log_action 'WARNING Quick Look cache refresh failed'; failures=$((failures + 1)); }
fi
snapshot after || { log_action 'WARNING post-change registry snapshot failed'; failures=$((failures + 1)); }
log_action "Completed with $failures warning(s). Evidence: $EVIDENCE"
log_action 'Registry state does not verify which provider Finder selected for a file.'
[[ "$ALL" == 0 ]] || log_action 'No Glimt copy is registered now; launch the Glimt.app you want to use to register it again.'
((failures == 0))
