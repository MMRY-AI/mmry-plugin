#!/usr/bin/env bats
# hooks-json.bats — Validate hooks.json structure and references.

load '../helpers/test-helper'

HOOKS_FILE=""

setup() {
    HOOKS_FILE="$PLUGIN_ROOT/hooks/hooks.json"
}

@test "hooks.json exists" {
    [[ -f "$HOOKS_FILE" ]]
}

@test "hooks.json is valid JSON" {
    if command -v jq &>/dev/null; then
        jq empty "$HOOKS_FILE"
    else
        local content
        content="$(cat "$HOOKS_FILE" | tr -d '[:space:]')"
        [[ "$content" == "{"* && "$content" == *"}" ]]
    fi
}

@test "hooks.json has SessionStart hook" {
    if command -v jq &>/dev/null; then
        local count
        count="$(jq '.hooks.SessionStart | length' "$HOOKS_FILE")"
        (( count >= 1 ))
    else
        grep -q '"SessionStart"' "$HOOKS_FILE"
    fi
}

@test "hooks.json has Stop hook" {
    if command -v jq &>/dev/null; then
        local count
        count="$(jq '.hooks.Stop | length' "$HOOKS_FILE")"
        (( count >= 1 ))
    else
        grep -q '"Stop"' "$HOOKS_FILE"
    fi
}

@test "hooks.json has PreCompact hook" {
    if command -v jq &>/dev/null; then
        local count
        count="$(jq '.hooks.PreCompact | length' "$HOOKS_FILE")"
        (( count >= 1 ))
    else
        grep -q '"PreCompact"' "$HOOKS_FILE"
    fi
}

@test "hooks.json has PostToolUse hook with ExitPlanMode matcher" {
    if command -v jq &>/dev/null; then
        local matcher
        matcher="$(jq -r '.hooks.PostToolUse[0].matcher' "$HOOKS_FILE")"
        [[ "$matcher" == "ExitPlanMode" ]]
    else
        grep -q '"ExitPlanMode"' "$HOOKS_FILE"
    fi
}

@test "hooks.json command paths reference session-init.sh" {
    grep -q 'session-init.sh' "$HOOKS_FILE"
}

@test "hooks.json command paths reference hook-guard.sh for stop-check" {
    local stop_cmd
    stop_cmd="$(grep -A5 '"Stop"' "$HOOKS_FILE" | grep '"command"')"
    [[ "$stop_cmd" == *'hook-guard.sh'* ]]
    [[ "$stop_cmd" == *'stop-check'* ]]
}

@test "hooks.json command paths reference hook-guard.sh for precompact-check" {
    local precompact_cmd
    precompact_cmd="$(grep -A5 '"PreCompact"' "$HOOKS_FILE" | grep '"command"')"
    [[ "$precompact_cmd" == *'hook-guard.sh'* ]]
    [[ "$precompact_cmd" == *'precompact-check'* ]]
}

@test "hooks.json command paths reference hook-guard.sh for plan-accepted-check" {
    local posttool_cmd
    posttool_cmd="$(grep -A10 '"PostToolUse"' "$HOOKS_FILE" | grep '"command"')"
    [[ "$posttool_cmd" == *'hook-guard.sh'* ]]
    [[ "$posttool_cmd" == *'plan-accepted-check'* ]]
}

# #31856: the label shown when a formation message wakes an idle session.
@test "hooks.json wake label for formation-check is exactly 'MMRY AI: Formation Transmission'" {
    local label
    label="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.Stop||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));if(s.length!==1)process.exit(2);process.stdout.write(String(s[0].rewakeSummary))' "$HOOKS_FILE")"
    [[ "$label" == "MMRY AI: Formation Transmission" ]]
}
