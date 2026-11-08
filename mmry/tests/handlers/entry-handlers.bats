#!/usr/bin/env bats
# entry-handlers.bats — drive the database and entry handlers against the mock API (#31460, renamed by #32957).
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

# --- list-databases ------------------------------------------------------------

@test "list-databases: reads GET /api/databases and names each type" {
    run bash "$HANDLERS/list-databases.sh"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"2 database(s)"* ]] || return 1
    [[ "$output" == *"Migraine log"* ]] || return 1
    [[ "$output" == *"Expenses"* ]] || return 1
    grep -q "GET http://localhost:5291/api/databases" "$LOG"
}

@test "list-databases: a database with no match hints says so, and says when a save becomes an entry" {
    run bash "$HANDLERS/list-databases.sh"
    [[ "$output" == *"words that help choose it: (none)"* ]] || return 1
    [[ "$output" == *"a save becomes an entry when it names this database and has values for its fields"* ]] || return 1
    # A type with hints says it can also be chosen by its words; a type with none must not.
    echo "$output" | grep "words that help choose it: (none)" | grep -q "or contains these words" && return 1
    echo "$output" | grep -v "(none)" | grep -q "or contains these words"
    [[ "$output" != *"recognised by"* ]] || return 1
}

@test "list-databases: --id reads one type and lists its fields" {
    run bash "$HANDLERS/list-databases.sh" --id 42
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"Database: Migraine log"* ]] || return 1
    [[ "$output" == *"severity (number)"* ]] || return 1
    [[ "$output" == *"triggers (list)"* ]] || return 1
    grep -q "GET http://localhost:5291/api/databases/42" "$LOG"
}

@test "list-databases: --include-retired is forwarded to the route" {
    run bash "$HANDLERS/list-databases.sh" --include-retired
    [[ "$status" -eq 0 ]] || return 1
    grep -q "includeRetired=true" "$LOG"
}

@test "list-databases: rejects an unknown argument" {
    run bash "$HANDLERS/list-databases.sh" --nonsense
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"Unknown argument"* ]] || return 1
}

# --- create-database -----------------------------------------------------------

@test "create-database: requires --name and --fields" {
    run bash "$HANDLERS/create-database.sh" --name "Only a name"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--name and --fields are required"* ]] || return 1
}

@test "create-database: posts the field schema as a JSON STRING, not a nested array" {
    # fieldSchema crosses the wire as a string containing JSON. Sending it as a nested array is
    # the mistake _mmry_json_string exists to prevent, and the server rejects it.
    run bash "$HANDLERS/create-database.sh" --name "Migraine log" \
        --fields '[{"key":"severity","type":"number"}]' --match-hints "migraine, aura"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"Created the database Migraine log with id 42."* ]] || return 1
    grep -q 'POST http://localhost:5291/api/databases' "$LOG"
    grep -q '"fieldSchema":"\[{\\"key\\":\\"severity\\"' "$LOG"
    grep -q '"matchHints":"migraine, aura"' "$LOG"
}

@test "create-database: 'global' becomes Global and 'private' becomes Private" {
    run bash "$HANDLERS/create-database.sh" --name X --fields '[]' --visibility global
    [[ "$status" -eq 0 ]] || return 1
    grep -q '"visibility":"Global"' "$LOG"
}

@test "create-database: an unrecognised visibility is refused, never silently made private" {
    run bash "$HANDLERS/create-database.sh" --name X --fields '[]' --visibility everybody-ish
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--visibility is 'private' or 'global'"* ]] || return 1
    [[ ! -f "$LOG" ]] || ! grep -q "POST .*api/databases" "$LOG"
}

@test "create-database: defaults to append mode and Private visibility" {
    run bash "$HANDLERS/create-database.sh" --name X --fields '[]'
    [[ "$status" -eq 0 ]] || return 1
    grep -q '"entryKeyMode":"append"' "$LOG"
    grep -q '"visibility":"Private"' "$LOG"
}

# --- revise-database -----------------------------------------------------------

@test "revise-database: --fields publishes a NEW VERSION and says nothing was lost" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --fields '[{"key":"severity","type":"number"}]'
    [[ "$status" -eq 0 ]] || return 1
    grep -q "POST http://localhost:5291/api/databases/42/versions" "$LOG"
    [[ "$output" == *"Database: Migraine log (id 42, version 2)"* ]] || return 1
    [[ "$output" == *"still readable"* ]] || return 1
}

@test "revise-database: --rename goes to PUT, not to a new version" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --rename "Headache log"
    [[ "$status" -eq 0 ]] || return 1
    grep -q "PUT http://localhost:5291/api/databases/42" "$LOG"
    ! grep -q "/versions" "$LOG" || return 1
    [[ "$output" == *"Headache log"* ]] || return 1
}

@test "revise-database: --retire reports the entries it still holds" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --retire
    [[ "$status" -eq 0 ]] || return 1
    grep -q "POST http://localhost:5291/api/databases/42/retire" "$LOG"
    [[ "$output" == *"It still holds 41 entries."* ]] || return 1
    [[ "$output" == *"stops collecting new ones"* ]] || return 1
}

@test "revise-database: --reinstate calls reinstate" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --reinstate
    [[ "$status" -eq 0 ]] || return 1
    grep -q "POST http://localhost:5291/api/databases/42/reinstate" "$LOG"
    [[ "$output" == *"Collecting again."* ]] || return 1
}

@test "revise-database: --retire and --reinstate together are refused" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --retire --reinstate
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"opposites"* ]] || return 1
}

@test "revise-database: --retire with a field change is refused rather than half-applied" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --retire --rename "Nope"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"take nothing else"* ]] || return 1
}

@test "revise-database: requires --id" {
    run bash "$HANDLERS/revise-database.sh" --rename "Headache log"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--id is required"* ]] || return 1
}

@test "revise-database: asking for nothing is an error, not a silent success" {
    run bash "$HANDLERS/revise-database.sh" --id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"nothing to change"* ]] || return 1
}

# --- save-entry -------------------------------------------------------------

@test "save-entry: requires --database-id and --content" {
    run bash "$HANDLERS/save-entry.sh" --database-id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--database-id and --content are required"* ]] || return 1
}

@test "save-entry: posts to the entries route and reports the outcome" {
    run bash "$HANDLERS/save-entry.sh" --database-id 42 \
        --content "Migraine on Tuesday" --fields '{"severity":7}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q "POST http://localhost:5291/api/databases/42/entries" "$LOG"
    [[ "$output" == *"Outcome: structured.created  (memory 99)"* ]] || return 1
}

@test "save-entry: the fields object crosses the wire unescaped" {
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "x" --fields '{"severity":7}'
    grep -q '"fields":{"severity":7}' "$LOG"
}

@test "save-entry: a degraded write says the fields were NOT stored" {
    # The one outcome that must never be reported as a record. If this line is lost, the handler
    # tells the user their symptom log has an entry it does not have.
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"outcome":"text.degraded","memoryId":99,"detail":"no field named severty"}'
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "x" --fields '{"severty":7}'
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"text.degraded"* ]] || return 1
    [[ "$output" == *"The words were saved; the fields were NOT."* ]] || return 1
    [[ "$output" == *"no field named severty"* ]] || return 1
}

@test "save-entry: a 400 from the route is an error, not a shrug" {
    export MOCK_CURL_HTTP_CODE=400
    export MOCK_CURL_RESPONSE='{"error":"Unknown field: severty"}'
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "x" --fields '{"severty":7}'
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"severty"* ]] || return 1
}

# --- query-entries -----------------------------------------------------------

@test "query-entries: requires --database-id" {
    run bash "$HANDLERS/query-entries.sh" --filter status=open
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--database-id is required"* ]] || return 1
}

@test "query-entries: reports the total and every field of every entry" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"2 entries in Migraine log:"* ]] || return 1
    [[ "$output" == *"severity: 7"* ]] || return 1
    [[ "$output" == *"triggers: red wine"* ]] || return 1
}

@test "query-entries: states the page, how many per page and the total (#33197)" {
    # An API before #33197 sends no paging sentence; the page is stated from the numbers it does send.
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"Page 1, 2 per page, 2 in total."* ]] || { echo "$output"; return 1; }
}

@test "query-entries: prints the API's paging sentence, which names the next page to ask for (#33197)" {
    export MOCK_ENTRIES_BODY='{"total":230,"page":1,"pageSize":8,"hasMore":true,"paging":"This page was shortened to 8 entries so that it fits in one reply. Page 1, 8 per page, 230 in total. For the next entries ask for page 2 with pageSize 8.","database":{"rootId":42,"name":"Journey Catalog"},"entries":[{"id":1,"entryKey":null,"savedAt":"2026-10-31T09:00:00","note":"One.","values":{"title":"A"}}]}'
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    unset MOCK_ENTRIES_BODY
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"230 entries in Journey Catalog:"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Page 1, 8 per page, 230 in total. For the next entries ask for page 2 with pageSize 8."* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"--page 2 --page-size 8"* ]] || { echo "$output"; return 1; }
}

@test "query-entries: a field with no value reads (blank), not an empty line" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$output" == *"triggers: (blank)"* ]] || return 1
}

@test "query-entries: filters become field.<key>= pairs, ANDed" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --filter status=open --filter severity=7
    [[ "$status" -eq 0 ]] || return 1
    grep -q "field.status=open&field.severity=7" "$LOG"
}

@test "query-entries: a filter value is URL-encoded rather than breaking the query" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --filter "trigger=red wine"
    [[ "$status" -eq 0 ]] || return 1
    grep -q "field.trigger=red%20wine" "$LOG"
}

@test "query-entries: order, page and page size are forwarded" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --order "createdDate desc" --page 2 --page-size 20
    [[ "$status" -eq 0 ]] || return 1
    grep -q "order=createdDate%20desc" "$LOG"
    grep -q "page=2" "$LOG"
    grep -q "pageSize=20" "$LOG"
}

@test "query-entries: --filter without an = is refused before any request" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --filter status
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--filter takes key=value"* ]] || return 1
}

# --- query-entries: only the fields asked for, and the note left out (#33198) ---

@test "query-entries: with neither --fields nor --no-note the request is exactly as before" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --filter status=open
    [[ "$status" -eq 0 ]] || return 1
    grep -q "GET http://localhost:5291/api/databases/42/entries?field.status=open" "$LOG" || { cat "$LOG"; return 1; }
    ! grep -q "fields=" "$LOG" || { cat "$LOG"; return 1; }
    ! grep -q "includeNote" "$LOG" || { cat "$LOG"; return 1; }
    [[ "$output" == *"words: Migraine on Tuesday after red wine."* ]] || return 1
    [[ "$output" == *"triggers: red wine"* ]] || return 1
}

@test "query-entries: --fields sends one fields= list and prints only those fields" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --fields severity
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "entries?fields=severity" "$LOG" || { cat "$LOG"; return 1; }
    [[ "$output" == *"severity: 7"* ]] || return 1
    [[ "$output" != *"triggers"* ]] || return 1
}

@test "query-entries: --fields takes a comma separated list, spaces trimmed and each key URL-encoded" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --fields "severity, red wine ,triggers" --filter status=open
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "field.status=open&fields=severity,red%20wine,triggers" "$LOG" || { cat "$LOG"; return 1; }
}

@test "query-entries: --no-note sends includeNote=false and prints no words" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --no-note
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "includeNote=false" "$LOG" || { cat "$LOG"; return 1; }
    [[ "$output" != *"words:"* ]] || return 1
    [[ "$output" == *"severity: 7"* ]] || return 1
}

@test "query-entries: --fields and --no-note together, with order and page" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --fields severity --no-note --order "severity desc" --page 2
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "fields=severity" "$LOG" || return 1
    grep -q "includeNote=false" "$LOG" || return 1
    grep -q "order=severity%20desc" "$LOG" || return 1
    [[ "$output" == *"2 entries in Migraine log:"* ]] || return 1
    [[ "$output" != *"words:"* && "$output" != *"triggers"* ]] || return 1
}

@test "query-entries: a field the database does not declare is refused with the fields it does declare" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --fields nope
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"does not declare the field 'nope'"* ]] || return 1
    [[ "$output" == *"severity and triggers"* ]] || return 1
}

@test "query-entries: --fields with no list is refused before any request" {
    run bash "$HANDLERS/query-entries.sh" --database-id 42 --fields
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--fields takes"* ]] || return 1
    [[ ! -s "$LOG" ]] || ! grep -q "/entries" "$LOG"
}

# --- save-memory, the routed save --------------------------------------------

@test "save-memory: an entry flag sends the structured block to POST /api/memories" {
    # Not to /api/memories/process. That route carries no structured block and may extract
    # several memories from one context, leaving no single memory for the fields to belong to.
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope health \
        --topic "Migraine on Tuesday" --content "Woke up with a migraine." \
        --database-name "Migraine log" --entry-fields '{"severity":7}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q "POST http://localhost:5291/api/memories " "$LOG"
    ! grep -q "/api/memories/process" "$LOG" || return 1
    grep -q '"structured":{"databaseName":"Migraine log","fields":{"severity":7}}' "$LOG"
}

@test "save-memory: a routed save with no database in the response says so plainly" {
    # The mock's plain {"id":99} is exactly what a degraded save looks like: the words were
    # stored, the structure was not. Reporting "recorded in your migraine log" here is the lie.
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope health \
        --topic "T" --content "C" --database-name "Migraine log"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"NewMemoryID: 99"* ]] || return 1
    [[ "$output" == *"SavedInDatabase: (none - saved as ordinary text, the structure was not stored)"* ]] || return 1
}

@test "save-memory: a routed save names the database the SERVER stored" {
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"id":99,"database":{"rootId":42,"name":"Migraine log"}}'
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope health \
        --topic "T" --content "C" --database-name "Migraine log"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"SavedInDatabase: Migraine log"* ]] || return 1
}

@test "save-memory: a name inside the user's own content is not read as a database" {
    # The customer's content can contain anything, including a JSON snippet with a name key.
    # Reading the whole body for "name" would report a format that was never stored.
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"id":99,"content":"they said {\"name\": \"Totally A Database\"}","database":null}'
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope health \
        --topic "T" --content "C" --database-name "Migraine log"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" != *"Totally A Database"* ]] || return 1
    [[ "$output" == *"SavedInDatabase: (none"* ]] || return 1
}

@test "save-memory: an entry flag without the classification is refused, naming what is missing" {
    run bash "$HANDLERS/save-memory.sh" --context "anything" --database-name "Migraine log"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--tier"* ]] || return 1
    [[ "$output" == *"--content"* ]] || return 1
}

@test "save-memory: without an entry flag nothing changes - it still goes to the AI route" {
    run bash "$HANDLERS/save-memory.sh" --context "Remember that we use UPC as the identifier."
    [[ "$status" -eq 0 ]] || return 1
    grep -q "/api/memories/process" "$LOG"
    [[ "$output" != *"SavedInDatabase"* ]] || return 1
}

@test "save-memory: --entry-name rides along as the entry key" {
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope work \
        --topic "T" --content "C" --database-name "Tasks" --entry-name "Rewire the settings page"
    [[ "$status" -eq 0 ]] || return 1
    grep -q '"entryKey":"Rewire the settings page"' "$LOG"
}

# --- the jq-less fallback ----------------------------------------------------
#
# WHY THESE EXIST. save-memory.sh's routed save reads the response twice over: with MMRY_JQ when
# lib-jq.sh resolved one, and with shell builtins when it did not. The builtin path holds the
# hand-rolled format-name extractor, which is exactly where #31460 QA round three found a
# whole-body grep reporting the CUSTOMER'S OWN words as a stored format. Every other test in this
# file runs with a jq on PATH (the suite helper guarantees one), so without these the builtin
# branch is executed by nothing and a bug reintroduced there ships green.
#
# HOW FAR THIS ACTUALLY REACHES, stated plainly rather than implied. On a real machine this
# branch is currently UNREACHABLE: _mmry_load_config parses mmry-config.json with MMRY_JQ and has
# had no regex fallback since #30624, so with no jq no apiKey is ever read and the request fails
# auth long before any response is parsed. These tests therefore supply the credentials through
# the environment, which is the only way in. They pin the extractor's behaviour; they do not
# demonstrate a customer-reachable path. See the PR notes on whether this fallback should be
# deleted or config parsing should regain a jq-less route.

_mmry_no_jq() {
    mkdir -p "$TEST_TMPDIR/no-jq-vendor"
    env MMRY_JQ_SKIP_SYSTEM=1 MMRY_JQ_VENDOR_DIR="$TEST_TMPDIR/no-jq-vendor"         MMRY_API_URL="http://localhost:5291" MMRY_API_KEY="test-api-key"         MMRY_AUTH_METHOD="apikey" "$@"
}

@test "save-memory (no jq): names the database the server stored, read from the database block" {
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"id":99,"content":"C","database":{"name":"Migraine log","rootId":42}}'
    run _mmry_no_jq bash "$HANDLERS/save-memory.sh"         --tier Operational --category Fact --scope health         --topic "T" --content "C" --database-name "Migraine log"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"SavedInDatabase: Migraine log"* ]] || return 1
}

@test "save-memory (no jq): a name inside the user's own content is not read as a database" {
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"id":99,"content":"they said {\"name\": \"Totally A Database\"}","database":null}'
    run _mmry_no_jq bash "$HANDLERS/save-memory.sh"         --tier Operational --category Fact --scope health         --topic "T" --content "C" --database-name "Migraine log"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" != *"Totally A Database"* ]] || return 1
    [[ "$output" == *"SavedInDatabase: (none"* ]] || return 1
}

@test "save-memory (no jq): a top-level name beside a null database is not read as the database" {
    # THE CASE THAT ACTUALLY SEPARATES the scoped extractor from a whole-body grep. A name buried
    # in the customer's content cannot be confused for a real one - the encoder escapes it as
    # \"name\", so a naive grep for "name": never matches it and the earlier fixture stays green
    # against BOTH implementations. A sibling key at the TOP LEVEL of the response is not escaped,
    # and that is what a whole-body grep reads and reports as a stored format when nothing was
    # stored at all. Without this test the scoping is asserted by comment only.
    export MOCK_CURL_HTTP_CODE=201
    export MOCK_CURL_RESPONSE='{"id":99,"name":"Totally A Database","content":"C","database":null}'
    run _mmry_no_jq bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope health \
        --topic "T" --content "C" --database-name "Migraine log"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" != *"Totally A Database"* ]] || return 1
    [[ "$output" == *"SavedInDatabase: (none"* ]] || return 1
}

# --- entry-history (#31384, ported by #31827) --------------------------------

@test "entry-history: requires --database-id and --entry-id" {
    run bash "$HANDLERS/entry-history.sh" --database-id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--database-id and --entry-id are both required"* ]] || return 1
    [[ ! -s "$LOG" ]] || ! grep -q "history" "$LOG"
}

@test "entry-history: reads the history route for that entry" {
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 9137
    [[ "$status" -eq 0 ]] || return 1
    grep -q "GET http://localhost:5291/api/databases/42/entries/9137/history" "$LOG"
}

@test "entry-history: prints the trail oldest first, old beside new, creation values included" {
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 9137
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"was: -  now: open"* ]] || return 1
    [[ "$output" == *"was: open  now: in progress"* ]] || return 1
    local first second
    first="$(printf '%s\n' "$output" | grep -n 'now: open' | head -1 | cut -d: -f1)"
    second="$(printf '%s\n' "$output" | grep -n 'now: in progress' | head -1 | cut -d: -f1)"
    [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || return 1
}

@test "entry-history: a reserved key is shown by its plain-English label, not its sentinel" {
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 9137
    [[ "$output" == *"The memory itself"* ]] || return 1
    [[ "$output" != *"~content~"* ]] || return 1
}

@test "entry-history: names who changed it when the server says" {
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 9137
    [[ "$output" == *"by Probe User"* ]] || return 1
}

@test "entry-history: an entry with no changes says so instead of printing nothing" {
    export MOCK_CURL_HTTP_CODE=200
    export MOCK_CURL_RESPONSE='{"entryId":9137,"changes":0,"history":[]}'
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 9137
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"Nothing has changed since this entry was saved."* ]] || return 1
}

@test "entry-history: a not-found is an error carrying the 404, with no claim it exists" {
    export MOCK_CURL_HTTP_CODE=404
    export MOCK_CURL_RESPONSE='{"error":"Not found"}'
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 2000000000
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"404"* ]] || return 1
    [[ "$output" != *"cannot see"* ]] || return 1
}

@test "entry-history: an id that is not a whole number is refused before any request" {
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id "../../memories"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"positive whole number"* ]] || return 1
    ! grep -q "databases" "$LOG" 2>/dev/null || return 1
}

# --- correcting a record made elsewhere (#31827 requirement 2) ----------------

@test "save-entry: --entry-id sends the id so the entry is UPDATED, and reports the update" {
    export MOCK_CURL_HTTP_CODE=200
    export MOCK_CURL_RESPONSE='{"outcome":"structured.updated","memoryId":99,"entryId":9137}'
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --entry-id 9137 \
        --content "Done." --fields '{"status":"done"}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q '"entryId":9137' "$LOG"
    [[ "$output" == *"Outcome: structured.updated  (memory 99)"* ]] || return 1
}

# --- the routed save keeps every shipped flag (#31827 requirement 4) -----------

@test "save-memory: a routed save still sends the agent name, beside the structured block" {
    # The record block was added AFTER the agent name (#30320) in mmry_create_memory, so no shipped
    # caller's positional arguments moved. If they had, the agent name would land in databaseName.
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope finance \
        --topic "Lunch" --content "Spent 40 dollars on lunch." \
        --agent-name "Records Probe" \
        --database-name "Expenses" --entry-fields '{"amount":40}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q '"agentName":"Records Probe"' "$LOG"
    grep -q '"structured":{"databaseName":"Expenses","fields":{"amount":40}}' "$LOG"
}

@test "save-memory: a routed save refuses a malformed --supersedes like the ordinary save does" {
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope finance \
        --topic "Lunch" --content "x" --supersedes "abc" \
        --database-name "Expenses" --entry-fields '{"amount":40}'
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--supersedes takes the id"* ]] || return 1
    ! grep -q "/api/memories" "$LOG" 2>/dev/null || return 1
}

@test "save-memory: a routed save forwards a valid --supersedes as supersedesId" {
    run bash "$HANDLERS/save-memory.sh" \
        --tier Operational --category Fact --scope finance \
        --topic "Lunch" --content "x" --supersedes 123 \
        --database-name "Expenses" --entry-fields '{"amount":40}'
    [[ "$status" -eq 0 ]] || return 1
    grep -q '"supersedesId":123' "$LOG"
}

@test "query-entries: shows the words each entry was saved from, not a topic the route never sends" {
    # Read from Integration (#31827): entries carry note, entryKey and savedAt. The first port
    # printed .topic, which is absent, so every record read "(no topic)" and its words were lost.
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"words: Migraine on Tuesday after red wine."* ]] || return 1
    [[ "$output" == *"id 1 | saved 2026-10-07T09:00:00"* ]] || return 1
    [[ "$output" != *"(no topic)"* ]] || return 1
}

# --- #32002: what the messages say a save does ---------------------------------

@test "revise-database: --match-hints says the words help choose the type, never that a save is filed by them (#32002)" {
    run bash "$HANDLERS/revise-database.sh" --id 42 --match-hints "migraine, headache"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"Those words now help the assistant choose this database. A save becomes an entry when MMRY can tell which database it belongs to, by its name or by these words, and has values for its fields, supplied or as labelled lines such as \"Amount: 25\". Otherwise it stays an ordinary memory."* ]] || return 1
    [[ "$output" != *"recognised"* ]] || return 1
    [[ "$output" != *"from now on"* ]] || return 1
}

@test "save-memory: an entry save with malformed fields is refused as the SKILL describes, and stores nothing (#32002)" {
    export MOCK_CURL_HTTP_CODE=400
    # The REAL body: GlobalExceptionHandler answers a malformed request body with this envelope
    # (seen live on Integration, 2026-10-10), not plain text.
    export MOCK_CURL_RESPONSE='{"error":"Request body is required.","detail":null}'
    run bash "$HANDLERS/save-memory.sh"         --tier Operational --category Fact --scope finance         --topic "Lunch" --content "Spent 40 dollars on lunch."         --database-name "Expenses" --entry-fields '{"amount":'
    [[ "$status" -eq 1 ]] || return 1
    [[ "$output" == *'Error (HTTP 400): {"error":"Request body is required.","detail":null}'* ]] || return 1
    [[ "$output" == *"Nothing was saved."* ]] || return 1
    [[ "$output" != *"NewMemoryID"* ]] || return 1
    [[ "$output" != *"SavedInDatabase"* ]] || return 1
    # The malformed fields really left the machine as sent, and exactly one save was attempted.
    grep -qF '"fields":{"amount":' "$LOG"
    [[ "$(grep -c 'POST http://localhost:5291/api/memories' "$LOG")" -eq 1 ]]
}

@test "SKILL.md describes the refusal the script prints (#32002)" {
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    grep -qF 'Error (HTTP 400): {"error":"Request body is required.","detail":null}' "$skill" || return 1
    grep -qF 'Nothing was saved.' "$skill" || return 1
    grep -q 'A refused entry save saves nothing' "$skill" || return 1
    ! grep -q 'This can never cost the save' "$skill"
}

@test "no plugin message or guidance contradicts when a save becomes an entry (#32002)" {
    # The rule (MemoryDatabaseRouter): a save becomes a record when MMRY can tell which type it
    # belongs to (named, or chosen by hint words) AND has values for that type's fields (supplied,
    # or labelled lines). Neither "the hints alone file a save" nor "a plain save never becomes a
    # record" is true.
    local f
    for f in hooks-handlers/revise-database.sh hooks-handlers/list-databases.sh hooks-handlers/create-database.sh \
             hooks-handlers/mmry-client.sh hooks-handlers/save-memory.sh skills/memory-system/SKILL.md; do
        if grep -qiE 'recognised as belonging|recognised by|what the router|will be recognised|saves stop being recognised|never cost the save|must be named explicitly|never becomes a|never turn|nothing files a plain save|only when it names|only when the save names|does not route a plain save' "$PLUGIN_ROOT/$f"; then
            fail "$f still carries a claim that contradicts when a save becomes a record"
        fi
    done
    # And the SKILL states the rule in both halves.
    grep -q "belongs to \*\*and\*\* has values for that database's fields" "$PLUGIN_ROOT/skills/memory-system/SKILL.md"
}

# --- the old names are gone (#32957, DD-164) ----------------------------------------------------
# "The old names don't need to work. Get rid of them." (Eric, 2026-10-27.) Each script refuses the
# option it used to take, before any request leaves the machine, and the old scripts do not exist.

@test "old names: each retired option is refused by the script that used to take it, before any request" {
    local spec
    for spec in \
        "save-entry.sh --format-id 42 --content x" \
        "save-entry.sh --database-id 42 --content x --record-id 9" \
        "save-entry.sh --database-id 42 --content x --record-name n" \
        "query-entries.sh --format-id 42" \
        "entry-history.sh --format-id 42 --entry-id 9" \
        "entry-history.sh --database-id 42 --record-id 9" \
        "save-memory.sh --topic t --content c --record-type Expenses" \
        "save-memory.sh --topic t --content c --record-fields {}" \
        "save-memory.sh --topic t --content c --record-name n"; do
        : > "$LOG"
        # shellcheck disable=SC2086
        run bash "$HANDLERS/"$spec
        [[ "$status" -ne 0 ]] || { echo "accepted: $spec"; return 1; }
        [[ "$output" == *"Unknown argument"* ]] || { echo "not refused by name: $spec: $output"; return 1; }
        [[ ! -s "$LOG" ]] || { echo "a request left the machine for: $spec"; cat "$LOG"; return 1; }
    done
}

@test "old names: none of the nine retired scripts is installed" {
    local s
    for s in create-format list-formats revise-format rename-format retire-format reinstate-format \
             save-record query-records record-history; do
        [[ ! -e "$HANDLERS/$s.sh" ]] || { echo "still installed: $s.sh"; return 1; }
    done
}

@test "new names: save-entry, query-entries and entry-history take the new options and reach the renamed routes" {
    run bash "$HANDLERS/save-entry.sh" --database-id 42 --content "Migraine on Tuesday" --entry-id 7 --entry-name tue
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "POST http://localhost:5291/api/databases/42/entries" "$LOG" || { cat "$LOG"; return 1; }
    grep -q '"entryId":7' "$LOG" || { cat "$LOG"; return 1; }
    run bash "$HANDLERS/query-entries.sh" --database-id 42
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"in Migraine log"* ]] || { echo "$output"; return 1; }
    run bash "$HANDLERS/entry-history.sh" --database-id 42 --entry-id 7
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "GET http://localhost:5291/api/databases/42/entries/7/history" "$LOG" || { cat "$LOG"; return 1; }
}

# --- save-entries: several entries in one request (#33317) ---------------------------------------
#
# The plugin's front door to the connector's mmry_entry_save_batch (#32943): POST
# /api/databases/{id}/entries/batch, one request for up to 25 entries, each reported on its own in
# the order sent. The caps are checked here too, so a batch the server would refuse whole never
# leaves the machine; the words are the server's own.

# Thirteen updates by entry id, the feedback #42 shape; the seventh carries a choice that is not one
# of the options.
_thirteen() {
    jq -cn '[range(1;14) | {entryId: (500 + .), content: "Product fact \(.), renumbered to \(. + 100)",
             fields: {number: (. + 100), status: (if . == 7 then "Withdrawn" else "Final" end)}}]' | tr -d '\r'
}

# The reply the route gives for _thirteen: twelve saved, the seventh refused with its reason.
_thirteen_reply() {
    jq -cn --arg reason "'Withdrawn' is not one of the options for the field Status (status). The options are: Draft, Final." \
        '{databaseId: 42, entries: 13, saved: 12, refused: 1, notSaved: 0,
          summary: "12 of 13 entries were saved; 1 was refused, each with its reason. Tell the user what happened to each entry.",
          results: [range(1;14) | if . == 7
              then {position: ., status: "refused", reason: $reason}
              else {position: ., status: "saved", entry: {MemoryId: (500 + .), Outcome: "structured.updated", EntryKey: null, DatabaseId: 42, RootDatabaseId: 42, Revision: 2, Visibility: "Private"}}
              end]}' | tr -d '\r'
}

# The body of the last request the mock saw.
_last_body() { tail -1 "$LOG" | sed 's/^[A-Z]* [^ ]* //'; }

@test "save-entries: requires --database-id and the entries" {
    run bash "$HANDLERS/save-entries.sh" --database-id 42
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"--database-id and --entries (or --entries-file) are required"* ]] || { echo "$output"; return 1; }
    [[ ! -s "$LOG" ]] || { cat "$LOG"; return 1; }
}

@test "save-entries: 13 updates with one invalid in ONE request: 12 reported saved, 1 refused with its reason, in the order sent" {
    local entries; entries="$(_thirteen)"
    export MOCK_CURL_HTTP_CODE=200
    MOCK_CURL_RESPONSE="$(_thirteen_reply)"; export MOCK_CURL_RESPONSE
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries "$entries"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

    # ONE request, to the batch route, carrying all thirteen entries exactly as given.
    [[ "$(grep -c '' "$LOG")" -eq 1 ]] || { cat "$LOG"; return 1; }
    grep -q "^POST http://localhost:5291/api/databases/42/entries/batch " "$LOG" || { cat "$LOG"; return 1; }
    [[ "$(_last_body | jq -r '.entries | fromjson | length' | tr -d '\r')" == "13" ]] || { _last_body; return 1; }
    [[ "$(_last_body | jq -c '.entries | fromjson' | tr -d '\r')" == "$entries" ]] || { _last_body; return 1; }

    [[ "$output" == *"12 of 13 entries were saved; 1 was refused, each with its reason."* ]] || { echo "$output"; return 1; }
    # Every entry on its own line, in the order sent.
    local order
    order="$(printf '%s\n' "$output" | sed -n 's/^Entry \([0-9]*\): .*/\1/p' | tr '\n' ' ')"
    [[ "$order" == "1 2 3 4 5 6 7 8 9 10 11 12 13 " ]] || { echo "order: $order"; echo "$output"; return 1; }
    [[ "$(printf '%s\n' "$output" | grep -c '^Entry [0-9]*: saved, structured.updated')" -eq 12 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | grep -q "^Entry 1: saved, structured.updated (entry 501, visibility Private)$" || { echo "$output"; return 1; }
    printf '%s\n' "$output" | grep -q "^Entry 7: refused. Reason: 'Withdrawn' is not one of the options for the field Status (status)." \
        || { echo "$output"; return 1; }
}

@test "save-entries: a batch over the entry cap is refused with a plain message before any request" {
    local entries
    entries="$(jq -cn '[range(0;26) | {content: "Overflow \(.)"}]' | tr -d '\r')"
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries "$entries"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"Nothing was saved: a batch may hold at most 25 entries and this one holds 26. Send them in batches of 25 or fewer."* ]] \
        || { echo "$output"; return 1; }
    [[ ! -s "$LOG" ]] || { echo "a request left the machine:"; cat "$LOG"; return 1; }

    # 25 is the cap, not over it: it is sent.
    entries="$(jq -cn '[range(0;25) | {content: "Within \(.)"}]' | tr -d '\r')"
    export MOCK_CURL_HTTP_CODE=200
    export MOCK_CURL_RESPONSE='{"databaseId":42,"entries":25,"saved":25,"refused":0,"notSaved":0,"summary":"25 of 25 entries were saved. Tell the user what happened to each entry.","results":[]}'
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries "$entries"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "entries/batch" "$LOG" || { cat "$LOG"; return 1; }
}

# One entry padded so the array's text is exactly N characters.
_of_length() {
    local n="$1" bare pad
    bare='[{"content":""}]'
    pad=$(( n - ${#bare} ))
    printf '[{"content":"%s"}]' "$(printf '%*s' "$pad" '' | tr ' ' 'w')"
}

@test "save-entries: a batch over 100,000 characters is refused before any request; exactly 100,000 is sent" {
    local over; over="$(_of_length 100001)"
    [[ "${#over}" -eq 100001 ]] || { echo "CONTROL: ${#over}"; return 1; }
    printf '%s' "$over" > "$TEST_TMPDIR/over.json"
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries-file "$TEST_TMPDIR/over.json"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"Nothing was saved: this batch is 100,001 characters and a batch may be at most 100,000. Send the entries in smaller batches."* ]] \
        || { echo "$output" | head -c 400; return 1; }
    [[ ! -s "$LOG" ]] || { echo "a request left the machine"; return 1; }

    local exact; exact="$(_of_length 100000)"
    [[ "${#exact}" -eq 100000 ]] || { echo "CONTROL: ${#exact}"; return 1; }
    printf '%s' "$exact" > "$TEST_TMPDIR/exact.json"
    export MOCK_CURL_HTTP_CODE=200
    export MOCK_CURL_RESPONSE='{"databaseId":42,"entries":1,"saved":1,"refused":0,"notSaved":0,"summary":"1 of 1 entries were saved. Tell the user what happened to each entry.","results":[{"position":1,"status":"saved","entry":{"MemoryId":9,"Outcome":"structured.created","Visibility":"Private"}}]}'
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries-file "$TEST_TMPDIR/exact.json"
    [[ "$status" -eq 0 ]] || { echo "$output" | head -c 400; return 1; }
    [[ "$(_last_body | jq -r '.entries | length' | tr -d '\r')" == "100000" ]] || return 1
}

@test "save-entries: --entries-file sends the same request as --entries, for a batch too long for a command line" {
    local entries; entries="$(_thirteen)"
    printf '%s' "$entries" > "$TEST_TMPDIR/batch.json"
    export MOCK_CURL_HTTP_CODE=200
    MOCK_CURL_RESPONSE="$(_thirteen_reply)"; export MOCK_CURL_RESPONSE
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries-file "$TEST_TMPDIR/batch.json"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$(_last_body | jq -c '.entries | fromjson' | tr -d '\r')" == "$entries" ]] || { _last_body; return 1; }

    : > "$LOG"
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries-file "$TEST_TMPDIR/no-such-file.json"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"no-such-file.json"* ]] || { echo "$output"; return 1; }
    [[ ! -s "$LOG" ]] || { cat "$LOG"; return 1; }
}

@test "save-entries: an entry held for the privacy question prints the question and its questionId, and says nothing is stored" {
    export MOCK_CURL_HTTP_CODE=200
    export MOCK_CURL_RESPONSE='{"databaseId":42,"entries":2,"saved":1,"refused":0,"notSaved":1,"summary":"1 of 2 entries were saved; 1 was not saved until the user answers a question. Tell the user what happened to each entry.","results":[{"position":1,"status":"saved","entry":{"MemoryId":77,"Outcome":"structured.created","Visibility":"Global"}},{"position":2,"status":"not saved","question":{"saved":false,"outcome":"visibility-required","recognised":"health","recognisedBy":"service","questionId":"Qx7_abcdefghijklmnopqr","ask":"This entry looks like a health matter, and the database is shared with everyone on your account. Should I keep this entry private, or share it like the rest of the database?","then":"Call mmry_entry_save again with the same arguments.","message":"NOT SAVED."}}]}'
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries '[{"content":"a"},{"content":"b"}]'
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | grep -q "^Entry 1: saved, structured.created (entry 77, visibility Global)$" || { echo "$output"; return 1; }
    printf '%s\n' "$output" | grep -q "^Entry 2: NOT SAVED. Ask the user: This entry looks like a health matter" || { echo "$output"; return 1; }
    [[ "$output" == *"questionId Qx7_abcdefghijklmnopqr"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Call mmry_entry_save again"* ]] || { echo "the connector's instruction leaked: $output"; return 1; }
}

@test "save-entries: a degraded entry says its fields were NOT stored" {
    export MOCK_CURL_HTTP_CODE=200
    export MOCK_CURL_RESPONSE='{"databaseId":42,"entries":1,"saved":1,"refused":0,"notSaved":0,"summary":"1 of 1 entries were saved. Tell the user what happened to each entry.","results":[{"position":1,"status":"saved","entry":{"MemoryId":5,"Outcome":"text.degraded","Detail":"no field named severty","Visibility":"Private"}}]}'
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries '[{"content":"x","fields":{"severty":7}}]'
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Entry 1: saved, text.degraded (entry 5, visibility Private). The words were saved; the fields were NOT. Reason: no field named severty"* ]] \
        || { echo "$output"; return 1; }
}

@test "save-entries: a batch the server refuses whole is an error carrying the server's own words" {
    export MOCK_CURL_HTTP_CODE=400
    export MOCK_CURL_RESPONSE='{"error":"Nothing was saved: entries must be a JSON array of objects, each with at least content.","detail":null}'
    run bash "$HANDLERS/save-entries.sh" --database-id 42 --entries '{"content":"not an array"}'
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"Nothing was saved: entries must be a JSON array of objects, each with at least content."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *'"detail"'* ]] || { echo "raw JSON shown: $output"; return 1; }
}

@test "database batch: dispatches to save-entries.sh and ends with the account page" {
    export MOCK_CURL_HTTP_CODE=200
    MOCK_CURL_RESPONSE="$(_thirteen_reply)"; export MOCK_CURL_RESPONSE
    run bash "$HANDLERS/database.sh" batch --database-id 42 --entries "$(_thirteen)"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    grep -q "POST http://localhost:5291/api/databases/42/entries/batch" "$LOG" || { cat "$LOG"; return 1; }
    [[ "$output" == *"Entry 13: saved"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"https://mmryai.com/databases"* ]] || { echo "$output"; return 1; }
}
