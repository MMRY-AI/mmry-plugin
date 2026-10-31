#!/usr/bin/env bats
# entry-page-fit.bats - a page of entries read through the plugin fits the tool that prints it
# (#33197 round 2, DD-165).
#
# query-entries.sh prints through the assistant's shell tool, which cuts output far below what a
# connector reply holds: Claude Code's Bash tool at 30,000 characters, the Codex shell at 10,000
# tokens (measured live in #33197 round 3: whole at 36,045 characters, cut at 42,084; the plugin
# holds Codex to 32,000). The mock API below pages like the real one: asked for
# an entry budget it returns the entries that fit; asked for none it returns all 40 entries of
# 2,000 characters, about 84,000 characters printed. So every test here FAILS if query-entries stops
# asking for the budget.

load '../helpers/test-helper'
load '../helpers/mock-config'

HANDLERS=""
LOG=""

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
    LOG="$TEST_TMPDIR/curl-log.txt"
    export MOCK_ENTRIES_WIDE=40 MOCK_ENTRY_VALUE_CHARS=2000
    unset MMRY_REPLY_CHARACTERS BASH_MAX_OUTPUT_LENGTH MMRY_HOST
}

teardown() {
    unset MOCK_ENTRIES_WIDE MOCK_ENTRY_VALUE_CHARS MOCK_ENTRIES_IGNORE_BUDGET MMRY_REPLY_CHARACTERS BASH_MAX_OUTPUT_LENGTH MMRY_HOST
}

bytes() { LC_ALL=C; printf '%s' "${#1}"; }

@test "entry-page-fit: on Claude Code a default read arrives whole, under 30,000 characters, with how to page on" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    local n; n="$(bytes "$output")"
    (( n <= 30000 )) || { echo "printed $n bytes"; return 1; }
    grep -q "entryCharacters=20000" "$LOG" || { cat "$LOG"; return 1; }
    [[ "$output" == *"Next page: --page 2 --page-size"* ]] || { echo "$output" | head -5; return 1; }
    # Whole: every entry the page names is printed, ending with its separator.
    local listed; listed="$(grep -c '^id ' <<<"$output")"
    [[ "$output" == *"per page, 40 in total."* ]] || { echo "$output" | head -3; return 1; }
    [[ "$(tail -n 1 <<<"$output")" == "---" ]] || return 1
    (( listed >= 1 ))
}

@test "entry-page-fit: Claude Code's own BASH_MAX_OUTPUT_LENGTH is honoured" {
    export BASH_MAX_OUTPUT_LENGTH=12000
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || return 1
    (( $(bytes "$output") <= 12000 )) || return 1
    grep -q "entryCharacters=8000" "$LOG"
}

@test "entry-page-fit: under Codex the page is held to 32,000 bytes, under the 36,000 measured" {
    # #33197 round 3: Codex was measured live showing a reply whole at 36,045 characters and cut at
    # 42,084 (10,000 of its tokens); 32,000 is the reply budget the API uses for the same reason.
    export MMRY_HOST=codex
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    (( $(bytes "$output") <= 32000 )) || return 1
    grep -q "entryCharacters=21333" "$LOG" || { cat "$LOG"; return 1; }
}

@test "entry-page-fit: a page that still prints over the limit is asked for again, smaller" {
    export MOCK_ENTRIES_IGNORE_BUDGET=1
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || return 1
    (( $(bytes "$output") <= 30000 )) || { echo "printed $(bytes "$output") bytes"; return 1; }
    [[ "$(grep -c 'entries' "$LOG")" -ge 2 ]] || { cat "$LOG"; return 1; }
}

@test "entry-page-fit: an explicit --page-size is still held to the limit" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --page 1 --page-size 40
    [[ "$status" -eq 0 ]] || return 1
    (( $(bytes "$output") <= 30000 )) || return 1
    grep -q "pageSize=40" "$LOG"
    grep -q "entryCharacters=" "$LOG"
}
