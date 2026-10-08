#!/usr/bin/env bats
# =============================================================================================
# #31847: A SAVED CORRECTION REPLACES THE MEMORY IT CORRECTS, IN CLAUDE CODE AND IN CODEX.
#
# save-memory.sh carries the replacement (#31740, ported here). This file proves the parts the
# #31740 suite does not:
#
#   Codex     the Codex install runs the same handler from ${CODEX_HOME}/mmry, with the Codex
#             credential file; the replacement must reach the API from there too (req 2).
#   Guidance  the assistant is told to use the replacement when correcting, on both hosts, and
#             told where the old memory's id comes from (req 1, req 2).
#   Id source that guidance says the id is on each memory loaded at session start, so that has
#             to be true of session-start.sh's output.
#   Audience  a replacement never sends a visibility or group the caller did not give, so the
#             server's rule "a replacement keeps the old memory's audience" decides (req 3).
# =============================================================================================

load '../helpers/test-helper'
load '../helpers/mock-config'

REPLACED='{"message":"Stored 1 memory under Operational tier. It replaces memory 42, which is no longer active.","stored":1,"supersede":{"memoryId":42,"applied":true,"reason":"replaced"}}'

setup() {
    setup_mock_curl
    rm -f "$TEST_TMPDIR/curl-log.txt"
}

_process_lines() { grep 'memories/process' "$TEST_TMPDIR/curl-log.txt" 2>/dev/null || true; }

# A Codex install laid out the way session-init.sh lays it out: handlers copied under
# ${CODEX_HOME}/mmry, credentials in ${CODEX_HOME}/mmry-config.json.
_codex_install() {
    export CODEX_HOME="$TEST_TMPDIR/codexhome"
    mkdir -p "$CODEX_HOME/mmry/hooks-handlers" "$CODEX_HOME/mmry/setup"
    cp "$PLUGIN_ROOT"/hooks-handlers/* "$CODEX_HOME/mmry/hooks-handlers/"
    cp "$PLUGIN_ROOT"/setup/*.sh "$CODEX_HOME/mmry/setup/" 2>/dev/null || true
    MMRY_CONFIG_FILE="$CODEX_HOME/mmry-config.json" create_test_config \
        "http://localhost:5399" "codex-api-key" "apikey" >/dev/null
}

# --- requirement 2: Codex ---------------------------------------------------------------------

@test "31847 req2: a correction saved from the Codex install sends the replacement and succeeds" {
    _codex_install
    export MOCK_CURL_HTTP_CODE="202" MOCK_CURL_RESPONSE="$REPLACED"
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$CODEX_HOME" \
        bash "$CODEX_HOME/mmry/hooks-handlers/save-memory.sh" \
        --context "The office moved to the fourth floor." --supersedes 42 --source codex --working-dir "$PWD"
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    [[ "$(_process_lines)" == *'"supersedesId":42'* ]] || { echo "not sent: $(_process_lines)"; return 1; }
    [[ "$output" == *"replaces memory 42"* ]]
}

@test "31847 req2: and it used the Codex install's own config, not a Claude Code one" {
    _codex_install
    export MOCK_CURL_HTTP_CODE="202" MOCK_CURL_RESPONSE="$REPLACED"
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$CODEX_HOME" \
        bash "$CODEX_HOME/mmry/hooks-handlers/save-memory.sh" --context "x" --supersedes 42
    [ "$status" -eq 0 ]
    grep -q 'localhost:5399/api/memories/process' "$TEST_TMPDIR/curl-log.txt" || { cat "$TEST_TMPDIR/curl-log.txt"; return 1; }
}

@test "31847 req2: a Codex replacement that leaves the old memory active is exit 3, never success" {
    _codex_install
    export MOCK_CURL_HTTP_CODE="202"
    export MOCK_CURL_RESPONSE='{"message":"Stored 1 memory. Memory 42 could not be replaced and is still active.","stored":1,"supersede":{"memoryId":42,"applied":false,"reason":"still-active"}}'
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$CODEX_HOME" \
        bash "$CODEX_HOME/mmry/hooks-handlers/save-memory.sh" --context "x" --supersedes 42
    [ "$status" -eq 3 ]
    [[ "$output" == *"NOT replaced"* ]]
}

# --- requirement 3: the audience is the server's to keep ---------------------------------------

@test "31847 req3: a replacement with no visibility or group given sends neither" {
    create_test_config "http://localhost:5291" "test-api-key" "apikey" >/dev/null
    export MOCK_CURL_HTTP_CODE="202" MOCK_CURL_RESPONSE="$REPLACED"
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x" --supersedes 42
    [ "$status" -eq 0 ]
    local body; body="$(_process_lines)"
    [[ "$body" != *'"visibility"'* ]] || { echo "sent a visibility: $body"; return 1; }
    [[ "$body" != *'"permissionGroupID"'* ]] || { echo "sent a group: $body"; return 1; }
}

# --- the id the guidance points at is really there ---------------------------------------------

@test "31847: each memory loaded at session start carries an id: line" {
    create_test_config "http://localhost:5291" "test-api-key" "apikey" >/dev/null
    export CLAUDE_SESSION_ID="test-session-31847"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    export MOCK_CURL_HTTP_CODE="200"
    export MOCK_CURL_RESPONSE='[{"id":42,"memoryTier":"Operational","scope":"global","topic":"Office","content":"Third floor."}]'
    bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" >/dev/null 2>&1 || true
    grep -qx 'id: 42' "$TEST_TMPDIR/mmry-memories.md" || { cat "$TEST_TMPDIR/mmry-memories.md"; return 1; }
}

# --- requirements 1 and 2: the assistant is told to replace, on both hosts ---------------------

@test "31847 req1: the Claude Code skill tells the assistant to correct with --supersedes" {
    local f="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    grep -q -- '--supersedes <id of the wrong one>' "$f"
    grep -q 'Where the id comes from' "$f"
    grep -q 'visibility and group' "$f"
}

@test "31847 req1: /mmry:save corrects with --supersedes, not a follow-up beside the old memory" {
    local f="$PLUGIN_ROOT/commands/save.md"
    grep -q -- '--supersedes <id of the wrong memory>' "$f"
    ! grep -q 'save a follow-up memory with the correction' "$f"
}

@test "31847 req2: the Codex skill tells the assistant to correct with --supersedes and read the exit" {
    local f="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    grep -q '^## Correcting a memory' "$f"
    grep -q -- '--supersedes 42' "$f"
    grep -q '| 3 | Saved, but memory 42 may still be active' "$f"
    grep -q 'Where the id comes from' "$f"
    grep -q 'visibility and group' "$f"
}

@test "31847 req2: the Codex correction example runs from the relocatable Codex path" {
    local f="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    awk '/^## Correcting a memory/{on=1} on && /save-memory.sh/{print; exit}' "$f" \
        | grep -qF '"${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/save-memory.sh"'
}
