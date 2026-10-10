#!/usr/bin/env bats
# records.bats - structured records through the PUBLISHED plugin's own handlers, live (#31827).
#
# Requirement 1: define a record type, record against it in the user's own words, and get an
# answer from the VALUES. Requirement 2: a record made through the connector is read and corrected
# from Claude Code, and its history read back on both surfaces.
#
# Every step runs the plugin's bash exactly as Claude Code runs it, configured the way a customer's
# is: through the environment its client library reads. Nothing here calls the API directly except
# the connector steps, which ARE the other surface.
#
# NEEDS (each test skips with the reason if it is missing; Integration only, never production):
#   MMRY_INTEGRATION_API_KEY  an API key for a throwaway Integration account
#   MMRY_INTEGRATION_JWT      a login token for the SAME account (connector tests only). It is
#                             short-lived (it expired within the hour on 2026-10-10), so take a
#                             fresh one from POST /api/auth/login immediately before the run.
#   MMRY_INTEGRATION_URL      optional, defaults to https://integration.mmryai.com

load '../helpers/test-helper'

URL="${MMRY_INTEGRATION_URL:-https://integration.mmryai.com}"

setup_file() {
    if [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]]; then
        skip "MMRY_INTEGRATION_API_KEY not set"
    fi
    case "${MMRY_INTEGRATION_URL:-https://integration.mmryai.com}" in
        https://mmryai.com|https://mmryai.com/*|https://www.mmryai.com*|*mnemo-dffsh5b3b6gadpcu*)
            # The production hosts. These tests create record types and records.
            skip "refusing to run against production" ;;
    esac
}

# Run a handler as the customer's Claude Code would.
_plugin() {
    local handler="$1"; shift
    export MMRY_API_URL="$URL"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_KEY="$MMRY_INTEGRATION_API_KEY"
    export MMRY_CONFIG_FILE="$TEST_TMPDIR/no-config-the-environment-decides.json"
    run bash "$PLUGIN_ROOT/hooks-handlers/$handler" "$@"
}

_state() { cat "$BATS_FILE_TMPDIR/$1" 2>/dev/null || true; }

# jq on Windows writes CRLF; a stray carriage return would make every id comparison below fail.
_jq() { jq "$@" | tr -d '\r'; }
_keep()  { printf '%s' "$2" > "$BATS_FILE_TMPDIR/$1"; }

# ---- requirement 1 ----------------------------------------------------------------------------

@test "records live: define a record type from Claude Code" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    local name="Expenses 31827 $(date +%s)"
    _plugin create-format.sh --name "$name" --description "Every expense, from bats" \
        --fields '[{"key":"amount","label":"Amount","type":"number"},{"key":"merchant","label":"Merchant","type":"text"},{"key":"kind","label":"Kind","type":"text"}]' \
        --mode append --match-hints "spent, paid, bought"
    [[ "$status" -eq 0 ]] || fail "create-format.sh failed: $output"
    [[ "$output" == *"Created record type ${name}"* ]] || fail "unexpected: $output"
    local id
    id="$(printf '%s' "$output" | grep -o 'id [0-9]*' | head -1 | sed 's/id //')"
    [[ -n "$id" ]] || fail "no format id in: $output"
    _keep format_id "$id"
    _keep format_name "$name"

    _plugin list-formats.sh
    [[ "$output" == *"$name"* ]] || fail "the new type is not listed: $output"
}

@test "records live: a save in the user's own words becomes a RECORD on that type" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    local name; name="$(_state format_name)"
    [[ -n "$name" ]] || fail "the type was not created by the first test, so this cannot run"
    _plugin save-memory.sh --tier Operational --category Fact --scope finance \
        --topic "Lunch at Rosie's" \
        --content "I spent 42 dollars on lunch at Rosie's diner today." \
        --record-type "$name" \
        --record-fields '{"amount":42,"merchant":"Rosie'"'"'s diner","kind":"food"}'
    [[ "$status" -eq 0 ]] || fail "save failed: $output"
    # The server says what it stored. "(none" here would mean the words were kept and the record
    # was not - exactly the 2026-10-10 Mac finding (memory 33157) this task exists to fix.
    [[ "$output" == *"RecordedAs: ${name}"* ]] || fail "the save did not become a record: $output"

    _plugin save-memory.sh --tier Operational --category Fact --scope finance \
        --topic "Train ticket" --content "Paid 15 for the train into town." \
        --record-type "$name" --record-fields '{"amount":15,"merchant":"Metro rail","kind":"travel"}'
    [[ "$output" == *"RecordedAs: ${name}"* ]] || fail "second save did not become a record: $output"
}

@test "records live: a question is answered from the VALUES, not the wording" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    local id; id="$(_state format_id)"
    [[ -n "$id" ]] || fail "the type was not created by the first test, so this cannot run"

    _plugin query-records.sh --format-id "$id" --filter kind=food
    [[ "$status" -eq 0 ]] || fail "query failed: $output"
    [[ "$output" == *"1 record(s)"* ]] || fail "expected exactly the food record: $output"
    [[ "$output" == *"amount: 42"* ]] || fail "$output"
    [[ "$output" == *"words: I spent 42 dollars on lunch"* ]] || fail "the user's words are missing: $output"
    [[ "$output" != *"Metro rail"* ]] || fail "the filter did not filter: $output"

    _plugin query-records.sh --format-id "$id" --filter amount=15
    [[ "$output" == *"1 record(s)"* && "$output" == *"Metro rail"* ]] || fail "query by number: $output"

    _plugin query-records.sh --format-id "$id" --order "amount desc"
    [[ "$output" == *"2 record(s)"* ]] || fail "$output"
    local first_42 first_15
    first_42="$(printf '%s\n' "$output" | grep -n 'amount: 42' | head -1 | cut -d: -f1)"
    first_15="$(printf '%s\n' "$output" | grep -n 'amount: 15' | head -1 | cut -d: -f1)"
    [[ "$first_42" -lt "$first_15" ]] || fail "amount desc did not sort: $output"
}

# ---- requirement 2 ----------------------------------------------------------------------------

_b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A connector access token for the same account, through the same OAuth flow ChatGPT uses.
_connector_token() {
    local redirect="https://client.example.com/mcpcb" cid ver ch red code
    cid="$(curl -s -X POST "$URL/oauth/register" -H 'Content-Type: application/json' \
        -d "{\"redirect_uris\":[\"$redirect\"],\"client_name\":\"31827 bats\",\"token_endpoint_auth_method\":\"none\"}" | _jq -r .client_id)"
    ver="$(openssl rand 32 | _b64u)"
    ch="$(printf '%s' "$ver" | openssl dgst -sha256 -binary | _b64u)"
    red="$(curl -s -X POST "$URL/oauth/authorize?client_id=$cid&redirect_uri=$(_jq -rn --arg r "$redirect" '$r|@uri')&response_type=code&code_challenge=$ch&code_challenge_method=S256" \
        -H "Authorization: Bearer $MMRY_INTEGRATION_JWT" | _jq -r .redirectUrl)"
    code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$red")"
    curl -s -X POST "$URL/oauth/token" --data-urlencode grant_type=authorization_code \
        --data-urlencode "code=$code" --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "client_id=$cid" --data-urlencode "code_verifier=$ver" \
        --data-urlencode "resource=$URL/mcp" | _jq -r '.access_token // empty'
}

# Call one connector tool; prints the first text block of the result.
_connector() {
    local tok="$1" tool="$2" args="$3" sid
    local h=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream'
             -H 'MCP-Protocol-Version: 2025-06-18' -H "Authorization: Bearer $tok")
    sid="$(curl -s -D - -o /dev/null -X POST "$URL/mcp" "${h[@]}" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"31827-bats","version":"1"}}}' \
        | tr -d '\r' | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: //p')"
    if [[ -n "$sid" ]]; then
        h+=(-H "Mcp-Session-Id: $sid")
        curl -s -o /dev/null -X POST "$URL/mcp" "${h[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    fi
    curl -s -X POST "$URL/mcp" "${h[@]}" \
        -d "$(jq -cn --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$t,arguments:$a}}')" \
        | sed -n 's/^data: //;/^{/p' | _jq -r '.result.content[0].text // empty'
}

@test "records live: a record made through the CONNECTOR is read and corrected from Claude Code" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    [[ -z "${MMRY_INTEGRATION_JWT:-}" ]] && skip "MMRY_INTEGRATION_JWT not set (connector tests)"
    command -v openssl >/dev/null || skip "openssl is needed for the connector's PKCE"
    local id; id="$(_state format_id)"
    [[ -n "$id" ]] || fail "the type was not created by the first test, so this cannot run"

    local tok; tok="$(_connector_token)"
    [[ -n "$tok" ]] || fail "could not obtain a connector token"
    _keep connector_token "$tok"

    local made rec
    made="$(_connector "$tok" mmry_record "{\"formatId\":$id,\"content\":\"Bought a 30 dollar book at the bookshop.\",\"fields\":\"{\\\"amount\\\":30,\\\"merchant\\\":\\\"Bookshop\\\",\\\"kind\\\":\\\"books\\\"}\",\"scope\":\"finance\"}")"
    [[ "$made" == *"structured.created"* ]] || fail "the connector did not create a record: $made"
    rec="$(_jq -r '.MemoryId // .memoryId' <<<"$made")"
    [[ "$rec" =~ ^[0-9]+$ ]] || fail "no record id from the connector: $made"
    _keep connector_record "$rec"

    # READ from Claude Code.
    _plugin query-records.sh --format-id "$id" --filter kind=books
    [[ "$output" == *"id $rec"* && "$output" == *"amount: 30"* ]] || fail "plugin cannot read it: $output"
    [[ "$output" == *"words: Bought a 30 dollar book"* ]] || fail "$output"

    # CORRECT from Claude Code.
    _plugin save-record.sh --format-id "$id" --record-id "$rec" \
        --content "Bought a 32 dollar book at the bookshop." --fields '{"amount":32}'
    [[ "$status" -eq 0 ]] || fail "correction failed: $output"
    [[ "$output" == *"structured.updated"* ]] || fail "the correction was not an update: $output"

    # And the correction is true on the other surface at once.
    local back
    back="$(_connector "$tok" mmry_records "{\"formatId\":$id,\"filters\":\"{\\\"kind\\\":\\\"books\\\"}\"}")"
    [[ "$(_jq -r '[.Entries[]? // .entries[]? | select((.Id // .id) == '"$rec"') | (.Values // .values).amount] | first' <<<"$back")" == "32" ]] \
        || fail "the connector does not see the plugin's correction: $(head -c 600 <<<"$back")"
}

@test "records live: Claude Code reads what the record used to hold, and so does the connector" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    local id rec tok
    [[ -z "${MMRY_INTEGRATION_JWT:-}" ]] && skip "MMRY_INTEGRATION_JWT not set (connector tests)"
    id="$(_state format_id)"; rec="$(_state connector_record)"; tok="$(_state connector_token)"
    [[ -n "$id" && -n "$rec" ]] || fail "no connector record from the previous test, so this cannot run"

    _plugin record-history.sh --format-id "$id" --record-id "$rec"
    [[ "$status" -eq 0 ]] || fail "$output"
    [[ "$output" == *"was: -  now: 30"* ]] || fail "the value it was created with is missing: $output"
    [[ "$output" == *"was: 30  now: 32"* ]] || fail "the correction is missing: $output"
    [[ "$output" == *"The memory itself"* ]] || fail "the words' change is missing: $output"

    local hist
    hist="$(_connector "$tok" mmry_record_history "{\"formatId\":$id,\"recordId\":$rec}")"
    [[ "$(_jq -r '[(.history // .History)[] | select((.field // .Field) == "amount") | (.current // .Current)] | join(",")' <<<"$hist")" == "30,32" ]] \
        || fail "the connector's history differs: $(head -c 600 <<<"$hist")"
}

@test "records live: a record on another account answers not-found, identically to one that never existed" {
    [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]] && skip "No API key"
    [[ -z "${MMRY_INTEGRATION_STRANGER_API_KEY:-}" ]] && skip "MMRY_INTEGRATION_STRANGER_API_KEY not set"
    [[ -z "${MMRY_INTEGRATION_JWT:-}" ]] && skip "MMRY_INTEGRATION_JWT not set (it probes the connector record)"
    local id rec; id="$(_state format_id)"; rec="$(_state connector_record)"
    [[ -n "$id" && -n "$rec" ]] || fail "no connector record from the previous tests, so this cannot run"

    export MMRY_INTEGRATION_API_KEY="$MMRY_INTEGRATION_STRANGER_API_KEY"
    _plugin list-formats.sh
    [[ "$status" -eq 0 ]] || fail "CONTROL: the second account's key does not work: $output"
    _plugin record-history.sh --format-id "$id" --record-id "$rec"
    [[ "$status" -ne 0 && "$output" == *"404"* ]] || fail "$output"
    [[ "$output" != *"32"* ]] || fail "another account read the history: $output"
    local theirs="$output"
    _plugin record-history.sh --format-id "$id" --record-id 2000000000
    [[ "$output" == "${theirs//$rec/2000000000}" || "$output" == "$theirs" ]] \
        || fail "a foreign record and a missing one answer differently: [$theirs] vs [$output]"
}
