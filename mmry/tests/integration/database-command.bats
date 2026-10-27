#!/usr/bin/env bats
# database-command.bats - the /mmry:database journey, live, through database.sh (#32443 R2).
#
# A database is created, two entries added, found, one corrected, its history shown, and the
# database retired and restored: every step runs database.sh with the subcommand exactly as the
# command page tells Claude to, configured the way a customer's plugin is.
#
# NEEDS (each test skips with the reason if it is missing; Integration only, never production):
#   MMRY_INTEGRATION_API_KEY  an API key for a throwaway Integration account
#   MMRY_INTEGRATION_URL      optional, defaults to https://integration.mmryai.com

load '../helpers/test-helper'

URL="${MMRY_INTEGRATION_URL:-https://integration.mmryai.com}"
PORTAL="See your databases and correct any entry yourself at https://mmryai.com/records"

setup_file() {
    if [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]]; then
        skip "MMRY_INTEGRATION_API_KEY not set"
    fi
    case "${MMRY_INTEGRATION_URL:-https://integration.mmryai.com}" in
        https://mmryai.com|https://mmryai.com/*|https://www.mmryai.com*|*mnemo-dffsh5b3b6gadpcu*)
            skip "refusing to run against production" ;;
    esac
}

_db() {
    export MMRY_API_URL="$URL"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_KEY="$MMRY_INTEGRATION_API_KEY"
    export MMRY_CONFIG_FILE="$TEST_TMPDIR/no-config-the-environment-decides.json"
    run bash "$PLUGIN_ROOT/hooks-handlers/database.sh" "$@"
}

_state() { cat "$BATS_FILE_TMPDIR/$1" 2>/dev/null || true; }
_keep()  { printf '%s' "$2" > "$BATS_FILE_TMPDIR/$1"; }
_need()  { local v; v="$(_state "$1")"; [[ -n "$v" ]] || fail "$1 was not set by an earlier step"; printf '%s' "$v"; }
_ends_with_portal() { [[ "$(printf '%s\n' "$output" | tr -d '\r' | grep -v '^$' | tail -1)" == "$PORTAL" ]] || fail "no portal line: $output"; }

@test "database live: create, with a description, through database.sh create" {
    local name="Migraine log 32443 $(date +%s)"
    _db create --name "$name" --description "Every migraine and how bad it was, from bats" \
        --fields '[{"key":"severity","label":"Severity","type":"number"},{"key":"trigger","label":"Trigger","type":"text"}]'
    [[ "$status" -eq 0 ]] || fail "create failed: $output"
    [[ "$output" == *"Created the database ${name} with id "* ]] || fail "unexpected: $output"
    _ends_with_portal
    _keep database_id "$(printf '%s' "$output" | grep -o 'with id [0-9]*' | head -1 | sed 's/with id //')"
    _keep format_name "$name"
    _db list
    [[ "$output" == *"$name"* ]] || fail "not listed: $output"
}

@test "database live: two entries added" {
    local id; id="$(_need database_id)"
    _db add --database-id "$id" --content "Migraine on Monday after red wine, a 7." --fields '{"severity":7,"trigger":"red wine"}'
    [[ "$status" -eq 0 && "$output" == *"Outcome: structured.created"* ]] || fail "first add: $output"
    _ends_with_portal
    _db add --database-id "$id" --content "Mild one on Wednesday, a 3, poor sleep." --fields '{"severity":3,"trigger":"poor sleep"}'
    [[ "$status" -eq 0 && "$output" == *"Outcome: structured.created"* ]] || fail "second add: $output"
}

@test "database live: found, by a field value" {
    local id; id="$(_need database_id)"
    _db find --database-id "$id"
    [[ "$status" -eq 0 && "$output" == *"2 entries in "* ]] || fail "find all: $output"
    _db find --database-id "$id" --filter severity=7
    [[ "$status" -eq 0 && "$output" == *"1 entry in "* && "$output" == *"red wine"* ]] || fail "find severity=7: $output"
    _ends_with_portal
    _keep entry_id "$(printf '%s' "$output" | grep -o '^id [0-9]*' | head -1 | sed 's/id //')"
}

@test "database live: one corrected, by its id" {
    local id entry; id="$(_need database_id)"; entry="$(_need entry_id)"
    _db correct --database-id "$id" --entry-id "$entry" --content "It was a 6, not a 7." --fields '{"severity":6}'
    [[ "$status" -eq 0 && "$output" == *"Outcome: structured.updated"* ]] || fail "correct: $output"
    _ends_with_portal
    _db find --database-id "$id" --filter severity=6
    [[ "$output" == *"1 entry in "* && "$output" == *"id ${entry}"* ]] || fail "the corrected value is not read back: $output"
}

@test "database live: its history shown, old value beside new" {
    local id entry; id="$(_need database_id)"; entry="$(_need entry_id)"
    _db history --database-id "$id" --entry-id "$entry"
    [[ "$status" -eq 0 ]] || fail "history: $output"
    [[ "$output" == *"was: 7"*"now: 6"* ]] || fail "the change from 7 to 6 is not in the history: $output"
    _ends_with_portal
}

@test "database live: retired, keeping its entries, and restored" {
    local id name; id="$(_need database_id)"; name="$(_need format_name)"
    _db retire --id "$id"
    [[ "$status" -eq 0 && "$output" == *"It still holds 2 entries."* && "$output" == *"Retired."* ]] || fail "retire: $output"
    _ends_with_portal
    _db list
    [[ "$output" != *"$name"* ]] || fail "a retired database is still listed by default: $output"
    _db list --include-retired
    [[ "$output" == *"$name"* ]] || fail "the retired database is not listed with --include-retired: $output"

    _db restore --id "$id"
    [[ "$status" -eq 0 && "$output" == *"Collecting again."* ]] || fail "restore: $output"
    _ends_with_portal
    _db list
    [[ "$output" == *"$name"* ]] || fail "the restored database is not listed: $output"
    _db find --database-id "$id"
    [[ "$output" == *"2 entries in "* ]] || fail "entries were not kept through retire and restore: $output"
}
