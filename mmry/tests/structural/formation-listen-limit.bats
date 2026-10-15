#!/usr/bin/env bats
# A customer can limit or switch off continuous listening, the watch finishes inside its hook budget,
# and a poll lock whose pid has been reused is reclaimed (#31850).
#
# Continuous listening (#31721) renews the idle watch about every 28 minutes for as long as the
# session is in the formation. Each renewal is a model turn that carries the session's whole context
# (32028: about 30,000 tokens in a fresh session, 570,000 to 880,000 in a long one), so an idle member
# left overnight paid for it all night. These prove, against a stub service and a simulated clock:
#
#   requirement 1 / test case 1  with a limit set, listening stops after it; with listening off, no
#                                renewal occurs; the shipped default is pinned and behaves as stated
#   requirement 3 / test case 3  the worst-case watch duration stays inside the 1800 s registration
#                                with the documented 60 s margin, and a lock held by a reused pid is
#                                reclaimed once it is older than the backstop age
#
# Requirement 2 (the renewal turn) is formation-renewal-turn.bats; requirement 4 (the docs) is
# formation-listen-docs.bats.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-31850-$$"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_JQ MMRY_IDLE_POLL_SECONDS MMRY_IDLE_POLL_INTERVAL
    unset MMRY_FORMATION_LISTEN_MINUTES MMRY_CONFIG_FILE
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset_locks
    URLS="${BATS_TEST_TMPDIR}/urls.log"
    : > "$URLS"
    export PATH="$(_routing_curl_dir):${PATH}"
    export MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid"
    export FAKE_URL_LOG="$URLS"
    export FAKE_CLOCK="${BATS_TEST_TMPDIR}/clock"
    printf '%s' "$(command date +%s)" > "$FAKE_CLOCK"
    DIRECTED='[{"transmissionID":41,"senderRole":"lead","senderSessionID":null,"senderUserID":7,"recipientMemberID":5,"content":"LL-DIRECTED take the validator","sentDate":"2026-10-15T01:00:00"}]'
}

teardown() {
    [[ -n "${BG_PID:-}" ]] && kill "$BG_PID" 2>/dev/null || true
    [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null || true
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset_locks
}

_sid() { printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'; }

_reset_locks() {
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_sid)" "${TMPDIR}/.mmry-formation-poll-$(_sid)" \
           "${TMPDIR}/.mmry-formation-renewed-$(_sid)" "${TMPDIR}/.mmry-formation-handover-$(_sid)" \
           "${TMPDIR}/.mmry-renewal-turn-$(_sid)"
}

# A curl that routes, as formation-listening.bats's does, and that can also HANG: with FAKE_HANG=1
# every request takes its whole --max-time on the simulated clock before it answers, which is the
# slowest a request can ever be. The membership route then fails its first ask (000) and answers
# "member" on the retry, which is the slowest path that still renews.
_routing_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/route-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""; maxt=0
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "--max-time" ]] && maxt="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s\n' "$url" >> "$FAKE_URL_LOG"
_advance() {
    local now=0
    { IFS= read -r now || true; } < "$FAKE_CLOCK"
    printf '%s' "$(( now + maxt ))" > "$FAKE_CLOCK"
}
case "$url" in
    */transmissions/sent*)
        body="${FAKE_SENT_BODY:-}"; code="${FAKE_SENT_CODE:-200}"
        if [[ "${FAKE_HANG:-}" == "1" ]]; then
            _advance
            n=$(( $(cat "${FAKE_CLOCK}.sent" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "${FAKE_CLOCK}.sent"
            (( n % 2 == 1 )) && { printf '000'; exit 28; }
        fi ;;
    *)
        body="${FAKE_BODY:-[]}"; code="${FAKE_CODE:-200}"
        if [[ "${FAKE_HANG:-}" == "1" ]]; then _advance; printf '000'; exit 28; fi ;;
esac
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

_member_true='{"formationId":4242,"member":true,"messages":[]}'

_count_polls() { grep -c '/transmissions?' "$URLS" 2>/dev/null || true; }
_count_sent()  { grep -c '/transmissions/sent' "$URLS" 2>/dev/null || true; }
_now()         { local n=0; { IFS= read -r n || true; } < "$FAKE_CLOCK"; printf '%s' "$n"; }

# The simulated clock, as formation-listening.bats uses it: `date +%s` reads it and `sleep N`
# advances it, so a whole chain of 28-minute windows runs in seconds. FAKE_KILL_PID / FAKE_KILL_AT
# end a staged lock holder once the clock reaches that second, which is how a watch that stands down
# in the middle of a handover is staged.
_fake_sleep() {
    local n="${1%%.*}" now=0
    n="${n:-0}"
    { IFS= read -r now || true; } < "$FAKE_CLOCK"
    now=$(( now + n ))
    printf '%s' "$now" > "$FAKE_CLOCK"
    if [[ -n "${FAKE_KILL_PID:-}" && -n "${FAKE_KILL_AT:-}" ]] && (( now >= FAKE_KILL_AT )); then
        kill "$FAKE_KILL_PID" 2>/dev/null || true
    fi
}
_fake_date() {
    if [ "$*" = "+%s" ]; then
        local now=0
        { IFS= read -r now || true; } < "$FAKE_CLOCK"
        printf '%s\n' "$now"
        return 0
    fi
    command date "$@"
}

# One watch on the simulated clock. Leaves its exit status in $WATCH_RC and what it said in
# $WATCH_OUT. Extra environment for the watch comes as NAME=value arguments.
_watch() {
    local hdir="$1"; shift
    local out="${BATS_TEST_TMPDIR}/watch.out"
    WATCH_RC=0
    (
        eval "sleep() { _fake_sleep \"\$@\"; }"
        eval "date() { _fake_date \"\$@\"; }"
        export -f _fake_sleep _fake_date sleep date
        env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_FORMATION_MODE=idle "$@" \
            bash "${hdir}/formation-check.sh" </dev/null >"$out" 2>&1
    ) || WATCH_RC=$?
    WATCH_OUT="$(cat "$out")"
}

# A chain of watches, each started by the Stop that follows the previous renewal, with 5 simulated
# seconds for the renewal turn in between, until one stops without renewing or `max` have run.
# Sets CHAIN_RENEWALS, CHAIN_STOPPED (1 when a watch stopped quietly) and CHAIN_ELAPSED (simulated
# seconds from the first watch starting to the last one ending).
_chain() {
    local hdir="$1" max="$2"; shift 2
    local t0 i
    t0="$(_now)"
    CHAIN_RENEWALS=0; CHAIN_STOPPED=0
    for (( i = 1; i <= max; i++ )); do
        _watch "$hdir" MMRY_IDLE_POLL_INTERVAL=600 "$@"
        if [[ "$WATCH_RC" -eq 2 && "$WATCH_OUT" == *"WATCH RENEWED"* ]]; then
            CHAIN_RENEWALS=$(( CHAIN_RENEWALS + 1 ))
            CHAIN_ELAPSED=$(( $(_now) - t0 ))
            _fake_sleep 5
            continue
        fi
        CHAIN_ELAPSED=$(( $(_now) - t0 ))
        if [[ "$WATCH_RC" -eq 0 && -z "$WATCH_OUT" ]]; then CHAIN_STOPPED=1; fi
        break
    done
}

# =============================================================================================
# TEST CASE 1: the limit, off, and the default
# =============================================================================================

@test "default: the shipped default is ONE constant, 120 minutes of idle listening" {
    run grep -c '^MMRY_FORMATION_LISTEN_DEFAULT_MINUTES=120$' "${HANDLERS}/formation-check.sh"
    [ "$output" -eq 1 ] || { echo "the default is not the single constant 120: ${output}"; return 1; }
    # Nothing else in the handlers spells a listening default of its own.
    run grep -l 'MMRY_FORMATION_LISTEN_DEFAULT_MINUTES=' "${HANDLERS}"/*.sh
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] || { echo "defined in more than one place: ${output}"; return 1; }
}

@test "default: with no setting, listening renews 4 times and stops quietly at 2 hours" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$HANDLERS" 10
    echo "default: ${CHAIN_RENEWALS} renewals, stopped=${CHAIN_STOPPED}, ${CHAIN_ELAPSED} s listened" >&3
    [ "$CHAIN_RENEWALS" -eq 4 ] || { echo "expected 4 renewals in 2 hours, got ${CHAIN_RENEWALS}"; return 1; }
    [ "$CHAIN_STOPPED" -eq 1 ] || { echo "the last watch did not stop quietly: rc ${WATCH_RC} ${WATCH_OUT}"; return 1; }
    # Listened the whole 2 hours and not past it (4 renewal turns of 5 s are inside the chain).
    (( CHAIN_ELAPSED >= 7200 - 5 && CHAIN_ELAPSED <= 7200 + 10 )) || { echo "listened ${CHAIN_ELAPSED} s"; return 1; }
    # The service is asked about membership only for a renewal it will actually make.
    [ "$(_count_sent)" -eq 4 ] || { echo "membership asked $(_count_sent) times for 4 renewals"; return 1; }
    [ ! -d "${TMPDIR}/.mmry-formation-renewed-$(_sid)" ] || { echo "a stopped chain left a renewal marker"; return 1; }
}

@test "limit: with 60 minutes set, listening stops after 60 minutes (2 renewals), quietly" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$HANDLERS" 10 MMRY_FORMATION_LISTEN_MINUTES=60
    echo "60 min: ${CHAIN_RENEWALS} renewals, ${CHAIN_ELAPSED} s" >&3
    [ "$CHAIN_RENEWALS" -eq 2 ] || { echo "expected 2 renewals, got ${CHAIN_RENEWALS}"; return 1; }
    [ "$CHAIN_STOPPED" -eq 1 ] || return 1
    (( CHAIN_ELAPSED >= 3600 - 5 && CHAIN_ELAPSED <= 3600 + 10 )) || { echo "listened ${CHAIN_ELAPSED} s"; return 1; }
}

@test "limit: a limit shorter than one window listens for that long and never renews" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$HANDLERS" 10 MMRY_FORMATION_LISTEN_MINUTES=10
    [ "$CHAIN_RENEWALS" -eq 0 ] || return 1
    [ "$CHAIN_STOPPED" -eq 1 ] || return 1
    (( CHAIN_ELAPSED >= 595 && CHAIN_ELAPSED <= 610 )) || { echo "listened ${CHAIN_ELAPSED} s, not 600"; return 1; }
    [ "$(_count_sent)" -eq 0 ]
}

@test "limit: the setting is read from mmry-config.json (formationListenMinutes)" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/mmry-config.json"
    printf '{"apiUrl":"http://fake.invalid","authMethod":"apikey","apiKey":"fake-key","formationListenMinutes":30}\n' > "$MMRY_CONFIG_FILE"
    _chain "$HANDLERS" 10
    echo "config 30: ${CHAIN_RENEWALS} renewals, ${CHAIN_ELAPSED} s" >&3
    [ "$CHAIN_RENEWALS" -eq 1 ] || { echo "expected 1 renewal for 30 minutes, got ${CHAIN_RENEWALS}"; return 1; }
    [ "$CHAIN_STOPPED" -eq 1 ] || return 1
    # And "off" spelled in the config file is off.
    printf '{"apiUrl":"http://fake.invalid","authMethod":"apikey","apiKey":"fake-key","formationListenMinutes":"off"}\n' > "$MMRY_CONFIG_FILE"
    _reset_locks; : > "$URLS"
    _chain "$HANDLERS" 10
    [ "$CHAIN_RENEWALS" -eq 0 ] || { echo "\"off\" in the config file renewed"; return 1; }
}

@test "off: with listening off, no renewal occurs and the service is never asked to renew" {
    local v
    for v in off OFF 0; do
        bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
        _reset_locks; : > "$URLS"
        _chain "$HANDLERS" 10 MMRY_FORMATION_LISTEN_MINUTES="$v"
        [ "$CHAIN_RENEWALS" -eq 0 ] || { echo "'${v}' renewed ${CHAIN_RENEWALS} times"; return 1; }
        [ "$CHAIN_STOPPED" -eq 1 ] || { echo "'${v}': ${WATCH_RC} ${WATCH_OUT}"; return 1; }
        [ "$(_count_sent)" -eq 0 ] || { echo "'${v}' asked the service about renewing"; return 1; }
        # Off is no RENEWAL, not no listening: the one watch after the turn still ran its window.
        [ "$(_count_polls)" -ge 2 ] || { echo "'${v}' did not listen at all"; return 1; }
        [ ! -e "${TMPDIR}/.mmry-renewal-turn-$(_sid)" ] || return 1
    done
}

@test "off: a message that arrives while listening is off is still delivered by the watch" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _watch "$HANDLERS" MMRY_IDLE_POLL_INTERVAL=600 MMRY_FORMATION_LISTEN_MINUTES=off FAKE_BODY="$DIRECTED"
    [ "$WATCH_RC" -eq 2 ] || { echo "rc ${WATCH_RC}: ${WATCH_OUT}"; return 1; }
    [[ "$WATCH_OUT" == *"LL-DIRECTED"* ]] || return 1
}

@test "unlimited: 'unlimited' renews for as long as the service confirms membership" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$HANDLERS" 8 MMRY_FORMATION_LISTEN_MINUTES=unlimited
    [ "$CHAIN_RENEWALS" -eq 8 ] || { echo "unlimited stopped after ${CHAIN_RENEWALS} renewals"; return 1; }
}

@test "default: a setting that is not a number, off or unlimited falls back to the default" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$HANDLERS" 10 MMRY_FORMATION_LISTEN_MINUTES=forever
    [ "$CHAIN_RENEWALS" -eq 4 ] || { echo "'forever' gave ${CHAIN_RENEWALS} renewals, not the default 4"; return 1; }
}

@test "restart: after the limit, the member's next turn starts listening again" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$HANDLERS" 10 MMRY_FORMATION_LISTEN_MINUTES=30
    [ "$CHAIN_STOPPED" -eq 1 ]
    # Hours later the person types; the turn ends; its Stop starts a fresh watch with a fresh limit.
    _fake_sleep 7200
    run env FAKE_BODY='[]' MMRY_FORMATION_MODE=prompt bash "${HANDLERS}/formation-check.sh"
    _chain "$HANDLERS" 10 MMRY_FORMATION_LISTEN_MINUTES=30
    [ "$CHAIN_RENEWALS" -eq 1 ] || { echo "the next turn did not restart listening: ${CHAIN_RENEWALS}"; return 1; }
}

@test "control: the limit tests fail against a watch that ignores the setting" {
    # POSITIVE CONTROL. With the limit check removed the chain renews past 60 minutes.
    local mutant="${BATS_TEST_TMPDIR}/handlers-nolimit"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    perl -0777 -pi -e 's{\n[ ]+_fc_listen_setting\n}{\n        _listen_secs=-1\n}' "${mutant}/formation-check.sh"
    ! cmp -s "${mutant}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _chain "$mutant" 4 MMRY_FORMATION_LISTEN_MINUTES=60
    (( CHAIN_RENEWALS > 2 )) || { echo "the mutant also stopped at ${CHAIN_RENEWALS} renewals, so the test proves nothing"; return 1; }
}

# =============================================================================================
# TEST CASE 3: the worst case fits the budget with the documented margin
# =============================================================================================

_budget() {
    node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.Stop||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));console.log(s[0].timeout)' "${BATS_TEST_DIRNAME}/../../hooks/hooks.json"
}

# The slowest watch there can be: it starts by waiting for a previous watch that stands down at the
# last moment of the handover wait, every request it makes takes its whole time limit, and the
# renewal question fails once and is answered on the retry. Echoes the simulated seconds from the
# hook starting to the watch exiting, and its exit status.
_worst_case() {
    local hdir="$1" t0 dir="${TMPDIR}/.mmry-formation-poll-$(_sid)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks; : > "$URLS"; rm -f "${FAKE_CLOCK}.sent"
    printf '%s' "$(command date +%s)" > "$FAKE_CLOCK"
    t0="$(_now)"
    sleep 600 &
    HOLDER_PID=$!
    mkdir -p "$dir"; printf '%s\n' "$HOLDER_PID" > "${dir}/pid"
    _watch "$hdir" FAKE_HANG=1 FAKE_KILL_PID="$HOLDER_PID" FAKE_KILL_AT=$(( t0 + 39 )) \
        MMRY_FORMATION_LISTEN_MINUTES=unlimited
    printf '%s %s' "$(( $(_now) - t0 ))" "$WATCH_RC"
}

@test "budget: the worst-case watch ends inside the Stop registration with at least the documented 60 s to spare" {
    local budget reserve margin took rc
    budget="$(_budget)"
    [ "$budget" -eq 1800 ] || { echo "the Stop registration is ${budget}, not 1800"; return 1; }
    # The figures the handler documents, read from it rather than restated here.
    reserve="$(sed -n 's/^_IDLE_PREP_RESERVE=\([0-9]*\)$/\1/p' "${HANDLERS}/formation-check.sh")"
    margin="$(sed -n 's/^_IDLE_MARGIN=\([0-9]*\)$/\1/p' "${HANDLERS}/formation-check.sh")"
    [ "$reserve" = "4" ] && [ "$margin" = "60" ] || { echo "reserve '${reserve}' margin '${margin}'"; return 1; }
    run grep -c "^_IDLE_BUDGET=${budget}\$" "${HANDLERS}/formation-check.sh"
    [ "$output" -eq 1 ] || { echo "_IDLE_BUDGET does not match the registration"; return 1; }

    read -r took rc <<< "$(_worst_case "$HANDLERS")"
    echo "worst case: ${took} s from hook start to exit (rc ${rc}); + ${reserve} s before the shell starts = $(( took + reserve )) of ${budget}, leaving $(( budget - took - reserve )) s" >&3
    [ "$rc" -eq 2 ] || { echo "the staged worst case did not reach its renewal (rc ${rc}): ${WATCH_OUT}"; return 1; }
    # The handover wait really happened, or this is not the worst case.
    (( took >= 1680 )) || { echo "only ${took} s: the window did not run"; return 1; }
    (( took + reserve + margin <= budget )) || { echo "${took} + ${reserve} + ${margin} > ${budget}"; return 1; }
}

@test "control: anchoring the window after the handover, as before, breaks the budget" {
    # POSITIVE CONTROL. The watch used to start its 28 minutes after it had taken the lock, so a
    # handover wait of up to 40 s came on top of the window and the margin.
    local mutant="${BATS_TEST_TMPDIR}/handlers-late-start"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    perl -0777 -pi -e 's{_deadline=\$\(\( _hook_start \+ MMRY_IDLE_POLL_SECONDS \)\)}{_deadline=\$(( \$(date +%s) + MMRY_IDLE_POLL_SECONDS ))}' "${mutant}/formation-check.sh"
    ! cmp -s "${mutant}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    local took rc
    read -r took rc <<< "$(_worst_case "$mutant")"
    echo "anchored after the handover: ${took} s" >&3
    (( took + 4 + 60 > 1800 )) || { echo "the mutant took ${took} s and still fits, so the budget test proves nothing"; return 1; }
}

# =============================================================================================
# TEST CASE 3: a lock whose pid has been reused is reclaimed after the backstop age
# =============================================================================================

# A lock whose pid file is `age` seconds old and names a LIVE process that is not a watch - which is
# what a reused pid looks like from outside.
_reused_lock() {
    local age="$1" dir="${TMPDIR}/.mmry-formation-poll-$(_sid)" then
    mkdir -p "$dir"
    sleep 600 &
    HOLDER_PID=$!
    printf '%s\n' "$HOLDER_PID" > "${dir}/pid"
    then="$(( $(command date +%s) - age ))"
    touch -d "@${then}" "${dir}/pid" 2>/dev/null \
        || touch -t "$(command date -r "$then" +%Y%m%d%H%M.%S 2>/dev/null)" "${dir}/pid"
}

@test "lock: the backstop age is derived from the registration, not chosen" {
    run grep -c '^_IDLE_LOCK_BACKSTOP=\$(( _IDLE_BUDGET + 60 ))$' "${HANDLERS}/formation-check.sh"
    [ "$output" -eq 1 ]
}

@test "lock: a lock held by a reused pid is reclaimed once it is older than the backstop age" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reused_lock 1900
    _watch "$HANDLERS" FAKE_BODY="$DIRECTED" MMRY_IDLE_POLL_INTERVAL=1 MMRY_IDLE_POLL_SECONDS=4
    [ "$WATCH_RC" -eq 2 ] || { echo "a lock past the backstop silenced delivery: ${WATCH_RC} ${WATCH_OUT}"; return 1; }
    [[ "$WATCH_OUT" == *"LL-DIRECTED"* ]] || return 1
}

@test "lock: a lock held by a live pid younger than the backstop age is still respected" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reused_lock 1700
    _watch "$HANDLERS" FAKE_BODY="$DIRECTED" MMRY_IDLE_POLL_INTERVAL=1 MMRY_IDLE_POLL_SECONDS=4
    [ "$WATCH_RC" -eq 0 ] || { echo "a live holder inside the budget was overrun: ${WATCH_RC} ${WATCH_OUT}"; return 1; }
    [ -z "$WATCH_OUT" ]
    [ "$(_count_polls)" -eq 0 ]
}

@test "control: without the backstop, the reused-pid lock silences delivery for good" {
    local mutant="${BATS_TEST_TMPDIR}/handlers-nobackstop"
    rm -rf "$mutant"; mkdir -p "$mutant"; cp "${HANDLERS}"/*.sh "$mutant"/
    perl -0777 -pi -e 's{_lock_is_stale "\$\{dir\}/pid" "\$_IDLE_LOCK_BACKSTOP" \|\| return 1}{return 1}' "${mutant}/formation-check.sh"
    ! cmp -s "${mutant}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reused_lock 1900
    _watch "$mutant" FAKE_BODY="$DIRECTED" MMRY_IDLE_POLL_INTERVAL=1 MMRY_IDLE_POLL_SECONDS=4
    [ "$WATCH_RC" -ne 2 ] || { echo "the mutant reclaimed it too, so the test proves nothing"; return 1; }
}

@test "lock: a watch whose lock has been reclaimed stands down and leaves the new holder's lock alone" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local dir="${TMPDIR}/.mmry-formation-poll-$(_sid)" out="${BATS_TEST_TMPDIR}/bg.out" rc=0 waited=0
    env FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" </dev/null >"$out" 2>&1 &
    BG_PID=$!
    while [ "$(_count_polls)" -lt 1 ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$(( waited + 1 )); done
    [ "$(_count_polls)" -ge 1 ] || { echo "the watch never polled"; return 1; }
    # Another watch reclaims the lock (as the backstop allows) and writes its own pid.
    sleep 600 &
    HOLDER_PID=$!
    printf '%s\n' "$HOLDER_PID" > "${dir}/pid"
    wait "$BG_PID" || rc=$?
    BG_PID=""
    [ "$rc" -eq 0 ] || { echo "the displaced watch exited ${rc}: $(cat "$out")"; return 1; }
    [ ! -s "$out" ]
    [ -d "$dir" ] || { echo "the displaced watch removed the new holder's lock"; return 1; }
    [ "$(cat "${dir}/pid")" = "$HOLDER_PID" ]
}
