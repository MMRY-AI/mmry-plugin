#!/usr/bin/env bats
# memory-lifecycle.bats — Create -> retrieve -> deactivate (live API).
# Requires MMRY_INTEGRATION_API_KEY env var.

load '../helpers/test-helper'

INTEGRATION_URL="https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net"
MEMORY_ID=""

setup_file() {
    if [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]]; then
        skip "MMRY_INTEGRATION_API_KEY not set"
    fi
}

_api() {
    local method="$1" path="$2" body="${3:-}"
    local curl_args=(-s -w '\n%{http_code}' --connect-timeout 10 --max-time 25
        -X "$method"
        -H "X-Api-Key: ${MMRY_INTEGRATION_API_KEY}"
        -H "Content-Type: application/json")
    [[ -n "$body" ]] && curl_args+=(-d "$body")
    curl "${curl_args[@]}" "${INTEGRATION_URL}${path}"
}

@test "lifecycle: create a memory (201)" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    local unique_topic="BATS-Test-$(date +%s)"
    local response
    response="$(_api POST "/api/memories" "{\"memoryTier\":\"Momentary\",\"category\":\"Fact\",\"scope\":\"test\",\"topic\":\"${unique_topic}\",\"content\":\"Integration test memory\"}")"
    local code
    code="$(echo "$response" | tail -1)"
    local body
    body="$(echo "$response" | sed '$d')"
    [[ "$code" == "201" ]]

    # Extract ID for subsequent tests
    if command -v jq &>/dev/null; then
        MEMORY_ID="$(echo "$body" | jq -r '.id')"
    else
        MEMORY_ID="$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')"
    fi
    [[ -n "$MEMORY_ID" ]]
    # Write ID to temp file for other tests
    echo "$MEMORY_ID" > "$BATS_FILE_TMPDIR/memory_id"
}

@test "lifecycle: get memory by ID (200)" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    [[ ! -f "$BATS_FILE_TMPDIR/memory_id" ]] && skip "No memory ID from create test"
    local mid
    mid="$(cat "$BATS_FILE_TMPDIR/memory_id")"
    local response
    response="$(_api GET "/api/memories/${mid}")"
    local code
    code="$(echo "$response" | tail -1)"
    [[ "$code" == "200" ]]
}

@test "lifecycle: deactivate memory (204)" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    [[ ! -f "$BATS_FILE_TMPDIR/memory_id" ]] && skip "No memory ID from create test"
    local mid
    mid="$(cat "$BATS_FILE_TMPDIR/memory_id")"
    local response
    response="$(_api DELETE "/api/memories/${mid}")"
    local code
    code="$(echo "$response" | tail -1)"
    [[ "$code" == "204" ]]
}

@test "lifecycle: deactivated memory returns 404" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    [[ ! -f "$BATS_FILE_TMPDIR/memory_id" ]] && skip "No memory ID from create test"
    local mid
    mid="$(cat "$BATS_FILE_TMPDIR/memory_id")"
    local response
    response="$(_api GET "/api/memories/${mid}")"
    local code
    code="$(echo "$response" | tail -1)"
    [[ "$code" == "404" ]]
}
