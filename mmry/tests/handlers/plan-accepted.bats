#!/usr/bin/env bats
# plan-accepted.bats — Test plan-accepted-check.sh output.

load '../helpers/test-helper'

@test "plan-accepted: outputs block JSON with decision" {
    run bash "$PLUGIN_ROOT/hooks-handlers/plan-accepted-check.sh"
    [[ "$output" == *'"decision":"block"'* ]]
}

@test "plan-accepted: emits the directive on stderr, the channel the model gets on exit 2 (#30642)" {
    # Capture stderr only. #30642: the directive must reach the model, not sit in the
    # user-only systemMessage field.
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/plan-accepted-check.sh" 2>&1 1>/dev/null'
    [[ "$output" == *'accepted an implementation plan'* ]]
    [[ "$output" == *'process-context.sh'* ]]
}

@test "plan-accepted: does not use systemMessage (user-only) (#30642)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/plan-accepted-check.sh"
    [[ "$output" != *'systemMessage'* ]]
}

@test "plan-accepted: exits with code 2" {
    run bash "$PLUGIN_ROOT/hooks-handlers/plan-accepted-check.sh"
    [[ "$status" -eq 2 ]]
}
