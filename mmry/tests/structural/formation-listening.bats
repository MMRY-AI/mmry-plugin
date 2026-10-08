#!/usr/bin/env bats
# A formation member keeps listening while it is in the formation, and a sender can see whether a
# directed message was read (#31721).
#
# The defect: the background watch that listens for a member sitting idle ran for four minutes,
# asked every fifteen seconds, and stopped for good. After that the member heard nothing until a
# person typed into its window, and the sender was never told the message had not been read. On
# 2026-10-04 a lead's questions and members' assignments sat unread for an hour or more.
#
# What these prove, at handler level, against a stub service:
#   requirement 1  the watch renews itself while the service confirms membership, and stops when
#                  the member leaves (locally or on the service) or membership cannot be confirmed;
#   requirement 2  the hook reports the directed ids it printed on its next poll, never before
#                  printing, never a broadcast, and keeps the report until a poll is answered; the
#                  sender sees both states in the roster;
#   requirement 3  a reply 10 s after the turn ends is surfaced within 15 s, and lengthening the
#                  early interval is caught;
#   requirement 4  over one full shipped window, fewer requests than the flat 15 s rate;
#   requirement 5  the poll lock: a live holder keeps it however old, a dead one releases it, and
#                  a pid-less lock goes by the age derived from the schedule.
# The live renewal across real Claude Code sessions is not provable here; see
# docs/evidence/31721-hook-ceiling.md for that measurement and the live test.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-31721-$$"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_JQ MMRY_IDLE_POLL_SECONDS MMRY_IDLE_POLL_INTERVAL
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset_locks
    URLS="${BATS_TEST_TMPDIR}/urls.log"
    : > "$URLS"
    # The environment every run here shares: a routing curl first on PATH, an API key, and a URL
    # nothing listens on. Exported rather than passed per command, because PATH on a Windows host
    # carries spaces and would not survive being word-split onto an env command line.
    export PATH="$(_routing_curl_dir):${PATH}"
    export MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid"
    export FAKE_URL_LOG="$URLS"
    DIRECTED='[{"transmissionID":41,"senderRole":"lead","senderSessionID":null,"senderUserID":7,"recipientMemberID":5,"content":"LS-DIRECTED take the validator","sentDate":"2026-10-07T01:00:00"},{"transmissionID":42,"senderRole":"lead","senderSessionID":null,"senderUserID":7,"recipientMemberID":null,"content":"LS-BROADCAST heads up","sentDate":"2026-10-07T01:00:01"}]'
}

teardown() {
    [[ -n "${BG_PID:-}" ]] && kill "$BG_PID" 2>/dev/null || true
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset_locks
}

_sid() { printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'; }

_reset_locks() {
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_sid)" "${TMPDIR}/.mmry-formation-poll-$(_sid)" \
           "${TMPDIR}/.mmry-formation-renewed-$(_sid)"
}

# A curl that ROUTES: the membership-and-read-status route answers with FAKE_SENT_*, everything else
# with FAKE_*. Every URL is logged, so "was it asked" and "what was it told" are observed facts.
# FAKE_READY_AT, when set, holds the message back until that epoch second, which is how a reply
# that arrives some seconds after the turn ended is staged. FAKE_SEQ_DIR, when set, serves the
# transmissions route from numbered files, one per request, so a test can script a conversation.
_routing_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/route-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s\n' "$url" >> "$FAKE_URL_LOG"
case "$url" in
    */transmissions/sent*)
        body="${FAKE_SENT_BODY:-}"; code="${FAKE_SENT_CODE:-200}" ;;
    *)
        body="${FAKE_BODY:-[]}"; code="${FAKE_CODE:-200}"
        if [[ -n "${FAKE_READY_AT:-}" ]] && (( $(date +%s) < FAKE_READY_AT )); then body='[]'; fi
        if [[ -n "${FAKE_SEQ_DIR:-}" ]]; then
            n=$(( $(cat "${FAKE_SEQ_DIR}/n" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "${FAKE_SEQ_DIR}/n"
            [[ -f "${FAKE_SEQ_DIR}/${n}.body" ]] && body="$(cat "${FAKE_SEQ_DIR}/${n}.body")"
            [[ -f "${FAKE_SEQ_DIR}/${n}.code" ]] && code="$(cat "${FAKE_SEQ_DIR}/${n}.code")"
        fi ;;
esac
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

_member_true='{"formationId":4242,"member":true,"messages":[]}'
_member_false='{"formationId":4242,"member":false,"messages":[]}'

_count_polls() { grep -c '/transmissions?' "$URLS" 2>/dev/null || true; }
_count_sent()  { grep -c '/transmissions/sent' "$URLS" 2>/dev/null || true; }

# =============================================================================================
# REQUIREMENT 1: renew while in the formation, stop when not
# =============================================================================================

@test "renew: a window that ends with nothing to say renews the watch while the service confirms membership" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ] || { echo "expected a renewal wake (exit 2), got ${status}: ${output}"; return 1; }
    [[ "$output" == *"MMRY FORMATION WATCH RENEWED (formation 4242)"* ]] || { echo "no renewal notice: ${output}"; return 1; }
    [[ "$output" == *"end your turn now"* ]]
    # A renewal is not a message, and must never be dressed as one.
    [[ "$output" != *"FORMATION TRANSMISSION"* ]]
    # It polled first, and asked about membership exactly once, at the end.
    [ "$(_count_polls)" -ge 2 ]
    [ "$(_count_sent)" -eq 1 ]
    # The next watch is told it follows a renewal.
    [ -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ]
}

@test "renew: the chain continues, watch after watch, with no person typing" {
    # Three consecutive watches against a service that keeps confirming membership. Each is what the
    # Stop after the previous renewal starts. Every one must renew, none may deliver, and none may be
    # refused by a lock the previous one left: that is "keeps listening for as long as it remains".
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local i
    for i in 1 2 3; do
        run env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
            MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
            bash "${HANDLERS}/formation-check.sh"
        [ "$status" -eq 2 ] || { echo "watch ${i} did not renew: ${status} ${output}"; return 1; }
        [[ "$output" == *"WATCH RENEWED"* ]] || { echo "watch ${i}: ${output}"; return 1; }
        [ ! -d "${TMPDIR}/.mmry-formation-poll-$(_sid)" ] || { echo "watch ${i} left its lock behind"; return 1; }
    done
    [ "$(_count_sent)" -eq 3 ]
}

@test "renew: a message that arrives during a renewed watch is still delivered" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ]
    run env FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"LS-DIRECTED take the validator"* ]]
    [[ "$output" != *"WATCH RENEWED"* ]]
}

@test "stop: leaving the formation mid-watch stops it at once, quietly, without asking to renew" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local out="${BATS_TEST_TMPDIR}/watch.out" t0 t1 rc=0
    t0="$(date +%s)"
    env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" </dev/null >"$out" 2>&1 &
    BG_PID=$!

    local waited=0
    while [ "$(_count_polls)" -lt 1 ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$(( waited + 1 )); done
    [ "$(_count_polls)" -ge 1 ] || { echo "the watch never polled, so leaving proves nothing"; return 1; }

    # What /mmry:formation leave does locally.
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"

    wait "$BG_PID" || rc=$?
    BG_PID=""
    t1="$(date +%s)"
    [ "$rc" -eq 0 ] || { echo "a watch whose member left exited ${rc}: $(cat "$out")"; return 1; }
    [ ! -s "$out" ] || { echo "a watch whose member left said something: $(cat "$out")"; return 1; }
    [ "$(_count_sent)" -eq 0 ] || { echo "it asked to renew a membership the member had just left"; return 1; }
    (( t1 - t0 < 30 )) || { echo "it ran on for $(( t1 - t0 )) s after the member left"; return 1; }
}

@test "stop: joining another formation stops the watch on the old one" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local out="${BATS_TEST_TMPDIR}/watch.out" rc=0
    env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" </dev/null >"$out" 2>&1 &
    BG_PID=$!
    local waited=0
    while [ "$(_count_polls)" -lt 1 ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$(( waited + 1 )); done
    bash "${HANDLERS}/formation-state.sh" set 5151 "$CLAUDE_SESSION_ID"
    wait "$BG_PID" || rc=$?
    BG_PID=""
    [ "$rc" -eq 0 ]
    [ ! -s "$out" ]
    [ "$(_count_sent)" -eq 0 ]
}

@test "stop: when the service says this session is no longer a member, the watch ends without waking anyone" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_false" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ] || { echo "a closed membership was renewed: ${status} ${output}"; return 1; }
    [ -z "$output" ]
    [ "$(_count_sent)" -eq 1 ]
    [ ! -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ]
}

@test "stop: membership the service cannot confirm is never renewed: not a 404, a 401, a 500 or a body without the answer" {
    local code body
    for pair in "404|" "401|" "500|" "200|[]" "200|{\"member\":\"yes\"}"; do
        code="${pair%%|*}"; body="${pair#*|}"
        bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
        _reset_locks
        : > "$URLS"
        run env FAKE_BODY='[]' FAKE_SENT_CODE="$code" FAKE_SENT_BODY="$body" \
            MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
            bash "${HANDLERS}/formation-check.sh"
        [ "$status" -eq 0 ] || { echo "HTTP ${code} '${body}' renewed the watch: ${output}"; return 1; }
        [ -z "$output" ] || { echo "HTTP ${code} '${body}' said: ${output}"; return 1; }
        # A server fault is asked about once more; a definite answer is not.
        if [ "$code" = "500" ]; then [ "$(_count_sent)" -eq 2 ]; else [ "$(_count_sent)" -eq 1 ]; fi
    done
}

@test "control: the leave test fails against a watch that does not re-read its membership" {
    # POSITIVE CONTROL for "leaving the formation mid-watch stops it". The same scenario against a
    # handler with the per-iteration check removed must run to the end of its window instead.
    local mutant="${BATS_TEST_TMPDIR}/handlers-noleave"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    perl -0777 -pi -e 's{\n[ ]+mmry_formation_state_read "\$session_id" \|\| exit 0\n[ ]+\[\[ "\$MMRY_FS_FORMATION" == "\$formation_id" \]\] \|\| exit 0\n}{\n}' "${mutant}/formation-check.sh"
    ! cmp -s "${mutant}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    bash -n "${mutant}/formation-check.sh"

    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local out="${BATS_TEST_TMPDIR}/watch.out" t0 t1
    t0="$(date +%s)"
    env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=8 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${mutant}/formation-check.sh" </dev/null >"$out" 2>&1 &
    BG_PID=$!
    local waited=0
    while [ "$(_count_polls)" -lt 1 ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$(( waited + 1 )); done
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"
    wait "$BG_PID" || true
    BG_PID=""
    t1="$(date +%s)"
    (( t1 - t0 >= 6 )) || { echo "the mutant stopped after $(( t1 - t0 )) s too, so the leave test proves nothing"; return 1; }
}

# =============================================================================================
# REQUIREMENT 2: the hook reports what it printed; the sender sees both states
# =============================================================================================

@test "read: the directed id printed is reported on the next poll, the broadcast never is, and then it is forgotten" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # First check: delivers both lines. Nothing is owed yet, so nothing is reported.
    run env FAKE_BODY="$DIRECTED" bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"LS-DIRECTED"* ]]
    run grep -c 'shownIds=' "$URLS"
    [ "$output" -eq 0 ]

    # Second check: carries the DIRECTED id 41, and not the broadcast 42.
    : > "$URLS"
    run env FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    run grep -o 'shownIds=[0-9,]*' "$URLS"
    [ "$output" = "shownIds=41" ] || { echo "expected exactly the directed id 41 to be reported, got: ${output}"; return 1; }

    # Third check: answered, so nothing is owed any more.
    : > "$URLS"
    run env FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh"
    run grep -c 'shownIds=' "$URLS"
    [ "$output" -eq 0 ]
}

@test "read: a poll that fails keeps the report, and the next one makes it" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run env FAKE_BODY="$DIRECTED" bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ]

    : > "$URLS"
    run env FAKE_CODE=500 FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    run grep -c 'shownIds=41' "$URLS"
    [ "$output" -eq 1 ]

    : > "$URLS"
    run env FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh"
    run grep -c 'shownIds=41' "$URLS"
    [ "$output" -eq 1 ] || { echo "the report owed after a failed poll was lost"; return 1; }
}

@test "read: nothing is reported for a batch that was not printed" {
    # The check that runs out of time (#31746) fetches and prints nothing. It must owe nothing
    # either, or the sender would be told a message was read that nobody was shown. A deadline in the
    # past is staged with a reserve larger than the budget, which is exactly "no time left".
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local mutant="${BATS_TEST_TMPDIR}/handlers-late"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    # The response arrives, then the deadline has passed: _fc_in_time refuses to hand over the block.
    perl -0777 -pi -e 's{_fc_in_time \|\| \{ _release_mutex; return 1; \}}{SECONDS=999; _fc_in_time || { _release_mutex; return 1; }}' "${mutant}/formation-check.sh"
    ! cmp -s "${mutant}/formation-check.sh" "${HANDLERS}/formation-check.sh"

    run env FAKE_BODY="$DIRECTED" MMRY_FORMATION_MODE=prompt bash "${mutant}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    : > "$URLS"
    run env FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh"
    run grep -c 'shownIds=' "$URLS"
    [ "$output" -eq 0 ] || { echo "an id was reported read for a batch that was never printed"; return 1; }
}

@test "read: a session with a pre-#31721 state file (two lines) still works and owes nothing" {
    printf '4242\n2026-10-07T00:00:00\n' > "${TMPDIR}/.mmry-formation-$(_sid)"
    run env FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    run cat "$URLS"
    [[ "$output" == *"since=2026-10-07T00%3A00%3A00"* ]]
    [[ "$output" != *"shownIds"* ]]
}

_ROSTER='{"formation":{"id":4242,"objective":"migrate the billing schema"},"members":[{"id":5,"role":"Wingman","email":"dev@example.com","leftDate":null},{"id":3,"role":"Lead","email":"lead@example.com","leftDate":null}]}'

@test "sender: the roster shows a directed message as NOT READ YET, and as READ once it has been shown" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local unread='{"formationId":4242,"member":true,"messages":[{"transmissionId":41,"recipientMemberId":5,"recipientRole":"Wingman","recipientHasLeft":false,"sentDate":"2026-10-07T01:00:00","read":false,"readDate":null,"preview":"take the validator"}]}'
    local read='{"formationId":4242,"member":true,"messages":[{"transmissionId":41,"recipientMemberId":5,"recipientRole":"Wingman","recipientHasLeft":false,"sentDate":"2026-10-07T01:00:00","read":true,"readDate":"2026-10-07T01:02:03.1234567","preview":"take the validator"}]}'

    run env FAKE_BODY="$_ROSTER" FAKE_SENT_BODY="$unread" bash "${HANDLERS}/formation-roster.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dev@example.com"* ]]
    [[ "$output" == *"Directed messages this session sent"* ]] || { echo "${output}"; return 1; }
    [[ "$output" == *"to member 5 (Wingman)  NOT READ YET  \"take the validator\""* ]] || { echo "${output}"; return 1; }

    run env FAKE_BODY="$_ROSTER" FAKE_SENT_BODY="$read" bash "${HANDLERS}/formation-roster.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"to member 5 (Wingman)  READ 2026-10-07 01:02:03 UTC  \"take the validator\""* ]] || { echo "${output}"; return 1; }
    [[ "$output" != *"NOT READ YET"* ]]
    # The footer is still last, and unchanged in substance.
    [[ "$(printf '%s\n' "$output" | tail -1)" == "with /mmry:formation report." ]]
}

@test "sender: the roster stands on its own when read status cannot be had" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local code
    for code in 404 500; do
        run env FAKE_BODY="$_ROSTER" FAKE_SENT_CODE="$code" FAKE_SENT_BODY='{}' bash "${HANDLERS}/formation-roster.sh"
        [ "$status" -eq 0 ]
        [[ "$output" == *"dev@example.com"* ]]
        [[ "$output" != *"Directed messages this session sent"* ]]
    done
}

@test "sender: a directed send tells the sender where to see whether it was read" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run env FAKE_CODE=201 FAKE_BODY='{"transmissionId":41,"formationId":4242,"recipientMemberId":5,"stored":1}' \
        bash "${HANDLERS}/formation-say.sh" "take the validator" 5
    [ "$status" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "$output" == *"Sent to member 5"* ]]
    [[ "$output" == *"not read yet until it has been shown to them"* ]]
    [[ "$output" == *"/mmry:formation roster shows whether it has been read"* ]]
}

# =============================================================================================
# REQUIREMENT 3: a reply soon after the turn ends is surfaced at least as quickly as before
# =============================================================================================

# Runs the shipped schedule (no interval override) against a stub that holds the reply back until
# 10 s after the turn ended, and echoes the whole seconds from turn end to the message being shown.
_reply_latency() {
    local hdir="$1" t0 t1
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    t0="$(date +%s)"
    run env FAKE_BODY="$DIRECTED" FAKE_READY_AT=$(( t0 + 10 )) FAKE_SENT_BODY="$_member_false" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=40 \
        bash "${hdir}/formation-check.sh"
    t1="$(date +%s)"
    [ "$status" -eq 2 ] || { echo "status ${status}: ${output}" >&2; printf 'none'; return 0; }
    [[ "$output" == *"LS-DIRECTED"* ]] || { echo "not delivered: ${output}" >&2; printf 'none'; return 0; }
    printf '%s' "$(( t1 - t0 ))"
}

@test "early: a reply sent 10 s after the turn ends is surfaced within 15 s" {
    local s; s="$(_reply_latency "$HANDLERS")"
    [ "$s" != "none" ] || { echo "the reply was never surfaced"; return 1; }
    echo "surfaced ${s} s after the turn ended" >&3
    (( s <= 15 )) || { echo "surfaced ${s} s after the turn ended; the requirement is 15"; return 1; }
}

@test "control: the 15 s test fails when the early interval is lengthened" {
    # POSITIVE CONTROL. The same staging against a handler whose early interval is lengthened must
    # miss the 15 s mark, or the test above is passing on the stub and not on the schedule. 20 s and
    # not the old flat 15: 15 lands on the boundary itself, and whole-second timing on a fast host
    # could read it either way, which would make this control a coin toss rather than a proof.
    local mutant="${BATS_TEST_TMPDIR}/handlers-slow-early"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    perl -pi -e 's{^_IDLE_EARLY_INTERVAL=3$}{_IDLE_EARLY_INTERVAL=20}' "${mutant}/formation-check.sh"
    ! cmp -s "${mutant}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }

    local s; s="$(_reply_latency "$mutant")"
    [ "$s" != "none" ] || { echo "the mutant never surfaced the reply at all"; return 1; }
    echo "the lengthened interval surfaced it ${s} s after the turn ended" >&3
    (( s > 15 )) || { echo "a 20 s early interval still surfaced it in ${s} s, so the test above proves nothing"; return 1; }
}

# =============================================================================================
# REQUIREMENT 4: fewer requests over a long wait
# =============================================================================================

# A clock that only moves when the handler sleeps, so the SHIPPED window - 28 minutes - runs in a
# second or two. `date +%s` reads it and `sleep N` advances it; every other use of date goes to the
# real one. Echoes the number of message polls the watch made over one full window.
_polls_over_window() {
    local hdir="$1" interval="${2:-}"
    local clock="${BATS_TEST_TMPDIR}/clock" shim="${BATS_TEST_TMPDIR}/clock-bin"
    local real_date; real_date="$(command -v date)"
    mkdir -p "$shim"
    cat > "${shim}/date" <<SHIM
#!/usr/bin/env bash
if [ "\$*" = "+%s" ]; then cat "${clock}"; exit 0; fi
exec "${real_date}" "\$@"
SHIM
    cat > "${shim}/sleep" <<SHIM
#!/usr/bin/env bash
n="\${1%%.*}"; n="\${n:-0}"
printf '%s' "\$(( \$(cat "${clock}") + n ))" > "${clock}"
SHIM
    chmod +x "${shim}/date" "${shim}/sleep"
    local start; start="$("$real_date" +%s)"
    printf '%s' "$start" > "$clock"

    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    : > "$URLS"
    if [ -n "$interval" ]; then
        env PATH="${shim}:${PATH}" FAKE_BODY='[]' FAKE_SENT_BODY="$_member_false" \
            MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_INTERVAL="$interval" \
            bash "${hdir}/formation-check.sh" </dev/null >/dev/null 2>&1 || true
    else
        env PATH="${shim}:${PATH}" FAKE_BODY='[]' FAKE_SENT_BODY="$_member_false" \
            MMRY_FORMATION_MODE=idle \
            bash "${hdir}/formation-check.sh" </dev/null >/dev/null 2>&1 || true
    fi
    printf '%s %s' "$(_count_polls)" "$(( $(cat "$clock") - start ))"
}

@test "fewer: over one full shipped window the watch asks fewer times than the flat 15 s rate" {
    local polls elapsed flat
    read -r polls elapsed <<< "$(_polls_over_window "$HANDLERS")"
    # The window really ran: the clock moved through most of the shipped 28 minutes.
    (( elapsed >= 1600 )) || { echo "the simulated window covered only ${elapsed} s"; return 1; }
    flat=$(( elapsed / 15 + 1 ))
    echo "backoff: ${polls} requests over ${elapsed} s; flat 15 s rate over the same time: ${flat}" >&3
    (( polls < flat )) || { echo "${polls} requests is not fewer than the flat rate's ${flat}"; return 1; }
    # And the backoff is not achieved by not listening: the first minute is the busiest.
    (( polls >= 40 )) || { echo "${polls} requests over a whole window is too few to be the schedule"; return 1; }
}

@test "control: the same count at a flat 15 s is the flat rate, so the counter measures the schedule" {
    local polls elapsed flat
    read -r polls elapsed <<< "$(_polls_over_window "$HANDLERS" 15)"
    flat=$(( elapsed / 15 + 1 ))
    echo "flat 15 s: ${polls} requests over ${elapsed} s" >&3
    (( polls >= flat - 1 && polls <= flat + 1 )) || { echo "flat interval made ${polls}, expected about ${flat}"; return 1; }
}

@test "fewer: a watch that follows a renewal starts at the slow end of the schedule" {
    local fresh renewed elapsed
    read -r fresh elapsed <<< "$(_polls_over_window "$HANDLERS")"
    mkdir -p "${TMPDIR}/.mmry-formation-renewed-$(_sid)"
    # _polls_over_window resets the locks, which would remove the marker; plant it after the reset.
    local hdir="${BATS_TEST_TMPDIR}/handlers-plant"
    rm -rf "$hdir"; mkdir -p "$hdir"; cp "${HANDLERS}"/*.sh "$hdir"/
    perl -0777 -pi -e 's{(_renew_marker="\$\{MMRY_TMPDIR\}/\.mmry-formation-renewed-\$\{_safe_sid\}"\n)}{$1        mkdir "\$_renew_marker" 2>/dev/null || true\n}' "${hdir}/formation-check.sh"
    ! cmp -s "${hdir}/formation-check.sh" "${HANDLERS}/formation-check.sh"
    read -r renewed elapsed <<< "$(_polls_over_window "$hdir")"
    echo "fresh watch: ${fresh} requests; after a renewal: ${renewed}" >&3
    (( renewed < fresh - 20 )) || { echo "a renewed watch made ${renewed}, a fresh one ${fresh}"; return 1; }
}

@test "fewer: a typed prompt clears the renewal marker, so the next watch starts fast again" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    mkdir -p "${TMPDIR}/.mmry-formation-renewed-$(_sid)"
    run env FAKE_BODY='[]' MMRY_FORMATION_MODE=prompt bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ ! -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ]
}

# =============================================================================================
# REQUIREMENT 5: the poll lock's rule, re-derived (#31405)
# =============================================================================================

@test "lock: a live watcher's lock is never taken over, however old it is" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local dir="${TMPDIR}/.mmry-formation-poll-$(_sid)"
    mkdir -p "$dir"
    sleep 300 &
    local live=$!
    printf '%s\n' "$live" > "${dir}/pid"
    touch -d "2020-01-01" "$dir" 2>/dev/null || touch -t 202001010000 "$dir"
    run env FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    kill "$live" 2>/dev/null || true
    [ "$status" -eq 0 ] || { echo "a second watcher started beside a live one: ${status} ${output}"; return 1; }
    [ -z "$output" ]
    [ "$(_count_polls)" -eq 0 ]
}

@test "lock: a dead watcher's lock is reclaimed at once, however fresh it is" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local dir="${TMPDIR}/.mmry-formation-poll-$(_sid)"
    mkdir -p "$dir"
    bash -c 'exit 0' &
    local dead=$!
    wait "$dead" || true
    printf '%s\n' "$dead" > "${dir}/pid"
    run env FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ] || { echo "a dead watcher's lock silenced delivery: ${status} ${output}"; return 1; }
    [[ "$output" == *"LS-DIRECTED"* ]]
}

@test "lock: a lock with no pid goes by age, and the age is the one derived from the schedule" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local dir="${TMPDIR}/.mmry-formation-poll-$(_sid)"
    # Younger than 120 s: held.
    mkdir -p "$dir"
    run env FAKE_BODY="$DIRECTED" MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Older than 120 s and younger than the old window + 60 (1740 s): reclaimed. Under the old rule
    # this lock would have silenced delivery for another 25 minutes.
    local ten_min_ago; ten_min_ago="$(( $(date +%s) - 600 ))"
    touch -d "@${ten_min_ago}" "$dir" 2>/dev/null \
        || touch -t "$(date -r "$ten_min_ago" +%Y%m%d%H%M.%S 2>/dev/null)" "$dir"
    run env FAKE_BODY="$DIRECTED" MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ] || { echo "a ten-minute-old abandoned lock was not reclaimed: ${status} ${output}"; return 1; }
    [[ "$output" == *"LS-DIRECTED"* ]]
}

@test "budget: the Stop registration outlasts the window with room for one last poll and the renewal question" {
    local window stop
    window="$(sed -n 's/^MMRY_IDLE_POLL_SECONDS="\${MMRY_IDLE_POLL_SECONDS:-\([0-9]*\)}"$/\1/p' "${HANDLERS}/formation-check.sh")"
    stop="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.Stop||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));console.log(s[0].timeout)' "${BATS_TEST_DIRNAME}/../../hooks/hooks.json")"
    [ -n "$window" ] && [ -n "$stop" ]
    echo "window ${window} s, Stop registration ${stop} s" >&3
    # Preparation (10) + the last request (25) + the renewal question (10, retried once after 3) +
    # one more retry (10) + margin: 120 s.
    (( stop - window >= 120 )) || { echo "only $(( stop - window )) s between the window and the registration"; return 1; }
    # And inside the ceiling measured on #31721: probes ran past an hour, so 3600 is a safe bound.
    (( stop <= 3600 ))
    # The lock's age rule is derived from the schedule, not the window.
    run grep -c '^_IDLE_LOCK_STALE=120$' "${HANDLERS}/formation-check.sh"
    [ "$output" -eq 1 ]
}

# =============================================================================================
# REQUIREMENT 5: the formation command page states the new listening behaviour
# =============================================================================================

@test "docs: the formation command page states the new listening behaviour and read status" {
    local doc="${BATS_TEST_DIRNAME}/../../commands/formation.md"
    # The old promise is gone.
    run grep -c "about four minutes" "$doc"
    [ "$output" -eq 0 ] || { echo "the page still says the watch lasts about four minutes"; return 1; }
    # The new behaviour, in the words a reader looks for.
    run grep -c "for as long as this session is in the formation" "$doc"
    [ "$output" -ge 1 ]
    run grep -ci "renew" "$doc"
    [ "$output" -ge 1 ]
    run grep -c "still listening" "$doc"
    [ "$output" -ge 1 ]
    # And how a sender finds out whether it was read.
    run grep -c "NOT READ YET" "$doc"
    [ "$output" -ge 1 ]
}
