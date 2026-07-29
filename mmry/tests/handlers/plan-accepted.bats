#!/usr/bin/env bats
# plan-accepted.bats — Test plan-accepted-check.sh and the #30642 delivery contract.

load '../helpers/test-helper'

@test "plan-accepted: exits 2 with empty stdout (directive is on stderr) (#30642)" {
    # #30642: on exit 2 Claude Code discards stdout and feeds stderr to the model, so stdout
    # must be empty (no JSON) and the directive is delivered on stderr.
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/plan-accepted-check.sh" 2>/dev/null'
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
}

@test "plan-accepted: emits the directive on stderr, the channel the model gets on exit 2 (#30642)" {
    # Capture stderr only. #30642: the directive must reach the model, not sit in the
    # user-only systemMessage field.
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/plan-accepted-check.sh" 2>&1 1>/dev/null'
    [[ "$output" == *'accepted an implementation plan'* ]]
    [[ "$output" == *'process-context.sh'* ]]
}

@test "plan-accepted: stderr is multi-line with real newlines and no literal backslash-n (#30642 regression)" {
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/plan-accepted-check.sh" 2>&1 1>/dev/null'
    [[ "${#lines[@]}" -ge 2 ]]
    [[ "$output" != *'\n'* ]]
    [[ "$output" != *'\"'* ]]
}

@test "plan-accepted: does not use systemMessage (user-only) (#30642)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/plan-accepted-check.sh"
    [[ "$output" != *'systemMessage'* ]]
}

@test "plan-accepted: exits with code 2" {
    run bash "$PLUGIN_ROOT/hooks-handlers/plan-accepted-check.sh"
    [[ "$status" -eq 2 ]]
}
