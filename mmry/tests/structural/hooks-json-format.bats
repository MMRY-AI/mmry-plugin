#!/usr/bin/env bats
# hooks-json-format.bats - the two hook registration files carry no trailing spaces (#33904).
#
# WHY. mmry/hooks/hooks.json had 66 of its 169 lines ending in a space: 62 since before #33452 and 4
# added by its Notification block. Nothing checked it, so each change to the file copied the habit
# forward and every review diff carried whitespace noise. codex-hooks.json never had any. #33904
# cleaned the whole file and this test keeps both clean.
#
# The check reads bytes, not parsed JSON, because a trailing space is invisible to every JSON
# reader: jq -S of the file before and after the clean-up is identical, which the PR records.

load '../helpers/test-helper'

HOOK_FILES=(hooks/hooks.json hooks/codex-hooks.json)

# Prints "file:line" for every line ending in a space or a tab, CR excluded so a CRLF checkout of
# an otherwise clean file is not reported as a trailing space.
_trailing_whitespace() {
    local rel="$1"
    awk -v f="$rel" '{ sub(/\r$/, "") } /[ \t]$/ { print f ":" NR }' "$PLUGIN_ROOT/$rel"
}

@test "hooks-json: both hook registration files exist (the checks below are not vacuous)" {
    local rel
    for rel in "${HOOK_FILES[@]}"; do
        [ -s "$PLUGIN_ROOT/$rel" ] || { echo "missing or empty: $rel"; return 1; }
    done
}

@test "hooks-json: hooks.json has no line ending in a space or a tab" {
    run _trailing_whitespace hooks/hooks.json
    [ "$status" -eq 0 ]
    if [ -n "$output" ]; then
        echo "trailing whitespace at:"
        echo "$output"
        return 1
    fi
}

@test "hooks-json: codex-hooks.json has no line ending in a space or a tab" {
    run _trailing_whitespace hooks/codex-hooks.json
    [ "$status" -eq 0 ]
    if [ -n "$output" ]; then
        echo "trailing whitespace at:"
        echo "$output"
        return 1
    fi
}

@test "hooks-json: the check can fail (a planted trailing space is reported)" {
    local d="$BATS_TEST_TMPDIR/plant/hooks"
    mkdir -p "$d"
    printf '{\n  "a": 1, \n  "b": 2\n}\n' > "$d/hooks.json"
    local saved="$PLUGIN_ROOT"
    PLUGIN_ROOT="$BATS_TEST_TMPDIR/plant"
    run _trailing_whitespace hooks/hooks.json
    PLUGIN_ROOT="$saved"
    [ "$status" -eq 0 ]
    [ "$output" = "hooks/hooks.json:2" ]
}

@test "hooks-json: both files are valid JSON" {
    command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
    local rel
    for rel in "${HOOK_FILES[@]}"; do
        jq -e . "$PLUGIN_ROOT/$rel" >/dev/null || { echo "not valid JSON: $rel"; return 1; }
    done
}
