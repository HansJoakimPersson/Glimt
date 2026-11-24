#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE=""
WORK_DIR=""
REQUEST_NUMBER=0
LAST_ELAPSED_MS=0

if [[ "$#" -lt 2 || "$#" -gt 3 || "$1" != "--app-bundle" ]]; then
    printf 'usage: %s --app-bundle <registered-signed-Glimt.app> [real-text-file|--routing-only]\n' "$0" >&2
    printf 'This script never builds, installs, registers, enables, unregisters, or removes an app.\n' >&2
    exit 2
fi
APP_BUNDLE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
EXPECTED_THUMBNAIL_EXECUTABLE="$APP_BUNDLE/Contents/PlugIns/GlimtThumbnail.appex/Contents/MacOS/GlimtThumbnail"
REAL_INPUT="${3:-}"
ROUTING_ONLY=0
if [[ "$REAL_INPUT" == "--routing-only" ]]; then
    ROUTING_ONLY=1
    REAL_INPUT=""
fi

fail() {
    printf 'ql-thumbnail-smoke: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        /bin/rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glimt-ql-thumbnail-smoke.XXXXXX")" \
    || fail "could not create a temporary work directory"
BUILD_LOG="$WORK_DIR/helper-build.log"
UNIFIED_LOG="$WORK_DIR/unified.log"
REQUEST_LOG="$WORK_DIR/request.log"
REQUEST_HELPER="$WORK_DIR/ql-thumbnail-request"

if ! swiftc -parse-as-library "$PROJECT_DIR/scripts/ql-thumbnail-request.swift" -o "$REQUEST_HELPER" >"$BUILD_LOG" 2>&1; then
    tail -n 30 "$BUILD_LOG" >&2
    fail "could not compile the QLThumbnailGenerator request helper"
fi

[[ -d "$APP_BUNDLE/Contents/PlugIns/GlimtThumbnail.appex" ]] || fail "the supplied bundle has no GlimtThumbnail extension"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)" == "com.glimt.app" ]] \
    || fail "the supplied bundle is not com.glimt.app"
codesign --verify --deep --strict "$APP_BUNDLE" || fail "the supplied app bundle is not validly signed"
APP_THUMBNAIL_PATH="$APP_BUNDLE/Contents/PlugIns/GlimtThumbnail.appex"
pluginkit -m -A -D -vv -i com.glimt.app.thumbnail >"$WORK_DIR/pluginkit-thumbnail.txt" 2>&1 \
    || fail "could not inspect Glimt Thumbnail registration"
grep -Fq "Path = $APP_THUMBNAIL_PATH" "$WORK_DIR/pluginkit-thumbnail.txt" \
    || fail "the supplied Thumbnail extension is not registered; build it with Xcode Sign to Run Locally first"
grep -Fq 'SDK = com.apple.quicklook.thumbnail' "$WORK_DIR/pluginkit-thumbnail.txt" \
    || fail "the registered Glimt extension does not declare the Quick Look thumbnail extension point"
awk 'index($0, "com.glimt.app.thumbnail") && substr($0, 1, 1) == "+" { enabled = 1 } END { exit !enabled }' \
    "$WORK_DIR/pluginkit-thumbnail.txt" || fail "the supplied Thumbnail extension is registered but disabled"

FIXTURE_DIR="$WORK_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"
for fixture in \
    text/plain.txt json/json.json yaml/yaml.yaml xml/xml.xml plist/plist.plist \
    markdown/markdown.md source/swift.swift source/java.java source/c.c \
    source/cpp.cpp source/python.py source/javascript.js source/typescript.ts \
    source/shell.sh data/csv.csv data/tsv.tsv; do
    mkdir -p "$FIXTURE_DIR/$(dirname "$fixture")"
    cp "$PROJECT_DIR/Fixtures/Showcase/$fixture" "$FIXTURE_DIR/$fixture" \
        || fail "could not stage the format fixture"
done
mkdir -p "$FIXTURE_DIR/make-source"
cp "$PROJECT_DIR/Fixtures/Cases/ambiguous/Makefile" "$FIXTURE_DIR/make-source/Makefile" \
    || fail "could not stage the Makefile thumbnail control"

observe_thumbnail_marker() {
    local marker_type="$1" request_token="$2" flags
    /usr/bin/log show --last 2m --style json --info \
        --predicate 'subsystem == "com.glimt.app" AND category == "thumbnail"' \
        >"$UNIFIED_LOG" 2>&1 || fail "could not read privacy-safe thumbnail markers"
    flags="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$UNIFIED_LOG" \
        --token "$request_token" --provider-path "$EXPECTED_THUMBNAIL_EXECUTABLE" \
        --kind thumbnail --expected-type "$marker_type")" \
        || fail "could not correlate the thumbnail request marker"
    read -r _ _ _ matching other_glimt_seen _ <<<"$flags"
    if [[ "$matching" == 1 ]]; then
        marker="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$UNIFIED_LOG" \
            --token "$request_token" --provider-path "$EXPECTED_THUMBNAIL_EXECUTABLE" \
            --kind thumbnail --expected-type "$marker_type" --emit-marker)"
    else
        marker=""
    fi
    printf '%s %s %s\n' "$matching" "$other_glimt_seen" "$marker"
}

run_request() {
    case_name="$1"
    fixture_path="$2"
    expected_type="$3"
    request_mode="$4"
    request_started="$(date '+%Y-%m-%d %H:%M:%S')"
    expected_size="$(stat -f '%z' "$fixture_path")"
    REQUEST_NUMBER=$((REQUEST_NUMBER + 1))
    request_identity="run-${REQUEST_NUMBER}-${case_name}"
    request_token="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
    [[ "$request_token" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "could not create a canonical request token"
    /usr/bin/xattr -w com.glimt.fr005-evidence "$request_token" "$fixture_path" \
        || fail "could not add the test-only correlation token"
    output_path="$WORK_DIR/render-$REQUEST_NUMBER.png"
    request_record="$WORK_DIR/request-$REQUEST_NUMBER.txt"
    marker_type="${5:-unknown}"
    {
        printf 'request=%s\n' "$request_identity"
        printf 'type=%s\n' "$expected_type"
        printf 'sizeBytes=%s\n' "$expected_size"
        printf 'token=%s\n' "$request_token"
        printf 'started=%s\n' "$request_started"
        printf 'fixtureIdentity=%s\n' "$case_name"
    } >"$request_record"

    if "$REQUEST_HELPER" "$fixture_path" "$output_path" >"$REQUEST_LOG" 2>&1; then
        request_status=0
    else
        request_status=$?
    fi

    marker_line=""
    other_glimt_seen=0
    marker_attempt_limit=8
    [[ "$request_mode" == "probe" ]] || marker_attempt_limit=40
    for ((attempt = 0; attempt < marker_attempt_limit; attempt++)); do
        observed="$(observe_thumbnail_marker "$marker_type" "$request_token")"
        read -r marker_found other_glimt_seen marker_line <<<"$observed"
        if [[ "$marker_found" == 1 || "$other_glimt_seen" == 1 ]]; then break; fi
        sleep 0.25
    done

    if [[ -z "$marker_line" ]]; then
        if [[ "$request_mode" == "probe" ]]; then
            if [[ "$request_status" -eq 0 ]]; then
                if [[ "$other_glimt_seen" == 1 ]]; then
                    printf 'ql-thumbnail-smoke: PROBE request=%s type=%s provider=other-registered-Glimt-copy image=256x256 nonblank=yes\n' \
                        "$request_identity" "$expected_type"
                else
                    printf 'ql-thumbnail-smoke: PROBE request=%s type=%s provider=non-Glimt image=256x256 nonblank=yes\n' \
                        "$request_identity" "$expected_type"
                fi
            else
                error_summary="$(tail -n 1 "$REQUEST_LOG" | tr '\n' ' ')"
                printf 'ql-thumbnail-smoke: PROBE request=%s type=%s provider=error result=%s\n' \
                    "$request_identity" "$expected_type" "${error_summary:-no thumbnail representation}"
            fi
            runtime_provenance="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$UNIFIED_LOG" \
                --token "$request_token" --kind thumbnail --emit-runtime-provenance)"
            if [[ -n "$runtime_provenance" ]]; then
                while IFS= read -r marker; do printf 'providerProvenance=%s\n' "$marker"; done <<<"$runtime_provenance"
            fi
            if [[ "$other_glimt_seen" == 1 ]]; then
                observed_provider="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$UNIFIED_LOG" \
                    --token "$request_token" --kind thumbnail --emit-observed-provider)"
                if [[ -n "$observed_provider" ]]; then
                    while IFS= read -r executable; do printf 'observedProviderExecutable=%s\n' "$executable"; done <<<"$observed_provider"
                fi
            fi
            return 0
        fi
        tail -n 10 "$REQUEST_LOG" >&2
        [[ "$other_glimt_seen" == 1 ]] \
            && fail "another registered Glimt copy handled $request_identity; exact bundle attribution failed"
        fail "no exact-bundle FR005 thumbnail-provider marker matched $request_identity"
    fi

    if [[ "$request_mode" == "probe" ]]; then
        printf 'ql-thumbnail-smoke: PROBE request=%s type=%s provider=Glimt\n' \
            "$request_identity" "$expected_type"
        printf 'matchedMarker=%s\n' "$marker_line" >>"$request_record"
        printf '%s\n' "$marker_line"
        runtime_provenance="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$UNIFIED_LOG" \
            --token "$request_token" --kind thumbnail --emit-runtime-provenance)"
        if [[ -n "$runtime_provenance" ]]; then
            while IFS= read -r marker; do printf 'providerProvenance=%s\n' "$marker"; done <<<"$runtime_provenance"
        fi
        observed_provider="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$UNIFIED_LOG" \
            --token "$request_token" --kind thumbnail --emit-observed-provider)"
        if [[ -n "$observed_provider" ]]; then
            while IFS= read -r executable; do printf 'observedProviderExecutable=%s\n' "$executable"; done <<<"$observed_provider"
        fi
        return 0
    fi

    [[ "$request_status" -eq 0 ]] || {
        tail -n 10 "$REQUEST_LOG" >&2
        fail "QLThumbnailGenerator failed for request $request_identity"
    }
    [[ -s "$output_path" ]] || fail "request $request_identity produced no PNG"

    marker_fields="${marker_line#*FR005_PROVIDER_V1 }"
    marker_pattern="^FR005_PROVIDER_V1 token=${request_token} provider=thumbnail phase=reply-prepared type=${marker_type} confidence=[0-9]+\\.[0-9][0-9] scores=[0-9.,]+ sampleBytes=([0-9]+) complete=[01] elapsedMs=([0-9]+)$"
    [[ "$marker_fields" =~ $marker_pattern ]] \
        || fail "marker fields did not match the public contract for request $request_identity"
    prefix_bytes="${BASH_REMATCH[1]}"
    LAST_ELAPSED_MS="${BASH_REMATCH[2]}"
    (( prefix_bytes <= 262144 )) \
        || fail "request $request_identity analyzed more than 262144 bytes"

    printf 'ql-thumbnail-smoke: PASS request=%s type=%s sizeBytes=%s prefixBytes=%s elapsedMs=%s PNG=256x256 nonblank=yes\n' \
        "$request_identity" "$expected_type" "$expected_size" "$prefix_bytes" "$LAST_ELAPSED_MS"
    printf 'matchedMarker=%s\n' "$marker_line" >>"$request_record"
    printf '%s\n' "$marker_line"
}

run_request format-text "$FIXTURE_DIR/text/plain.txt" public.plain-text probe text
run_request format-json "$FIXTURE_DIR/json/json.json" public.json probe json
run_request format-yaml "$FIXTURE_DIR/yaml/yaml.yaml" public.yaml probe yaml
run_request format-xml "$FIXTURE_DIR/xml/xml.xml" public.xml probe xml
run_request format-plist "$FIXTURE_DIR/plist/plist.plist" com.apple.property-list probe plist
run_request format-markdown "$FIXTURE_DIR/markdown/markdown.md" net.daringfireball.markdown probe markdown
run_request format-swift "$FIXTURE_DIR/source/swift.swift" public.swift-source probe swift
run_request format-java "$FIXTURE_DIR/source/java.java" com.sun.java-source probe java
run_request format-c "$FIXTURE_DIR/source/c.c" public.c-source probe c
run_request format-cpp "$FIXTURE_DIR/source/cpp.cpp" public.c-plus-plus-source probe cpp
run_request format-python "$FIXTURE_DIR/source/python.py" public.python-script probe python
run_request format-javascript "$FIXTURE_DIR/source/javascript.js" com.netscape.javascript-source probe javascript
run_request format-typescript "$FIXTURE_DIR/source/typescript.ts" com.microsoft.typescript probe typescript
run_request format-shell "$FIXTURE_DIR/source/shell.sh" public.shell-script probe shell
run_request format-csv "$FIXTURE_DIR/data/csv.csv" public.comma-separated-values-text probe csv
run_request format-tsv "$FIXTURE_DIR/data/tsv.tsv" public.tab-separated-values-text probe tsv

# The extensionless Makefile route is Glimt's existing thumbnail control.
run_request make-source "$FIXTURE_DIR/make-source/Makefile" public.make-source probe makefile

REAL_INPUT="${REAL_INPUT:-${FR004_INPUT:-}}"
if [[ -n "$REAL_INPUT" ]]; then
    [[ -f "$REAL_INPUT" && -r "$REAL_INPUT" ]] || fail "real input is not a readable file"
    REAL_FIXTURE="$WORK_DIR/real-input/Makefile"
    mkdir -p "$(dirname "$REAL_FIXTURE")"
    cp "$REAL_INPUT" "$REAL_FIXTURE" || fail "could not stage the real text input as Makefile"
    run_request real-input "$REAL_FIXTURE" public.make-source required makefile
fi

if [[ "$ROUTING_ONLY" -eq 1 ]]; then
    printf 'ql-thumbnail-smoke: FORMAT ROUTING ONLY complete; 16 catalog fixtures and Makefile control requested\n'
    exit 0
fi

LARGE_DIR="$WORK_DIR/large-files"
LARGE_SOURCE="$LARGE_DIR/source/Makefile"
mkdir -p "$(dirname "$LARGE_SOURCE")"
dd if=/dev/zero bs=1048576 count=100 2>/dev/null \
    | tr '\000' 'a' >"$LARGE_SOURCE" || fail "could not generate the 100 MB UTF-8 fixture"
[[ "$(stat -f '%z' "$LARGE_SOURCE")" == "104857600" ]] \
    || fail "generated large-file fixture was not exactly 100 MB"

LARGE_ELAPSED="$WORK_DIR/elapsed-ms.txt"
LARGE_INODES="$WORK_DIR/large-inodes.txt"
: >"$LARGE_ELAPSED"
: >"$LARGE_INODES"
for ((sample = 1; sample <= 20; sample++)); do
    sample_dir="$LARGE_DIR/request-$sample"
    mkdir -p "$sample_dir"
    sample_file="$sample_dir/Makefile"
    cp -c "$LARGE_SOURCE" "$sample_file" \
        || fail "could not create a distinct large-file clone for request $sample"
    sample_header="$(printf 'thumbnail-sample-%02d' "$sample")"
    printf '%-63s\n' "$sample_header" \
        | dd of="$sample_file" bs=64 count=1 conv=notrunc 2>/dev/null \
        || fail "could not give large-file request $sample unique text content"
    [[ "$(stat -f '%z' "$sample_file")" == "104857600" ]] \
        || fail "large-file request $sample changed the 100 MB fixture size"
    sample_inode="$(stat -f '%i' "$sample_file")"
    if grep -Fxq "$sample_inode" "$LARGE_INODES"; then
        fail "large-file request $sample reused an inode and could hit the thumbnail cache"
    fi
    printf '%s\n' "$sample_inode" >>"$LARGE_INODES"
    run_request "large-$sample" "$sample_file" public.make-source required makefile
    printf '%s\n' "$LAST_ELAPSED_MS" >>"$LARGE_ELAPSED"
done

awk '
    { values[NR] = $1 }
    END {
        if (NR < 20) exit 1
        for (i = 1; i <= NR; i++) {
            for (j = i + 1; j <= NR; j++) {
                if (values[j] < values[i]) {
                    temporary = values[i]
                    values[i] = values[j]
                    values[j] = temporary
                }
            }
        }
        rank = int((95 * NR + 99) / 100)
        printf "ql-thumbnail-smoke: large-file samples=%d sizeBytes=104857600 prefixBytes<=262144 p95Rank=%d p95ElapsedMs=%d\n", NR, rank, values[rank]
        if (values[rank] >= 100) exit 2
    }
' "$LARGE_ELAPSED" || fail "100 MB thumbnail nearest-rank p95 did not meet the under-100 ms requirement"
