#!/usr/bin/env bats
# entry-surface.bats — the database and entry surface is PRESENT IN THIS REPOSITORY (#31460, renamed by #32957).
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
ENTRY_HANDLERS=(
    list-databases.sh
    create-database.sh
    revise-database.sh
    save-entry.sh
    query-entries.sh
    entry-history.sh
)

@test "every database and entry handler exists in hooks-handlers/" {
    local missing=""
    for h in "${ENTRY_HANDLERS[@]}"; do
        [[ -f "$PLUGIN_ROOT/hooks-handlers/$h" ]] || missing+=" $h"
    done
    if [[ -n "$missing" ]]; then
        fail "structured-record handlers missing from the PUBLISHED plugin:${missing}"
    fi
}

@test "database and entry handlers are non-empty and run bash" {
    for h in "${ENTRY_HANDLERS[@]}"; do
        local f="$PLUGIN_ROOT/hooks-handlers/$h"
        [[ -s "$f" ]] || fail "$h is empty"
        local first
        first="$(head -1 "$f")"
        [[ "$first" == "#!/usr/bin/env bash" || "$first" == "#!/bin/bash" ]] || fail "$h has no bash shebang: $first"
    done
}

@test "database and entry handlers are syntactically valid" {
    for h in "${ENTRY_HANDLERS[@]}"; do
        bash -n "$PLUGIN_ROOT/hooks-handlers/$h" || fail "$h does not parse"
    done
}

@test "database and entry handlers source THIS repo's client library, not the API repo's" {
    # The API repo's copy is named mnemo-client.sh. Importing that name here would source a file
    # that does not exist and every handler would die on its first line.
    for h in "${ENTRY_HANDLERS[@]}"; do
        local f="$PLUGIN_ROOT/hooks-handlers/$h"
        grep -q 'hooks-handlers/mmry-client.sh' "$f" || fail "$h does not source mmry-client.sh"
        if grep -q 'mnemo-client.sh' "$f"; then
            fail "$h sources mnemo-client.sh, which does not exist in the published plugin"
        fi
    done
}

@test "database and entry handlers call no mnemo_-prefixed function" {
    # A straight copy from the API repo leaves mnemo_create_format and friends behind. They are
    # undefined here, and under set -e the handler dies with 'command not found'.
    for h in "${ENTRY_HANDLERS[@]}"; do
        local f="$PLUGIN_ROOT/hooks-handlers/$h"
        if grep -qE '\bmnemo_|MNEMO_' "$f"; then
            fail "$h still refers to the API repo's mnemo_ / MNEMO_ names"
        fi
    done
}

@test "client library defines every database and entry function" {
    local lib="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    local missing=""
    for fn in mmry_list_databases mmry_get_database mmry_create_database mmry_revise_database \
              mmry_rename_database mmry_retire_database mmry_reinstate_database \
              mmry_save_entry mmry_get_entries mmry_get_entry_history \
              _mmry_json_string _mmry_database_name; do
        grep -q "^${fn}() {" "$lib" || missing+=" $fn"
    done
    [[ -z "$missing" ]] || fail "mmry-client.sh is missing:${missing}"
}

@test "client library reaches the database routes" {
    local lib="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    grep -q '"/api/databases"' "$lib" || fail "no POST/GET /api/databases"
    grep -q '/api/databases/\${id}/versions' "$lib" || fail "no revise route"
    grep -q '/api/databases/\${database_id}/entries' "$lib" || fail "no entries route"
}

@test "save-memory.sh accepts the three entry flags" {
    local f="$PLUGIN_ROOT/hooks-handlers/save-memory.sh"
    for flag in --database-name --entry-fields --entry-name; do
        grep -q -- "$flag)" "$f" || fail "save-memory.sh does not parse $flag"
    done
}

@test "save-memory.sh reports what was actually saved" {
    # The SavedInDatabase line is the honesty mechanism: a save that named a type may still have been
    # stored as plain text, and the caller must be able to tell. Both branches must be present -
    # a script that only ever prints the happy one is the lie this line exists to prevent.
    local f="$PLUGIN_ROOT/hooks-handlers/save-memory.sh"
    grep -q 'SavedInDatabase: \${saved_in}' "$f" || fail "no SavedInDatabase line for a stored entry"
    grep -q 'SavedInDatabase: (none' "$f" || fail "no SavedInDatabase line for a degraded save"
}

@test "SKILL.md documents the database and entry surface" {
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    grep -q '## Your AI Database' "$skill" || fail "SKILL.md has no AI database section (#32457, DD-150)"
    local missing=""
    for h in "${ENTRY_HANDLERS[@]}"; do
        grep -q "$h" "$skill" || missing+=" $h"
    done
    [[ -z "$missing" ]] || fail "SKILL.md never mentions:${missing}"
    grep -q -- '--database-name' "$skill" || fail "SKILL.md never shows a routed save"
    grep -q 'SavedInDatabase' "$skill" || fail "SKILL.md never tells the assistant to read SavedInDatabase"
}

@test "SKILL.md reaches entries through the handlers, with no server route table (#32272)" {
    # The route table this test used to require was removed by #32272 (DD-140 in the mmry
    # repository): the server's route list is an internal mechanic, and the assistant reaches
    # every record operation through the handlers the test above already requires.
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    ! grep -q '/api/' "$skill" || fail "SKILL.md names a server route"
    grep -q 'list-databases.sh' "$skill" || fail "SKILL.md never names list-databases.sh"
}

@test "client library reaches the entry history route (#31827)" {
    grep -q '/api/databases/\$1/entries/\$2/history' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh" \
        || fail "mmry-client.sh has no record history route"
}

@test "SKILL.md documents entry history and correction (#31827)" {
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    grep -q '### What an entry used to hold' "$skill" || fail "no 'What an entry used to hold' section"
    grep -q '### Correcting an entry' "$skill" || fail "no 'Correcting an entry' section"
    grep -q 'mmryai.com/databases' "$skill" || fail "SKILL.md never tells the assistant about mmryai.com/databases"
    grep -q 'mmry_entry_history' "$skill" || fail "'One account, every surface' omits the connector's history tool"
}

@test "SKILL.md states when a save becomes an entry (#32002)" {
    # Integration, 2026-10-10 (#32002): a save becomes a record when MMRY can tell which type it
    # belongs to AND has values for that type's fields. The skill must say both halves, and tell
    # the assistant that naming the type and giving its fields is the reliable path.
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    if grep -qi 'later ordinary save. be recognised and recorded\|recorded here without the user asking' "$skill"; then
        fail "SKILL.md still claims match hints alone route a plain save into a record type"
    fi
    grep -q 'When a save becomes an entry' "$skill" \
        || fail "SKILL.md does not state when a save becomes an entry"
    grep -q 'Naming the database and giving its fields is the reliable way' "$skill" \
        || fail "SKILL.md does not tell the assistant to name the database"
}
