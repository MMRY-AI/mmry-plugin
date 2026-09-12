#!/usr/bin/env bats
# record-handlers.bats — drive the structured-record handlers against the mock API (#31460).
#
# These exercise the handlers the way an assistant runs them: arguments in, request out, output
# read back. The mock curl logs every request to $TEST_TMPDIR/curl-log.txt, so the assertions can
# check the METHOD, the PATH and the BODY that actually left the machine rather than trusting a
# success message.

load '../helpers/test-helper'
load '../helpers/mock-config'

HANDLERS=""
LOG=""

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
    LOG="$TEST_TMPDIR/curl-log.txt"
}

# --- list-formats ------------------------------------------------------------

@test "list-formats: reads GET /api/data-formats and names each type" {
    run bash "$HANDLERS/list-formats.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2 record type(s)"* ]]
    [[ "$output" == *"Migraine log"* ]]
    [[ "$output" == *"Expenses"* ]]
    grep -q "GET http://localhost:5291/api/data-formats" "$LOG"
}

@test "list-formats: a type with no match hints says it must be named explicitly" {
    run bash "$HANDLERS/list-formats.sh"
    [[ "$output" == *"must be named explicitly"* ]]
}

@test "list-formats: --id reads one type and lists its fields" {
    run bash "$HANDLERS/list-formats.sh" --id 42
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Record type: Migraine log"* ]]
    [[ "$output" == *"severity (number)"* ]]
    [[ "$output" == *"triggers (list)"* ]]
    grep -q "GET http://localhost:5291/api/data-formats/42" "$LOG"
}

@test "list-formats: --include-retired is forwarded to the route" {
    run bash "$HANDLERS/list-formats.sh" --include-retired
    [[ "$status" -eq 0 ]]
    grep -q "includeRetired=true" "$LOG"
}

@test "list-formats: rejects an unknown argument" {
    run bash "$HANDLERS/list-formats.sh" --nonsense
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unknown argument"* ]]
}

# --- create-format -----------------------------------------------------------

@test "create-format: requires --name and --fields" {
    run bash "$HANDLERS/create-format.sh" --name "Only a name"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--name and --fields are required"* ]]
}

@test "create-format: posts the field schema as a JSON STRING, not a nested array" {
    # fieldSchema crosses the wire as a string containing JSON. Sending it as a nested array is
    # the mistake _mmry_json_string exists to prevent, and the server rejects it.
    run bash "$HANDLERS/create-format.sh" --name "Migraine log" \
        --fields '[{"key":"severity","type":"number"}]' --match-hints "migraine, aura"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Created record type Migraine log with id 42."* ]]
    grep -q 'POST http://localhost:5291/api/data-formats' "$LOG"
    grep -q '"fieldSchema":"\[{\\"key\\":\\"severity\\"' "$LOG"
    grep -q '"matchHints":"migraine, aura"' "$LOG"
}

@test "create-format: 'global' becomes Global and 'private' becomes Private" {
    run bash "$HANDLERS/create-format.sh" --name X --fields '[]' --visibility global
    [[ "$status" -eq 0 ]]
    grep -q '"visibility":"Global"' "$LOG"
}

@test "create-format: an unrecognised visibility is refused, never silently made private" {
    run bash "$HANDLERS/create-format.sh" --name X --fields '[]' --visibility everybody-ish
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--visibility is 'private' or 'global'"* ]]
    [[ ! -f "$LOG" ]] || ! grep -q "POST .*api/data-formats" "$LOG"
}

@test "create-format: defaults to append mode and Private visibility" {
    run bash "$HANDLERS/create-format.sh" --name X --fields '[]'
    [[ "$status" -eq 0 ]]
    grep -q '"entryKeyMode":"append"' "$LOG"
    grep -q '"visibility":"Private"' "$LOG"
}

# --- revise-format -----------------------------------------------------------

@test "revise-format: --fields publishes a NEW VERSION and says nothing was lost" {
    run bash "$HANDLERS/revise-format.sh" --id 42 --fields '[{"key":"severity","type":"number"}]'
    [[ "$status" -eq 0 ]]
    grep -q "POST http://localhost:5291/api/data-formats/42/versions" "$LOG"
    [[ "$output" == *"RecordType: Migraine log (id 42, version 2)"* ]]
    [[ "$output" == *"still readable"* ]]
}

@test "revise-format: --rename goes to PUT, not to a new version" {
    run bash "$HANDLERS/revise-format.sh" --id 42 --rename "Headache log"
    [[ "$status" -eq 0 ]]
    grep -q "PUT http://localhost:5291/api/data-formats/42" "$LOG"
    ! grep -q "/versions" "$LOG"
    [[ "$output" == *"Headache log"* ]]
}

@test "revise-format: --retire reports the records it still holds" {
    run bash "$HANDLERS/revise-format.sh" --id 42 --retire
    [[ "$status" -eq 0 ]]
    grep -q "POST http://localhost:5291/api/data-formats/42/retire" "$LOG"
    [[ "$output" == *"It still holds 41 record(s)."* ]]
    [[ "$output" == *"stops collecting new ones"* ]]
}

@test "revise-format: --reinstate calls reinstate" {
    run bash "$HANDLERS/revise-format.sh" --id 42 --reinstate
    [[ "$status" -eq 0 ]]
    grep -q "POST http://localhost:5291/api/data-formats/42/reinstate" "$LOG"
    [[ "$output" == *"Collecting again."* ]]
}

@test "revise-format: --retire and --reinstate together are refused" {
    run bash "$HANDLERS/revise-format.sh" --id 42 --retire --reinstate
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"opposites"* ]]
}

@test "revise-format: --retire with a field change is refused rather than half-applied" {
    run bash "$HANDLERS/revise-format.sh" --id 42 --retire --rename "Nope"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"take nothing else"* ]]
}

@test "revise-format: requires --id" {
    run bash "$HANDLERS/revise-format.sh" --rename "Headache log"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--id is required"* ]]
}

@test "revise-format: asking for nothing is an error, not a silent success" {
    run bash "$HANDLERS/revise-format.sh" --id 42
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"nothing to change"* ]]
}

# --- save-record -------------------------------------------------------------

@test "save-record: requires --format-id and --content" {
    run bash "$HANDLERS/save-record.sh" --format-id 42
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--format-id and --content are required"* ]]
}

@test "save-record: posts to the entries route and reports the outcome" {
    run bash "$HANDLERS/save-record.sh" --format-id 42 \
        --content "Migraine on Tuesday" --fields '{"severity":7}'
    [[ "$status" -eq 0 ]]
    grep -q "POST http://localhost:5291/api/data-formats/42/entries" "$LOG"
    [[ "$output" == *"Outcome: structured.created  (memory 99)"* ]]
}

@test "save-record: the fields object crosses the wire unescaped" {
    run bash "$HANDLERS/save-record.sh" --format-id 42 --content "x" --fields '{"severity":7}'
    grep -q '"fields":{"severity":7}' "$LOG"
}

@test "save-record: a degraded write says the fields were NOT stored" {
    # The one outcome that must never be reported as a record. If this line is lost, the handler
    # tells the user their symptom log has an entry it does not have.
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"outcome":"text.degraded","memoryId":99,"detail":"no field named severty"}'
    run bash "$HANDLERS/save-record.sh" --format-id 42 --content "x" --fields '{"severty":7}'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"text.degraded"* ]]
    [[ "$output" == *"The words were saved; the fields were NOT."* ]]
    [[ "$output" == *"no field named severty"* ]]
}

@test "save-record: a 400 from the route is an error, not a shrug" {
    export MOCK_CURL_HTTP_CODE=400
    export MOCK_CURL_RESPONSE='{"error":"Unknown field: severty"}'
    run bash "$HANDLERS/save-record.sh" --format-id 42 --content "x" --fields '{"severty":7}'
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"severty"* ]]
}

# --- query-records -----------------------------------------------------------

@test "query-records: requires --format-id" {
    run bash "$HANDLERS/query-records.sh" --filter status=open
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--format-id is required"* ]]
}

@test "query-records: reports the total and every field of every record" {
    run bash "$HANDLERS/query-records.sh" --format-id 42
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2 record(s) in Migraine log:"* ]]
    [[ "$output" == *"severity: 7"* ]]
    [[ "$output" == *"triggers: red wine"* ]]
}

@test "query-records: a field with no value reads (blank), not an empty line" {
    run bash "$HANDLERS/query-records.sh" --format-id 42
    [[ "$output" == *"triggers: (blank)"* ]]
}

@test "query-records: filters become field.<key>= pairs, ANDed" {
    run bash "$HANDLERS/query-records.sh" --format-id 42 --filter status=open --filter severity=7
    [[ "$status" -eq 0 ]]
    grep -q "field.status=open&field.severity=7" "$LOG"
}

@test "query-records: a filter value is URL-encoded rather than breaking the query" {
    run bash "$HANDLERS/query-records.sh" --format-id 42 --filter "trigger=red wine"
    [[ "$status" -eq 0 ]]
    grep -q "field.trigger=red%20wine" "$LOG"
}

@test "query-records: order, page and page size are forwarded" {
    run bash "$HANDLERS/query-records.sh" --format-id 42 --order "createdDate desc" --page 2 --page-size 20
    [[ "$status" -eq 0 ]]
    grep -q "order=createdDate%20desc" "$LOG"
    grep -q "page=2" "$LOG"
    grep -q "pageSize=20" "$LOG"
}

@test "query-records: --filter without an = is refused before any request" {
    run bash "$HANDLERS/query-records.sh" --format-id 42 --filter status
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--filter takes key=value"* ]]
}
