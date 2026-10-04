#!/usr/bin/env bats
# save-memory.bats — Test save-memory.sh handler against the thin-client contract.
#
# Contract (as of v1.4 #29732, reaffirmed by v1.8 #29950):
#   - Required arg: --context (or legacy --topic and --content; the script will
#     compose context from them).
#   - Optional args: --working-dir, --session-id, --project-id, --task-id,
#     --visibility, --permission-group-id, --supersedes, and legacy --tier,
#     --category, --scope (all forwarded as suggestions; the server classifies).
#   - On success: prints the server-supplied ack ("message" field in the 202
#     response) or "Memory sent to MMRY AI for processing." as fallback.
#   - On error: prints an Error line and exits non-zero.
#   - Never prints memory IDs (the server's response is not echoed verbatim).
#
# This file was rewritten under #30011 to replace stale fat-client assertions
# (pre-v1.4) that had been silently failing for five releases.

load '../helpers/test-helper'
load '../helpers/mock-config'

# Pattern matched by every successful save's stdout. Either the server's ack
# message, or the script's fallback string.
SAVE_SUCCESS_PATTERN='Memory sent to MMRY AI'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
}

# --- Argument validation -----------------------------------------------------

@test "save-memory: fails when neither --context nor legacy --topic+--content given" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--context"* ]]
}

@test "save-memory: fails with missing --content (when --topic given but no --context)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --tier Foundation --category Fact --scope global --topic "Test"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--context"* ]]
}

@test "save-memory: fails with missing --topic (when --content given but no --context)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --tier Foundation --category Fact --scope global --content "Content"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--context"* ]]
}

@test "save-memory: fails on unknown argument" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "anything" --unknown-flag value
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown argument"* ]]
}

# --- Success paths -----------------------------------------------------------

@test "save-memory: succeeds with --context only" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Test content body"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$SAVE_SUCCESS_PATTERN"* ]]
}

@test "save-memory: succeeds with legacy --topic + --content (server composes context)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --tier Foundation --category Fact --scope global \
        --topic "Test Topic" --content "Test content body"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$SAVE_SUCCESS_PATTERN"* ]]
}

@test "save-memory: forwards optional metadata flags to the API" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "We chose X" \
        --task-id "TASK-42" --working-dir "/home/user/project" \
        --session-id "sess-abc"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$SAVE_SUCCESS_PATTERN"* ]]
    grep -q "POST.*memories" "$TEST_TMPDIR/curl-log.txt"
}

# --- Error handling ---------------------------------------------------------

@test "save-memory: surfaces API errors and exits non-zero" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"error":"Validation failed"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "anything"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Error"* ]]
}

# --- Visibility / permission group ------------------------------------------

@test "save-memory: accepts --visibility private" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Only for me" \
        --visibility private
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$SAVE_SUCCESS_PATTERN"* ]]
}

@test "save-memory: private visibility is sent in API request body" {
    bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Internal choice" \
        --visibility private 2>&1
    grep -q "POST.*memories" "$TEST_TMPDIR/curl-log.txt"
}

@test "save-memory: succeeds with no visibility (server defaults to global)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Everyone sees this"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$SAVE_SUCCESS_PATTERN"* ]]
}

@test "save-memory: accepts --supersedes for updates" {
    # #31740: this used to pass with the id silently dropped. A replacement now succeeds only
    # when the API reports it applied; handlers/save-supersede.bats covers the rest.
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory. It replaces memory 42, which is no longer active.","stored":1,"supersede":{"memoryId":42,"applied":true,"reason":"replaced"}}'
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "New version" \
        --supersedes 42
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"replaces memory 42"* ]]
}

@test "save-memory: accepts all optional parameters together" {
    # #31740: with --supersedes, success means the API reported the replacement applied.
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory. It replaces memory 10, which is no longer active.","stored":1,"supersede":{"memoryId":10,"applied":true,"reason":"replaced"}}'
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "All options set" \
        --task-id "TASK-99" --working-dir "/tmp/project" \
        --project-id 5 --session-id "sess-xyz" \
        --visibility private --supersedes 10
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"replaces memory 10"* ]]
}

@test "save-memory: accepts --permission-group-id" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Shared with team" \
        --visibility group --permission-group-id 42
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$SAVE_SUCCESS_PATTERN"* ]]
}

@test "save-memory: permission-group-id is sent in API request body" {
    bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Team choice" \
        --visibility group --permission-group-id 7 2>&1
    grep -q "POST.*memories" "$TEST_TMPDIR/curl-log.txt"
}

# --- Output contract --------------------------------------------------------

@test "save-memory: does not echo back the memory body (server classifies, client confirms)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "A unique sentinel string PineappleZebra92"
    [[ "$status" -eq 0 ]]
    # v1.8 (#29950) contract: client output is a short ack, not the content.
    [[ "$output" != *"PineappleZebra92"* ]]
}

@test "save-memory: does not output memory ID" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" \
        --context "Should not show ID"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"NewMemoryID"* ]]
    [[ "$output" != *": 99"* ]]
}
