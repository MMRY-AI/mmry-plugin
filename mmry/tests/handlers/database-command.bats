#!/usr/bin/env bats
# database-command.bats - /mmry:database and the scripts it reaches, against the mock API (#32443).
#
# The command page tells the assistant to run database.sh with a subcommand. These tests run it the
# same way and check three things for every subcommand: the request that actually left the machine
# (method, path, body, read from the mock curl's log), what was printed, and that a successful
# answer ends with the account page where the customer corrects entries themselves.
#
# The page and the script are checked against each other too: each subcommand's section on the page
# runs database.sh with that subcommand, so the page cannot send the assistant somewhere else.

load '../helpers/test-helper'
load '../helpers/mock-config'

HANDLERS=""
LOG=""
PORTAL="See your databases and correct any entry yourself at https://mmryai.com/databases"

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
    LOG="$TEST_TMPDIR/curl-log.txt"
}

db() { bash "$HANDLERS/database.sh" "$@"; }

# The last non-empty line of the output.
_last_line() { printf '%s\n' "$output" | tr -d '\r' | grep -v '^$' | tail -1; }

# --- the page and the script agree ------------------------------------------

@test "database page: every subcommand section runs database.sh with that subcommand" {
    local page="$PLUGIN_ROOT/commands/database.md" sub section
    for sub in create list add find correct history retire restore; do
        # The section is everything from "### sub" to the next "### " heading.
        section="$(tr -d '\r' < "$page" | awk -v h="### $sub" '$0 == h {on=1; next} on && /^### / {exit} on {print}')"
        [[ -n "$section" ]] || { echo "no section for $sub"; return 1; }
        grep -qF "hooks-handlers/database.sh\" $sub" <<< "$section" || { echo "section $sub does not run database.sh $sub"; return 1; }
    done
}

@test "database page: says database and entry, and tells the assistant to keep the portal line" {
    local page="$PLUGIN_ROOT/commands/database.md"
    grep -q "https://mmryai.com/databases" "$page"
    grep -q "keep that line in your answer" "$page"
    # DD-150: the customer's words. DD-164 (#32957): the names too, so no retired script or option.
    ! grep -qiE 'record type' "$page"
    ! grep -qE 'create-format|list-formats|revise-format|save-record|query-records|record-history|--format-id|--record-(id|type|name|fields)' "$page"
    grep -q "Asking in plain words" "$page"
}

# --- R1: create with a description -------------------------------------------

@test "create: defines a database through create-database.sh, description included, and links the portal" {
    run db create --name "Migraine log" --description "Every migraine and what came before it" \
        --fields '[{"key":"severity","label":"Severity","type":"number"}]' --match-hints "migraine, headache"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Created the database Migraine log with id 42."* ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases ' "$LOG"
    grep -q '"name":"Migraine log"' "$LOG"
    grep -q '"description":"Every migraine and what came before it"' "$LOG"
    grep -q '"fieldSchema":"\[{\\"key\\":\\"severity\\"' "$LOG"
    grep -q '"matchHints":"migraine, headache"' "$LOG"
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "create: a refusal from create-database.sh is passed through, with no portal line and no request" {
    run db create --description "no name or fields"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--name and --fields are required"* ]] || return 1
    [[ "$output" != *"mmryai.com/databases"* ]] || return 1
    [[ ! -f "$LOG" ]] || ! grep -q "api/databases" "$LOG"
}

# --- R2: every other subcommand ----------------------------------------------

@test "list: reads the databases and prints them" {
    run db list
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"2 database(s)"* ]] || return 1
    [[ "$output" == *"Migraine log"* ]] || return 1
    grep -q "GET http://localhost:5291/api/databases" "$LOG"
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "list --id: reads one database with its fields" {
    run db list --id 42
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"Database: Migraine log"* ]] || return 1
    [[ "$output" == *"severity (number)"* ]] || return 1
    grep -q "GET http://localhost:5291/api/databases/42" "$LOG"
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "list --include-retired: is forwarded" {
    run db list --include-retired
    [[ "$status" -eq 0 ]] || return 1
    grep -q "includeRetired=true" "$LOG"
}

@test "add: saves an entry through save-entry.sh and prints the outcome" {
    run db add --database-id 42 --content "Migraine on Tuesday after red wine" --fields '{"severity":7}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases/42/entries' "$LOG"
    grep -q '"content":"Migraine on Tuesday after red wine"' "$LOG"
    grep -q '"fields":{"severity":7}' "$LOG"
    ! grep -q '"entryId"' "$LOG" || return 1
    [[ "$output" == *"Outcome: structured.created  (memory 99)"* ]] || return 1
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "add: naming an existing entry is refused before any request, pointing at correct" {
    run db add --database-id 42 --entry-id 7 --content "x"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"use correct with --entry-id"* ]] || return 1
    [[ ! -f "$LOG" ]] || ! grep -q "api/databases" "$LOG"
}

@test "find: reads entries through query-entries.sh with the filter and order" {
    run db find --database-id 42 --filter severity=7 --order "severity desc"
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'GET http://localhost:5291/api/databases/42/entries?field.severity=7&order=severity%20desc' "$LOG"
    [[ "$output" == *"2 entries in Migraine log:"* ]] || return 1
    [[ "$output" == *"severity: 7"* ]] || return 1
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "correct: updates the named entry through save-entry.sh and reports the server's outcome" {
    export MOCK_CURL_RESPONSE='{"outcome":"structured.updated","memoryId":99,"entryId":7}'
    run db correct --database-id 42 --entry-id 7 --content "It was a 5, not a 7" --fields '{"severity":5}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases/42/entries' "$LOG"
    grep -q '"entryId":7' "$LOG"
    grep -q '"fields":{"severity":5}' "$LOG"
    [[ "$output" == *"Outcome: structured.updated  (memory 99)"* ]] || return 1
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "correct: without --entry-id is refused before any request" {
    run db correct --database-id 42 --content "x" --fields '{"severity":5}'
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"correct needs --entry-id"* ]] || return 1
    [[ ! -f "$LOG" ]] || ! grep -q "api/databases" "$LOG"
}

@test "history: reads the entry's history through entry-history.sh and prints it oldest first" {
    run db history --database-id 42 --entry-id 9137
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'GET http://localhost:5291/api/databases/42/entries/9137/history' "$LOG"
    [[ "$output" == *"was: open  now: in progress"* ]] || return 1
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "retire: retires through retire-database.sh, says nothing was deleted, and links the portal" {
    run db retire --id 42
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases/42/retire' "$LOG"
    [[ "$output" == *"It still holds 41 entries."* ]] || return 1
    [[ "$output" == *"keeps every entry it holds"* ]] || return 1
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "restore: reinstates through reinstate-database.sh and links the portal" {
    run db restore --id 42
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases/42/reinstate' "$LOG"
    [[ "$output" == *"Collecting again."* ]] || return 1
    [ "$(_last_line)" = "$PORTAL" ]
}

@test "a server refusal is passed through with its status and no portal line" {
    export MOCK_CURL_HTTP_CODE=404
    export MOCK_CURL_RESPONSE='{"error":"Not found."}'
    run db retire --id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"Error (HTTP 404)"* ]] || return 1
    [[ "$output" != *"mmryai.com/databases"* ]] || return 1
}

@test "no subcommand, or an unknown one, prints the usage and sends nothing" {
    run db
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"Subcommands: create, list, add, find, correct, history, retire, restore."* ]] || return 1
    run db delete --id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"unknown subcommand 'delete'"* ]] || return 1
    [[ ! -f "$LOG" ]] || ! grep -q "api/databases" "$LOG"
}

# --- the three parity scripts ------------------------------------------------

@test "rename-database: renames through PUT, touching no field" {
    run bash "$HANDLERS/rename-database.sh" --id 42 --name "Headache log" --description "Every headache"
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'PUT http://localhost:5291/api/databases/42 ' "$LOG"
    grep -q '"name":"Headache log"' "$LOG"
    grep -q '"description":"Every headache"' "$LOG"
    ! grep -q "/versions" "$LOG" || return 1
    [[ "$output" == *"Database: Headache log (id 42"* ]] || return 1
}

@test "rename-database: requires --id and something to change" {
    run bash "$HANDLERS/rename-database.sh" --name "X"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--id is required"* ]] || return 1
    run bash "$HANDLERS/rename-database.sh" --id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"nothing to change"* ]] || return 1
    [[ ! -f "$LOG" ]] || ! grep -q "api/databases" "$LOG"
}

@test "retire-database: retires by id" {
    run bash "$HANDLERS/retire-database.sh" --id 42
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases/42/retire' "$LOG"
    [[ "$output" == *"Retired."* ]] || return 1
}

@test "reinstate-database: reinstates by id" {
    run bash "$HANDLERS/reinstate-database.sh" --id 42
    [[ "$status" -eq 0 ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases/42/reinstate' "$LOG"
    [[ "$output" == *"Collecting again."* ]] || return 1
}

@test "retire-database and reinstate-database: require --id and refuse anything else" {
    local s
    for s in retire-database.sh reinstate-database.sh; do
        run bash "$HANDLERS/$s"
        [[ "$status" -ne 0 && "$output" == *"--id is required"* ]] || { echo "$s: $output"; return 1; }
        run bash "$HANDLERS/$s" --id 42 --fields '[]'
        [[ "$status" -ne 0 && "$output" == *"Unknown argument"* ]] || { echo "$s: $output"; return 1; }
    done
    [[ ! -f "$LOG" ]] || ! grep -q "api/databases" "$LOG"
}
