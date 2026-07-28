#!/usr/bin/env bats
# precompact-check.bats — Test precompact-check.sh debounce and the #30642 delivery contract.

load '../helpers/test-helper'

@test "precompact-check: first invocation blocks (exit 2) with empty stdout (#30642)" {
    # #30642: exit 2 keeps compaction paused; Claude Code discards stdout on exit 2, so the
    # directive is delivered on stderr and stdout must be empty (no JSON).
    rm -f "$TEST_TMPDIR/.mmry-precompact-checked"
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/precompact-check.sh" 2>/dev/null'
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
}

@test "precompact-check: creates marker file" {
    rm -f "$TEST_TMPDIR/.mmry-precompact-checked"
    bash "$PLUGIN_ROOT/hooks-handlers/precompact-check.sh" 2>/dev/null || true
    [[ -f "$TEST_TMPDIR/.mmry-precompact-checked" ]]
}

@test "precompact-check: second invocation within 120s exits 0 and removes marker" {
    rm -f "$TEST_TMPDIR/.mmry-precompact-checked"
    touch "$TEST_TMPDIR/.mmry-precompact-checked"
    run bash "$PLUGIN_ROOT/hooks-handlers/precompact-check.sh"
    [[ "$status" -eq 0 ]]
    # Marker should be removed
    [[ ! -f "$TEST_TMPDIR/.mmry-precompact-checked" ]]
}

@test "precompact-check: old marker (>120s) triggers block again" {
    touch -t 202001010000.00 "$TEST_TMPDIR/.mmry-precompact-checked"
    run bash "$PLUGIN_ROOT/hooks-handlers/precompact-check.sh"
    [[ "$status" -eq 2 ]]
    # #30642: block is signalled by exit 2; the directive (merged stderr) is the payload.
    [[ "$output" == *'Context compression is imminent'* ]]
}

@test "precompact-check: emits the directive on stderr, the channel the model gets on exit 2 (#30642)" {
    rm -f "$TEST_TMPDIR/.mmry-precompact-checked"
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/precompact-check.sh" 2>&1 1>/dev/null'
    [[ "$output" == *'Context compression is imminent'* ]]
    [[ "$output" == *'process-context.sh'* ]]
}

@test "precompact-check: stderr is multi-line with real newlines and no literal backslash-n (#30642 regression)" {
    # The reviewer found the directive text (authored for the old JSON field) printed raw to
    # stderr with literal \n / \" markers. Assert real newlines (multiple lines) and no markers.
    rm -f "$TEST_TMPDIR/.mmry-precompact-checked"
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/precompact-check.sh" 2>&1 1>/dev/null'
    [[ "${#lines[@]}" -ge 2 ]]
    [[ "$output" != *'\n'* ]]
    [[ "$output" != *'\"'* ]]
}

@test "precompact-check: does not use systemMessage (user-only) (#30642)" {
    rm -f "$TEST_TMPDIR/.mmry-precompact-checked"
    run bash "$PLUGIN_ROOT/hooks-handlers/precompact-check.sh"
    [[ "$output" != *'systemMessage'* ]]
}
