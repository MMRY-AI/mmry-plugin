#!/usr/bin/env bats
# =============================================================================================
# #31740 QA round 2: tests written and run by QA #2 (formation 33), committed as written.
# Each passes on the fixed code and fails on its mutant:
#   K1  P13b  a 400 prints the API's reason, not the raw dump
#   K2  P14   a 401 with --supersedes keeps the /mmry:setup guidance
#   K3  P12b  a 19-digit group id is refused before sending
#   K4  P11d  --permission-group-id with no value says what is missing
#   K5        an unverified replacement is not reported as definitely still active (the round 2
#             defect, fixed in 6fa1023; "DEFECT" dropped from its title now that it passes)
# =============================================================================================
load '../helpers/test-helper'
load '../helpers/mock-config'
SAVE=""
setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    SAVE="$PLUGIN_ROOT/hooks-handlers/save-memory.sh"
    rm -f "$TEST_TMPDIR/curl-log.txt"
}
_process_lines() { grep 'memories/process' "$TEST_TMPDIR/curl-log.txt" 2>/dev/null || true; }
@test "K1 a 400 refusal prints the API's reason, not the raw dump" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"message":"Nothing was saved. Memory 42 is Private, and a replacement keeps the visibility of the memory it replaces.","stored":0,"supersede":{"memoryId":42,"applied":false,"reason":"visibility-differs"}}'
    run bash "$SAVE" --context "A correction" --visibility global --supersedes 42
    [ "$status" -eq 1 ]
    [[ "$output" == *"MMRY AI: Nothing was saved"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Error (HTTP 400)"* ]]
}
@test "K2 a 401 with --supersedes still gets the re-authenticate guidance" {
    export MOCK_CURL_HTTP_CODE="401"
    export MOCK_CURL_RESPONSE='{"message":"Unauthorized."}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 1 ]
    [[ "$output" == *"/mmry:setup"* ]] || { echo "$output"; return 1; }
}
@test "K3 a 19-digit group id is refused before anything is sent" {
    run bash "$SAVE" --context "x" --visibility group --permission-group-id 1234567890123456789
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ -z "$(_process_lines)" ]]
}
@test "K4 --permission-group-id with no value says what is missing" {
    run bash "$SAVE" --context "x" --permission-group-id
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a group id"* ]] || { echo "$output"; return 1; }
}
@test "K5 an unverified replacement is not reported as definitely still active" {
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory. Whether memory 42 was replaced could not be confirmed; it may still be active.","stored":1,"supersede":{"memoryId":42,"applied":false,"reason":"unverified"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 3 ]
    [[ "$output" != *"NOT replaced and is still active"* ]] || { echo "$output"; return 1; }
}
