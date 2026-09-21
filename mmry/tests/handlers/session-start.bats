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

@test "session-start: a 403 offers the expired trial as a likely cause, not as a fact (#31195)" {
    # From the #31195 census of status-to-message mappings. A 403 on the startup read says access
    # was refused; it does not say which of the several things gating access is the one that fired.
    # Telling a subscriber whose payment lapsed that "their free trial has ended" points them at a
    # trial they finished months ago, and it is the same defect as the formation 502: a status
    # mapped to its most likely cause, then stated as though it were the known one.
    export MOCK_CURL_HTTP_CODE="403"
    export MOCK_CURL_RESPONSE='{"error":"forbidden"}'
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    [[ "$status" -eq 0 ]]
    # The trial stays named. It IS the most common cause and the message is more useful for saying
    # so. What changes is that it is no longer the only explanation on offer.
    [[ "$output" == *'trial'* ]]
    [[ "$output" == *'subscription'* ]]
    [[ "$output" != *'their free trial has ended'* ]]
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

# ============================================================================
# #31411 QA: A WRITER FAILURE MUST NOT KILL THE HOOK, AND MUST NOT BE SILENT.
#
# session-start.sh runs under `set -euo pipefail` with no trap and no set +e. Its call to
# mmry_write_foundation_cache was unguarded, and the comment above it still said
# "Best-effort", which was true on master: that function ended in `|| true` and had no
# return-1 path. #31583 gave it six. So under errexit any one of them terminated the hook at
# that line, BEFORE it printed its JSON, and the session ran with no Foundation directives
# and nobody was told.
#
# These assert on STDOUT ONLY. The writer's failure also produces a shell redirection error on
# stderr, which `2>/dev/null` inside the function cannot suppress because the shell emits it.
# Claude Code reads stdout, so merging the two here would fail the test for something the
# product does not do.
# ============================================================================

@test "session-start: #31411 a Foundation cache write failure does not kill the hook" {
    # Deterministic failure with nothing stubbed: a DIRECTORY where the writer must create the
    # manifest file, so the real writer takes its real failure path.
    _plugin_with_failing_writer

    run bash -c "bash '$FAILING_ROOT/hooks-handlers/session-start.sh' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookEventName":"SessionStart"'* ]]
    [[ "$output" == *'memor'* ]]
}

@test "session-start: #31411 that failure is REPORTED, not swallowed" {
    _plugin_with_failing_writer

    run bash -c "bash '$FAILING_ROOT/hooks-handlers/session-start.sh' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Foundation directives could not be stored'* ]]
    [[ "$output" == *'NOT be applied'* ]]
    [[ "$output" == *'mmry:load-memories'* ]]
}

@test "session-start: #31411 the JSON on stdout is still valid when the writer fails" {
    _plugin_with_failing_writer

    run bash -c "bash '$FAILING_ROOT/hooks-handlers/session-start.sh' 2>/dev/null"
    [ "$status" -eq 0 ]
    if command -v jq >/dev/null; then
        printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    else
        printf '%s' "$output" | python3 -c 'import sys,json; json.load(sys.stdin)'
    fi
}

@test "session-start: #31411 control - a healthy write says nothing about a failure" {
    run bash -c "bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *'could not be stored'* ]]
}

# A copy of the plugin whose cache writer always fails, so the #31411 tests above exercise
# session-start's HANDLING of that failure rather than a filesystem trick.
#
# The first version put a directory where the manifest file had to go. That worked until the
# writer began landing both files by atomic rename (#31583 QA): `mv file dir` moves the file
# INTO the directory and succeeds, so the injected failure silently stopped happening and
# those tests went red in the full suite. A test whose failure injection depends on the
# internals of the thing it tests will keep doing that.
#
# Defined at the end of the file on purpose: bats sources the whole file before running any
# test, so position does not matter and appending avoids disturbing the block above.
_plugin_with_failing_writer() {
    FAILING_ROOT="$TEST_TMPDIR/plugin"
    cp -R "$PLUGIN_ROOT" "$FAILING_ROOT"
    local client="$FAILING_ROOT/hooks-handlers/mmry-client.sh"
    # Force the documented failure contract: return non-zero, write nothing.
    awk '{ print } /^mmry_write_foundation_cache\(\) \{$/ { print "    return 1" }' "$client" > "$client.tmp"
    mv "$client.tmp" "$client"
    # ANCHORED TO POSITION, not to the text (#31583 QA round 2). The first guard here was
    # grep -q '^    return 1$', which mmry-client.sh already satisfies twice at lines 416 and
    # 430 before any mutation, so it passed on an untouched copy. If the awk pattern ever
    # stopped matching, nothing would be injected, the writer would succeed, and the three
    # tests that prove the session-start guard works would go green while exercising the
    # healthy path. That is the fifth assertion on this branch whose premise was satisfied by
    # something other than the thing under test.
    #
    # This asserts the line IMMEDIATELY AFTER the function header is the injected return, so
    # it cannot be satisfied by a return 1 anywhere else in the file.
    local after
    after="$(awk '/^mmry_write_foundation_cache\(\) \{$/ { getline; print; exit }' "$client")"
    [ "$after" = "    return 1" ] || {
        echo "injection did not land: line after the header was [$after]"
        return 1
    }
}
