#!/usr/bin/env bats
# An idle Claude Code member keeps listening after its session compacts itself (#33256).
#
# The defect (formation 73, 2026-10-30): a project manager sat idle for 53.7 hours and heard none of
# the lead's directed assignments. Its idle watch had stopped, Claude Code then compacted the idle
# session on its own, the formation step at that moment ran out of time and was cancelled, and
# nothing started listening again. No turn ended afterwards, so no Stop ever fired to start a watch,
# and nobody was told. Evidence: R:\Intranet\ClaudeAI\plans\MMRY\v1.32.1\v1.32.1-pm2-idle-gap-evidence.md.
#
# What these prove, at handler level, against a stub service:
#   test case 1  the after-compaction event (SessionStart with source "compact", registered with
#                matcher "compact" and asyncRewake) starts the watch again for a member with no live
#                watch, and a directed message is delivered within one listening interval; removing
#                the re-arm turns it red. "startup", "resume" and "clear" do not re-arm.
#
# NOT PostCompact (#33256 round 2). PostCompact arrived in Claude Code 2.1.76, and Claude Code 2.1.75
# rejects a plugin hooks file that names it: "Invalid key in record", "Registered 0 hooks", so every
# MMRY hook and the MCP server were off, silently (R:\Intranet\ClaudeAI\plans\MMRY\v1.36\
# idle-compaction\old-client-33256.md, cell B). SessionStart has fired with source "compact" after a
# compaction since long before that, and both 2.1.75 and 2.1.322 run an asyncRewake SessionStart hook
# in the background and wake the session on its exit 2, as they do for Stop.
#   test case 2  the after-compaction step killed at its time limit: the next end of turn starts the
#                watch again and a directed message after that is delivered; removing the end-of-turn
#                re-arm turns it red
#   test case 3  a watch that stopped before its set limit: the next turn is told that listening had
#                stopped and has resumed, and how to resume; a watch that reached its set limit says
#                nothing new (develop has no limit notice yet, that is 32243, so "the existing notice
#                only" is today's quiet stop, unchanged)
# The live idle compaction on Windows (test case 4) is not provable here; it is booked separately.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    HOOKS="${BATS_TEST_DIRNAME}/../../hooks"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-33256-$$"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_JQ MMRY_IDLE_POLL_SECONDS MMRY_IDLE_POLL_INTERVAL
    unset MMRY_FORMATION_LISTEN_MINUTES MMRY_CONFIG_FILE MMRY_FORMATION_MODE FAKE_CLOCK
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset_locks
    URLS="${BATS_TEST_TMPDIR}/urls.log"
    : > "$URLS"
    export PATH="$(_routing_curl_dir):${PATH}"
    export MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid"
    export FAKE_URL_LOG="$URLS"
    export KT_DIR="${BATS_TEST_TMPDIR}/kt"
    mkdir -p "$KT_DIR"
    DIRECTED='[{"transmissionID":61,"senderRole":"lead","senderSessionID":null,"senderUserID":7,"recipientMemberID":5,"content":"CR-DIRECTED take the validator","sentDate":"2026-11-18T01:00:00"}]'
    BG_PID=""; LIVE_PID=""
}

teardown() {
    # Release any stalled stub first, then stop only the processes this test started.
    : > "${KT_DIR}/release" 2>/dev/null || true
    [[ -n "${BG_PID:-}" ]] && { kill "$BG_PID" 2>/dev/null || true; wait "$BG_PID" 2>/dev/null || true; }
    [[ -n "${LIVE_PID:-}" ]] && { kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true; }
    if [[ -f "${KT_DIR}/stalled" ]]; then
        local p=""; p="$(cat "${KT_DIR}/stalled" 2>/dev/null || true)"
        [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null || true
    fi
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    _reset_locks
}

_sid() { printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'; }

_reset_locks() {
    local s; s="$(_sid)"
    rm -rf "${TMPDIR:?}/.mmry-formation-cs-${s}" "${TMPDIR:?}/.mmry-formation-poll-${s}" \
           "${TMPDIR:?}/.mmry-formation-renewed-${s}" "${TMPDIR:?}/.mmry-formation-handover-${s}"
    rm -f "${TMPDIR:?}/.mmry-renewal-turn-${s}" "${TMPDIR:?}/.mmry-listen-${s}" "${TMPDIR:?}/.mmry-listen-notice-${s}"
}

# A curl that routes as formation-listening.bats's does: the membership route answers with
# FAKE_SENT_*, everything else with FAKE_*, or from numbered files in FAKE_SEQ_DIR, one per request.
# With KT_STALL=1 a request stalls (it writes its pid and waits for a release file), which is how a
# step that runs out of time is staged: the test then kills the handler outright, as Claude Code does.
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
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s%s\n' "${FAKE_TAG:+${FAKE_TAG} }" "$url" >> "$FAKE_URL_LOG"
if [[ "${KT_STALL:-}" == "1" ]]; then
    printf '%s\n' "$$" > "${KT_DIR}/stalled"
    w=0; while [[ ! -f "${KT_DIR}/release" && $w -lt 600 ]]; do sleep 0.1; w=$((w + 1)); done
    printf '000'; exit 28
fi
case "$url" in
    */transmissions/sent*)
        body="${FAKE_SENT_BODY:-}"; code="${FAKE_SENT_CODE:-200}" ;;
    *)
        body="${FAKE_BODY:-[]}"; code="${FAKE_CODE:-200}"
        if [[ -n "${FAKE_SEQ_DIR:-}" ]]; then
            n=$(( $(cat "${FAKE_SEQ_DIR}/n" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "${FAKE_SEQ_DIR}/n"
            [[ -f "${FAKE_SEQ_DIR}/${n}.body" ]] && body="$(cat "${FAKE_SEQ_DIR}/${n}.body")"
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

_count_polls() { grep -c '/transmissions?' "$URLS" 2>/dev/null || true; }
_count_sent()  { grep -c '/transmissions/sent' "$URLS" 2>/dev/null || true; }

# A hook payload as Claude Code sends it, for this session.
_payload() {
    printf '{"session_id":"%s","hook_event_name":"%s"%s}' "$CLAUDE_SESSION_ID" "$1" "${2:-}"
}

# Fire one event at a handler directory the way the registration does: the payload on stdin.
# Usage: _fire DIR EVENT EXTRA_JSON [NAME=value ...]
_fire() {
    local hdir="$1" ev="$2" extra="$3"; shift 3
    _payload "$ev" "$extra" | env "$@" bash "${hdir}/formation-check.sh"
}

# The simulated clock (formation-listen-limit.bats): `date +%s` reads FAKE_CLOCK and `sleep N`
# advances it. Used only where a test has to place a later turn minutes after a watch ended.
_fake_sleep() {
    local n="${1%%.*}" now=0
    n="${n:-0}"
    { IFS= read -r now || true; } < "$FAKE_CLOCK"
    printf '%s' "$(( now + n ))" > "$FAKE_CLOCK"
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
# Run the handler on the simulated clock. Leaves $FC_RC and $FC_OUT (stdout and stderr together).
_on_clock() {
    local hdir="$1"; shift
    local out="${BATS_TEST_TMPDIR}/clock.out"
    FC_RC=0
    (
        eval "sleep() { _fake_sleep \"\$@\"; }"
        eval "date() { _fake_date \"\$@\"; }"
        export -f _fake_sleep _fake_date sleep date
        env "$@" bash "${hdir}/formation-check.sh" </dev/null >"$out" 2>&1
    ) || FC_RC=$?
    FC_OUT="$(cat "$out")"
}
_clock_start() { export FAKE_CLOCK="${BATS_TEST_TMPDIR}/clock"; printf '%s' "$(command date +%s)" > "$FAKE_CLOCK"; }
_clock_advance() { local n=0; { IFS= read -r n || true; } < "$FAKE_CLOCK"; printf '%s' "$(( n + $1 ))" > "$FAKE_CLOCK"; }

# A copy of the handlers to mutate for a positive control.
_mutant() {
    local m="${BATS_TEST_TMPDIR}/handlers-$1"
    rm -rf "${m:?}"; mkdir -p "$m"; cp "${HANDLERS}"/*.sh "$m"/
    printf '%s' "$m"
}

# Start a watch in the background on the real clock and wait until it has asked once.
# Usage: _bg_watch DIR EVENT[:SOURCE] [NAME=value ...]; leaves BG_PID. SessionStart:compact sends
# the payload a compaction does.
_bg_watch() {
    local hdir="$1" ev="$2" extra=""; shift 2
    local waited=0
    if [[ "$ev" == *:* ]]; then extra=",\"source\":\"${ev#*:}\""; ev="${ev%%:*}"; fi
    : > "$URLS"
    _payload "$ev" "$extra" | env "$@" bash "${hdir}/formation-check.sh" >"${BATS_TEST_TMPDIR}/bg.out" 2>&1 &
    BG_PID=$!
    while [ "$(_count_polls)" -lt 1 ] && [ ! -f "${KT_DIR}/stalled" ] && [ "$waited" -lt 300 ]; do
        sleep 0.1; waited=$(( waited + 1 ))
    done
    [ "$(_count_polls)" -ge 1 ] || [ -f "${KT_DIR}/stalled" ] || { echo "the background watch never asked"; return 1; }
}

# Kill the background watch outright, as Claude Code does at a hook's time limit: no trap runs.
_kill_bg() {
    kill -9 "$BG_PID" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
    : > "${KT_DIR}/release"
    BG_PID=""
}

_notice_header='MMRY FORMATION LISTENING HAD STOPPED (formation 4242)'

# =============================================================================================
# TEST CASE 1: the after-compaction event starts the watch again
# =============================================================================================

@test "TC1 wired: formation-check is registered on SessionStart with matcher compact, asyncRewake, the Stop budget and the same gate" {
    run node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const fc = h => h.type === "command" && typeof h.command === "string" && h.command.includes("formation-check");
        const st = (d.hooks.Stop || []).flatMap(g => g.hooks).filter(fc);
        const cg = (d.hooks.SessionStart || []).filter(g => g.matcher === "compact");
        const rc = cg.flatMap(g => g.hooks).filter(fc);
        if (rc.length !== 1) { console.log("SessionStart \"compact\": expected 1 formation-check registration, got " + rc.length); process.exit(1); }
        if (rc[0].asyncRewake !== true) { console.log("SessionStart compact: asyncRewake not set"); process.exit(1); }
        if (rc[0].timeout !== st[0].timeout) { console.log("SessionStart compact timeout " + rc[0].timeout + " is not the Stop budget " + st[0].timeout); process.exit(1); }
        if (rc[0].rewakeSummary !== st[0].rewakeSummary) { console.log("SessionStart compact rewakeSummary differs from Stop"); process.exit(1); }
        if (rc[0].command !== st[0].command) { console.log("SessionStart compact gate differs from Stop"); process.exit(1); }
        console.log("ok");
    ' "${HOOKS}/hooks.json"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # The handler's budget is the registration's (formation-listen-limit.bats pins it for Stop).
    grep -q '^_IDLE_BUDGET=1800$' "${HANDLERS}/formation-check.sh"
}

@test "TC1 wired: one compaction runs formation-check once, through the re-arm; every other source runs only the sweep" {
    # Two SessionStart registrations carry the same gate, and the handler cannot tell which one ran
    # it. So the matchers must never overlap: a compaction that ran both would start the watch in the
    # 15 s sweep too, which Claude Code cancels, leaving the asyncRewake watch to find a live lock.
    # The matching is Claude Code's own: no matcher, "" or "*" matches every source, and a matcher of
    # letters, digits, _ and | is a list of exact names (2.1.75 cli.js wYz; 2.1.322 the same rule).
    run node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const fc = h => h.type === "command" && typeof h.command === "string" && h.command.includes("formation-check");
        const matches = (m, q) => {
            if (!m || m === "*") return true;
            if (/^[a-zA-Z0-9_|]+$/.test(m)) return m.split("|").map(s => s.trim()).includes(q);
            return new RegExp(m).test(q);
        };
        const run = q => (d.hooks.SessionStart || []).filter(g => matches(g.matcher, q)).flatMap(g => g.hooks).filter(fc);
        let bad = 0;
        for (const q of ["startup", "resume", "clear", "fork", "compact"]) {
            const r = run(q);
            const kind = r.map(h => h.asyncRewake === true ? "re-arm" : "sweep").join(",");
            console.log(q + ": " + (kind || "none"));
            if (r.length !== 1) { console.log("  expected exactly one formation-check, got " + r.length); bad++; continue; }
            if (q === "compact" && r[0].asyncRewake !== true) { console.log("  a compaction runs the synchronous sweep, not the re-arm"); bad++; }
            if (q !== "compact" && (r[0].asyncRewake === true || r[0].async === true)) { console.log("  " + q + " runs the re-arm"); bad++; }
        }
        process.exit(bad ? 1 : 0);
    ' "${HOOKS}/hooks.json"
    echo "$output" >&3
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "hooks.json names no PostCompact, and every event in it is one Claude Code 2.1.75 accepts" {
    # Claude Code 2.1.75 drops a plugin's WHOLE hooks file when one event name is unknown to it, and
    # says so only in /plugin and the debug log. Every MMRY hook and the MCP server are then off.
    # The list is 2.1.75's own, verbatim, from the error it printed for PostCompact (Seat D's cell B,
    # R:\Intranet\ClaudeAI\plans\MMRY\v1.36\idle-compaction\old-client-33256.md, 2026-11-19), which
    # is the hook event enum in its cli.js. A new event needs a client floor and a decision first.
    local accepted=" PreToolUse PostToolUse PostToolUseFailure Notification UserPromptSubmit SessionStart SessionEnd Stop SubagentStart SubagentStop PreCompact PermissionRequest Setup TeammateIdle TaskCompleted Elicitation ElicitationResult ConfigChange WorktreeCreate WorktreeRemove InstructionsLoaded "
    local events e
    events="$(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks).join(" "))' "${HOOKS}/hooks.json")"
    echo "events: ${events}" >&3
    [[ -n "$events" ]] || { echo "no events read"; return 1; }
    for e in $events; do
        [[ "$e" != "PostCompact" ]] || { echo "hooks.json registers PostCompact, which 2.1.75 rejects with the whole file"; return 1; }
        [[ "$accepted" == *" $e "* ]] || { echo "${e} is not an event Claude Code 2.1.75 accepts"; return 1; }
    done
}

@test "TC1: after compaction a member with no live watch listens again, and a directed message is delivered within one interval" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local seq="${BATS_TEST_TMPDIR}/seq"; mkdir -p "$seq"
    printf '[]' > "${seq}/1.body"
    printf '%s' "$DIRECTED" > "${seq}/2.body"
    run _fire "$HANDLERS" SessionStart ',"source":"compact","model":"x"' \
        FAKE_SEQ_DIR="$seq" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=30 MMRY_IDLE_POLL_INTERVAL=1
    echo "exit ${status}, polls $(_count_polls)" >&3
    [ "$status" -eq 2 ] || { echo "after compaction nothing woke the session (exit ${status}): ${output}"; return 1; }
    [[ "$output" == *"CR-DIRECTED take the validator"* ]] || { echo "the directed message was not delivered: ${output}"; return 1; }
    [[ "$output" == *"DIRECTED TO YOU"* ]] || return 1
    # Within one listening interval: the message was there from the second ask, and the second ask
    # delivered it. A re-arm that waited a window, or asked once and stopped, would show otherwise.
    [ "$(_count_polls)" -eq 2 ] || { echo "asked $(_count_polls) times"; return 1; }
    [[ "$output" != *"WATCH RENEWED"* ]] || return 1
    [ ! -d "${TMPDIR}/.mmry-formation-poll-$(_sid)" ] || { echo "the re-armed watch left its lock behind"; return 1; }
}

@test "TC1 control: with the after-compaction re-arm removed, the same message is not delivered" {
    local m; m="$(_mutant norearm)"
    perl -0777 -pi -e 's{^[^\n]*"\$hook_source" == "compact" \]\] && mode="rearm"[^\n]*\n}{}m' "${m}/formation-check.sh"
    ! cmp -s "${m}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local seq="${BATS_TEST_TMPDIR}/seq"; mkdir -p "$seq"
    printf '[]' > "${seq}/1.body"
    printf '%s' "$DIRECTED" > "${seq}/2.body"
    run _fire "$m" SessionStart ',"source":"compact"' \
        FAKE_SEQ_DIR="$seq" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=30 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -ne 2 ] || { echo "the mutant delivered too, so the test proves nothing: ${output}"; return 1; }
    [[ "$output" != *"CR-DIRECTED"* ]] || return 1
}

@test "TC1: after compaction, messages already waiting are delivered with a wake, never swept silently into context" {
    # A sweep at SessionStart puts messages into context WITHOUT waking an idle session, and marks
    # them seen. After a compaction the session may be idle, so SessionStart "compact" is the watch:
    # what is waiting goes out on stderr with exit 2, which asyncRewake turns into a wake.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run _fire "$HANDLERS" SessionStart ',"source":"compact"' FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=10 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -eq 2 ] || { echo "a compaction did not wake the session with what was waiting: ${status} ${output}"; return 1; }
    [[ "$output" == *"CR-DIRECTED"* ]] || return 1
    [[ ! "$output" =~ \"hookEventName\":[[:space:]]*\"SessionStart\" ]] || { echo "a compaction swept the messages into context: ${output}"; return 1; }
}

@test "TC1: a SessionStart that is not a compaction still sweeps, as before" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run _fire "$HANDLERS" SessionStart ',"source":"resume"' FAKE_BODY="$DIRECTED"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"hookEventName\":[[:space:]]*\"SessionStart\" ]] || { echo "the resume sweep changed: ${output}"; return 1; }
    [[ "$output" == *"CR-DIRECTED"* ]] || return 1
}

# Fire SessionStart with one source at a member with no live watch. A message arrives on the second
# ask, which only a listening watch makes. Leaves $status, $output and the ask count in $polls.
_no_rearm_case() {
    local hdir="$1" src="$2" seq="${BATS_TEST_TMPDIR}/seq-$2"
    _reset_locks
    rm -rf "${seq:?}"; mkdir -p "$seq"
    printf '[]' > "${seq}/1.body"
    printf '%s' "$DIRECTED" > "${seq}/2.body"
    : > "$URLS"
    run _fire "$hdir" SessionStart ",\"source\":\"${src}\"" FAKE_SEQ_DIR="$seq" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=4 MMRY_IDLE_POLL_INTERVAL=1
    polls="$(_count_polls)"
}

@test "TC1: startup, resume and clear do not re-arm: one ask, the sweep's, and no watch" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local src polls
    for src in startup resume clear; do
        _no_rearm_case "$HANDLERS" "$src"
        echo "${src}: exit ${status}, asks ${polls}" >&3
        [ "$status" -eq 0 ] || { echo "${src} woke the session (exit ${status}): ${output}"; return 1; }
        [ "$polls" -eq 1 ] || { echo "${src} asked ${polls} times; a sweep asks once"; return 1; }
        [[ "$output" != *"CR-DIRECTED"* ]] || { echo "${src} listened and delivered: ${output}"; return 1; }
        [ ! -d "${TMPDIR}/.mmry-formation-poll-$(_sid)" ] || { echo "${src} took the watch's lock"; return 1; }
    done
}

@test "TC1 control: a handler that re-arms on every SessionStart turns the no-re-arm test red" {
    local m; m="$(_mutant everyss)"
    perl -0777 -pi -e 's{\[\[ "\$hook_event" == "SessionStart" && "\$hook_source" == "compact" \]\] && mode="rearm"}{[[ "\$hook_event" == "SessionStart" ]] && mode="rearm"}' "${m}/formation-check.sh"
    ! cmp -s "${m}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local polls
    _no_rearm_case "$m" resume
    [ "$status" -eq 2 ] || { echo "the mutant did not re-arm on resume, so the test proves nothing: ${status} ${output}"; return 1; }
    [ "$polls" -ge 2 ] || return 1
}

@test "TC1: the re-arm leaves a live watch alone: one watcher, no request" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _bg_watch "$HANDLERS" Stop FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=120 MMRY_IDLE_POLL_INTERVAL=1
    : > "$URLS"
    run _fire "$HANDLERS" SessionStart ',"source":"compact"' FAKE_TAG=R FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=10 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -eq 0 ] || { echo "the re-arm acted beside a live watch: ${status} ${output}"; return 1; }
    [ -z "$output" ]
    run grep -c '^R ' "$URLS"
    [ "$output" -eq 0 ] || { echo "the re-arm asked the service beside a live watch"; return 1; }
    kill -0 "$BG_PID" 2>/dev/null || { echo "the live watch was stood down"; return 1; }
}

@test "TC1: a watch that reached its set limit is not restarted by a compaction" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # Listening limited to 1 minute: the watch listens 60 s and stops quietly at its limit.
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_FORMATION_LISTEN_MINUTES=1
    [ "$FC_RC" -eq 0 ] || { echo "the limited watch did not stop quietly: ${FC_RC} ${FC_OUT}"; return 1; }
    _clock_advance 600
    : > "$URLS"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=rearm FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" MMRY_FORMATION_LISTEN_MINUTES=1
    [ "$FC_RC" -eq 0 ] || { echo "a compaction restarted listening past its limit: ${FC_RC} ${FC_OUT}"; return 1; }
    [ "$(_count_polls)" -eq 0 ] || { echo "it asked the service past the limit"; return 1; }
}

@test "TC1: the re-armed watch counts the listening limit from the member's last turn, not from the compaction" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # A 30-minute limit. The member's last turn starts a watch that is killed 5 minutes in (the
    # compaction); the compaction comes 40 minutes after that turn, past the limit.
    _bg_watch "$HANDLERS" Stop FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_FORMATION_LISTEN_MINUTES=30 \
        MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=1
    _kill_bg
    _clock_advance 2400
    : > "$URLS"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=rearm FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" MMRY_FORMATION_LISTEN_MINUTES=30
    [ "$FC_RC" -eq 0 ] || { echo "the compaction began a fresh limit: ${FC_RC} ${FC_OUT}"; return 1; }
    [ "$(_count_polls)" -eq 0 ] || return 1
}

@test "TC1: with listening off, a compaction after the one window does not open another" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # Off: one window after the member's turn. Here the window is killed 5 s in (the compaction).
    _bg_watch "$HANDLERS" Stop FAKE_BODY='[]' MMRY_FORMATION_LISTEN_MINUTES=off MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=1
    _kill_bg
    # A compaction inside that window finishes it ...
    _clock_advance 60
    : > "$URLS"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=rearm FAKE_BODY="$DIRECTED" MMRY_FORMATION_LISTEN_MINUTES=off MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=5
    [ "$FC_RC" -eq 2 ] || { echo "a compaction inside the off window did not listen: ${FC_RC} ${FC_OUT}"; return 1; }
    [[ "$FC_OUT" == *"CR-DIRECTED"* ]] || return 1
    # ... and one after it does not open another.
    _bg_watch "$HANDLERS" Stop FAKE_BODY='[]' MMRY_FORMATION_LISTEN_MINUTES=off MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=1
    _kill_bg
    _clock_start; _clock_advance 900
    : > "$URLS"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=rearm FAKE_BODY="$DIRECTED" MMRY_FORMATION_LISTEN_MINUTES=off MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=5
    [ "$FC_RC" -eq 0 ] || { echo "a compaction opened a second window with listening off: ${FC_RC} ${FC_OUT}"; return 1; }
    [ "$(_count_polls)" -eq 0 ]
}

@test "TC1: an after-compaction event that names a dispatched agent does nothing (#31991)" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    run _fire "$HANDLERS" SessionStart ',"source":"compact","agent_id":"a1b2","agent_type":"general-purpose"' \
        FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=4 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(_count_polls)" -eq 0 ]
}

@test "TC1: a session in no formation pays one file test and nothing else after a compaction" {
    run _fire "$HANDLERS" SessionStart ',"source":"compact"' FAKE_BODY="$DIRECTED" MMRY_IDLE_POLL_SECONDS=4 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(_count_polls)" -eq 0 ]
}

# =============================================================================================
# TEST CASE 2: the after-compaction step runs out of time; the next end of turn starts listening
# =============================================================================================

@test "TC2: the after-compaction step killed at its limit, then the next end of turn starts the watch and delivers" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # The after-compaction watch stalls on its first request and is killed outright, as a hook that
    # reaches its time limit is: no trap runs, so its lock and its listening record stay behind.
    _bg_watch "$HANDLERS" SessionStart:compact KT_STALL=1 FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=1
    _kill_bg
    [ -d "${TMPDIR}/.mmry-formation-poll-$(_sid)" ] || { echo "the killed step left no lock, so this stages nothing"; return 1; }
    # The member's next turn ends. A directed message is sent after that.
    local seq="${BATS_TEST_TMPDIR}/seq"; mkdir -p "$seq"
    printf '[]' > "${seq}/1.body"
    printf '%s' "$DIRECTED" > "${seq}/2.body"
    : > "$URLS"
    run _fire "$HANDLERS" Stop '' FAKE_SEQ_DIR="$seq" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=30 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -eq 2 ] || { echo "the end of turn did not start the watch again: ${status} ${output}"; return 1; }
    [[ "$output" == *"CR-DIRECTED take the validator"* ]] || return 1
}

@test "TC2: a SessionStart sweep killed mid-request (the step cancelled in the evidence) does not stop the next end of turn" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _payload SessionStart ',"source":"resume"' | env KT_STALL=1 bash "${HANDLERS}/formation-check.sh" >/dev/null 2>&1 &
    BG_PID=$!
    local waited=0
    while [ ! -f "${KT_DIR}/stalled" ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$(( waited + 1 )); done
    [ -f "${KT_DIR}/stalled" ] || { echo "the sweep never asked"; return 1; }
    _kill_bg
    [ -d "${TMPDIR}/.mmry-formation-cs-$(_sid)" ] || { echo "the killed sweep left no delivery lock, so this stages nothing"; return 1; }
    run _fire "$HANDLERS" Stop '' FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" \
        MMRY_IDLE_POLL_SECONDS=10 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -eq 2 ] || { echo "the killed sweep's lock silenced the end of turn: ${status} ${output}"; return 1; }
    [[ "$output" == *"CR-DIRECTED"* ]] || return 1
}

@test "TC2 control: without the end-of-turn re-arm of a dead step's lock, the member stays deaf" {
    local m; m="$(_mutant noreclaim)"
    perl -0777 -pi -e 's{(_acquire_poller\(\) \{.*?if \[\[ "\$pid" =~ \^\[0-9\]\+\$ && "\$pid" != "\$\$" \]\]; then\n)}{$1        kill -0 "\$pid" 2>/dev/null || return 1\n}s' "${m}/formation-check.sh"
    ! cmp -s "${m}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _bg_watch "$m" SessionStart:compact KT_STALL=1 FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=1
    _kill_bg
    run _fire "$m" Stop '' FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=10 MMRY_IDLE_POLL_INTERVAL=1
    [ "$status" -ne 2 ] || { echo "the mutant delivered too, so the test proves nothing: ${output}"; return 1; }
}

# =============================================================================================
# TEST CASE 3: a member whose listening stopped early is told on its next turn
# =============================================================================================

@test "TC3: a watch that stopped before its limit (renewal not confirmed): the next turn is told it stopped and has resumed" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # The window ends and the service cannot confirm membership (a server fault, twice): the watch
    # stops quietly, long before the 24-hour default limit.
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_CODE=500 MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    [ "$FC_RC" -eq 0 ] || { echo "the watch did not stop quietly: ${FC_RC} ${FC_OUT}"; return 1; }
    [ -z "$FC_OUT" ]
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ "$FC_RC" -eq 0 ]
    [[ "$FC_OUT" =~ \"hookEventName\":[[:space:]]*\"UserPromptSubmit\" ]] || { echo "the next turn was told nothing: ${FC_OUT}"; return 1; }
    [[ "$FC_OUT" == *"$_notice_header"* ]] || { echo "no stopped notice: ${FC_OUT}"; return 1; }
    [[ "$FC_OUT" == *"has resumed"* ]] || return 1
    # How to resume, and where to look.
    [[ "$FC_OUT" == *"end your turn"* ]] || { echo "the notice does not say how to resume: ${FC_OUT}"; return 1; }
    [[ "$FC_OUT" == *"/mmry:formation status"* ]] || return 1
    [[ "$FC_OUT" == *"about 30 minutes ago"* ]] || { echo "the notice does not say when it stopped: ${FC_OUT}"; return 1; }
}

@test "TC3: a watch killed outright before its limit: the next turn is told it stopped and has resumed" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _bg_watch "$HANDLERS" Stop FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=600 MMRY_IDLE_POLL_INTERVAL=1
    _kill_bg
    _clock_start
    _clock_advance 900
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ "$FC_RC" -eq 0 ]
    [[ "$FC_OUT" == *"$_notice_header"* ]] || { echo "no stopped notice after a killed watch: ${FC_OUT}"; return 1; }
}

@test "TC3: the notice rides with the messages when there are some, after the ordinary block" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_CODE=500 MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY="$DIRECTED"
    [[ "$FC_OUT" == *"CR-DIRECTED"* ]] || { echo "the messages were lost: ${FC_OUT}"; return 1; }
    [[ "$FC_OUT" == *"$_notice_header"* ]] || return 1
    [[ "$FC_OUT" == *"They may be stale; check before acting."* ]] || { echo "the ordinary preamble changed: ${FC_OUT}"; return 1; }
}

@test "TC3: the notice is shown once, not on every turn after" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_CODE=500 MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [[ "$FC_OUT" == *"$_notice_header"* ]] || return 1
    _clock_advance 30
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ "$FC_RC" -eq 0 ]
    [ -z "$FC_OUT" ] || { echo "the notice was repeated: ${FC_OUT}"; return 1; }
}

@test "TC3: a watch that reached its set limit says nothing new on the next turn (the quiet stop is unchanged)" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_FORMATION_LISTEN_MINUTES=1
    [ "$FC_RC" -eq 0 ] || { echo "the limited watch did not stop quietly: ${FC_RC} ${FC_OUT}"; return 1; }
    [ -z "$FC_OUT" ] || { echo "the limit stop said something: ${FC_OUT}"; return 1; }
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ "$FC_RC" -eq 0 ]
    [ -z "$FC_OUT" ] || { echo "a watch that reached its limit produced a notice: ${FC_OUT}"; return 1; }
}

@test "TC3: with listening off, the one watch after a turn ending at its window is not an early stop" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' MMRY_FORMATION_LISTEN_MINUTES=off MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    [ "$FC_RC" -eq 0 ]
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ -z "$FC_OUT" ] || { echo "listening off produced a notice: ${FC_OUT}"; return 1; }
}

@test "TC3: no notice while a watch is listening, or after one that renewed or delivered" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # A live watch: a person types while it listens.
    _bg_watch "$HANDLERS" Stop FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=120 MMRY_IDLE_POLL_INTERVAL=1
    run env MMRY_FORMATION_MODE=prompt FAKE_BODY='[]' bash "${HANDLERS}/formation-check.sh" </dev/null
    [ -z "$output" ] || { echo "a notice while a watch was listening: ${output}"; return 1; }
    kill "$BG_PID" 2>/dev/null || true; wait "$BG_PID" 2>/dev/null || true; BG_PID=""
    _reset_locks
    # A watch that renewed: the renewal turn and the turn after it are ordinary.
    run env MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" </dev/null
    [ "$status" -eq 2 ]
    _clock_start; _clock_advance 900
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ -z "$FC_OUT" ] || { echo "a notice after a renewal: ${FC_OUT}"; return 1; }
    # A watch that delivered a message.
    run env MMRY_FORMATION_MODE=idle FAKE_BODY="$DIRECTED" MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" </dev/null
    [ "$status" -eq 2 ]
    _clock_advance 900
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ -z "$FC_OUT" ] || { echo "a notice after a delivery: ${FC_OUT}"; return 1; }
}

@test "TC3: after an early stop and a compaction, the re-armed watch's delivery carries the notice, and the next turn does not repeat it" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_CODE=500 MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=rearm FAKE_BODY="$DIRECTED" FAKE_SENT_BODY="$_member_true" MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    [ "$FC_RC" -eq 2 ] || { echo "the re-armed watch did not deliver: ${FC_RC} ${FC_OUT}"; return 1; }
    [[ "$FC_OUT" == *"CR-DIRECTED"* ]] || return 1
    [[ "$FC_OUT" == *"$_notice_header"* ]] || { echo "the wake did not say listening had stopped: ${FC_OUT}"; return 1; }
    _clock_advance 30
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ -z "$FC_OUT" ] || { echo "the notice was repeated: ${FC_OUT}"; return 1; }
}

@test "TC3: a stop recorded for another formation is not reported in this one" {
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_CODE=500 MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    bash "${HANDLERS}/formation-state.sh" set 5151 "$CLAUDE_SESSION_ID"
    _clock_advance 1800
    _on_clock "$HANDLERS" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [ -z "$FC_OUT" ] || { echo "a stop in formation 4242 was reported in 5151: ${FC_OUT}"; return 1; }
}

@test "TC3 control: with the notice removed, the early-stop test goes red" {
    local m; m="$(_mutant nonotice)"
    perl -0777 -pi -e 's{^_fc_listen_notice_due\(\) \{\n}{_fc_listen_notice_due() \{\n    return 1\n}m' "${m}/formation-check.sh"
    ! cmp -s "${m}/formation-check.sh" "${HANDLERS}/formation-check.sh" || { echo "mutation did not apply"; return 1; }
    _clock_start
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _on_clock "$m" MMRY_FORMATION_MODE=idle FAKE_BODY='[]' FAKE_SENT_CODE=500 MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5
    _clock_advance 1800
    _on_clock "$m" MMRY_FORMATION_MODE=prompt FAKE_BODY='[]'
    [[ "$FC_OUT" != *"$_notice_header"* ]] || { echo "the mutant still gave the notice, so the test proves nothing"; return 1; }
}
