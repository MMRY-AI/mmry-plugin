#!/usr/bin/env bats
# The formation message check finishes inside its hook budget, and never loses a message when it
# does not (#31746).
#
# The defect: Claude Code gives the UserPromptSubmit check ten seconds. On a loaded Windows machine
# the check spent about six of them getting ready and then waited on a request allowed twenty-five,
# so it ran out of time regularly. When it did, Claude Code killed it, showed the person a timeout
# error, and threw its output away - and because the check recorded messages as seen BEFORE it
# printed them, a kill between the two lost them for good. A message addressed to one session was
# never shown to anybody.
#
# These tests prove, at handler level:
#   - stopped at any point between asking the service and showing the result, the next check
#     shows every message exactly once (and the order that loses them is caught by a control);
#   - a service slower than the request limit gets nothing printed and nothing marked, inside the
#     budget, and the next check delivers;
#   - the handler's idea of each budget is the one actually registered, on both hosts;
#   - a lock left by a killed check does not silence the next one, and a live one still does.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-31746-$$"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_JQ
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_sid)" "${TMPDIR}/.mmry-formation-poll-$(_sid)"

    # Two messages, so "every message" is a count and not a single yes or no.
    BODY='[{"senderRole":"lead","senderSessionID":"lead-1","senderUserID":1,"content":"KT-MSG-ONE review the claim","sentDate":"2026-10-07T01:00:00"},{"senderRole":"member","senderSessionID":"dev-2","senderUserID":2,"recipientMemberID":5,"content":"KT-MSG-TWO take the slot","sentDate":"2026-10-07T01:05:00"}]'
}

teardown() {
    [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null || true
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

_sid() {
    printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'
}

# A real jq, resolved the way the product resolves one, as an absolute path for the wrapper to run.
_real_jq() {
    local j
    j="$(bash -c "source '${HANDLERS}/lib-jq.sh' >/dev/null 2>&1; mmry_resolve_jq >/dev/null 2>&1; printf '%s' \"\$MMRY_JQ\"")"
    [[ "$j" == "jq" ]] && j="$(command -v jq)"
    printf '%s' "$j"
}

# Whole seconds: portable to the BSD date a Mac ships. Callers compare with a strict less-than.
_now() { date +%s; }

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 2: STOPPED AT EACH POINT BETWEEN ASKING AND SHOWING
# ---------------------------------------------------------------------------------------------
# A fake curl and a jq wrapper that can each be told to STOP the check in its tracks: the stalled
# process writes its pid and waits, and the test then kills the check outright with SIGKILL - the
# worst case, which no trap survives, and what a timeout does on Windows. The points are:
#
#   curl     while the request is in flight
#   jq:N     at the Nth jq run after the request was made: parsing the response, and in the
#            prompt route the run that writes the result out, i.e. the act of showing it
#
# The number of jq runs after the request is not assumed. A calibration run counts them, so the
# test covers every one of them in whatever handler it is given, the control's included.
_kt_bin() {
    local dir="${BATS_TEST_TMPDIR}/kt-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
: > "${KT_DIR}/asked"
if [[ "${KT_STALL:-}" == "curl" ]]; then
    printf '%s\n' "$$" > "${KT_DIR}/stalled"
    w=0; while [[ ! -f "${KT_DIR}/release" && $w -lt 600 ]]; do sleep 0.1; w=$((w + 1)); done
    exit 28
fi
answer="${KT_BODY:-}"
case "$url" in
    *since=)  ;;
    *since=*) answer='[]' ;;
esac
[[ -n "$out" ]] && printf '%s' "$answer" > "$out"
printf '200'
exit 0
FAKECURL
    cat > "${dir}/jq" <<'FAKEJQ'
#!/usr/bin/env bash
if [[ -f "${KT_DIR}/asked" && "${1:-}" != "--version" ]]; then
    n=$(( $(cat "${KT_DIR}/jq-count" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "${KT_DIR}/jq-count"
    if [[ "${KT_STALL:-}" == "jq:${n}" ]]; then
        printf '%s\n' "$$" > "${KT_DIR}/stalled"
        w=0; while [[ ! -f "${KT_DIR}/release" && $w -lt 600 ]]; do sleep 0.1; w=$((w + 1)); done
        exit 137
    fi
fi
exec "$KT_REAL_JQ" "$@"
FAKEJQ
    chmod +x "${dir}/curl" "${dir}/jq"
    printf '%s' "$dir"
}

# Run the check once, from handler directory $1, in mode $2, stalling at $3 ("" for no stall).
# Writes stdout and stderr to $4.
_kt_fire() {
    local hdir="$1" mode="$2" stall="$3" out="$4"
    env PATH="${KT_BIN}:${PATH}" MMRY_JQ="${KT_BIN}/jq" KT_REAL_JQ="$KT_REAL_JQ" \
        KT_DIR="$KT_DIR" KT_BODY="$BODY" KT_STALL="$stall" \
        MMRY_FORMATION_MODE="$mode" MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key \
        MMRY_API_URL="http://fake.invalid" \
        bash "${hdir}/formation-check.sh" </dev/null >"$out" 2>&1
}

# Stop the check at one point, kill it, then run two more checks. Echoes how many times each
# message was shown by the checks AFTER the killed one, as "<one>,<two>", or "never-reached" if
# the check never arrived at the point. The killed check's output is discarded, as Claude Code
# discards it.
_kt_point() {
    local hdir="$1" mode="$2" point="$3"
    rm -rf "$KT_DIR"; mkdir -p "$KT_DIR"
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_sid)" "${TMPDIR}/.mmry-formation-poll-$(_sid)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"

    _kt_fire "$hdir" "$mode" "$point" "${KT_DIR}/killed.out" &
    local hook=$! w=0
    while [[ ! -s "${KT_DIR}/stalled" && $w -lt 600 ]]; do sleep 0.1; w=$((w + 1)); done
    if [[ ! -s "${KT_DIR}/stalled" ]]; then
        : > "${KT_DIR}/release"; kill -9 "$hook" 2>/dev/null || true; wait "$hook" 2>/dev/null || true
        printf 'never-reached'
        return 0
    fi
    kill -9 "$hook" 2>/dev/null || true
    kill -9 "$(cat "${KT_DIR}/stalled")" 2>/dev/null || true
    : > "${KT_DIR}/release"
    wait "$hook" 2>/dev/null || true

    rm -f "${KT_DIR}/asked" "${KT_DIR}/jq-count"
    _kt_fire "$hdir" "$mode" "" "${KT_DIR}/next1.out" || true
    _kt_fire "$hdir" "$mode" "" "${KT_DIR}/next2.out" || true
    local one two
    one=$(( $(grep -c 'KT-MSG-ONE' "${KT_DIR}/next1.out" || true) + $(grep -c 'KT-MSG-ONE' "${KT_DIR}/next2.out" || true) ))
    two=$(( $(grep -c 'KT-MSG-TWO' "${KT_DIR}/next1.out" || true) + $(grep -c 'KT-MSG-TWO' "${KT_DIR}/next2.out" || true) ))
    printf '%s,%s' "$one" "$two"
}

# Every point for one handler and mode. Prints one line per point, "<point> <one>,<two>", and a
# final "points=<n>". Prints "calibration-failed" if an unstopped check did not deliver.
_kt_all_points() {
    local hdir="$1" mode="$2" n k
    rm -rf "$KT_DIR"; mkdir -p "$KT_DIR"
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_sid)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _kt_fire "$hdir" "$mode" "" "${KT_DIR}/calibrate.out" || true
    if ! grep -q 'KT-MSG-TWO' "${KT_DIR}/calibrate.out"; then
        printf 'calibration-failed\n'; cat "${KT_DIR}/calibrate.out"
        return 0
    fi
    n="$(cat "${KT_DIR}/jq-count" 2>/dev/null || echo 0)"
    printf 'curl %s\n' "$(_kt_point "$hdir" "$mode" curl)"
    for (( k = 1; k <= n; k++ )); do
        printf 'jq:%s %s\n' "$k" "$(_kt_point "$hdir" "$mode" "jq:${k}")"
    done
    printf 'points=%s\n' "$(( n + 1 ))"
}

_kt_init() {
    KT_BIN="$(_kt_bin)"
    KT_REAL_JQ="$(_real_jq)"
    KT_DIR="${BATS_TEST_TMPDIR}/kt"
    [[ -n "$KT_REAL_JQ" ]] || { echo "no jq on this host, system or bundled"; return 1; }
}

# A copy of the handler with "seen" written BEFORE the block is shown: the order this task removes.
_mark_first_handler_dir() {
    local dir="${BATS_TEST_TMPDIR}/handlers-mark-first"
    rm -rf "$dir"; mkdir -p "$dir"
    cp "${HANDLERS}"/*.sh "$dir"/
    perl -0777 -pi -e 's{^([ ]+)_poll_once \|\| exit 0\r?\n}{$1_poll_once || exit 0\n$1_mark_shown\n}mg' "${dir}/formation-check.sh"
    if cmp -s "${dir}/formation-check.sh" "${HANDLERS}/formation-check.sh"; then
        echo "the mark-first mutation did not apply; the control would prove nothing" >&2
        return 1
    fi
    bash -n "${dir}/formation-check.sh" || { echo "the mark-first mutation is not valid bash" >&2; return 1; }
    printf '%s' "$dir"
}

@test "req2 prompt: stopped at each point between asking and showing, the next check shows every message exactly once" {
    _kt_init || return 1
    local result; result="$(_kt_all_points "$HANDLERS" prompt)"
    echo "$result" >&3
    [[ "$result" != *calibration-failed* ]] || { echo "$result"; return 1; }
    [[ "$result" != *never-reached* ]] || { echo "a point was never reached: $result"; return 1; }
    # The prompt route has at least the request, the parse, and the write-out.
    local points="${result##*points=}"
    (( points >= 3 )) || { echo "only ${points} points covered: $result"; return 1; }
    local bad; bad="$(printf '%s\n' "$result" | grep -v '^points=' | grep -v ' 1,1$' || true)"
    [ -z "$bad" ] || { echo "not shown exactly once after a stop at: $bad"; return 1; }
}

@test "req2 tool: stopped at each point between asking and showing, the next check shows every message exactly once" {
    _kt_init || return 1
    local result; result="$(_kt_all_points "$HANDLERS" tool)"
    echo "$result" >&3
    [[ "$result" != *calibration-failed* ]] || { echo "$result"; return 1; }
    [[ "$result" != *never-reached* ]] || { echo "a point was never reached: $result"; return 1; }
    local points="${result##*points=}"
    (( points >= 2 )) || { echo "only ${points} points covered: $result"; return 1; }
    local bad; bad="$(printf '%s\n' "$result" | grep -v '^points=' | grep -v ' 1,1$' || true)"
    [ -z "$bad" ] || { echo "not shown exactly once after a stop at: $bad"; return 1; }
}

@test "control: the stop test fails against a handler that writes seen before printing" {
    # The ticket requires the stop test to be SEEN to fail when seen is written first. The mutant is
    # the shipped handler with one change: "seen" recorded straight after the poll, before the block
    # is written out. Stopped while the block is being written, it has already marked the batch, so
    # the next check is told nothing is new and both messages are gone.
    _kt_init || return 1
    local mutant; mutant="$(_mark_first_handler_dir)" || return 1
    local result; result="$(_kt_all_points "$mutant" prompt)"
    echo "$result" >&3
    [[ "$result" != *calibration-failed* ]] || { echo "$result"; return 1; }
    printf '%s\n' "$result" | grep -q ' 0,0$' || {
        echo "the mark-first mutant lost nothing at any point, so the stop test proves nothing: $result"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 3: A SERVICE SLOWER THAN THE REQUEST LIMIT
# ---------------------------------------------------------------------------------------------
# A real HTTP server and the real curl, so the limit under test is curl enforcing the time the
# handler gave it, not a fake deciding to give up. The server reads its delay from a file on every
# request, so the same server is slow for one check and prompt for the next. It logs every request,
# so the slow check's silence is attributable: it asked, and was not answered in time.
_start_stub() {
    command -v node >/dev/null 2>&1 || skip "node is needed for the stub service"
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB_DIR"
    printf '%s' "$BODY" > "${STUB_DIR}/body"
    printf '%s' "${1:-0}" > "${STUB_DIR}/delay"
    cat > "${STUB_DIR}/stub.js" <<'STUB'
const http = require("http"), fs = require("fs"), dir = process.argv[2];
const srv = http.createServer((q, r) => {
    fs.appendFileSync(dir + "/requests", q.url + "\n");
    let d = 0;
    try { d = Number(fs.readFileSync(dir + "/delay", "utf8")) || 0; } catch (e) {}
    const body = /[?&]since=./.test(q.url) ? "[]" : fs.readFileSync(dir + "/body", "utf8");
    setTimeout(() => {
        try { r.writeHead(200, { "Content-Type": "application/json" }); r.end(body); } catch (e) {}
    }, d * 1000);
});
srv.listen(0, "127.0.0.1", () => fs.writeFileSync(dir + "/port", String(srv.address().port)));
STUB
    node "${STUB_DIR}/stub.js" "$STUB_DIR" >/dev/null 2>&1 &
    STUB_PID=$!
    local w=0
    while [[ ! -s "${STUB_DIR}/port" && $w -lt 100 ]]; do sleep 0.1; w=$((w + 1)); done
    [[ -s "${STUB_DIR}/port" ]] || { echo "the stub service did not start"; return 1; }
    STUB_URL="http://127.0.0.1:$(cat "${STUB_DIR}/port")"
}

_fire_real() {
    local mode="$1"
    env MMRY_FORMATION_MODE="$mode" MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key \
        MMRY_API_URL="$STUB_URL" bash "${HANDLERS}/formation-check.sh" </dev/null
}

# The registered budget for an event, from the shipped hooks.json.
_registered_budget() {
    node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const t=(d.hooks[process.argv[2]]||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check")).map(h=>h.timeout);console.log(t.length===1?t[0]:"none");' \
        "${BATS_TEST_DIRNAME}/../../hooks/hooks.json" "$1"
}

_req3() {
    local mode="$1" event="$2"
    _start_stub 30 || return 1
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local budget; budget="$(_registered_budget "$event")"
    [[ "$budget" =~ ^[0-9]+$ ]] || { echo "no registered budget for ${event}: ${budget}"; return 1; }

    # 1. Slower than the request limit: nothing printed, nothing marked, no error, inside the budget.
    local t0 t1
    t0="$(_now)"
    run _fire_real "$mode"
    t1="$(_now)"
    echo "${mode}: slow check took $(( t1 - t0 ))s against a ${budget}s budget, status ${status}" >&3
    [ "$status" -eq 0 ] || { echo "status ${status}: ${output}"; return 1; }
    [ -z "$output" ] || { echo "the person was shown something: ${output}"; return 1; }
    (( t1 - t0 < budget )) || { echo "took $(( t1 - t0 ))s, budget ${budget}s"; return 1; }
    [ "$(grep -c . "${STUB_DIR}/requests")" -ge 1 ] || { echo "the check never asked, so its silence proves nothing"; return 1; }
    run bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_SESSION_ID"
    [ "$output" = "4242 " ] || { echo "something was marked seen: [${output}]"; return 1; }
    [ ! -d "${TMPDIR}/.mmry-formation-cs-$(_sid)" ] || { echo "the delivery mutex was left behind"; return 1; }

    # 2. The service answers promptly now: the next check delivers every message.
    printf '0' > "${STUB_DIR}/delay"
    run _fire_real "$mode"
    [[ "$output" == *KT-MSG-ONE* && "$output" == *KT-MSG-TWO* ]] || { echo "next check did not deliver both: ${output}"; return 1; }

    # 3. And the one after that shows neither again.
    run _fire_real "$mode"
    [[ "$output" != *KT-MSG-ONE* && "$output" != *KT-MSG-TWO* ]] || { echo "delivered twice: ${output}"; return 1; }
}

@test "req3 prompt: a service slower than the request limit gets nothing printed or marked, and the next check delivers" {
    _req3 prompt UserPromptSubmit
}

@test "req3 tool: a service slower than the request limit gets nothing printed or marked, and the next check delivers" {
    _req3 tool PostToolUse
}

@test "req3 start: a service slower than the request limit gets nothing printed or marked, and the next check delivers" {
    _req3 start SessionStart
}

# ---------------------------------------------------------------------------------------------
# THE HANDLER'S BUDGETS ARE THE REGISTERED ONES
# ---------------------------------------------------------------------------------------------
# The handler works to a deadline inside a budget it cannot read from Claude Code, so it carries
# the figure. A figure that drifts from hooks.json is a deadline set against the wrong clock, so
# both hosts' registrations are read here and compared with the handler's table.
_handler_figure() {
    # $1 = the case label, e.g. "prompt|start" or "tool"; $2 = _fc_budget or _fc_request
    grep -F "${1}) " "${HANDLERS}/formation-check.sh" | grep -F '_fc_budget=' \
        | grep -oE "${2}=[0-9]+" | head -1 | cut -d= -f2
}

@test "budgets: each synchronous mode's deadline matches its registration on both hosts, with margin" {
    local reserve; reserve="$(grep -oE '^_fc_reserve=[0-9]+' "${HANDLERS}/formation-check.sh" | cut -d= -f2)"
    [[ "$reserve" =~ ^[0-9]+$ ]] || { echo "no _fc_reserve in the handler"; return 1; }
    local ps_budget ps_req tool_budget tool_req
    ps_budget="$(_handler_figure 'prompt|start' _fc_budget)"; ps_req="$(_handler_figure 'prompt|start' _fc_request)"
    tool_budget="$(_handler_figure tool _fc_budget)";         tool_req="$(_handler_figure tool _fc_request)"
    echo "handler: prompt/start ${ps_budget}s request ${ps_req}s; tool ${tool_budget}s request ${tool_req}s; reserve ${reserve}s" >&3
    [[ "$ps_budget" =~ ^[0-9]+$ && "$ps_req" =~ ^[0-9]+$ && "$tool_budget" =~ ^[0-9]+$ && "$tool_req" =~ ^[0-9]+$ ]] || {
        echo "could not read the handler's table"; return 1; }

    local f got checked=0
    for f in hooks.json codex-hooks.json; do
        got="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const o={};for(const[ev,gs]of Object.entries(d.hooks))for(const g of gs)for(const h of g.hooks)if(h.command.includes("formation-check"))o[ev]=h.timeout;console.log([o.UserPromptSubmit,o.SessionStart,o.PostToolUse].join(" "));' \
            "${BATS_TEST_DIRNAME}/../../hooks/${f}")"
        echo "${f}: UserPromptSubmit SessionStart PostToolUse = ${got}" >&3
        [ "$got" = "${ps_budget} ${ps_budget} ${tool_budget}" ] || { echo "${f} registers ${got}, the handler assumes ${ps_budget} ${ps_budget} ${tool_budget}"; return 1; }
        checked=$(( checked + 1 ))
    done
    [ "$checked" -eq 2 ] || return 1

    # The request is shorter than the budget, and the budget leaves at least a second for preparation
    # on top of the request and the reserve.
    (( ps_req + reserve + 1 <= ps_budget )) || { echo "prompt/start: request ${ps_req} + reserve ${reserve} leaves no time to prepare in ${ps_budget}"; return 1; }
    (( tool_req + reserve + 1 <= tool_budget )) || { echo "tool: request ${tool_req} + reserve ${reserve} leaves no time to prepare in ${tool_budget}"; return 1; }
}

@test "budgets: every other caller of the client keeps the 10 s connect and 25 s total defaults" {
    # The shorter limits are the formation check's alone. A request made by a command the person ran
    # must not inherit them, so the client's defaults are pinned, and the check's limits are set in
    # its own shell and never exported.
    grep -qF 'connect_timeout="${MMRY_HTTP_CONNECT_TIMEOUT:-10}" max_time="${MMRY_HTTP_MAX_TIME:-25}"' \
        "${HANDLERS}/mmry-client.sh" || { echo "the client's defaults changed"; return 1; }
    run grep -nE 'export[[:space:]]+MMRY_HTTP_(CONNECT_TIMEOUT|MAX_TIME)' "${HANDLERS}/formation-check.sh"
    [ "$status" -ne 0 ] || { echo "the check exports its limits: ${output}"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# PREPARATION: WHAT THE CHECK NO LONGER SPAWNS (REQUIREMENT 1)
# ---------------------------------------------------------------------------------------------
# The timing itself is a Windows measurement recorded on the task, because a wall-clock bar in a
# suite cannot separate healthy from broken on a loaded runner (see hook-budgets.bats). What can be
# held here is what the time was spent on: processes. Counted, not timed.
@test "preparation: a delivering prompt check runs jq at most five times and no state helper process" {
    _kt_init || return 1
    rm -rf "$KT_DIR"; mkdir -p "$KT_DIR"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"

    # A jq that logs one line per run, before and after the request.
    local logjq="${BATS_TEST_TMPDIR}/logjq"
    mkdir -p "$logjq"
    printf '#!/usr/bin/env bash\necho RUN >> "%s/jq.log"\nexec "%s" "$@"\n' "$KT_DIR" "$KT_REAL_JQ" > "${logjq}/jq"
    chmod +x "${logjq}/jq"

    env PATH="${logjq}:${KT_BIN}:${PATH}" MMRY_JQ="${logjq}/jq" KT_DIR="$KT_DIR" KT_BODY="$BODY" KT_STALL="" \
        MMRY_FORMATION_MODE=prompt MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "${HANDLERS}/formation-check.sh" </dev/null > "${KT_DIR}/out" 2>&1 || true
    grep -q 'KT-MSG-TWO' "${KT_DIR}/out" || { echo "it did not deliver, so the count means nothing"; cat "${KT_DIR}/out"; return 1; }

    local runs; runs="$(grep -c . "${KT_DIR}/jq.log" || true)"
    echo "jq runs for one delivering prompt check: ${runs}" >&3
    (( runs <= 5 )) || { echo "jq ran ${runs} times:"; cat "${KT_DIR}/jq.log"; return 1; }

    # The state helper is sourced, never run: no `bash ... formation-state.sh` in the handler's code.
    run grep -nE '^[^#]*bash[[:space:]]+"?\$\{HANDLER_DIR\}/formation-state\.sh' "${HANDLERS}/formation-check.sh"
    [ "$status" -ne 0 ] || { echo "the handler still runs the state helper as a process: ${output}"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# A LOCK LEFT BY A KILLED CHECK (REQUIREMENTS 2 AND 4)
# ---------------------------------------------------------------------------------------------
@test "locks: a delivery mutex whose holder is dead does not silence the next check" {
    _kt_init || return 1
    rm -rf "$KT_DIR"; mkdir -p "$KT_DIR"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    # A pid that existed and has exited.
    local dead; dead="$(bash -c 'printf %s $$')"
    if kill -0 "$dead" 2>/dev/null; then skip "pid ${dead} was reused before the test could use it"; fi
    mkdir -p "${TMPDIR}/.mmry-formation-cs-$(_sid)"
    printf '%s\n' "$dead" > "${TMPDIR}/.mmry-formation-cs-$(_sid)/pid"

    _kt_fire "$HANDLERS" tool "" "${KT_DIR}/out" || true
    grep -q 'KT-MSG-ONE' "${KT_DIR}/out" || { echo "a dead holder's lock silenced delivery"; cat "${KT_DIR}/out"; return 1; }
}

@test "locks: a delivery mutex whose holder is alive still silences the other reader" {
    # Requirement 4: reclaiming a dead holder's lock must not become taking a live one, or two
    # readers show the same batch. The bats process running this test is alive by definition.
    _kt_init || return 1
    rm -rf "$KT_DIR"; mkdir -p "$KT_DIR"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    mkdir -p "${TMPDIR}/.mmry-formation-cs-$(_sid)"
    printf '%s\n' "$$" > "${TMPDIR}/.mmry-formation-cs-$(_sid)/pid"

    _kt_fire "$HANDLERS" tool "" "${KT_DIR}/out" || true
    [ ! -s "${KT_DIR}/out" ] || { echo "a live holder's lock was taken: $(cat "${KT_DIR}/out")"; return 1; }
    [ -d "${TMPDIR}/.mmry-formation-cs-$(_sid)" ] || { echo "the live holder's lock was removed"; return 1; }
}
