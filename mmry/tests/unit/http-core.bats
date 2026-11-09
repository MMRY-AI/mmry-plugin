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

# #33480: a request's temp file is made with a builtin exclusive create, not $(mktemp). Bash's
# noclobber refuses only an existing REGULAR file: a name already holding a link to a device (or a
# FIFO) is opened and written through. Such a name must be passed over, left as it was, and another
# one used, so the response is never sent somewhere it cannot be read back. RANDOM is seeded so the
# first name tried is known and can be taken first.
@test "request temp file: a name already holding a link to a device is passed over, not written through" {
    local base="$TEST_TMPDIR/mmry-resp" a b taken
    RANDOM=4242; a=$RANDOM; b=$RANDOM
    taken="${base}-$$-${a}${b}"
    ln -s /dev/null "$taken"
    [[ -L "$taken" ]] || { echo "the link was not made"; return 1; }
    RANDOM=4242
    _mmry_mktemp_v "$base"
    [[ -n "$_MMRY_TMPF" ]] || { echo "no name was returned"; return 1; }
    [[ "$_MMRY_TMPF" != "$taken" ]] || { echo "the name holding the link was used: $_MMRY_TMPF"; return 1; }
    [[ -f "$_MMRY_TMPF" && ! -L "$_MMRY_TMPF" ]] || { echo "not a regular file of its own: $_MMRY_TMPF"; return 1; }
    [[ ! -s "$_MMRY_TMPF" ]] || { echo "the new file is not empty"; return 1; }
    [[ -L "$taken" ]]
}

@test "request temp file: noclobber is left as the caller had it" {
    set +C
    _mmry_mktemp_v "$TEST_TMPDIR/mmry-resp"
    [[ "$-" != *C* ]] || { set +C; echo "noclobber was left on"; return 1; }
    set -C
    _mmry_mktemp_v "$TEST_TMPDIR/mmry-resp"
    local kept=0; [[ "$-" == *C* ]] && kept=1
    set +C
    [[ "$kept" == 1 ]]
}
