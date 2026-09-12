#!/usr/bin/env bats
# record-surface.bats — the structured-record surface is PRESENT IN THIS REPOSITORY (#31460).
#
# WHY THIS FILE EXISTS, and it is not a formality. The whole of the structured-record plugin work
# for v1.24 was written into src/Mnemo.Plugin inside the API repository, which is a fossil copy
# that no customer ever receives: the marketplace distributes THIS repository, and an assistant
# looks for these handlers under $CLAUDE_PLUGIN_ROOT here. Two Intervals tasks (#30390, #31460)
# recorded "Plugin: available" while every one of these files was absent from the published
# plugin. The defect was a surface that was CLAIMED AND MISSING.
#
# So these assertions exist to REFUSE when a handler, a client function or its documentation is
# not here. Every one of them fails on an empty tree. They are structural on purpose: they need
# no network, no config and no mock, so nothing can make them pass by accident.

load '../helpers/test-helper'

# The five entry points an assistant is told to run. Absence of any one of them is the defect.
RECORD_HANDLERS=(
    list-formats.sh
    create-format.sh
    revise-format.sh
    save-record.sh
    query-records.sh
)

@test "every structured-record handler exists in hooks-handlers/" {
    local missing=""
    for h in "${RECORD_HANDLERS[@]}"; do
        [[ -f "$PLUGIN_ROOT/hooks-handlers/$h" ]] || missing+=" $h"
    done
    if [[ -n "$missing" ]]; then
        fail "structured-record handlers missing from the PUBLISHED plugin:${missing}"
    fi
}

@test "structured-record handlers are non-empty and run bash" {
    for h in "${RECORD_HANDLERS[@]}"; do
        local f="$PLUGIN_ROOT/hooks-handlers/$h"
        [[ -s "$f" ]] || fail "$h is empty"
        local first
        first="$(head -1 "$f")"
        [[ "$first" == "#!/usr/bin/env bash" || "$first" == "#!/bin/bash" ]] || fail "$h has no bash shebang: $first"
    done
}

@test "structured-record handlers are syntactically valid" {
    for h in "${RECORD_HANDLERS[@]}"; do
        bash -n "$PLUGIN_ROOT/hooks-handlers/$h" || fail "$h does not parse"
    done
}

@test "structured-record handlers source THIS repo's client library, not the API repo's" {
    # The API repo's copy is named mnemo-client.sh. Importing that name here would source a file
    # that does not exist and every handler would die on its first line.
    for h in "${RECORD_HANDLERS[@]}"; do
        local f="$PLUGIN_ROOT/hooks-handlers/$h"
        grep -q 'hooks-handlers/mmry-client.sh' "$f" || fail "$h does not source mmry-client.sh"
        if grep -q 'mnemo-client.sh' "$f"; then
            fail "$h sources mnemo-client.sh, which does not exist in the published plugin"
        fi
    done
}

@test "structured-record handlers call no mnemo_-prefixed function" {
    # A straight copy from the API repo leaves mnemo_create_format and friends behind. They are
    # undefined here, and under set -e the handler dies with 'command not found'.
    for h in "${RECORD_HANDLERS[@]}"; do
        local f="$PLUGIN_ROOT/hooks-handlers/$h"
        if grep -qE '\bmnemo_|MNEMO_' "$f"; then
            fail "$h still refers to the API repo's mnemo_ / MNEMO_ names"
        fi
    done
}

@test "client library defines every structured-record function" {
    local lib="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    local missing=""
    for fn in mmry_list_formats mmry_get_format mmry_create_format mmry_revise_format \
              mmry_rename_format mmry_retire_format mmry_reinstate_format \
              mmry_create_record mmry_get_records _mmry_json_string _mmry_format_name; do
        grep -q "^${fn}() {" "$lib" || missing+=" $fn"
    done
    [[ -z "$missing" ]] || fail "mmry-client.sh is missing:${missing}"
}

@test "client library reaches the data-format routes" {
    local lib="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    grep -q '"/api/data-formats"' "$lib" || fail "no POST/GET /api/data-formats"
    grep -q '/api/data-formats/\${id}/versions' "$lib" || fail "no revise route"
    grep -q '/api/data-formats/\${format_id}/entries' "$lib" || fail "no entries route"
}

@test "save-memory.sh accepts the three record flags" {
    local f="$PLUGIN_ROOT/hooks-handlers/save-memory.sh"
    for flag in --record-type --record-fields --record-name; do
        grep -q -- "$flag)" "$f" || fail "save-memory.sh does not parse $flag"
    done
}

@test "save-memory.sh reports what was actually recorded" {
    # The RecordedAs line is the honesty mechanism: a save that named a type may still have been
    # stored as plain text, and the caller must be able to tell. Both branches must be present -
    # a script that only ever prints the happy one is the lie this line exists to prevent.
    local f="$PLUGIN_ROOT/hooks-handlers/save-memory.sh"
    grep -q 'RecordedAs: \${recorded}' "$f" || fail "no RecordedAs line for a stored record"
    grep -q 'RecordedAs: (none' "$f" || fail "no RecordedAs line for a degraded save"
}

@test "SKILL.md documents the structured-record surface" {
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    grep -q '## Structured Records' "$skill" || fail "SKILL.md has no Structured Records section"
    local missing=""
    for h in "${RECORD_HANDLERS[@]}"; do
        grep -q "$h" "$skill" || missing+=" $h"
    done
    [[ -z "$missing" ]] || fail "SKILL.md never mentions:${missing}"
    grep -q -- '--record-type' "$skill" || fail "SKILL.md never shows a routed save"
    grep -q 'RecordedAs' "$skill" || fail "SKILL.md never tells the assistant to read RecordedAs"
}

@test "SKILL.md lists the data-format endpoints" {
    grep -q '/api/data-formats' "$PLUGIN_ROOT/skills/memory-system/SKILL.md" \
        || fail "SKILL.md's endpoint table omits /api/data-formats"
}
