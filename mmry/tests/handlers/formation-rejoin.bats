#!/usr/bin/env bats
# formation-rejoin.bats - a session that leaves a formation and joins it again keeps its seat and
# is shown what it missed, once (#32385, DD-146 in the API repository).
#
# The service gives a returning session its original roster entry back (the API repository's
# migration 073 and formation-rejoin.test.ts prove that half). This file proves the plugin's half:
#
#   requirement 1  the join output shows the returning member id, and says it is a return.
#   requirement 4  leaving keeps this session's delivery position for the formation it left, and a
#                  join of the SAME formation restores it, so the next poll asks from where it was
#                  rather than from the start and nothing shown before leaving is shown again; a
#                  join of a DIFFERENT formation starts from the start as it always did. A message
#                  the service marks sentWhileAway is rendered with the away marker, and one it does
#                  not is rendered without it.
#
# The network is a fake curl that answers like the service and records every request, so what the
# plugin SENDS (the since= position) is observed rather than inferred.

load '../helpers/test-helper'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    BODIES="$TEST_TMPDIR/bodies"
    URLS="$TEST_TMPDIR/urls"
    mkdir -p "$BIN"
    : > "$BODIES"; : > "$URLS"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
# A fake MMRY AI. Records "METHOD URL" and every request body; answers like the service would.
out=""; method="GET"; url=""; prev=""; body=""
for arg in "$@"; do
    case "$prev" in
        -o) out="$arg" ;;
        -X) method="$arg" ;;
        --data-binary|-d|--data) if [[ "$arg" == @* ]]; then body="$(cat "${arg#@}")"; else body="$arg"; fi ;;
    esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_URL_LOG"
[[ -n "$body" ]] && printf '%s\n' "$body" >> "$FAKE_BODY_LOG"
returned='null'
[[ -n "${FAKE_RETURNED:-}" ]] && returned='"2026-10-19T10:00:00"'
code=200; resp='{}'
case "$method $url" in
    "POST "*/api/sessions) code=201; resp='' ;;
    "POST "*/api/formations/leave) resp='{"formationId":4242,"sessionId":"'"${FAKE_OWN_SID:-}"'","leftDate":"2026-10-19T09:00:00","formationStatus":"Active","memberCount":1,"activeMemberCount":1}' ;;
    "POST "*/api/formations/*/join)
        fid="${url%/join}"; fid="${fid##*/}"
        resp='{"formation":{"id":'"$fid"',"objective":"the rejoin job"},"members":[{"id":12,"sessionId":null,"role":"Lead","displayName":"The lead","leftDate":null,"returnedDate":null},{"id":31,"sessionId":"'"${FAKE_OWN_SID:-}"'","role":"Wingman","displayName":"Validator worker","leftDate":null,"returnedDate":'"$returned"'}]}' ;;
    "GET "*/transmissions/sent*) resp='{"formationId":4242,"member":true,"messages":[]}' ;;
    "GET "*/transmissions*) resp="${FAKE_TX:-[]}" ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export FAKE_URL_LOG="$URLS" FAKE_BODY_LOG="$BODIES"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID FAKE_RETURNED
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    SID="aaaa2222-rejoin-$$"
    export CLAUDE_CODE_SESSION_ID="$SID" FAKE_OWN_SID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    rm -f "$TEST_TMPDIR"/.mmry-away-* 2>/dev/null || true
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_state() { bash "$HH/formation-state.sh" get "$SID"; }

# ---------------------------------------------------------------------------------------------
# Requirement 1: the join output shows the returning id
# ---------------------------------------------------------------------------------------------

@test "R-01 a first join says which member this session is, and does not call it a return" {
    run bash "$HH/formation-join.sh" 4242
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"You are member 31"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"back as member"* ]] || { echo "$output"; return 1; }
}

@test "R-02 a join that returned the seat says so, with the id the session had before" {
    run env FAKE_RETURNED=1 bash "$HH/formation-join.sh" 4242
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"You are back as member 31"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"the id you had before"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Validator worker"* ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# Requirement 4: the delivery position survives leave and rejoin of the same formation
# ---------------------------------------------------------------------------------------------

@test "R-03 leave keeps the position, and a join of the same formation restores it" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    bash "$HH/formation-state.sh" seen "2026-10-19T01:00:00" "$SID"
    [ "$(_state)" = "4242 2026-10-19T01:00:00" ]

    run bash "$HH/formation-leave.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Delivery has stopped: the membership record is gone.
    [ -z "$(_state)" ] || { echo "state after leave: $(_state)"; return 1; }

    run bash "$HH/formation-join.sh" 4242
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_state)" = "4242 2026-10-19T01:00:00" ] || { echo "state after rejoin: [$(_state)]"; return 1; }
}

@test "R-04 a join of a different formation after leaving starts from the start" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    bash "$HH/formation-state.sh" seen "2026-10-19T01:00:00" "$SID"
    run bash "$HH/formation-leave.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    run bash "$HH/formation-join.sh" 4343
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_state)" = "4343 " ] || { echo "state after joining another: [$(_state)]"; return 1; }
}

@test "R-05 the restored position is what the next poll asks from" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    bash "$HH/formation-state.sh" seen "2026-10-19T01:00:00" "$SID"
    run bash "$HH/formation-leave.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run bash "$HH/formation-join.sh" 4242
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    : > "$URLS"
    run env FAKE_TX='[]' bash "$HH/formation-check.sh"
    grep -q 'transmissions?sessionId=.*since=2026-10-19T01%3A00%3A00' "$URLS" || { cat "$URLS"; return 1; }
}

@test "R-06 a kept position is used once: a later leave with nothing seen keeps nothing" {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    bash "$HH/formation-state.sh" seen "2026-10-19T01:00:00" "$SID"
    run bash "$HH/formation-leave.sh"
    run bash "$HH/formation-join.sh" 4242
    [ "$(_state)" = "4242 2026-10-19T01:00:00" ]
    # Leave again, having seen nothing new since the restore: the kept position is the same one.
    run bash "$HH/formation-leave.sh"
    run bash "$HH/formation-join.sh" 4343
    [ "$(_state)" = "4343 " ] || { echo "[$(_state)]"; return 1; }
    run bash "$HH/formation-leave.sh"
    run bash "$HH/formation-join.sh" 4242
    # The position belonged to 4242 and was dropped when 4343 was joined: nothing is restored now.
    [ "$(_state)" = "4242 " ] || { echo "[$(_state)]"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# Requirement 4: the away marker on a rendered message
# ---------------------------------------------------------------------------------------------

_deliver() {
    bash "$HH/formation-state.sh" set 4242 "$SID"
    run env FAKE_TX="$1" bash "$HH/formation-check.sh"
}

TX_AWAY='[{"transmissionID":1,"senderRole":"Lead","senderSessionID":null,"senderUserID":1,"senderMemberID":12,"senderName":"The lead","recipientMemberID":null,"sentWhileAway":true,"content":"said while you were out","sentDate":"2026-10-19T09:30:00"}]'
TX_NOW='[{"transmissionID":2,"senderRole":"Lead","senderSessionID":null,"senderUserID":1,"senderMemberID":12,"senderName":"The lead","recipientMemberID":null,"sentWhileAway":false,"content":"said now","sentDate":"2026-10-19T10:30:00"}]'
TX_OLD_SHAPE='[{"transmissionID":3,"senderRole":"Lead","senderSessionID":null,"senderUserID":1,"senderMemberID":12,"senderName":"The lead","recipientMemberID":null,"content":"older service","sentDate":"2026-10-19T10:31:00"}]'

@test "R-07 a message sent while this session was away carries the away marker and its guidance" {
    _deliver "$TX_AWAY"
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[The lead (12)] SENT WHILE YOU WERE AWAY: said while you were out"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"while this session was out of the formation"* ]] || { echo "$output"; return 1; }
}

@test "R-08 a message sent while this session was present carries no marker, nor does an older service's shape" {
    _deliver "$TX_NOW"
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[The lead (12)] said now"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SENT WHILE YOU WERE AWAY"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"out of the formation"* ]] || { echo "$output"; return 1; }

    bash "$HH/formation-state.sh" clear "$SID"
    _deliver "$TX_OLD_SHAPE"
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[The lead (12)] older service"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SENT WHILE YOU WERE AWAY"* ]] || { echo "$output"; return 1; }
}
