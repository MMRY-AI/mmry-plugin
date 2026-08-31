#!/usr/bin/env bats
# make-private.bats — make-private.sh: the "make it private" follow-through (#29901).

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
}

@test "make-private: no argument targets the most recent memory and sets Private" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    run bash "$PLUGIN_ROOT/hooks-handlers/make-private.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"visible only to you"* ]]
    grep -q "PUT.*memories/1/visibility" "$TEST_TMPDIR/curl-log.txt"
    grep -q '"visibility":"Private"' "$TEST_TMPDIR/curl-log.txt"
}

@test "make-private: an explicit id is used without a lookup call" {
    run bash "$PLUGIN_ROOT/hooks-handlers/make-private.sh" 4321
    [[ "$status" -eq 0 ]]
    grep -q "PUT.*memories/4321/visibility" "$TEST_TMPDIR/curl-log.txt"
    ! grep -qE "GET .*/api/memories( |\?|$)" "$TEST_TMPDIR/curl-log.txt"
}

@test "make-private: group target requires a group id" {
    run bash "$PLUGIN_ROOT/hooks-handlers/make-private.sh" 4321 group
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"group id is required"* ]]
}

@test "make-private: group target sends the group id" {
    run bash "$PLUGIN_ROOT/hooks-handlers/make-private.sh" 4321 group 7
    [[ "$status" -eq 0 ]]
    grep -q '"visibility":"Group"' "$TEST_TMPDIR/curl-log.txt"
    grep -q '"permissionGroupID":7' "$TEST_TMPDIR/curl-log.txt"
}

@test "make-private: unknown target is rejected" {
    run bash "$PLUGIN_ROOT/hooks-handlers/make-private.sh" 4321 sideways
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown target"* ]]
}

@test "make-private: a 403 (not the creator) surfaces an error, not success" {
    export MOCK_CURL_HTTP_CODE="403"
    export MOCK_CURL_RESPONSE='{"error":"Only the person who saved a memory can change who can see it."}'
    run bash "$PLUGIN_ROOT/hooks-handlers/make-private.sh" 4321
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Error"* ]]
}
