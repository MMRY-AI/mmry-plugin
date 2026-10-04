#!/usr/bin/env bats
# =============================================================================================
# #31740: A SAVE THAT REPLACES AN EARLIER MEMORY ACTUALLY REPLACES IT.
#
# save-memory.sh parsed --supersedes and never sent it, so a correction was saved beside the
# memory it corrected and both stayed live, with nothing to say the correction had not taken.
# The API now accepts supersedesId on a manual save and reports what happened to that memory;
# this is the plugin's half: send it, and tell the assistant the truth about the outcome.
#
#   exit 0  saved, and the memory named by --supersedes is retired
#   exit 1  nothing saved (the API refused the replacement, or the id was not a memory id)
#   exit 3  saved, but the memory named by --supersedes is still active
#
# Requirement 1  the id is sent, as a number, and a reported replacement is a success.
# Requirement 2  every way the replacement can fail is reported, never a silent success.
# Requirement 3  a save without --supersedes sends exactly the request it always has.
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

# --- requirement 3 ---------------------------------------------------------------------------

@test "31740 req3: a save without --supersedes sends exactly today's request" {
    # The literal is the body develop builds for these arguments, before this change.
    run bash "$SAVE" --context "Plain save" --working-dir "/w" --session-id "s-1"
    [ "$status" -eq 0 ]
    local line; line="$(_process_lines)"
    [[ "$line" == *' {"context":"Plain save","hookType":"manual","workingDirectory":"/w","sessionId":"s-1"}' ]] \
        || { echo "body changed: $line"; return 1; }
    [[ "$line" != *supersedes* ]]
}

@test "31740 req3: and its output and exit status are unchanged" {
    run bash "$SAVE" --context "Plain save"
    [ "$status" -eq 0 ]
    [[ "$output" == "Memory sent to MMRY AI for processing." ]]
}

# --- requirement 1 ---------------------------------------------------------------------------

@test "31740 req1: --supersedes is sent as a number, and a reported replacement succeeds" {
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory under Operational tier. It replaces memory 42, which is no longer active.","stored":1,"supersede":{"memoryId":42,"applied":true,"reason":"replaced"}}'
    run bash "$SAVE" --context "The office moved to the fourth floor." --supersedes 42
    [ "$status" -eq 0 ]
    [[ "$(_process_lines)" == *'"supersedesId":42}'* ]] || { echo "not sent as a number: $(_process_lines)"; return 1; }
    [[ "$output" == *"replaces memory 42"* ]]
}

# --- requirement 2 ---------------------------------------------------------------------------

@test "31740 req2: a replacement the API refuses saves nothing and says why" {
    export MOCK_CURL_HTTP_CODE="404"
    export MOCK_CURL_RESPONSE='{"message":"Nothing was saved. Memory 42 was not found, is no longer active, or is not one you can see, so it cannot be replaced.","stored":0,"supersede":{"memoryId":42,"applied":false,"reason":"not-found"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 1 ]
    [[ "$output" == *"Nothing was saved"* ]] || { echo "$output"; return 1; }
    # The server's words, not the generic dump of the raw response.
    [[ "$output" != *"Error (HTTP 404)"* ]]
}

@test "31740 req2: saved but the old memory still active exits 3 and says so" {
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory. Memory 42 could not be replaced and is still active.","stored":1,"supersede":{"memoryId":42,"applied":false,"reason":"still-active"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 3 ]
    [[ "$output" == *"NOT replaced"* ]]
}

@test "31740 req2: a server that ignores the replacement is not taken as having applied it" {
    # What production answers until the API half ships: the ordinary 202, no supersede field.
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory under Operational tier.","stored":1}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 3 ]
    [[ "$output" == *"did not report replacing memory 42"* ]]
}

@test "31740 req2: an id that cannot be a memory is refused before anything is sent" {
    local bad
    # '' is in the list on purpose (#31740 QA round 1): an empty value used to be ignored, so the
    # save went through as an unrelated memory.
    for bad in abc 0 -5 4.2 '' 99999999999; do
        rm -f "$TEST_TMPDIR/curl-log.txt"
        run bash "$SAVE" --context "A correction" --supersedes "$bad"
        [ "$status" -eq 1 ] || { echo "accepted --supersedes $bad (status $status)"; return 1; }
        [[ "$output" == *"positive whole number"* ]] || { echo "$bad: $output"; return 1; }
        [[ -z "$(_process_lines)" ]] || { echo "$bad reached the API"; return 1; }
    done
}

@test "31740 req2: the largest memory id the API can hold is accepted" {
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"m","stored":1,"supersede":{"memoryId":2147483647,"applied":true,"reason":"replaced"}}'
    run bash "$SAVE" --context "A correction" --supersedes 2147483647
    [ "$status" -eq 0 ]
    [[ "$(_process_lines)" == *'"supersedesId":2147483647}'* ]]
}

# --- QA round 1 (#31740) ----------------------------------------------------------------------

@test "31740 qa: one past the largest id the API can hold is refused before anything is sent" {
    # QA's surviving mutation P5: nothing tested the bound itself.
    run bash "$SAVE" --context "A correction" --supersedes 2147483648
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"positive whole number"* ]] || { echo "$output"; return 1; }
    [[ -z "$(_process_lines)" ]]
}

@test "31740 qa: --supersedes with no value at all is refused, not read as the next flag" {
    run bash "$SAVE" --context "A correction" --supersedes
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"needs the id"* ]] || { echo "$output"; return 1; }
    [[ -z "$(_process_lines)" ]]
}

@test "31740 qa: --permission-group-id is checked like --supersedes" {
    local bad
    for bad in abc 0 -1 1.5 ''; do
        rm -f "$TEST_TMPDIR/curl-log.txt"
        run bash "$SAVE" --context "x" --visibility group --permission-group-id "$bad"
        [ "$status" -eq 1 ] || { echo "accepted --permission-group-id '$bad' (status $status)"; return 1; }
        [[ "$output" == *"positive whole number"* ]] || { echo "$bad: $output"; return 1; }
        [[ -z "$(_process_lines)" ]] || { echo "'$bad' reached the API"; return 1; }
    done
    rm -f "$TEST_TMPDIR/curl-log.txt"
    run bash "$SAVE" --context "x" --visibility group --permission-group-id 7
    [ "$status" -eq 0 ] || { echo "a valid group id was refused: $output"; return 1; }
    [[ "$(_process_lines)" == *'"permissionGroupID":7'* ]]
}

@test "31740 qa: nothing stored is exit 1, never 'saved, old one still active'" {
    # QA (A): the assistant told the customer a lost correction had been saved.
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"AI processing failed. Nothing was saved, so memory 42 was not replaced and is still active.","stored":0,"supersede":{"memoryId":42,"applied":false,"reason":"nothing-stored"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"Nothing was saved"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"NOT replaced and is still active"* ]]
}

@test "31740 qa: nothing stored is exit 1 even from a server that reports no outcome" {
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"AI processing not configured.","stored":0}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"Nothing was saved"* ]]
}

@test "31740 qa: a Foundation memory the API will not replace is exit 1 with the API's reason" {
    export MOCK_CURL_HTTP_CODE="403"
    export MOCK_CURL_RESPONSE='{"message":"Nothing was saved. Memory 42 is a Foundation memory.","stored":0,"supersede":{"memoryId":42,"applied":false,"reason":"foundation"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"is a Foundation memory"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Error (HTTP 403)"* ]]
}

@test "31740 qa: a different visibility the API refuses is exit 1 with the API's reason" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"message":"Nothing was saved. Memory 42 is Private, and a replacement keeps the visibility of the memory it replaces.","stored":0,"supersede":{"memoryId":42,"applied":false,"reason":"visibility-differs"}}'
    run bash "$SAVE" --context "A correction" --visibility global --supersedes 42
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"keeps the visibility"* ]]
}

@test "31740 qa: a replacement the API could not confirm is exit 3, saved and possibly still active" {
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory. Whether memory 42 was replaced could not be confirmed; it may still be active.","stored":1,"supersede":{"memoryId":42,"applied":false,"reason":"unverified"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"could not be confirmed"* ]] || { echo "$output"; return 1; }
    # QA round 2: nothing may contradict it. "May still be active" is the truth; "was NOT replaced
    # and is still active" is a claim nobody can make, because the read-back failed.
    [[ "$output" != *"NOT replaced"* ]] || { echo "contradicting line printed: $output"; return 1; }
    [[ "$output" != *"is still active"* ]] || { echo "contradicting line printed: $output"; return 1; }
}

@test "31740 qa2: an unverified replacement says it may still be active even with no server message" {
    # The plugin's own line has to carry it, because the server's message is optional.
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"stored":1,"supersede":{"memoryId":42,"applied":false,"reason":"unverified"}}'
    run bash "$SAVE" --context "A correction" --supersedes 42
    [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"Whether memory 42 was replaced could not be confirmed, so it may still be active."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"NOT replaced"* ]] || { echo "contradicting line printed: $output"; return 1; }
}
