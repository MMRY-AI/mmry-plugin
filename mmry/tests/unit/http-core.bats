#!/usr/bin/env bats
# http-core.bats — Test _mmry_request with mock curl.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    export MMRY_API_KEY="test-key"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_URL="http://localhost:5291"
    setup_mock_curl
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}

@test "request: returns 0 for 200 response" {
    run _mmry_request GET "/api/health"
    [[ "$status" -eq 0 ]]
}

@test "request: returns 0 for 201 response" {
    run _mmry_request POST "/api/memories" '{"topic":"test"}'
    [[ "$status" -eq 0 ]]
}

@test "request: returns 0 for 204 response" {
    run _mmry_request PUT "/api/memories/1/visibility"
    [[ "$status" -eq 0 ]]
}

@test "request: returns 1 for 500 response" {
    export MOCK_CURL_HTTP_CODE="500"
    export MOCK_CURL_RESPONSE='{"error":"server error"}'
    run _mmry_request GET "/api/unknown-path"
    [[ "$status" -eq 1 ]]
}

@test "request: returns 1 for 400 response" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"error":"bad request"}'
    run _mmry_request POST "/api/memories" '{}'
    [[ "$status" -eq 1 ]]
}

@test "request: sets MMRY_HTTP_CODE correctly" {
    _mmry_request GET "/api/health"
    [[ "$MMRY_HTTP_CODE" == "200" ]]
}

@test "request: sets MMRY_RESPONSE correctly" {
    _mmry_request GET "/api/health"
    [[ "$MMRY_RESPONSE" == '{"status":"Healthy"}' ]]
}

@test "request: handles auth failure (no key) gracefully" {
    MMRY_API_KEY=""
    MMRY_AUTH_METHOD=""
    run _mmry_request GET "/api/memories"
    [[ "$status" -eq 1 ]]
}

@test "request: logs curl call to curl-log.txt" {
    _mmry_request GET "/api/health"
    [[ -f "$TEST_TMPDIR/curl-log.txt" ]]
    grep -q "GET.*health" "$TEST_TMPDIR/curl-log.txt"
}

@test "request: sends POST body for create operations" {
    _mmry_request POST "/api/memories" '{"topic":"hello"}'
    grep -q 'POST.*memories' "$TEST_TMPDIR/curl-log.txt"
}
