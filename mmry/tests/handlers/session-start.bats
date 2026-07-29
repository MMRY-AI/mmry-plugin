#!/usr/bin/env bats
# session-start.bats — Test SessionStart hook handler.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    export CLAUDE_SESSION_ID="test-session-123"
    # Prevent session-start from copying files to ~/.claude/mmry
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers"
    mkdir -p "$HOME/.claude/mmry/setup"
}

@test "session-start: outputs hookSpecificOutput JSON on success" {
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"hookSpecificOutput"'* ]]
    [[ "$output" == *'"hookEventName":"SessionStart"'* ]]
}

@test "session-start: includes memory count in output" {
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    # Mock returns 1 memory, so count should be 1
    [[ "$output" == *'1 memories'* ]] || [[ "$output" == *'1 memor'* ]]
}

@test "session-start: creates temp markdown file with memory content" {
    bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" > /dev/null 2>&1
    local mem_file="$TEST_TMPDIR/mmry-memories.md"
    [[ -f "$mem_file" ]]
}

@test "session-start: handles zero memories with onboarding message" {
    # Override mock to return empty array
    export MOCK_CURL_RESPONSE='[]'
    export MOCK_CURL_HTTP_CODE="200"
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'Welcome to MMRY AI'* ]] || [[ "$output" == *'fresh start'* ]]
}

@test "session-start: handles API error gracefully (exits 0)" {
    export MOCK_CURL_HTTP_CODE="500"
    export MOCK_CURL_RESPONSE='{"error":"server down"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"error"'* ]] || [[ "$output" == *'session-start failed'* ]]
}

@test "session-start: handles 403 trial expired" {
    export MOCK_CURL_HTTP_CODE="403"
    export MOCK_CURL_RESPONSE='{"error":"trial expired"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'trial'* ]]
}

@test "session-start: shows setup guidance when no API key configured" {
    # Create config with empty API key
    create_test_config "http://localhost:5291" "" "apikey"
    # Also clear the env var
    export MMRY_API_KEY=""
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'hookSpecificOutput'* ]]
    [[ "$output" == *'setup'* ]] || [[ "$output" == *'Setup'* ]] || [[ "$output" == *'MMRY AI'* ]]
}

@test "session-start: 402 credits-exhausted message is unchanged" {
    export MOCK_CURL_HTTP_CODE="402"
    export MOCK_CURL_RESPONSE='{"error":"no credits"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'credits'* ]] || [[ "$output" == *'Credits'* ]]
    [[ "$output" != *'/mmry:setup'* ]]
}

@test "session-start: 401 invalid credential warns and directs to setup (#30321)" {
    export MOCK_CURL_HTTP_CODE="401"
    export MOCK_CURL_RESPONSE='{"error":"unauthorized"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'hookSpecificOutput'* ]]
    [[ "$output" == *'invalid or expired'* ]]
    [[ "$output" == *'may not be saved or loaded'* ]]
    [[ "$output" == *'/mmry:setup'* ]]
    [[ "$output" != *'session-start failed'* ]]
}
