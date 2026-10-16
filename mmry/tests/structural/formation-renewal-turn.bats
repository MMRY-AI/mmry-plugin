#!/usr/bin/env bats
# A renewal turn triggers no save prompt and no extra service requests (#31850 requirement 2).
#
# WHAT A RENEWAL TURN IS, MEASURED on Claude Code 2.1.292 (docs/evidence/31850/README.md): the watch
# exits 2 with the renewal notice; Claude Code turns that into a new prompt, and UserPromptSubmit
# FIRES for it, with the notice inside the prompt text; the model replies "Still listening."; then
# Stop fires, running every Stop hook again, with stop_hook_active true.
#
# Before #31850 that turn cost, besides the model turn itself:
#   - the UserPromptSubmit formation check polled the service once, and removed the renewal marker,
#     so the next watch started at the fast end of its schedule instead of the slow end;
#   - the Stop save prompt fired (its 15-minute debounce is shorter than the 28-minute window), and
#     exit 2 made a SECOND model turn, asking the model to save memories from a turn that did nothing.
#
# These replay that sequence against the handlers with the payloads Claude Code sends, and count
# every request the stub service receives. A live run with the whole plugin installed is in
# docs/evidence/31850/README.md.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-31850-turn-$$"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_JQ MMRY_IDLE_POLL_SECONDS MMRY_IDLE_POLL_INTERVAL
    unset MMRY_FORMATION_LISTEN_MINUTES MMRY_CONFIG_FILE
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset
    URLS="${BATS_TEST_TMPDIR}/urls.log"
    : > "$URLS"
    export PATH="$(_curl_dir):${PATH}"
    export MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid"
    export FAKE_URL_LOG="$URLS"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset
}

_sid() { printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'; }

_reset() {
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_sid)" "${TMPDIR}/.mmry-formation-poll-$(_sid)" \
           "${TMPDIR}/.mmry-formation-renewed-$(_sid)" "${TMPDIR}/.mmry-formation-handover-$(_sid)" \
           "${TMPDIR}/.mmry-renewal-turn-$(_sid)"
    rm -f "${TMPDIR}/.mmry-stop-checked" "${TMPDIR}/.mmry-stop-count" "${TMPDIR}/.mmry-last-save"
}

_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s\n' "$url" >> "$FAKE_URL_LOG"
case "$url" in
    */transmissions/sent*) body='{"formationId":4242,"member":true,"messages":[]}' ;;
    *) body="${FAKE_BODY:-[]}" ;;
esac
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '200'
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

_requests() { grep -c . "$URLS" 2>/dev/null || true; }

# The payloads, in the shape Claude Code 2.1.292 sent them in the probe (only the fields that matter).
_ups_renewal() {
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\\n<summary>Stop hook feedback</summary>\\n</task-notification>\\n<system-reminder>\\nStop hook blocking error from command \\"Stop\\": MMRY FORMATION WATCH RENEWED (formation 4242). No message arrived in the last 28 minutes. This session is still a member, so MMRY is renewing the background watch that keeps it listening while idle. There is nothing to act on and nothing to report. Reply with exactly: Still listening.\\n\\n</system-reminder>"}' "$CLAUDE_SESSION_ID"
}
_ups_typed() {
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$CLAUDE_SESSION_ID" "$1"
}
_stop_payload() {
    printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s,"last_assistant_message":"%s"}' \
        "${2:-$CLAUDE_SESSION_ID}" "${3:-true}" "$1"
}

# A watch renews: the state a renewal turn starts from. An old save-prompt marker, so that without
# #31850 the save prompt is due on the next Stop.
_renew() {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    touch -t 202001010000.00 "${TMPDIR}/.mmry-stop-checked"
    run env MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ] && [[ "$output" == *"WATCH RENEWED"* ]] || { echo "setup: no renewal: ${status} ${output}"; return 1; }
    [ -f "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || { echo "setup: the renewal left no renewal-turn marker"; return 1; }
    : > "$URLS"
}

# The renewal turn's two hook events, through the handlers as Claude Code would run them. Sets
# UPS_RC/UPS_OUT and STOP_RC/STOP_OUT. $1: the handler directory.
_renewal_turn() {
    local hdir="$1" payload
    payload="${BATS_TEST_TMPDIR}/ups.json"; _ups_renewal > "$payload"
    UPS_RC=0; UPS_OUT="$(bash "${hdir}/formation-check.sh" < "$payload" 2>&1)" || UPS_RC=$?
    payload="${BATS_TEST_TMPDIR}/stop.json"; _stop_payload "Still listening." > "$payload"
    STOP_RC=0; STOP_OUT="$(bash "${hdir}/stop-check.sh" < "$payload" 2>&1)" || STOP_RC=$?
}

@test "renewal turn: no save prompt and no service request, measured" {
    _renew
    local count_before; count_before="$(cat "${TMPDIR}/.mmry-stop-count" 2>/dev/null || echo none)"
    _renewal_turn "$HANDLERS"
    echo "UserPromptSubmit rc ${UPS_RC}; Stop save check rc ${STOP_RC}; requests during the turn: $(_requests)" >&3
    [ "$UPS_RC" -eq 0 ] && [ -z "$UPS_OUT" ] || { echo "the prompt check said something: ${UPS_RC} ${UPS_OUT}"; return 1; }
    [ "$STOP_RC" -eq 0 ] || { echo "the save prompt fired on a renewal turn (rc ${STOP_RC}): ${STOP_OUT}"; return 1; }
    [ -z "$STOP_OUT" ] || { echo "the save check said: ${STOP_OUT}"; return 1; }
    [ "$(_requests)" -eq 0 ] || { echo "the renewal turn made requests: $(cat "$URLS")"; return 1; }
    # It is as if the turn never happened to the save prompt: its debounce and count are untouched.
    [ "$(_stop_marker_age)" -gt 900 ] || { echo "the renewal turn reset the save debounce"; return 1; }
    [ "$(cat "${TMPDIR}/.mmry-stop-count" 2>/dev/null || echo none)" = "$count_before" ] || return 1
    # The marker is spent, and the next watch is still told it follows a renewal.
    [ ! -e "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || { echo "the renewal-turn marker was not consumed"; return 1; }
    [ -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ] || { echo "the prompt check removed the renewal marker"; return 1; }
}

_stop_marker_age() {
    local m; m="$(stat -c %Y "${TMPDIR}/.mmry-stop-checked" 2>/dev/null || stat -f %m "${TMPDIR}/.mmry-stop-checked")"
    printf '%s' "$(( $(date +%s) - m ))"
}

@test "control: before #31850 the same turn prompted for a save and polled the service" {
    # POSITIVE CONTROL. The handlers as develop shipped them (git show) replay the same turn.
    local base="${BATS_TEST_TMPDIR}/handlers-develop"
    rm -rf "$base"; mkdir -p "$base"; cp "${HANDLERS}"/*.sh "$base"/
    git -C "${BATS_TEST_DIRNAME}" show 0d5d967:mmry/hooks-handlers/stop-check.sh > "${base}/stop-check.sh" 2>/dev/null \
        || skip "the develop baseline 0d5d967 is not in this clone"
    git -C "${BATS_TEST_DIRNAME}" show 0d5d967:mmry/hooks-handlers/formation-check.sh > "${base}/formation-check.sh"
    _renew
    _renewal_turn "$base"
    echo "develop: Stop save check rc ${STOP_RC}; requests: $(_requests)" >&3
    [ "$STOP_RC" -eq 2 ] || { echo "the baseline did not prompt, so the test above proves nothing"; return 1; }
    [ "$(_requests)" -ge 1 ] || { echo "the baseline made no request, so the count above proves nothing"; return 1; }
}

@test "typed prompt: a person typing after a renewal gets the ordinary save prompt back" {
    _renew
    local payload="${BATS_TEST_TMPDIR}/ups.json"
    _ups_typed "what is the status" > "$payload"
    run bash -c "bash '${HANDLERS}/formation-check.sh' < '$payload'"
    [ "$status" -eq 0 ]
    [ "$(_requests)" -eq 1 ] || { echo "a typed prompt should check for messages once: $(_requests)"; return 1; }
    [ ! -e "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || { echo "a typed prompt left the renewal-turn marker"; return 1; }
    [ ! -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ] || return 1
    _stop_payload "Here is the status." "" false > "${BATS_TEST_TMPDIR}/stop.json"
    run bash -c "bash '${HANDLERS}/stop-check.sh' < '${BATS_TEST_TMPDIR}/stop.json'"
    [ "$status" -eq 2 ] || { echo "the save prompt did not come back after a typed turn: ${status}"; return 1; }
    [[ "$output" == *"Save what is new since the last memory"* ]] || return 1
}

@test "delivered message: a turn woken by a real message is not mistaken for a renewal" {
    _renew
    run env FAKE_BODY='[{"transmissionID":9,"senderRole":"lead","senderSessionID":"x","senderUserID":7,"recipientMemberID":null,"content":"RT-REAL work arrived","sentDate":"2026-10-15T01:00:00"}]' \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 2 ] && [[ "$output" == *"RT-REAL"* ]] || { echo "${status} ${output}"; return 1; }
    [ ! -e "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || { echo "a delivered message left the renewal-turn marker"; return 1; }
    _stop_payload "Done." > "${BATS_TEST_TMPDIR}/stop.json"
    run bash -c "bash '${HANDLERS}/stop-check.sh' < '${BATS_TEST_TMPDIR}/stop.json'"
    [ "$status" -eq 2 ] || { echo "the save prompt was suppressed after real work: ${status}"; return 1; }
}

@test "scope: another session's renewal does not silence this session's save prompt" {
    _renew
    _stop_payload "Here is the change." "some-other-session" false > "${BATS_TEST_TMPDIR}/stop.json"
    run bash -c "bash '${HANDLERS}/stop-check.sh' < '${BATS_TEST_TMPDIR}/stop.json'"
    [ "$status" -eq 2 ] || { echo "another session's marker silenced this one: ${status}"; return 1; }
    [ -f "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || { echo "another session consumed this session's marker"; return 1; }
}

@test "scope: a renewal-turn marker older than 15 minutes is discarded, not obeyed" {
    _renew
    printf '%s\n' "$(( $(date +%s) - 1000 ))" > "${TMPDIR}/.mmry-renewal-turn-$(_sid)"
    _stop_payload "Still listening." > "${BATS_TEST_TMPDIR}/stop.json"
    run bash -c "bash '${HANDLERS}/stop-check.sh' < '${BATS_TEST_TMPDIR}/stop.json'"
    [ "$status" -eq 2 ] || { echo "a stale marker silenced the save prompt: ${status}"; return 1; }
    [ ! -e "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || { echo "the stale marker was left behind"; return 1; }
}

@test "cost: with no renewal pending, the save check never waits on its input" {
    # The common path must not pay for this. stdin held open and never written: the save check
    # still answers at once, because it reads the payload only when a renewal-turn marker exists.
    local ms
    ms="$(_stop_check_ms "$HANDLERS")"
    echo "save check with stdin held open: ${ms} ms" >&3
    # A read of the payload waits its whole 2 s timeout on a pipe nobody writes, so anything under
    # 2000 ms did not read it. Measured: about 250 ms on an idle Windows host.
    (( ms < 2000 )) || { echo "the save check waited ${ms} ms on stdin"; return 1; }
}

# Milliseconds for one save check whose stdin is held open and never written. A process substitution
# rather than a pipe, because a pipeline waits for `sleep` itself.
_stop_check_ms() {
    local t0 t1
    t0="$(date +%s%N)"
    bash "$1/stop-check.sh" < <(sleep 8 2>/dev/null) >/dev/null 2>&1 || true
    t1="$(date +%s%N)"
    printf '%s' "$(( (t1 - t0) / 1000000 ))"
}

@test "control: a save check that always reads its payload is caught by the cost test" {
    local mutant="${BATS_TEST_TMPDIR}/handlers-alwaysread"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    perl -0777 -pi -e 's{\[\[ -n "\$any" \]\] \|\| return 1}{true}' "${mutant}/stop-check.sh"
    ! cmp -s "${mutant}/stop-check.sh" "${HANDLERS}/stop-check.sh" || { echo "mutation did not apply"; return 1; }
    local ms; ms="$(_stop_check_ms "$mutant")"
    (( ms >= 2000 )) || { echo "the mutant took only ${ms} ms, so the cost test proves nothing"; return 1; }
}

@test "slow end: the watch after a renewal turn still starts at the slow end of its schedule" {
    # The prompt check used to clear the renewal marker on the renewal turn itself, so this never
    # held in a real session: the turn the renewal makes fires UserPromptSubmit.
    _renew
    _renewal_turn "$HANDLERS"
    [ -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ] || { echo "no renewal marker left for the next watch"; return 1; }
    run grep -c '_lock_is_stale "\$_renew_marker" 120 || _offset=\$_IDLE_LATE_UNTIL' "${HANDLERS}/formation-check.sh"
    [ "$output" -eq 1 ]
}
