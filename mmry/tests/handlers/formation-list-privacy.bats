#!/usr/bin/env bats
# formation-list-privacy.bats - the formation list shows names only, and every read of one
# formation is asked from this session (#31854, DD-198).
#
# The service's half (who is answered) is the API repository's migration 100 and its backend suite.
# This file proves the plugin's half, on Claude Code and on Codex, which run the same scripts:
#
#   test case 1  formation-list.sh prints each live formation's id and name and nothing else: no
#                member count, whatever the service sends.
#   test case 2  the reads of one formation (roster, status, report, progress, assign, waiting)
#                name the calling session, because the service answers only a current member by
#                session or the person who started the formation.
#   test case 3  a session picks a formation from the list, joins it, and then reads its roster.
#
# The network is a fake curl that records "METHOD URL" for every request, so what the plugin SENDS
# is observed rather than inferred.

load '../helpers/test-helper'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    URLS="$TEST_TMPDIR/urls"
    mkdir -p "$BIN" "$TEST_TMPDIR/codexhome/mmry" "$TEST_TMPDIR/claudecfg"
    : > "$URLS"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; method="GET"; url=""; prev=""
for arg in "$@"; do
    case "$prev" in
        -o) out="$arg" ;;
        -X) method="$arg" ;;
    esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_URL_LOG"
code=200; resp='{}'
case "$method $url" in
    "POST "*/api/sessions) code=201; resp='' ;;
    "GET "*/api/formations/active*) resp="${FAKE_LIST:-[]}" ;;
    "POST "*/api/formations/*/join) resp="${FAKE_ROSTER:-}" ;;
    "GET "*/transmissions/sent*) resp='{"formationId":4242,"member":true,"messages":[]}' ;;
    "GET "*/transmissions*) resp='[]' ;;
    "GET "*/api/formations/*/close-out*) resp='{"formationId":4242,"objective":"the names job","members":[],"counts":{}}' ;;
    "GET "*/api/formations/*) resp="${FAKE_ROSTER:-}" ;;
esac
[[ -n "$resp" ]] || resp='{}'
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export FAKE_URL_LOG="$URLS"
    unset MMRY_API_URL MMRY_API_KEY
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    SID="bbbb2222-listprivacy-$$"
    export CLAUDE_CODE_SESSION_ID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    export FAKE_ROSTER='{"formation":{"id":4242,"objective":"the names job"},"members":[{"id":12,"sessionId":null,"userId":1,"email":"a@b.c","role":"Lead","displayName":"The lead","assignment":null,"progress":null,"leftDate":null},{"id":31,"sessionId":"'"$SID"'","userId":1,"email":"a@b.c","role":"Wingman","displayName":"Validator worker","assignment":"the validator","progress":null,"leftDate":null}]}'
    # What the service sends from 1.38: id and name, nothing else.
    NAMES_ONLY='[{"id":4242,"name":"the names job"},{"id":4243,"name":"the other job"}]'
    # What a service older than 1.38 sent: the same formations, with counts.
    WITH_COUNTS='[{"id":4242,"objective":"the names job","status":"Active","memberCount":7,"activeMemberCount":7},{"id":4243,"objective":"the other job","status":"Active","memberCount":3,"activeMemberCount":2}]'
    W1="The list shows each formation's id and name. Join one to see its members and messages."
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_codex() { export MMRY_HOST=codex CODEX_HOME="$TEST_TMPDIR/codexhome" CODEX_SESSION_ID="$SID"; }

# "GET <url>" lines for the read of formation 4242 itself (not a sub-route).
_detail_reads() { grep -E '^GET http://fake\.invalid/api/formations/4242(\?|$)' "$URLS" || true; }

# ---------------------------------------------------------------------------------------------
# Test case 1: the list shows names only
# ---------------------------------------------------------------------------------------------

@test "list: every live formation is printed by id and name, and nothing else" {
    FAKE_LIST="$NAMES_ONLY" run bash "$HH/formation-list.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"4242  the names job"* ]] || return 1
    [[ "$output" == *"4243  the other job"* ]] || return 1
    [[ "$output" != *"active member"* ]] || return 1
    [[ "$output" != *"no objective"* ]] || return 1
    [[ "$output" != *"("* ]] || return 1
}

@test "list: the line under the list says what it shows and how to see more" {
    FAKE_LIST="$NAMES_ONLY" run bash "$HH/formation-list.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$W1"* ]] || return 1
}

@test "list: a member count sent by an older service is never printed" {
    FAKE_LIST="$WITH_COUNTS" run bash "$HH/formation-list.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"4242  the names job"* ]] || return 1
    [[ "$output" != *"active member"* ]] || return 1
    [[ "$output" != *"7"* ]] || return 1
    [[ "$output" != *"Active"* ]] || return 1
}

@test "list: an account with no live formation keeps its one line, with no line under it" {
    FAKE_LIST='[]' run bash "$HH/formation-list.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "No active formations on this account." ]
}

@test "list on Codex: the same names-only list and the same line under it" {
    _codex
    FAKE_LIST="$NAMES_ONLY" run bash "$HH/formation-list.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"4242  the names job"* ]] || return 1
    [[ "$output" == *"4243  the other job"* ]] || return 1
    [[ "$output" != *"active member"* ]] || return 1
    [[ "$output" == *"$W1"* ]] || return 1
}

# ---------------------------------------------------------------------------------------------
# Test case 2: every read of one formation names the calling session
# ---------------------------------------------------------------------------------------------

@test "client: mmry_get_formation sends the session it is given, URL-encoded" {
    run bash -c 'source "$1/mmry-client.sh"; mmry_get_formation 4242 "a b:c&d"' _ "$HH"
    [ "$status" -eq 0 ]
    grep -qxF 'GET http://fake.invalid/api/formations/4242?sessionId=a%20b%3Ac%26d' "$URLS"
}

@test "client: mmry_get_formation with no session given sends the session's own id" {
    run bash -c 'source "$1/mmry-client.sh"; mmry_get_formation 4242' _ "$HH"
    [ "$status" -eq 0 ]
    grep -qxF "GET http://fake.invalid/api/formations/4242?sessionId=${SID}" "$URLS"
}

@test "client: mmry_get_formation_close_out sends this session" {
    run bash -c 'source "$1/mmry-client.sh"; mmry_get_formation_close_out 4242' _ "$HH"
    [ "$status" -eq 0 ]
    grep -qxF "GET http://fake.invalid/api/formations/4242/close-out?sessionId=${SID}" "$URLS"
}

@test "roster: the read names this session" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run bash "$HH/formation-roster.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Validator worker"* ]] || return 1
    [ "$(_detail_reads)" = "GET http://fake.invalid/api/formations/4242?sessionId=${SID}" ]
}

@test "roster with a formation id given: the read still names this session" {
    run bash "$HH/formation-roster.sh" 4242
    [ "$status" -eq 0 ]
    [ "$(_detail_reads)" = "GET http://fake.invalid/api/formations/4242?sessionId=${SID}" ]
}

@test "status: the read names this session" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run bash "$HH/formation-status.sh"
    [ -n "$(_detail_reads)" ]
    [ -z "$(_detail_reads | grep -v -F "?sessionId=${SID}")" ]
}

@test "report: the close-out read names this session" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run bash "$HH/formation-report.sh"
    grep -qxF "GET http://fake.invalid/api/formations/4242/close-out?sessionId=${SID}" "$URLS"
}

@test "progress: the roster read behind it names this session" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run bash "$HH/formation-progress.sh" Accepted
    [ -n "$(_detail_reads)" ]
    [ -z "$(_detail_reads | grep -v -F "?sessionId=${SID}")" ]
}

@test "assign: the roster read behind a self-rename names this session" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run bash "$HH/formation-assign.sh" --name "A new name"
    [ -n "$(_detail_reads)" ]
    [ -z "$(_detail_reads | grep -v -F "?sessionId=${SID}")" ]
}

@test "no script reads one formation except through the two helpers that name the session" {
    # formation-waiting.sh and any later script: a read of /api/formations/<id> or its close-out
    # written anywhere but mmry-client.sh would skip the session and be refused by the service.
    run bash -c 'grep -n -E "_mmry_request GET \"/api/formations/[^\"]*\"" "$1"/*.sh | grep -v "/mmry-client.sh:"'  _ "$HH"
    [ -z "$output" ]
    # In the client, the read of one formation and its close-out both carry sessionId.
    run bash -c 'grep -E "_mmry_request GET \"/api/formations/\\$\\{formation_id\\}(/close-out)?[\"?]" "$1/mmry-client.sh"' _ "$HH"
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == *'?sessionId='* ]] || return 1
    [[ "${lines[1]}" == *'?sessionId='* ]] || return 1
}

@test "roster on Codex: the read names the Codex conversation's session" {
    _codex
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run bash "$HH/formation-roster.sh"
    [ "$status" -eq 0 ]
    [ "$(_detail_reads)" = "GET http://fake.invalid/api/formations/4242?sessionId=${SID}" ]
}

# ---------------------------------------------------------------------------------------------
# Test case 3: pick from the list, join, then see the details
# ---------------------------------------------------------------------------------------------

@test "a session picks a formation from the list, joins it, and then reads its roster" {
    FAKE_LIST="$NAMES_ONLY" run bash "$HH/formation-list.sh"
    [ "$status" -eq 0 ]
    picked="$(printf '%s\n' "$output" | awk '$2 == "the" && $3 == "names" {print $1; exit}')"
    [ "$picked" = "4242" ]

    run bash "$HH/formation-join.sh" "$picked"
    [ "$status" -eq 0 ]
    grep -qxF "POST http://fake.invalid/api/formations/4242/join" "$URLS"

    run bash "$HH/formation-roster.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"The lead"* ]] || return 1
    [[ "$output" == *"Validator worker"* ]] || return 1
    [ "$(_detail_reads)" = "GET http://fake.invalid/api/formations/4242?sessionId=${SID}" ]
}
