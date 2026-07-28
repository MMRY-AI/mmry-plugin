#!/usr/bin/env bats
# stop-check.bats — Test stop-check.sh debounce, output, and the #29912/#30642 contract.

load '../helpers/test-helper'

setup() {
    # Each test starts with clean state files.
    rm -f "$TEST_TMPDIR/.mmry-stop-checked"
    rm -f "$TEST_TMPDIR/.mmry-stop-count"
    rm -f "$TEST_TMPDIR/.mmry-last-save"
}

# --- Debounce and basic block contract -------------------------------------

@test "stop-check: first invocation blocks (exit 2) and emits decision:block" {
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    # #30642: exit 2 is preserved so the stop stays blocked; Claude Code feeds the hook's
    # stderr to the model on exit 2 (that is where the directive now lives).
    [[ "$status" -eq 2 ]]
    [[ "$output" == *'"decision":"block"'* ]]
}

@test "stop-check: creates marker file" {
    bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" 2>/dev/null || true
    [[ -f "$TEST_TMPDIR/.mmry-stop-checked" ]]
}

@test "stop-check: second invocation within debounce window exits 0 with no output" {
    # Pre-stamp a fresh marker.
    touch "$TEST_TMPDIR/.mmry-stop-checked"
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "stop-check: old marker (>900s) triggers block again" {
    # #29912 — debounce extended from 120s to 900s. Use a clearly-old marker.
    touch -t 202001010000.00 "$TEST_TMPDIR/.mmry-stop-checked"
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *'"decision":"block"'* ]]
}

# --- #30642 delivery contract ----------------------------------------------

@test "stop-check: directive is emitted on stderr, the channel the model gets on exit 2 (#30642)" {
    # Capture stderr only (stdout to /dev/null).
    run bash -c 'bash "'"$PLUGIN_ROOT"'/hooks-handlers/stop-check.sh" 2>&1 1>/dev/null'
    [[ "$output" == *'Save what is new since the last memory'* ]]
    [[ "$output" == *'save-memory.sh'* ]]
    [[ "$output" == *'skip'* ]]
}

@test "stop-check: does not use systemMessage (user-only) or an empty reason (#30642)" {
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" != *'systemMessage'* ]]
    [[ "$output" != *'"reason":""'* ]]
    # Old status-line phrasing must be gone.
    [[ "$output" != *'Mnemo: saving important memories'* ]]
}

@test "stop-check: directive is a single imperative with an explicit skip clause" {
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *'Save what is new since the last memory'* ]]
    [[ "$output" == *'save-memory.sh'* ]]
    [[ "$output" == *'skip'* ]]
}

# --- #29912 escalation / anchoring contract --------------------------------

@test "stop-check: increments firings counter on each unique trigger" {
    bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" >/dev/null 2>&1 || true
    local first
    first="$(cat "$TEST_TMPDIR/.mmry-stop-count" 2>/dev/null)"
    [[ "$first" == "1" ]]

    # Force the marker old so the next call is not debounced.
    touch -t 202001010000.00 "$TEST_TMPDIR/.mmry-stop-checked"
    bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" >/dev/null 2>&1 || true
    local second
    second="$(cat "$TEST_TMPDIR/.mmry-stop-count" 2>/dev/null)"
    [[ "$second" == "2" ]]
}

@test "stop-check: compliance escalation triggers at 3+ firings without save" {
    # Pre-set counter to 2 so this firing becomes the 3rd.
    echo "2" > "$TEST_TMPDIR/.mmry-stop-count"
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *'You have skipped 3 Stop firings without saving'* ]]
    [[ "$output" == *'briefly state'* ]]
}

@test "stop-check: no escalation on first firing" {
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" != *'You have skipped'* ]]
}

@test "stop-check: surfaces last-save anchor when .mmry-last-save exists" {
    # 5-minute-old save.
    python_or_date_ts=$(($(date +%s) - 300))
    echo "$python_or_date_ts" > "$TEST_TMPDIR/.mmry-last-save"

    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *'Your last save was 5 minute(s) ago'* ]]
    [[ "$output" == *'save only what is new'* ]]
}

@test "stop-check: no last-save clause when sentinel absent" {
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" != *'Your last save was'* ]]
}

@test "stop-check: successful save (deleting counter file) drops escalation" {
    # Counter reset is what mmry-client.sh's _mmry_mark_save_success does.
    echo "5" > "$TEST_TMPDIR/.mmry-stop-count"
    rm -f "$TEST_TMPDIR/.mmry-stop-count"  # simulate save success reset
    run bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh"
    [[ "$status" -eq 2 ]]
    [[ "$output" != *'You have skipped'* ]]
}
