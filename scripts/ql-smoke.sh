#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE=""
FORMAT_ROUTING_ONLY=0
ROUTING_TIMEOUT_SECONDS=12
FIXTURE_UTF8=""
FIXTURE_UTF16=""
FIXTURE_CP1252=""
FIXTURE_BINARY=""
FAIL_COUNT=0
PASS_COUNT=0
EXTERNAL_COUNT=0
PLATFORM_COUNT=0
OTHER_GLIMT_COUNT=0
CASE_COUNT=0
ACTIVE_FIXTURE=""
ATTRIBUTE_PRESENT=0
REQUEST_TOKEN=""
EVIDENCE_ATTRIBUTE="com.glimt.fr005-evidence"
WORK_DIR=""
QL_PID=""

fail() {
    printf 'ql-smoke: FAIL infrastructure=%s\n' "$1" >&2
    exit 1
}

# This function deliberately distinguishes a failed Glimt request from a provider not invoked.
classify_preview() {
    local infrastructure_error="$1" begin_seen="$2" final_seen="$3" render_seen="$4" external_seen="$5" other_glimt_seen="$6"
    if [[ "$infrastructure_error" -ne 0 ]]; then
        printf 'FAIL\n'
    elif [[ "$other_glimt_seen" -eq 1 ]]; then
        printf 'BLOCKED_OTHER_GLIMT_PROVIDER\n'
    elif [[ "$begin_seen" -eq 1 && "$final_seen" -eq 1 && "$render_seen" -eq 1 ]]; then
        printf 'PASS\n'
    elif [[ "$begin_seen" -eq 1 || "$final_seen" -eq 1 ]]; then
        printf 'FAIL\n'
    elif [[ "$external_seen" -eq 1 ]]; then
        printf 'BLOCKED_EXTERNAL_PROVIDER\n'
    else
        printf 'BLOCKED_PLATFORM_ROUTING\n'
    fi
}

observe_request_markers() {
    local flags
    flags="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$RENDER_LOG" \
        --token "$REQUEST_TOKEN" --provider-path "$EXPECTED_PREVIEW_EXECUTABLE" --kind preview)" \
        || return 1
    read -r begin_seen final_seen render_seen _ other_glimt_seen _ <<<"$flags"
}

if [[ "${1:-}" == "--test-classification" ]]; then
    while read -r infrastructure begin final metadata external other_glimt expected; do
        actual="$(classify_preview "$infrastructure" "$begin" "$final" "$metadata" "$external" "$other_glimt")"
        [[ "$actual" == "$expected" ]] || fail "classification expected=$expected actual=$actual"
    done <<'CASES'
0 1 1 1 0 0 PASS
0 1 1 1 1 0 PASS
0 1 0 0 1 0 FAIL
0 1 1 0 0 0 FAIL
0 0 1 1 0 0 FAIL
0 0 0 0 1 0 BLOCKED_EXTERNAL_PROVIDER
0 0 0 0 0 0 BLOCKED_PLATFORM_ROUTING
0 0 0 0 0 1 BLOCKED_OTHER_GLIMT_PROVIDER
1 1 1 1 0 0 FAIL
1 0 0 0 1 0 FAIL
CASES
    printf 'ql-smoke: classification tests 10/10 PASS\n'
    exit 0
fi

if [[ ( "$#" -ne 2 && "$#" -ne 3 ) || "$1" != "--app-bundle" ]]; then
    printf 'usage: %s --app-bundle <registered-signed-Glimt.app> [--routing-only]\n' "$0" >&2
    printf 'The smoke check never builds, installs, registers, enables, or removes an app.\n' >&2
    exit 2
fi
APP_BUNDLE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
EXPECTED_PREVIEW_EXECUTABLE="$APP_BUNDLE/Contents/PlugIns/GlimtPreview.appex/Contents/MacOS/GlimtPreview"
if [[ "${3:-}" == "--routing-only" ]]; then
    FORMAT_ROUTING_ONLY=1
    ROUTING_TIMEOUT_SECONDS=4
fi

# Preserve even pre-existing binary attribute values. Only this existing Debug correlation
# attribute is touched; fixture content and all other attributes remain unchanged.
restore_fixture_attribute() {
    [[ -n "$ACTIVE_FIXTURE" ]] || return 0
    if [[ "$ATTRIBUTE_PRESENT" -eq 1 ]]; then
        local original_hex
        original_hex="$(cat "$WORK_DIR/original-attribute.hex")" || return 1
        /usr/bin/xattr -wx "$EVIDENCE_ATTRIBUTE" "$original_hex" "$ACTIVE_FIXTURE" || return 1
    else
        /usr/bin/xattr -d "$EVIDENCE_ATTRIBUTE" "$ACTIVE_FIXTURE" || return 1
    fi
    ACTIVE_FIXTURE=""
    REQUEST_TOKEN=""
}

prepare_fixture_attribute() {
    local fixture="$1"
    [[ -f "$fixture" ]] || return 1
    /usr/bin/xattr "$fixture" >"$WORK_DIR/attribute-names" || return 1
    ATTRIBUTE_PRESENT=0
    if grep -Fxq "$EVIDENCE_ATTRIBUTE" "$WORK_DIR/attribute-names"; then
        /usr/bin/xattr -px "$EVIDENCE_ATTRIBUTE" "$fixture" >"$WORK_DIR/original-attribute.hex" || return 1
        ATTRIBUTE_PRESENT=1
    else
        [[ "$?" -eq 1 ]] || return 1
    fi
    REQUEST_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')" || return 1
    ACTIVE_FIXTURE="$fixture"
    /usr/bin/xattr -w "$EVIDENCE_ATTRIBUTE" "$REQUEST_TOKEN" "$fixture" || return 1
}

cleanup() {
    if ! restore_fixture_attribute; then
        printf 'ql-smoke: FAIL infrastructure=fixture-attribute-restore; backup retained in %s\n' "$WORK_DIR" >&2
        # Never delete the saved original value when restoration failed.
        trap - EXIT
        exit 1
    fi
    if [[ -n "$QL_PID" ]] && kill -0 "$QL_PID" 2>/dev/null; then
        kill "$QL_PID" 2>/dev/null || true
        wait "$QL_PID" 2>/dev/null || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        /bin/rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glimt-ql-smoke.XXXXXX")" \
    || fail "could not create a temporary work directory"
QUICKLOOK_LOG="$WORK_DIR/qlmanage.log"
RENDER_LOG="$WORK_DIR/render.log"
[[ -d "$APP_BUNDLE/Contents/PlugIns/GlimtPreview.appex" ]] \
    || fail "the supplied bundle has no GlimtPreview extension"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)" == "com.glimt.app" ]] \
    || fail "the supplied bundle is not com.glimt.app"
codesign --verify --deep --strict "$APP_BUNDLE" \
    || fail "the supplied app bundle is not validly signed"

FIXTURE_UTF8="$PROJECT_DIR/Fixtures/Cases/json/valid/simple.json"
FIXTURE_UTF16="$PROJECT_DIR/Fixtures/Cases/json/valid/utf16le.json"
FIXTURE_CP1252="$PROJECT_DIR/Fixtures/Cases/json/valid/windows1252.json"
FIXTURE_BINARY="$PROJECT_DIR/Fixtures/Cases/binary/payload.json"
FIXTURE_YAML="$PROJECT_DIR/Fixtures/Cases/yaml/valid/multi-document.yaml"
FIXTURE_MAKEFILE="$PROJECT_DIR/Fixtures/Cases/ambiguous/Makefile"
FIXTURE_DOCKERFILE="$PROJECT_DIR/Fixtures/Cases/ambiguous/Dockerfile"
FIXTURE_ENV="$PROJECT_DIR/Fixtures/Cases/ambiguous/.env"
FIXTURE_ENV_LOCAL="$PROJECT_DIR/Fixtures/Cases/ambiguous/.env.local"
FIXTURE_GITIGNORE="$PROJECT_DIR/Fixtures/Cases/ambiguous/.gitignore"
FIXTURE_EXTENSIONLESS_TEXT="$PROJECT_DIR/Fixtures/Cases/text/extensionless"
FIXTURE_EXTENSIONLESS_BINARY="$PROJECT_DIR/Fixtures/Cases/binary/extensionless"
FIXTURE_TEXT="$PROJECT_DIR/Fixtures/Showcase/text/plain.txt"
FIXTURE_C="$PROJECT_DIR/Fixtures/Showcase/source/c.c"
FIXTURE_CPP="$PROJECT_DIR/Fixtures/Showcase/source/cpp.cpp"
FIXTURE_JAVASCRIPT="$PROJECT_DIR/Fixtures/Showcase/source/javascript.js"
FIXTURE_CSV="$PROJECT_DIR/Fixtures/Showcase/data/csv.csv"
FIXTURE_TSV="$PROJECT_DIR/Fixtures/Showcase/data/tsv.tsv"

APP_PREVIEW_PATH="$APP_BUNDLE/Contents/PlugIns/GlimtPreview.appex"

inspect_extension_registration() {
    local extension_id="$1" extension_point="$2" extension_path="$3"
    local check_status
    if python3 "$PROJECT_DIR/scripts/ql-registration-check.py" \
        --query --bundle-path "$extension_path" \
        --bundle-identifier "$extension_id" --extension-point "$extension_point"; then
        return 0
    else
        check_status=$?
        if [[ "$check_status" -eq 20 ]]; then
            printf 'ql-smoke: FAIL infrastructure=pluginkit-inspection extension=%s\n' "$extension_id" >&2
        else
            printf 'ql-smoke: FAIL registration-check extension=%s status=%s\n' "$extension_id" "$check_status" >&2
        fi
        exit 1
    fi
}

inspect_extension_registration com.glimt.app.preview com.apple.quicklook.preview "$APP_PREVIEW_PATH"
inspect_extension_registration com.glimt.app.thumbnail com.apple.quicklook.thumbnail \
    "$APP_BUNDLE/Contents/PlugIns/GlimtThumbnail.appex"

check_qlmanage_status() {
    [[ -n "$QL_PID" ]] || return 0
    if ! kill -0 "$QL_PID" 2>/dev/null; then
        if wait "$QL_PID"; then
            QLMANAGE_STATUS=0
        else
            QLMANAGE_STATUS=$?
        fi
        QL_PID=""
    fi
}

# Marker recognition ignores stale Glimt processes and previous requests, including requests
# sharing the same coarse wall-clock timestamp. The renderer event must occur between this token's
# begin and successful display marker; private file metadata remains redacted by Unified Logging.

observe_external_markdown_provider() {
    # A running competitor does not prove it handled this request. Attribute only using
    # a correlated provider log marker; otherwise retain BLOCKED_PLATFORM_ROUTING.
    return 0
}

run_quicklook_fixture() {
    # shellcheck disable=SC2034  # callers still pass the legacy marker; e4-log-marker.py now decides
    local case_name="$1" fixture_path="$2" expected_marker="$3" case_mode="${4:-platform}"
    local request_fixture infrastructure_error=0 begin_seen=0 final_seen=0 render_seen=0 external_seen=0 other_glimt_seen=0
    local deadline outcome reason runtime_provenance observed_provider
    CASE_COUNT=$((CASE_COUNT + 1))
    request_fixture="$WORK_DIR/fixtures/$CASE_COUNT/$(basename "$fixture_path")"
    mkdir -p "$(dirname "$request_fixture")"
    if ! cp "$fixture_path" "$request_fixture"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'ql-smoke: FAIL case=%s reason=infrastructure-fixture-copy\n' "$case_name"
        return
    fi
    if ! prepare_fixture_attribute "$request_fixture"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'ql-smoke: FAIL case=%s reason=infrastructure-fixture-correlation\n' "$case_name"
        restore_fixture_attribute || fail "could not restore the fixture correlation attribute"
        return
    fi
    QLMANAGE_STATUS="running"
    qlmanage -p "$request_fixture" >"$QUICKLOOK_LOG" 2>&1 &
    QL_PID="$!"
    # Use elapsed time, not a fixed number of expensive log queries, to bound routing observation.
    deadline=$((SECONDS + ROUTING_TIMEOUT_SECONDS))
    while true; do
        check_qlmanage_status
        if /usr/bin/log show --style json --info --last 2m \
            --predicate 'subsystem == "com.glimt.app" AND category == "preview"' \
            >"$RENDER_LOG" 2>&1; then
            observe_request_markers || infrastructure_error=1
        else
            infrastructure_error=1
        fi
        if [[ "$case_mode" == "markdown" && "$begin_seen" -eq 0 ]]; then
            observe_external_markdown_provider || infrastructure_error=1
        fi
        if [[ -z "$QL_PID" && "$QLMANAGE_STATUS" != "0" ]]; then infrastructure_error=1; fi
        if [[ "$final_seen" -eq 1 || "$other_glimt_seen" -eq 1 || "$infrastructure_error" -ne 0 || "$SECONDS" -ge "$deadline" ]]; then break; fi
        sleep 0.25
    done
    check_qlmanage_status
    if [[ -n "$QL_PID" ]] && kill -0 "$QL_PID" 2>/dev/null; then
        # Closing our own observation window is intentional, not a successful render assertion.
        if kill "$QL_PID" 2>/dev/null; then
            wait "$QL_PID" 2>/dev/null || true
            QLMANAGE_STATUS=0
        else
            infrastructure_error=1
        fi
    fi
    QL_PID=""
    [[ "$QLMANAGE_STATUS" == "0" ]] || infrastructure_error=1
    runtime_provenance="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$RENDER_LOG" \
        --token "$REQUEST_TOKEN" --kind preview --emit-runtime-provenance)" \
        || infrastructure_error=1
    observed_provider="$(python3 "$PROJECT_DIR/scripts/e4-log-marker.py" "$RENDER_LOG" \
        --token "$REQUEST_TOKEN" --kind preview --emit-observed-provider)" \
        || infrastructure_error=1
    restore_fixture_attribute || infrastructure_error=1
    outcome="$(classify_preview "$infrastructure_error" "$begin_seen" "$final_seen" "$render_seen" "$external_seen" "$other_glimt_seen")"
    case "$outcome" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)); reason="Glimt-request-completed" ;;
        FAIL)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            if [[ "$infrastructure_error" -ne 0 ]]; then reason="infrastructure"; else reason="Glimt-renderer-event-missing"; fi ;;
        BLOCKED_EXTERNAL_PROVIDER) EXTERNAL_COUNT=$((EXTERNAL_COUNT + 1)); reason="competing-Markdown-provider-observed" ;;
        BLOCKED_OTHER_GLIMT_PROVIDER) OTHER_GLIMT_COUNT=$((OTHER_GLIMT_COUNT + 1)); reason="another-registered-Glimt-copy-served-request" ;;
        BLOCKED_PLATFORM_ROUTING) PLATFORM_COUNT=$((PLATFORM_COUNT + 1)); reason="no-Glimt-request-observed" ;;
    esac
    printf 'ql-smoke: %s case=%s reason=%s begin=%s final=%s rendererEvent=%s\n' \
        "$outcome" "$case_name" "$reason" "$begin_seen" "$final_seen" "$render_seen"
    if [[ -n "$runtime_provenance" ]]; then
        while IFS= read -r marker; do printf 'providerProvenance=%s\n' "$marker"; done <<<"$runtime_provenance"
    fi
    if [[ -n "$observed_provider" ]]; then
        while IFS= read -r executable; do printf 'observedProviderExecutable=%s\n' "$executable"; done <<<"$observed_provider"
    fi
    [[ -z "$ACTIVE_FIXTURE" ]] || fail "could not restore the fixture correlation attribute"
}

if [[ "$FORMAT_ROUTING_ONLY" -eq 1 ]]; then
    run_quicklook_fixture "Format Text" "$PROJECT_DIR/Fixtures/Showcase/text/plain.txt" 'FR002_RENDER'
    run_quicklook_fixture "Format JSON" "$PROJECT_DIR/Fixtures/Showcase/json/json.json" 'FR002_RENDER'
    run_quicklook_fixture "Format YAML" "$PROJECT_DIR/Fixtures/Showcase/yaml/yaml.yaml" 'FR002_RENDER'
    run_quicklook_fixture "Format XML" "$PROJECT_DIR/Fixtures/Showcase/xml/xml.xml" 'FR002_RENDER'
    run_quicklook_fixture "Format plist" "$PROJECT_DIR/Fixtures/Showcase/plist/plist.plist" 'FR002_RENDER'
    run_quicklook_fixture "Format Markdown" "$PROJECT_DIR/Fixtures/Showcase/markdown/markdown.md" 'FR002_RENDER'
    run_quicklook_fixture "Format Swift" "$PROJECT_DIR/Fixtures/Showcase/source/swift.swift" 'FR002_RENDER'
    run_quicklook_fixture "Format Java" "$PROJECT_DIR/Fixtures/Showcase/source/java.java" 'FR002_RENDER'
    run_quicklook_fixture "Format C" "$PROJECT_DIR/Fixtures/Showcase/source/c.c" 'FR002_RENDER'
    run_quicklook_fixture "Format C++" "$PROJECT_DIR/Fixtures/Showcase/source/cpp.cpp" 'FR002_RENDER'
    run_quicklook_fixture "Format Python" "$PROJECT_DIR/Fixtures/Showcase/source/python.py" 'FR002_RENDER'
    run_quicklook_fixture "Format JavaScript" "$PROJECT_DIR/Fixtures/Showcase/source/javascript.js" 'FR002_RENDER'
    run_quicklook_fixture "Format TypeScript" "$PROJECT_DIR/Fixtures/Showcase/source/typescript.ts" 'FR002_RENDER' platform
    run_quicklook_fixture "Format Shell" "$PROJECT_DIR/Fixtures/Showcase/source/shell.sh" 'FR002_RENDER'
    run_quicklook_fixture "Format CSV" "$PROJECT_DIR/Fixtures/Showcase/data/csv.csv" 'FR002_RENDER'
    run_quicklook_fixture "Format TSV" "$PROJECT_DIR/Fixtures/Showcase/data/tsv.tsv" 'FR002_RENDER'
    printf 'ql-smoke: FORMAT ROUTING ONLY complete; cases=%s PASS=%s FAIL=%s BLOCKED_EXTERNAL_PROVIDER=%s BLOCKED_OTHER_GLIMT_PROVIDER=%s BLOCKED_PLATFORM_ROUTING=%s\n' \
        "$CASE_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$EXTERNAL_COUNT" "$OTHER_GLIMT_COUNT" "$PLATFORM_COUNT"
    [[ "$FAIL_COUNT" -eq 0 ]]
    exit
fi

run_quicklook_fixture "JSON UTF-8 control" "$FIXTURE_UTF8" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=17 lineCount=1 lineCountLowerBound=false binary=false'
run_quicklook_fixture "JSON UTF-16 control" "$FIXTURE_UTF16" \
    'FR002_RENDER type=PlainText encoding=UTF-16 LE lineEnding=LF sizeBytes=36 lineCount=1 lineCountLowerBound=false binary=false'
run_quicklook_fixture "JSON Windows-1252 control" "$FIXTURE_CP1252" \
    'FR002_RENDER type=PlainText encoding=Windows-1252 lineEnding=CRLF sizeBytes=17 lineCount=1 lineCountLowerBound=false binary=false'
run_quicklook_fixture "JSON binary control" "$FIXTURE_BINARY" \
    'FR002_RENDER type=BinaryData encoding=none lineEnding=none sizeBytes=3 lineCount=0 lineCountLowerBound=false binary=true'

run_quicklook_fixture "YAML multi-document" "$FIXTURE_YAML" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=89 lineCount=9 lineCountLowerBound=false binary=false'

run_quicklook_fixture "Makefile" "$FIXTURE_MAKEFILE" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=54 lineCount=4 lineCountLowerBound=false binary=false'
run_quicklook_fixture "Dockerfile" "$FIXTURE_DOCKERFILE" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=60 lineCount=3 lineCountLowerBound=false binary=false'
run_quicklook_fixture ".env" "$FIXTURE_ENV" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=4 lineCount=1 lineCountLowerBound=false binary=false'
run_quicklook_fixture ".env.local" "$FIXTURE_ENV_LOCAL" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=8 lineCount=1 lineCountLowerBound=false binary=false' \
    platform
run_quicklook_fixture ".gitignore" "$FIXTURE_GITIGNORE" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=6 lineCount=1 lineCountLowerBound=false binary=false'
REPOSITORY_GITIGNORE_BYTES="$(/usr/bin/wc -c <"$PROJECT_DIR/.gitignore" | /usr/bin/tr -d ' ')"
REPOSITORY_GITIGNORE_LINES="$(/usr/bin/wc -l <"$PROJECT_DIR/.gitignore" | /usr/bin/tr -d ' ')"
run_quicklook_fixture "repository .gitignore" "$PROJECT_DIR/.gitignore" \
    "FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=$REPOSITORY_GITIGNORE_BYTES lineCount=$REPOSITORY_GITIGNORE_LINES lineCountLowerBound=false binary=false"
run_quicklook_fixture "extensionless text" "$FIXTURE_EXTENSIONLESS_TEXT" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=11 lineCount=1 lineCountLowerBound=false binary=false'
run_quicklook_fixture "extensionless binary" "$FIXTURE_EXTENSIONLESS_BINARY" \
    'FR002_RENDER type=BinaryData encoding=none lineEnding=none sizeBytes=5 lineCount=0 lineCountLowerBound=false binary=true'

run_quicklook_fixture "Source Example.swift" "$PROJECT_DIR/Fixtures/Cases/source/Example.swift" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=80 lineCount=5 lineCountLowerBound=false binary=false'
run_quicklook_fixture "Format Text" "$FIXTURE_TEXT" 'FR002_RENDER'
run_quicklook_fixture "Source Example.java" "$PROJECT_DIR/Fixtures/Showcase/source/java.java" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=81 lineCount=5 lineCountLowerBound=false binary=false'
run_quicklook_fixture "Source C" "$FIXTURE_C" 'FR002_RENDER'
run_quicklook_fixture "Source C++" "$FIXTURE_CPP" 'FR002_RENDER'
run_quicklook_fixture "Source example.py" "$PROJECT_DIR/Fixtures/Showcase/source/python.py" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=117 lineCount=5 lineCountLowerBound=false binary=false'
run_quicklook_fixture "Source JavaScript" "$FIXTURE_JAVASCRIPT" 'FR002_RENDER'
printf 'ql-smoke: NOTE platform: macOS may select MPEG before Glimt for .ts; Core verifies this fixture as TypeScript\n'
run_quicklook_fixture "Source example.ts" "$PROJECT_DIR/Fixtures/Showcase/source/typescript.ts" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=119 lineCount=3 lineCountLowerBound=false binary=false' \
    platform
run_quicklook_fixture "Source example.sh" "$PROJECT_DIR/Fixtures/Showcase/source/shell.sh" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=128 lineCount=7 lineCountLowerBound=false binary=false'

run_quicklook_fixture "Markdown headings" "$PROJECT_DIR/Fixtures/Cases/markdown/headings.md" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=27 lineCount=5 lineCountLowerBound=false binary=false' \
    markdown
run_quicklook_fixture "Markdown fenced code" "$PROJECT_DIR/Fixtures/Cases/markdown/fenced-code.md" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=28 lineCount=3 lineCountLowerBound=false binary=false' \
    markdown

run_quicklook_fixture "XML simple" "$PROJECT_DIR/Fixtures/Cases/xml/valid/simple.xml" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=106 lineCount=6 lineCountLowerBound=false binary=false'
run_quicklook_fixture "XML property list" "$PROJECT_DIR/Fixtures/Cases/plist/xml/simple.plist" \
    'FR002_RENDER type=PlainText encoding=UTF-8 lineEnding=LF sizeBytes=299 lineCount=12 lineCountLowerBound=false binary=false'
run_quicklook_fixture "Binary property list" "$PROJECT_DIR/Fixtures/Showcase/plist/binary.plist" \
    'FR002_RENDER type=BinaryData encoding=none lineEnding=none sizeBytes=82 lineCount=0 lineCountLowerBound=false binary=true'
run_quicklook_fixture "Format CSV" "$FIXTURE_CSV" 'FR002_RENDER'
run_quicklook_fixture "Format TSV" "$FIXTURE_TSV" 'FR002_RENDER'

printf 'ql-smoke: SUMMARY cases=%s PASS=%s FAIL=%s BLOCKED_EXTERNAL_PROVIDER=%s BLOCKED_OTHER_GLIMT_PROVIDER=%s BLOCKED_PLATFORM_ROUTING=%s\n' \
    "$CASE_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$EXTERNAL_COUNT" "$OTHER_GLIMT_COUNT" "$PLATFORM_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
