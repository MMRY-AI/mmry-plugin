#!/usr/bin/env bats
# visibility.bats — Test visibility.sh handler (#29901 default memory visibility).

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
}

@test "visibility: no argument shows the current default" {
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Current default"* ]]
    [[ "$output" == *"Global"* ]]
}

@test "visibility: no argument reads the default-visibility endpoint" {
    bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" >/dev/null 2>&1
    grep -q "GET.*users/me/default-visibility" "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: private sets the default to Private" {
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" private
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Private"* ]]
    grep -q "PUT.*users/me/default-visibility" "$TEST_TMPDIR/curl-log.txt"
    grep -q '"visibility":"Private"' "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: global sets the default back to Global" {
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" global
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Global"* ]]
    grep -q '"visibility":"Global"' "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: accepts mixed-case mode" {
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" PRIVATE
    [[ "$status" -eq 0 ]]
    grep -q '"visibility":"Private"' "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: bare group lists the user's groups by name" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" group
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Finance Team"* ]]
    [[ "$output" == *"Engineering"* ]]
}

@test "visibility: bare group does not surface numeric group IDs" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" group
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"ID:"* ]]
}

@test "visibility: group by name resolves the id and sets the default" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" group "Engineering"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Engineering"* ]]
    grep -q '"visibility":"Group"' "$TEST_TMPDIR/curl-log.txt"
    grep -q '"permissionGroupID":2' "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: group name match is case-insensitive" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" group "engineering"
    [[ "$status" -eq 0 ]]
    grep -q '"permissionGroupID":2' "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: unknown group name fails and lists valid groups" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" group "Nope"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No group named"* ]]
    [[ "$output" == *"Finance Team"* ]]
}

@test "visibility: unknown mode is rejected without an API call" {
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" sideways
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown option"* ]]
    ! grep -q "default-visibility" "$TEST_TMPDIR/curl-log.txt"
}

@test "visibility: shows a Private default when one is stored" {
    if ! command -v jq &>/dev/null; then
        skip "Requires jq"
    fi
    export MOCK_DEFAULT_VISIBILITY_BODY='{"visibility":"Private","permissionGroupID":null}'
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Private"* ]]
}

@test "visibility: handles API error on read" {
    export MOCK_CURL_HTTP_CODE="500"
    export MOCK_CURL_RESPONSE='{"error":"server error"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Error"* ]]
}

@test "visibility: handles API error on set" {
    export MOCK_CURL_HTTP_CODE="403"
    export MOCK_CURL_RESPONSE='{"error":"not a member"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/visibility.sh" private
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Error"* ]]
}
