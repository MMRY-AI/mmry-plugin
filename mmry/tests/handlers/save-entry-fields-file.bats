#!/usr/bin/env bats
# save-entry-fields-file.bats - save-entry.sh reads its fields from a file (#34252).
#
# An entry may hold 200 values of up to 4,000 characters each, far more than Windows lets a command
# line carry (32,767 characters). save-entries.sh has taken --entries-file since #33317; save-entry.sh
# took its fields only on the command line, so a large entry could not be saved through it at all.
# --fields-file reads them with the read builtin and the body travels in a file (_mmry_request).

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
    LOG="$TEST_TMPDIR/curl-log.txt"
}

@test "save-entry --fields-file: sends the file's fields as the entry's fields" {
    printf '%s' '{"severity":7,"triggers":["red wine"]}' > "$TEST_TMPDIR/fields.json"
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "Migraine after red wine." \
        --fields-file "$TEST_TMPDIR/fields.json"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"structured.created"* ]] || { echo "$output"; return 1; }
    grep -q 'POST http://localhost:5291/api/databases/42/entries' "$LOG"
    grep -q '"fields":{"severity":7,"triggers":\["red wine"\]}' "$LOG"
}

@test "save-entry --fields-file: a 40,000-character fields file is sent whole (more than a Windows command line holds)" {
    local v; v="$(printf 'a%.0s' $(seq 1 3990))"
    local f="$TEST_TMPDIR/big.json" i
    { printf '{'; for i in 0 1 2 3 4 5 6 7 8 9; do (( i )) && printf ','; printf '"f%d":"%s"' "$i" "$v"; done; printf '}'; } > "$f"
    [[ $(wc -c < "$f") -gt 32767 ]] || { echo "fixture too small"; return 1; }
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "Wide entry." --fields-file "$f"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "\"f9\":\"${v}\"}" "$LOG" || { echo "the last field did not arrive whole"; return 1; }
}

@test "save-entry --fields-file: refuses --fields and --fields-file together" {
    printf '%s' '{"severity":7}' > "$TEST_TMPDIR/fields.json"
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "x" --fields '{"severity":1}' \
        --fields-file "$TEST_TMPDIR/fields.json"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--fields or with --fields-file, not both"* ]] || { echo "$output"; return 1; }
    [[ ! -s "$LOG" ]] || ! grep -q 'POST' "$LOG"
}

@test "save-entry --fields-file: a file that cannot be read is named and nothing is sent" {
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "x" --fields-file "$TEST_TMPDIR/nope.json"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"cannot read the fields file"* ]] || { echo "$output"; return 1; }
    [[ ! -s "$LOG" ]] || ! grep -q 'POST' "$LOG"
}

@test "save-entry: a refused save prints the server's reason (the field that is too long)" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"error":"The value of '"'"'pending_version'"'"' is longer than 4000 characters, which is more than a field holds. Save it as ordinary text instead.","detail":null}'
    printf '%s' '{"pending_version":"x"}' > "$TEST_TMPDIR/fields.json"
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "x" --fields-file "$TEST_TMPDIR/fields.json"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"HTTP 400"*"longer than 4000 characters"* ]] || { echo "$output"; return 1; }
}
