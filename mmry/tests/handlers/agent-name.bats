#!/usr/bin/env bats
# agent-name.bats - the creating agent's name travels with every save (#30320).
#
# A memory records the name of the agent that created it, as its own field. The plugin's part is
# to put that name in the save request without the user tagging anything:
#
#   - save-memory.sh and process-context.sh take --agent-name, and otherwise fall back to
#     MMRY_AGENT_NAME (a name the user configured), then MMRY_SESSION_AGENT_NAME (what Claude Code
#     reported for this session).
#   - session-start.sh reads agent_type from the SessionStart payload, which Claude Code sends when
#     the session was started with `claude --agent <name>`, and exports it through
#     CLAUDE_ENV_FILE, which Claude Code sources before each Bash tool command. That is the shell
#     save-memory.sh runs in.
#   - No name from any of them sends no agentName, and the save is otherwise unchanged.
#   - A name that cannot be sent as given (over 100 characters, control characters) is not sent,
#     and the memory is still saved.
#
# Every assertion reads the request BODY the mock curl logged, because "the save succeeded" is
# true whether or not the name went with it.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    unset MMRY_AGENT_NAME MMRY_SESSION_AGENT_NAME CLAUDE_ENV_FILE
}

# The JSON body of the last POST to the given path, from the mock curl log.
_last_body() {
    grep "^POST .*$1 " "$TEST_TMPDIR/curl-log.txt" | tail -1 | sed "s#^POST [^ ]* ##"
}

_agent_in_last_save() {
    printf '%s' "$(_last_body /api/memories/process)" | jq -r 'if has("agentName") then .agentName else "<absent>" end'
}

@test "agent-name: --agent-name is sent as agentName on a save" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "Ship on Friday" --agent-name "release-manager"
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = "release-manager" ] || { echo "body: $(_last_body /api/memories/process)"; return 1; }
}

@test "agent-name: a save with no agent identity sends no agentName and is otherwise unchanged" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "Ship on Friday"
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = "<absent>" ] || return 1
    [ "$(printf '%s' "$(_last_body /api/memories/process)" | jq -r '.context')" = "Ship on Friday" ]
}

@test "agent-name: MMRY_AGENT_NAME is used when no flag is given" {
    MMRY_AGENT_NAME="configured-agent" run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x"
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = "configured-agent" ]
}

@test "agent-name: the session's reported agent is used when nothing else names one" {
    MMRY_SESSION_AGENT_NAME="security-reviewer" run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x"
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = "security-reviewer" ]
}

@test "agent-name: precedence is flag, then configured name, then the session's agent" {
    MMRY_AGENT_NAME="configured" MMRY_SESSION_AGENT_NAME="session" \
        run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x" --agent-name "flagged"
    [ "$(_agent_in_last_save)" = "flagged" ] || return 1
    MMRY_AGENT_NAME="configured" MMRY_SESSION_AGENT_NAME="session" \
        run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x"
    [ "$(_agent_in_last_save)" = "configured" ]
}

@test "agent-name: quotes, backslashes and non-ASCII reach the body unchanged" {
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x" --agent-name 'O"Brien \ Zoë'
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = 'O"Brien \ Zoë' ] || { echo "body: $(_last_body /api/memories/process)"; return 1; }
}

@test "agent-name: an over-long name is not sent, and the memory is still saved" {
    long="$(printf 'a%.0s' $(seq 1 101))"
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "keep these words" --agent-name "$long"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"longer than 100 characters"* ]] || return 1
    [ "$(_agent_in_last_save)" = "<absent>" ] || return 1
    [ "$(printf '%s' "$(_last_body /api/memories/process)" | jq -r '.context')" = "keep these words" ]
}

@test "agent-name: exactly one hundred characters is sent unchanged" {
    exact="$(printf 'a%.0s' $(seq 1 99))z"
    run bash "$PLUGIN_ROOT/hooks-handlers/save-memory.sh" --context "x" --agent-name "$exact"
    [ "$(_agent_in_last_save)" = "$exact" ]
}

@test "agent-name: process-context.sh sends --agent-name and the session agent too" {
    run bash "$PLUGIN_ROOT/hooks-handlers/process-context.sh" --hook-type precompact --context "briefing" --agent-name "planner"
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = "planner" ] || return 1
    MMRY_SESSION_AGENT_NAME="session-agent" run bash "$PLUGIN_ROOT/hooks-handlers/process-context.sh" --hook-type stop --context "segment"
    [ "$(_agent_in_last_save)" = "session-agent" ]
}

@test "agent-name: mmry_create_memory sends a fourteenth argument as agentName" {
    run bash -c "source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh' && mmry_load_config >/dev/null 2>&1; \
        mmry_create_memory Operational Fact global T C '' '' '' '' '' '' '' '' 'direct-agent'"
    [ "$(printf '%s' "$(_last_body '/api/memories')" | jq -r '.agentName')" = "direct-agent" ]
}

# ---- SessionStart: Claude Code's agent_type reaches the Bash tool shell --------------------

_session_start_with() {
    # $1 = the hook payload. HOME is isolated so the handler copy step touches nothing real.
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    export CLAUDE_ENV_FILE="$TEST_TMPDIR/claude-env.sh"
    : > "$CLAUDE_ENV_FILE"
    run bash -c "printf '%s' '$1' | bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh'"
}

@test "agent-name: SessionStart with agent_type exports it through CLAUDE_ENV_FILE" {
    _session_start_with '{"session_id":"s-1","hook_event_name":"SessionStart","source":"startup","agent_type":"security-reviewer"}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q "^export MMRY_SESSION_AGENT_NAME='security-reviewer'$" "$CLAUDE_ENV_FILE" || { cat "$CLAUDE_ENV_FILE"; return 1; }
}

@test "agent-name: end to end, a session started as an agent saves under that agent's name" {
    # The whole chain the customer gets, with no tagging: Claude Code reports the agent at
    # SessionStart, the env file is sourced into the Bash tool shell, the assistant runs the save
    # command exactly as /mmry:save tells it to, and the request carries the name.
    _session_start_with '{"session_id":"s-2","hook_event_name":"SessionStart","source":"startup","agent_type":"my-plugin:reviewer"}'
    [[ "$status" -eq 0 ]] || return 1
    run bash -c "source '$CLAUDE_ENV_FILE' && bash '$PLUGIN_ROOT/hooks-handlers/save-memory.sh' --context 'reviewed the PR'"
    [[ "$status" -eq 0 ]] || return 1
    [ "$(_agent_in_last_save)" = "my-plugin:reviewer" ]
}

@test "agent-name: SessionStart without agent_type clears any earlier name for the session" {
    _session_start_with '{"session_id":"s-3","hook_event_name":"SessionStart","source":"resume"}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q "^unset MMRY_SESSION_AGENT_NAME$" "$CLAUDE_ENV_FILE" || { cat "$CLAUDE_ENV_FILE"; return 1; }
    run bash -c "export MMRY_SESSION_AGENT_NAME=stale; source '$CLAUDE_ENV_FILE' && bash '$PLUGIN_ROOT/hooks-handlers/save-memory.sh' --context 'x'"
    [ "$(_agent_in_last_save)" = "<absent>" ]
}

@test "agent-name: a run with no hook payload (/mmry:load-memories) leaves the env file alone" {
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    export CLAUDE_ENV_FILE="$TEST_TMPDIR/claude-env.sh"
    printf "export MMRY_SESSION_AGENT_NAME='kept'\n" > "$CLAUDE_ENV_FILE"
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" < /dev/null
    [ "$(cat "$CLAUDE_ENV_FILE")" = "export MMRY_SESSION_AGENT_NAME='kept'" ]
}

@test "agent-name: a hostile agent_type cannot run anything when the env file is sourced" {
    _session_start_with '{"session_id":"s-4","hook_event_name":"SessionStart","agent_type":"x$(touch PWNED)`touch PWNED2`"}'
    [[ "$status" -eq 0 ]] || return 1
    run bash -c "cd '$TEST_TMPDIR' && source '$CLAUDE_ENV_FILE' && printf '%s' \"\$MMRY_SESSION_AGENT_NAME\""
    [ "$output" = 'x$(touch PWNED)`touch PWNED2`' ] || { echo "got: $output"; return 1; }
    [ ! -e "$TEST_TMPDIR/PWNED" ] && [ ! -e "$TEST_TMPDIR/PWNED2" ]
}

@test "agent-name: no CLAUDE_ENV_FILE (Codex, or any other host) writes nothing and does not fail" {
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    unset CLAUDE_ENV_FILE
    run bash -c "printf '%s' '{\"session_id\":\"s-5\",\"agent_type\":\"a\"}' | bash '$PLUGIN_ROOT/hooks-handlers/session-start.sh'"
    [[ "$status" -eq 0 ]]
}
