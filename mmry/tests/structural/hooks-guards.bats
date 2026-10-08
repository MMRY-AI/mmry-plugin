#!/usr/bin/env bats
# hooks-guards.bats — Verify hooks.json guards and error message correctness.

load '../helpers/test-helper'

# ── hooks.json uses hook-guard.sh for guarded hooks ──

@test "Stop hook delegates to hook-guard.sh" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    local stop_cmd
    stop_cmd="$(grep -A5 '"Stop"' "$hooks_file" | grep '"command"')"
    [[ "$stop_cmd" == *'hook-guard.sh'* ]]
    [[ "$stop_cmd" == *'stop-check'* ]]
}

@test "PreCompact hook delegates to hook-guard.sh" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    local precompact_cmd
    precompact_cmd="$(grep -A5 '"PreCompact"' "$hooks_file" | grep '"command"')"
    [[ "$precompact_cmd" == *'hook-guard.sh'* ]]
    [[ "$precompact_cmd" == *'precompact-check'* ]]
}

@test "PostToolUse hook delegates to hook-guard.sh" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    local posttool_cmd
    posttool_cmd="$(grep -A10 '"PostToolUse"' "$hooks_file" | grep '"command"')"
    [[ "$posttool_cmd" == *'hook-guard.sh'* ]]
    [[ "$posttool_cmd" == *'plan-accepted-check'* ]]
}

@test "SessionStart hook delegates to session-init.sh" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    local session_cmd
    session_cmd="$(grep -A10 '"SessionStart"' "$hooks_file" | grep '"command"')"
    [[ "$session_cmd" == *'session-init.sh'* ]]
}

# ── hooks.json has no bash -c (Windows quoting fix) ──

@test "hooks.json guard hooks use a shell -c with existence check" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    # Guard-based hooks (Stop, PreCompact, PostToolUse) intentionally use a `-c` wrapper
    # to check if the stable copy exists before running. The formation-check registrations
    # use `sh -c`, because their first step is the POSIX membership gate (#31746); the
    # others use `bash -c`. Either way the guard's existence is tested before it is run.
    local guard_cmds
    guard_cmds="$(grep '"command"' "$hooks_file" | grep 'hook-guard.sh')"
    [[ -n "$guard_cmds" ]] || return 1
    local line n=0
    while IFS= read -r line; do
        [[ "$line" == *'bash -c'* || "$line" == *'sh -c'* ]] || { echo "no -c wrapper: $line"; return 1; }
        [[ "$line" == *'[ -f'* ]] || { echo "no existence check: $line"; return 1; }
        n=$((n + 1))
    done <<< "$guard_cmds"
    (( n > 0 )) || return 1
}

# This test used to require '|| true' on EVERY guard hook, and that requirement was itself the
# defect (#31196). In the shape '[ -f x ] && bash y || true' the trailing || true catches the
# handler's exit code as well as the missing-file case, so a handler that delivers by exiting 2
# was reported to Claude Code as exit 0 - nothing to report - and its message never entered the
# model's context. Proven against Claude Code 2.1.236: the wrapped form delivered nothing to the
# model, the unwrapped form delivered verbatim.
#
# So the invariant is not "always || true". It is: a hook whose exit code carries no meaning may
# swallow it, and a hook that DELIVERS by exit code must not. The two are separated by name here
# rather than by rule, because which handlers deliver is a fact about them, not a pattern.
@test "hooks.json: delivery hooks preserve their exit code, guard-only hooks may swallow it" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

    # formation-check delivers on exit 2. Swallowing it is silent, total delivery failure.
    run grep -c 'formation-check || true' "$hooks_file"
    [ "$output" -eq 0 ]

    # ...and it still guards the missing-file case, which is the only thing that may map to 0. Since
    # #31746 the registration is the membership gate, which tests for the guard with `[ -f` and then
    # EXECs it, so the guard's exit code - and the handler's 2 - is the registration's exit code.
    local fc line n=0
    fc="$(grep '"command"' "$hooks_file" | grep 'formation-check')"
    [[ -n "$fc" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == *'[ -f'* ]] || { echo "no existence check: $line"; return 1; }
        [[ "$line" == *'exec bash ~/.claude/mmry/hooks-handlers/hook-guard.sh formation-check'* ]] || {
            echo "the guard is not exec'd, so its exit code may not survive: $line"; return 1; }
        n=$((n + 1))
    done <<< "$fc"
    (( n == 4 )) || { echo "expected 4 formation-check registrations, found $n"; return 1; }
}

# ── hook-guard.sh behavior ──

@test "hook-guard.sh exits 0 silently when target script does not exist" {
    run bash "$PLUGIN_ROOT/hooks-handlers/hook-guard.sh" nonexistent-script
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "hook-guard.sh exits 0 silently when no argument given" {
    run bash "$PLUGIN_ROOT/hooks-handlers/hook-guard.sh"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── mmry-client.sh error message ──

@test "mmry-client.sh no-API-key message references /mmry:setup" {
    local client_file="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    grep -q '/mmry:setup' "$client_file"
}

@test "mmry-client.sh no-API-key message does not reference file path" {
    local client_file="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    # Old message referenced the pre-rebrand file name mnemo-setup.sh; guard against regression
    ! grep -q 'mnemo-setup\.sh' "$client_file"
}
