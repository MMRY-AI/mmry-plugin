#!/usr/bin/env bats
# Leftover formation memberships (#31844).
#
# THE DEFECT. A session that ends without leaving its formation leaves its membership file,
# .mmry-formation-<session>, in MMRY's temp folder for ever. The #31746 gate opened for ANY file
# matching .mmry-formation-*, so one such file - or a delivery lock sharing the prefix - made every
# later session on the machine pay for the full formation check: measured in the 31746 round-2 QA at
# 22 processes and about 11 s per firing on Claude Code, 17 and about 6.4 s on Codex. Measured by
# the PM on 2026-10-08: 41 such entries on one Windows machine, the oldest from 30 August, three of
# them live members of a running formation.
#
# What this file proves, one block per test case on the ticket:
#   1. A membership file older than the stale period with no live member is removed at the next
#      session start, by the shipped session-init.sh, and the gate then stays closed.
#   2. An active member's file is refreshed by its own checks and by its idle watch, and survives
#      the cleanup across an idle period longer than the stale period.
#   3. On a machine seeded with stale files and locks from ended sessions, a session in no formation
#      starts no further process at the gate - including while ANOTHER session on the same machine
#      is genuinely a member, which no machine-wide gate can achieve.
#
# Every gate assertion runs the command lifted out of the shipped hooks file, never a copy of it.

setup() {
    PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    HANDLERS="${PLUGIN_ROOT}/hooks-handlers"
    HOOKS="${PLUGIN_ROOT}/hooks"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$TMPDIR"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID MMRY_HOST \
          MMRY_FORMATION_MODE MMRY_JQ MMRY_FORMATION_STALE_SECONDS
    ME="me-$$-${BATS_TEST_NUMBER}"
    OTHER="ended-$$-${BATS_TEST_NUMBER}"
    LIVE="live-$$-${BATS_TEST_NUMBER}"
    REAL_SH="$(command -v sh)"
    REAL_BASH="$(command -v bash)"
    # The period the product ships with, read from the file that owns it, so a change to the period
    # is a change these tests follow rather than a second number that can drift.
    PERIOD="$(grep -oE '^MMRY_FORMATION_STALE_SECONDS="\$\{MMRY_FORMATION_STALE_SECONDS:-[0-9]+\}"' \
        "${HANDLERS}/formation-state.sh" | grep -oE '[0-9]+' | tail -1)"
}

teardown() {
    [[ -n "${BG_PID:-}" ]] && kill "$BG_PID" 2>/dev/null || true
    [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null || true
}

# ---- helpers ---------------------------------------------------------------------------------

# Set a path's mtime to N seconds ago, on GNU and on BSD.
_backdate() {
    local path="$1" ago="$2" now t ts
    now="$(date +%s)"; t=$(( now - ago ))
    ts="$(date -d "@${t}" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$t" +%Y%m%d%H%M.%S)"
    touch -t "$ts" "$path"
}

_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

_age() { echo $(( $(date +%s) - $(_mtime "$1") )); }

_member() {   # $1 = session id, $2 = formation id
    TMPDIR="$TMPDIR" bash "${HANDLERS}/formation-state.sh" set "${2:-4242}" "$1"
}

_registrations() {
    node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const [ev, gs] of Object.entries(d.hooks))
            for (const g of gs) for (const h of g.hooks)
                if (h.command.includes("formation-check")) console.log(ev + "\t" + h.command);
    ' "$1"
}

_command_for() {
    _registrations "$1" | awk -F'\t' -v ev="$2" '$1 == ev { sub(/^[^\t]*\t/, ""); print; exit }'
}

_codex_command_for() {
    local c; c="$(_command_for "${HOOKS}/codex-hooks.json" "$1")"
    printf '%s' "${c//\$\{PLUGIN_ROOT\}/$2}"
}

_codex_windows_command_for() {
    node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const g of (d.hooks[process.argv[2]] || [])) for (const h of g.hooks)
            if (h.command.includes("formation-check")) { process.stdout.write(h.commandWindows || ""); process.exit(0); }
    ' "${HOOKS}/codex-hooks.json" "$1"
}

_is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
    return 1
}

_shim_dir() {
    local dir="${BATS_TEST_TMPDIR}/shim" name real
    mkdir -p "$dir"
    for name in sh bash; do
        real="$REAL_SH"; [[ "$name" == "bash" ]] && real="$REAL_BASH"
        printf '#!%s\nprintf "%%s\n" "%s $*" >> "$GATE_LOG"\nexec "%s" "$@"\n' "$real" "$name" "$real" > "${dir}/${name}"
        chmod +x "${dir}/${name}"
    done
    printf '%s' "$dir"
}

_standins() {
    FAKE_HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${FAKE_HOME}/.claude/mmry/hooks-handlers"
    printf '#!/usr/bin/env bash\necho "GUARD-REACHED $*"\n' > "${FAKE_HOME}/.claude/mmry/hooks-handlers/hook-guard.sh"
    FAKE_ROOT="${BATS_TEST_TMPDIR}/codex-root"
    mkdir -p "${FAKE_ROOT}/hooks-handlers"
    printf '#!/usr/bin/env bash\necho "LAUNCHER-REACHED $*"\n' > "${FAKE_ROOT}/hooks-handlers/codex-hook.sh"
    cp "${HANDLERS}/codex-hook.cmd" "${FAKE_ROOT}/hooks-handlers/"
    chmod +x "${FAKE_HOME}/.claude/mmry/hooks-handlers/hook-guard.sh" "${FAKE_ROOT}/hooks-handlers/codex-hook.sh"
}

# Run a registered command as the host does, with every program it can start reachable only through
# a recording shim. $1 = command, $2 = the CLAUDE_CODE_SESSION_ID to give it ("" for none).
# Leaves $status, $output and $LAUNCHES (the registration's own sh counts as one).
_run_counted() {
    local cmd="$1" sid="${2:-}"
    GATE_LOG="${BATS_TEST_TMPDIR}/launches.log"
    : > "$GATE_LOG"
    if [[ -n "$sid" ]]; then
        run env PATH="$(_shim_dir)" HOME="$FAKE_HOME" TMPDIR="$TMPDIR" GATE_LOG="$GATE_LOG" \
            CLAUDE_CODE_SESSION_ID="$sid" "$REAL_BASH" -c "$cmd" < /dev/null
    else
        run env PATH="$(_shim_dir)" HOME="$FAKE_HOME" TMPDIR="$TMPDIR" GATE_LOG="$GATE_LOG" \
            "$REAL_BASH" -c "$cmd" < /dev/null
    fi
    LAUNCHES="$(grep -c . "$GATE_LOG" || true)"
}

# A session start: the shipped session-init.sh, which hands over to the shipped session-start.sh, run
# as the host runs it, with the hook payload on stdin and the fake service below on PATH. Since QA
# round 2 the sweep runs in session-start.sh, after the payload's session id is read, and asks the
# service before it removes anything, so the whole chain is under test, not a probe.
#   $1 = the session_id in the hook payload ("" for a payload without one)
#   $2 = the CLAUDE_CODE_SESSION_ID in the environment (optional; unset when not given)
# What the service says about a session: the file ${SVC}/sent-<session id> if there is one, else
# $SS_SENT, which defaults to "not a member" - the answer for an ended session in a closed formation.
_SS_NOT_MEMBER='{"formationId":4242,"member":false,"messages":[]}'
_session_start() {
    [[ -n "${SVC:-}" ]] || _idle_fixture
    local home="${BATS_TEST_TMPDIR}/ss-home"; mkdir -p "$home"
    local payload='{}' sent="${SS_SENT:-$_SS_NOT_MEMBER}"
    [[ -n "${1:-}" ]] && payload="{\"session_id\":\"$1\",\"hook_event_name\":\"SessionStart\"}"
    local -a extra=()
    (( $# >= 2 )) && extra=(CLAUDE_CODE_SESSION_ID="$2")
    run env HOME="$home" TMPDIR="$TMPDIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" PATH="${SS_PATH:-${SVC}:${PATH}}" \
        FC_LOG="$FC_LOG" FC_SENT="$sent" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_NO_SELF_UPDATE=1 "${extra[@]}" \
        bash "${PLUGIN_ROOT}/hooks-handlers/session-init.sh" <<< "$payload"
}

# The session start finished and loaded memories (its SessionStart output was printed).
_started() {
    [[ "$status" -eq 0 && "$output" == *'"hookEventName":"SessionStart"'* ]]
}

# How many membership questions the fake service has been asked.
_asked() { grep -c '/transmissions/sent' "$FC_LOG" || true; }

# What the service will say about session $1: "true", "false", or a raw body.
_service_says() {
    [[ -n "${SVC:-}" ]] || _idle_fixture
    case "$2" in
        true|false) printf '{"formationId":4242,"member":%s,"messages":[]}' "$2" > "${SVC}/sent-$1" ;;
        *) printf '%s' "$2" > "${SVC}/sent-$1" ;;
    esac
}

# What the service will say about session $2 IN FORMATION $1 only: "true", "false", or a raw body.
_service_says_in() {
    [[ -n "${SVC:-}" ]] || _idle_fixture
    case "$3" in
        true|false) printf '{"formationId":%s,"member":%s,"messages":[]}' "$1" "$3" > "${SVC}/sent-$1-$2" ;;
        *) printf '%s' "$3" > "${SVC}/sent-$1-$2" ;;
    esac
}

# A fake service for the formation check: transmissions answer $FC_TX (default an empty list), the
# membership question answers ${SVC}/sent-<session id> when there is one, else $FC_SENT. With
# FC_SWITCH set, the membership question first rewrites the asking session's record to name
# formation FC_SWITCH (a join elsewhere at that very moment). ${SVC}/down: nothing connects.
# ${SVC}/delay: every request takes that many seconds first. ${SVC}/delay-sent: only the membership
# question does (#31844 QA round 3), so a start that asks several costs only those.
# KEYED ON THE FORMATION TOO (#31844 QA round 3, M5): ${SVC}/sent-<formation>-<session> answers for
# that pair alone and is preferred, so a question about the wrong formation gets the fallback answer.
_idle_fixture() {
    SVC="${BATS_TEST_TMPDIR}/svc"; mkdir -p "$SVC"
    {
        echo '#!/usr/bin/env bash'
        echo 'out=""; prev=""; url=""'
        echo 'for arg in "$@"; do'
        echo '    [[ "$prev" == "-o" ]] && out="$arg"'
        echo '    case "$arg" in http*) url="$arg" ;; esac'
        echo '    prev="$arg"'
        echo 'done'
        echo 'printf "%s\n" "$url" >> "${FC_LOG:-/dev/null}"'
        echo 'here="${BASH_SOURCE[0]%/*}"'
        echo '[[ -f "$here/delay" ]] && sleep "$(cat "$here/delay")"'
        echo 'if [[ -f "$here/down" ]]; then printf 000; exit 7; fi'
        echo 'case "$url" in'
        echo '    */transmissions/sent*)'
        echo '        sid="${url##*sessionId=}"; sid="${sid%%&*}"'
        echo '        fid="${url#*/formations/}"; fid="${fid%%/*}"'
        echo '        [[ -f "$here/delay-sent" ]] && sleep "$(cat "$here/delay-sent")"'
        echo '        if [[ -f "$here/sent-$fid-$sid" ]]; then answer="$(cat "$here/sent-$fid-$sid")"'
        echo '        elif [[ -f "$here/sent-$sid" ]]; then answer="$(cat "$here/sent-$sid")"; else answer="${FC_SENT:-}"; fi'
        echo '        [[ -n "${FC_SWITCH:-}" ]] && printf "%s\n" "$FC_SWITCH" > "${FC_STATE_FILE}"'
        echo '        ;;'
        echo '    *) answer="${FC_TX:-[]}" ;;'
        echo 'esac'
        echo '[[ -n "$out" ]] && printf "%s" "$answer" > "$out"'
        echo 'printf 200'
        echo 'exit 0'
    } > "${SVC}/curl"
    chmod +x "${SVC}/curl"
    FC_LOG="${BATS_TEST_TMPDIR}/requests.log"; : > "$FC_LOG"
    mkdir -p "${BATS_TEST_TMPDIR}/fc-home"
}

# The environment every formation-check run below shares, as env arguments.
_fc_env() {
    FC_ENV=(HOME="${BATS_TEST_TMPDIR}/fc-home" TMPDIR="$TMPDIR" PATH="${SVC}:${PATH}" FC_LOG="$FC_LOG"
            FC_STATE_FILE="${TMPDIR}/.mmry-formation-${ME}"
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid"
            CLAUDE_SESSION_ID="$ME")
}

# One idle watch of two seconds that ends by asking the membership question. $1 = its answer,
# $2 = a formation to switch the record to at the moment of asking (optional).
_run_idle() {
    _fc_env
    run env "${FC_ENV[@]}" FC_SENT="$1" FC_SWITCH="${2:-}" MMRY_FORMATION_MODE=idle \
        MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" < /dev/null
}

# =============================================================================================
# THE DEFINED PERIOD
# =============================================================================================

@test "period: the stale period is defined once, in formation-state.sh, and is at least a day" {
    [[ "$PERIOD" =~ ^[0-9]+$ ]] || { echo "no MMRY_FORMATION_STALE_SECONDS default in formation-state.sh"; return 1; }
    echo "stale period: ${PERIOD} s ($(( PERIOD / 3600 )) h)" >&3
    # Long enough that an idle member whose watch could not renew (a laptop asleep over a weekend,
    # a Codex session, which has no idle watch at all) is not mistaken for an ended one.
    (( PERIOD >= 86400 )) || { echo "a period of ${PERIOD} s would sweep members idle overnight"; return 1; }
}

# =============================================================================================
# TEST CASE 1: A STALE FILE WITH NO LIVE MEMBER IS REMOVED AT THE NEXT SESSION START
# =============================================================================================

@test "stale 1: an ended session's file older than the period is removed by the next session start" {
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 60 ))
    _session_start "$ME"
    echo "session start: status $status, membership questions $(_asked)" >&3
    _started || { echo "the session start did not go on to load memories: status $status, output [$output]"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "the stale membership file survived the session start"; return 1; }
    [[ "$(_asked)" -eq 1 ]] || { echo "expected one membership question, the service was asked $(_asked)"; return 1; }
}

@test "stale 1 D1: a session start whose payload carries no session id sweeps nothing" {
    # The own record's protection is only as good as the id. Without the payload's id there is no
    # trustworthy id, so nothing is swept - not even a record the service would call ended.
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 60 ))
    _session_start "" ""
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "no payload id: a record was swept anyway"; return 1; }
    # Also with an environment id present: it is not the payload's, so it is not used.
    _session_start "" "inherited-$$"
    [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "no payload id, inherited env id: a record was swept"; return 1; }
    [[ "$(_asked)" -eq 0 ]] || { echo "the service was asked $(_asked) membership questions with no payload id"; return 1; }
    # CONTROL: the same record goes at the next start that does carry an id.
    _session_start "$ME"
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "control: a start with a payload id did not sweep"; return 1; }
}

@test "stale 1: a file younger than the period is NOT removed - it may be a live member between checks" {
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD - 600 ))
    _session_start "$ME"
    [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "a file inside the period was swept"; return 1; }
}

@test "stale 1: the starting session's own file is never swept, however old (a resumed session)" {
    _member "$ME"
    _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD * 3 ))
    _session_start "$ME"
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the starting session's own membership was swept"; return 1; }
}

@test "stale 1: an old file whose idle watch is still running (live poller pid) is a live member and is kept" {
    _member "$LIVE"
    _backdate "${TMPDIR}/.mmry-formation-${LIVE}" $(( PERIOD + 60 ))
    mkdir -p "${TMPDIR}/.mmry-formation-poll-${LIVE}"
    sleep 300 & HOLDER_PID=$!
    printf '%s\n' "$HOLDER_PID" > "${TMPDIR}/.mmry-formation-poll-${LIVE}/pid"
    _session_start "$ME"
    [[ -f "${TMPDIR}/.mmry-formation-${LIVE}" ]] || { echo "a member with a live watch was swept"; return 1; }
    # CONTROL: the same lock with a DEAD pid does not protect it.
    kill "$HOLDER_PID"; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""
    _session_start "$ME"
    [[ ! -e "${TMPDIR}/.mmry-formation-${LIVE}" ]] || { echo "a dead watch pid still protected the stale file"; return 1; }
}

@test "stale 1: the sweep touches nothing that is not a membership file" {
    # The locks and markers share the prefix; their owners manage them, and a live one removed out
    # from under its holder could start a second reader.
    local n
    for n in cs poll handover renewed; do
        mkdir -p "${TMPDIR}/.mmry-formation-${n}-${OTHER}"
        _backdate "${TMPDIR}/.mmry-formation-${n}-${OTHER}" $(( PERIOD + 60 ))
        printf 'x\n' > "${TMPDIR}/.mmry-formation-${n}-asfile-${OTHER}"
        _backdate "${TMPDIR}/.mmry-formation-${n}-asfile-${OTHER}" $(( PERIOD + 60 ))
    done
    printf 'keep\n' > "${TMPDIR}/unrelated-file"
    _backdate "${TMPDIR}/unrelated-file" $(( PERIOD + 60 ))
    _session_start "$ME"
    for n in cs poll handover renewed; do
        [[ -d "${TMPDIR}/.mmry-formation-${n}-${OTHER}" ]] || { echo "the sweep removed the ${n} lock"; return 1; }
        [[ -f "${TMPDIR}/.mmry-formation-${n}-asfile-${OTHER}" ]] || { echo "the sweep removed a ${n}- file"; return 1; }
    done
    [[ -f "${TMPDIR}/unrelated-file" ]] || { echo "the sweep removed a file outside its pattern"; return 1; }
}

@test "stale 1: the sweep never makes a session start fail, when stat fails or rm fails" {
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 60 ))
    local bin="${BATS_TEST_TMPDIR}/badbin" real_rm; real_rm="$(command -v rm)"
    mkdir -p "$bin"
    _idle_fixture
    # stat fails outright.
    printf '#!/bin/sh\necho broken >&2\nexit 1\n' > "$bin/stat"
    chmod +x "$bin/stat"
    SS_PATH="${bin}:${SVC}:${PATH}" _session_start "$ME"
    _started || { echo "a failing stat broke the session start: status $status, output [$output]"; return 1; }
    # rm fails on the membership file, so the sweep's removal fails; every other rm works.
    rm -f "$bin/stat"
    printf '#!/bin/sh\ncase "$*" in *.mmry-formation-*) echo broken >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_rm" > "$bin/rm"
    chmod +x "$bin/rm"
    SS_PATH="${bin}:${SVC}:${PATH}" _session_start "$ME"
    _started || { echo "a failing rm broke the session start: status $status, output [$output]"; return 1; }
    [[ "$(_asked)" -ge 1 ]] || { echo "control: the sweep never reached its question, so rm was never tried"; return 1; }
}

@test "stale 1: after the sweep the gate stays closed for a session in no formation, on every registration" {
    _standins
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 60 ))
    # BEFORE the sweep the fallback scan (no session id from the host) sees the leftover. This is the
    # behaviour the sweep exists to end, and it proves the file under test CAN open the gate.
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" ""
    [[ "$output" == *GUARD-REACHED* ]] || { echo "control: the leftover did not open the fallback gate: $output"; return 1; }
    _session_start "$ME"
    local ev sid
    for sid in "$ME" ""; do
        for ev in SessionStart UserPromptSubmit PostToolUse Stop; do
            _run_counted "$(_command_for "${HOOKS}/hooks.json" "$ev")" "$sid"
            [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
                echo "claude $ev (session id [${sid}]): status $status, output [$output], launches $LAUNCHES"; return 1; }
        done
    done
    for ev in SessionStart UserPromptSubmit PostToolUse; do
        _run_counted "$(_codex_command_for "$ev" "$FAKE_ROOT")" ""
        [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
            echo "codex $ev: status $status, output [$output], launches $LAUNCHES"; return 1; }
    done
}

@test "stale 1: the idle watch removes the local file when the service says this session is no longer a member" {
    _idle_fixture
    _member "$ME" 4242
    _run_idle '{"member":false,"sent":[]}'
    local left="removed"; [[ -e "${TMPDIR}/.mmry-formation-${ME}" ]] && left="kept"
    echo "member:false -> status $status, file ${left}" >&3
    grep -q '/transmissions/sent' "$FC_LOG" || { echo "control: the membership question was never asked"; return 1; }
    [[ "$status" -eq 0 ]] || { echo "the watch woke the session on a non-member: $status $output"; return 1; }
    [[ "$left" == removed ]] || { echo "member:false left the membership file behind"; return 1; }
}

@test "stale 1: an unknown or failed answer, or member:true, never removes the membership" {
    _idle_fixture
    local body
    for body in '{"member":true,"sent":[]}' '{"sent":[]}' 'not json' ''; do
        _member "$ME" 4242
        : > "$FC_LOG"
        _run_idle "$body"
        grep -q '/transmissions/sent' "$FC_LOG" || { echo "control [${body}]: the membership question was never asked"; return 1; }
        [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "answer [${body}] removed the membership"; return 1; }
    done
}

@test "stale 1: member:false about one formation never removes a record that now names another" {
    # The session joined formation 4343 at the moment the watch for 4242 asked. The answer is about
    # 4242; the record is about 4343 and must survive it.
    _idle_fixture
    _member "$ME" 4242
    _run_idle '{"member":false,"sent":[]}' 4343
    grep -q '/transmissions/sent' "$FC_LOG" || { echo "control: the membership question was never asked"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "member:false about 4242 removed a membership of 4343"; return 1; }
    [[ "$(head -1 "${TMPDIR}/.mmry-formation-${ME}")" == 4343 ]] || { echo "the record no longer names 4343"; return 1; }
}

# =============================================================================================
# REQUIREMENT 2 (QA ROUND 2): A GENUINE MEMBER NEVER LOSES ITS MEMBERSHIP TO THE CLEANUP
#
# Each of these is a member whose record goes stale through no fault of its own: nothing refreshes
# it, and it has no running watch. Age cannot tell it from an ended session; the service can.
# Every scenario test here FAILED on ac6472b, whose sweep removed on age and watch alone.
# =============================================================================================

@test "member 2a: a Codex member idle longer than the period (Codex has no idle watch) keeps its record" {
    local codex="codex-$$-${BATS_TEST_NUMBER}"
    _standins
    _member "$codex" 4242
    _backdate "${TMPDIR}/.mmry-formation-${codex}" $(( PERIOD + 3600 ))
    _service_says "$codex" true
    _session_start "$ME"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    echo "membership questions: $(_asked)" >&3
    [[ -f "${TMPDIR}/.mmry-formation-${codex}" ]] || { echo "the idle Codex member's record was removed"; return 1; }
    [[ "$(head -1 "${TMPDIR}/.mmry-formation-${codex}")" == 4242 ]] || { echo "the record no longer names its formation"; return 1; }
    grep -q "sessionId=${codex}" "$FC_LOG" || { echo "control: the service was never asked about the Codex member"; return 1; }
    # And its gate still opens, so directed messages still reach it.
    _run_counted "$(_codex_command_for UserPromptSubmit "$FAKE_ROOT")" ""
    [[ "$output" == *"LAUNCHER-REACHED formation-check"* ]] || { echo "the Codex member's gate is closed: $output"; return 1; }
}

@test "member 2b: a Claude Code member whose watch stopped on an unreachable service, then sat idle, keeps its record" {
    _standins
    _idle_fixture
    _member "$ME" 4242
    # The watch asks its membership question, the service cannot be reached twice, and it stops.
    : > "${SVC}/down"
    _run_idle '{"member":true,"sent":[]}'
    rm -f "${SVC}/down"
    [[ "$status" -eq 0 ]] || { echo "control: the watch did not stop quietly: $status $output"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "control: the stopped watch removed the record itself"; return 1; }
    local pid=""
    [[ -f "${TMPDIR}/.mmry-formation-poll-${ME}/pid" ]] && pid="$(cat "${TMPDIR}/.mmry-formation-poll-${ME}/pid")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then echo "control: the watch is still running"; return 1; fi
    # Then it sits idle past the period, and another window starts.
    _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD + 3600 ))
    _service_says "$ME" true
    _session_start "$OTHER"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the member whose watch stopped was removed"; return 1; }
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" "$ME"
    [[ "$output" == *"GUARD-REACHED formation-check"* ]] || { echo "the member's gate is closed: $output"; return 1; }
}

@test "member 2c: a member closed on Friday and resumed after another window started on Tuesday keeps its record" {
    _standins
    _member "$ME" 4242
    # Friday 17:00 to Tuesday morning: four days with nothing written.
    _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( 4 * 86400 ))
    _service_says "$ME" true
    _session_start "$OTHER"           # Tuesday: another window first
    _started || { echo "the other window's start failed: status $status, output [$output]"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the closed member's record was removed by the other window"; return 1; }
    _session_start "$ME"              # then the member is resumed, same id
    _started || { echo "the resumed start failed: status $status, output [$output]"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the resumed member's record is gone"; return 1; }
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" "$ME"
    [[ "$output" == *"GUARD-REACHED formation-check"* ]] || { echo "the resumed member's gate is closed: $output"; return 1; }
}

@test "member 2 D1: the sweep itself refuses to run without an id, whoever calls it" {
    # session-start.sh only calls the sweep with the payload's id, but the function's own contract
    # is that a call with no id sweeps nothing. A stale record the service calls ended is the bait.
    _member "$OTHER" 4242
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 3600 ))
    _idle_fixture
    _service_says "$OTHER" false
    local call
    for call in '""' ''; do
        run env HOME="${BATS_TEST_TMPDIR}/fc-home" TMPDIR="$TMPDIR" PATH="${SVC}:${PATH}" FC_LOG="$FC_LOG" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            bash -c "source '${HANDLERS}/mmry-client.sh' && source '${HANDLERS}/formation-state.sh' && mmry_formation_sweep ${call}"
        [[ "$status" -eq 0 ]] || { echo "sweep [${call}] exited $status: $output"; return 1; }
        [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "the sweep called with [${call}] removed a record"; return 1; }
    done
    [[ "$(_asked)" -eq 0 ]] || { echo "the sweep with no id asked the service $(_asked) times"; return 1; }
    # CONTROL: the same call with an id does remove it, so the harness can see a removal.
    run env HOME="${BATS_TEST_TMPDIR}/fc-home" TMPDIR="$TMPDIR" PATH="${SVC}:${PATH}" FC_LOG="$FC_LOG" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash -c "source '${HANDLERS}/mmry-client.sh' && source '${HANDLERS}/formation-state.sh' && mmry_formation_sweep '${ME}'"
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "control: the sweep with an id did not remove the ended record: $output"; return 1; }
}

@test "member 2 D1: the starting session's own record survives when its environment id is empty or inherited" {
    # The payload names this session. The environment says nothing, or names another session (an
    # inherited CLAUDE_CODE_SESSION_ID). The service is made to call this session "not a member", so
    # only the own-id protection can keep the record: this test is about the id, not the question.
    _member "$ME" 4242
    _service_says "$ME" false
    local env_id
    for env_id in "" "inherited-$$"; do
        _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD + 3600 ))
        _session_start "$ME" "$env_id"
        _started || { echo "env [${env_id}]: session start failed: status $status, output [$output]"; return 1; }
        [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "env id [${env_id}]: the session's own record was swept"; return 1; }
    done
    if grep -q "sessionId=${ME}" "$FC_LOG"; then echo "the service was asked about the starting session itself"; return 1; fi
}

@test "member 2: no clean 'not a member' answer, no removal - unreachable, a body without member, member:true, bad JSON" {
    _member "$OTHER" 4242
    _idle_fixture
    local body
    for body in down '{"member":true,"messages":[]}' '{"messages":[]}' 'not json' empty; do
        rm -f "${SVC}/down" "${SVC}/sent-${OTHER}"
        case "$body" in
            down) : > "${SVC}/down" ;;
            empty) : > "${SVC}/sent-${OTHER}" ;;
            *) _service_says "$OTHER" "$body" ;;
        esac
        _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 3600 ))
        : > "$FC_LOG"
        _session_start "$ME"
        [[ "$status" -eq 0 ]] || { echo "[${body}]: session start exited $status: $output"; return 1; }
        [[ "$(_asked)" -ge 1 ]] || { echo "control [${body}]: the service was never asked"; return 1; }
        [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "answer [${body}] removed the record"; return 1; }
    done
}

@test "member 2: member:false under any status other than 2xx never removes (500 503 401 403 404 429)" {
    _member "$OTHER" 4242
    _idle_fixture
    _service_says "$OTHER" false
    cp "${SVC}/curl" "${SVC}/curl.200"
    local code
    for code in 500 503 401 403 404 429; do
        sed "s/^printf 200\$/printf ${code}/" "${SVC}/curl.200" > "${SVC}/curl"
        chmod +x "${SVC}/curl"
        _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 3600 ))
        : > "$FC_LOG"
        _session_start "$ME"
        [[ "$(_asked)" -ge 1 ]] || { echo "control ${code}: the service was never asked"; return 1; }
        [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "HTTP ${code} with member:false removed the record"; return 1; }
    done
}

@test "member 2 boundary: past the period an ended session's record is still removed; inside it nobody is asked" {
    _member "$OTHER" 4242
    _service_says "$OTHER" false
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD - 120 ))
    _session_start "$ME"
    [[ -f "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "inside the period: removed"; return 1; }
    [[ "$(_asked)" -eq 0 ]] || { echo "inside the period the service was asked $(_asked) times"; return 1; }
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 120 ))
    _session_start "$ME"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "past the period, service says ended: the record was kept"; return 1; }
    [[ "$(_asked)" -eq 1 ]] || { echo "expected exactly one question, got $(_asked)"; return 1; }
}

@test "member 2 bounded: forty stale records against a service that is down cost one question, and all are kept" {
    local i
    for i in $(seq 1 40); do
        _member "gone-${i}-$$" 37
        _backdate "${TMPDIR}/.mmry-formation-gone-${i}-$$" $(( PERIOD + 3600 ))
    done
    _idle_fixture
    : > "${SVC}/down"
    _session_start "$ME"
    [[ "$status" -eq 0 ]] || { echo "session start exited $status: $output"; return 1; }
    echo "service down, 40 stale records: questions asked $(_asked)" >&3
    [[ "$(_asked)" -eq 1 ]] || { echo "the sweep asked $(_asked) questions of a service that is down"; return 1; }
    [[ "$(ls -A "$TMPDIR" | grep -c '^\.mmry-formation-gone-')" -eq 40 ]] || { echo "records were removed with the service down"; return 1; }
}

@test "member 2 bounded: at most MMRY_FORMATION_SWEEP_MAX_ASKS questions a start; the rest go at later starts" {
    local i max
    max="$(grep -oE '^MMRY_FORMATION_SWEEP_MAX_ASKS="\$\{MMRY_FORMATION_SWEEP_MAX_ASKS:-[0-9]+\}"' \
        "${HANDLERS}/formation-state.sh" | grep -oE '[0-9]+' | tail -1)"
    [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 && max < 40 )) || { echo "no usable MMRY_FORMATION_SWEEP_MAX_ASKS default: [$max]"; return 1; }
    # Only the cap may limit the count here. With the shipped time budget a slow machine stops
    # sooner, which would hide a missing cap (seen in the mutation run) and fail a sound one.
    export MMRY_FORMATION_SWEEP_BUDGET=600
    for i in $(seq 1 40); do
        _member "gone-${i}-$$" 37
        _backdate "${TMPDIR}/.mmry-formation-gone-${i}-$$" $(( PERIOD + 3600 ))
    done
    _session_start "$ME"
    local left; left="$(ls -A "$TMPDIR" | grep -c '^\.mmry-formation-gone-' || true)"
    echo "40 ended records, cap ${max}: asked $(_asked), left ${left}" >&3
    [[ "$(_asked)" -eq "$max" ]] || { echo "asked $(_asked), cap is ${max}"; return 1; }
    [[ "$left" -eq $(( 40 - max )) ]] || { echo "left ${left}, expected $(( 40 - max ))"; return 1; }
    local n=0
    while (( left > 0 && n < 10 )); do
        _session_start "$ME"; n=$(( n + 1 ))
        left="$(ls -A "$TMPDIR" | grep -c '^\.mmry-formation-gone-' || true)"
    done
    [[ "$left" -eq 0 ]] || { echo "after ${n} more starts ${left} ended records remain"; return 1; }
}

@test "member 2 bounded: a slow service stops the questions at the time budget" {
    local i budget
    budget="$(grep -oE '^MMRY_FORMATION_SWEEP_BUDGET="\$\{MMRY_FORMATION_SWEEP_BUDGET:-[0-9]+\}"' \
        "${HANDLERS}/formation-state.sh" | grep -oE '[0-9]+' | tail -1)"
    [[ "$budget" =~ ^[0-9]+$ ]] && (( budget > 0 && budget <= 15 )) || { echo "no usable budget default: [$budget]"; return 1; }
    for i in $(seq 1 10); do
        _member "gone-${i}-$$" 37
        _backdate "${TMPDIR}/.mmry-formation-gone-${i}-$$" $(( PERIOD + 3600 ))
    done
    _idle_fixture
    printf '3\n' > "${SVC}/delay"
    _session_start "$ME"
    rm -f "${SVC}/delay"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    echo "3 s a request, budget ${budget} s: questions asked $(_asked)" >&3
    # Every request in this fake takes 3 s, the memory load's included. A question is only started
    # when it can finish inside the budget, so there are at most budget / 3 of them, rounded up.
    (( $(_asked) >= 1 && $(_asked) <= (budget + 2) / 3 )) || { echo "asked $(_asked) questions at 3 s each against a ${budget} s budget"; return 1; }
}

@test "member 2: a record whose name is not the session id as written is never asked about or removed" {
    local odd='odd id/with:bytes'
    TMPDIR="$TMPDIR" bash "${HANDLERS}/formation-state.sh" set 4242 "$odd"
    local f="${TMPDIR}/.mmry-formation-odd_id_with_bytes"
    [[ -f "$f" ]] || { echo "control: the record is not where expected"; ls -A "$TMPDIR"; return 1; }
    _backdate "$f" $(( PERIOD + 3600 ))
    _session_start "$ME"
    [[ -f "$f" ]] || { echo "the record with a rewritten name was removed"; return 1; }
    [[ "$(_asked)" -eq 0 ]] || { echo "the service was asked about a session id that does not exist"; return 1; }
}

# =============================================================================================
# QA ROUND 3: EVERY STALE RECORD IS REACHED, AND THE CLEANUP REMOVES NOTHING BUT A RECORD
#
# REACH (requirement 1). The sweep asked about stale records in the same order at every start, and a
# record the service called a member was never refreshed, so a full cap of quiet members sorting
# ahead of an ended record used up every start's questions and the ended record was never reached.
# Now a clean member:true refreshes the record, and the questions go oldest first.
#
# INJECTION (security). The sweep took the path in each line of stat's output on trust. A record name
# carrying a newline could add a line naming any file at all, and the no-formation branch removed it
# without a question. Now only names of the record form are considered, and only a path that is
# exactly one of the records collected is ever removed.
# =============================================================================================

# $1 quiet members of formation 4242 that the service vouches for, $2 ended records of formation 37
# it does not. All past the period; every member's name sorts ahead of every ended record's.
_quiet_and_dead() {
    local i
    for i in $(seq 1 "$1"); do
        _member "a0000${i}-quiet-$$" 4242
        _service_says_in 4242 "a0000${i}-quiet-$$" true
        _backdate "${TMPDIR}/.mmry-formation-a0000${i}-quiet-$$" $(( PERIOD + 3600 ))
    done
    for i in $(seq 1 "$2"); do
        _member "z0000${i}-dead-$$" 37
        _service_says_in 37 "z0000${i}-dead-$$" false
        _backdate "${TMPDIR}/.mmry-formation-z0000${i}-dead-$$" $(( PERIOD + 3600 ))
    done
}

_left() { ls -A "$TMPDIR" | grep -c -- "$1" || true; }

_shipped_cap() {
    grep -oE '^MMRY_FORMATION_SWEEP_MAX_ASKS="\$\{MMRY_FORMATION_SWEEP_MAX_ASKS:-[0-9]+\}"' \
        "${HANDLERS}/formation-state.sh" | grep -oE '[0-9]+' | tail -1
}

@test "reach r3: ten quiet members ahead of five ended records - every ended record goes within the stated starts, every member stays" {
    # QA's reproduction. Only the cap limits the questions here, as in the cap test above.
    export MMRY_FORMATION_SWEEP_BUDGET=600
    local cap bound starts=0 dead=5 i
    cap="$(_shipped_cap)"
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || { echo "no usable cap default: [$cap]"; return 1; }
    # The bound: every stale record is reached within ceil(stale records / cap) starts.
    bound=$(( (15 + cap - 1) / cap ))
    _quiet_and_dead 10 5
    while (( dead > 0 && starts <= bound )); do
        _session_start "$ME"; starts=$(( starts + 1 ))
        _started || { echo "start ${starts} failed: status $status, output [$output]"; return 1; }
        dead="$(_left '^\.mmry-formation-z0000.*-dead-')"
        echo "start ${starts}: questions so far $(_asked), ended records left ${dead}" >&3
    done
    (( dead == 0 )) || { echo "after ${starts} starts ${dead} of 5 ended records remain: the questions never reach them"; return 1; }
    (( starts <= bound )) || { echo "the ended records took ${starts} starts; the bound is ${bound}"; return 1; }
    [[ "$(_left '^\.mmry-formation-a0000.*-quiet-')" -eq 10 ]] || { echo "members were removed: $(ls -A "$TMPDIR")"; return 1; }
    for i in $(seq 1 10); do
        [[ "$(head -1 "${TMPDIR}/.mmry-formation-a0000${i}-quiet-$$")" == 4242 ]] || { echo "member ${i} no longer names 4242"; return 1; }
    done
    # Each question names the record's own formation (M5).
    grep -q "/formations/4242/transmissions/sent?sessionId=a00001-quiet-$$" "$FC_LOG" \
        || { echo "no question about member 1 in formation 4242:"; cat "$FC_LOG"; return 1; }
    grep -q "/formations/37/transmissions/sent?sessionId=z00001-dead-$$" "$FC_LOG" \
        || { echo "no question about ended record 1 in formation 37:"; cat "$FC_LOG"; return 1; }
    # A member the service vouched for is not asked about again for a full period.
    : > "$FC_LOG"
    _session_start "$ME"
    [[ "$(_asked)" -eq 0 ]] || { echo "members already vouched for were asked again: $(_asked) questions"; return 1; }
}

@test "reach r3: with a slow service only a few questions fit the budget, and every ended record is still reached" {
    _quiet_and_dead 5 2
    printf '2\n' > "${SVC}/delay-sent"
    local starts=0 dead=2 before=0 asked k=0 bound
    # At most 7 starts (one question each); fewer when more fit. A start that asks nothing ends it.
    while (( dead > 0 && starts < 7 && (starts == 0 || k > 0) && (k == 0 || starts <= (7 + k - 1) / k) )); do
        _session_start "$ME"; starts=$(( starts + 1 ))
        _started || { echo "start ${starts} failed: status $status, output [$output]"; return 1; }
        asked="$(_asked)"
        if (( k == 0 || asked - before < k )); then k=$(( asked - before )); fi
        before="$asked"
        dead="$(_left '^\.mmry-formation-z0000.*-dead-')"
        echo "start ${starts}: questions so far ${asked}, ended records left ${dead}" >&3
    done
    rm -f "${SVC}/delay-sent"
    (( k >= 1 )) || { echo "a start asked no question at all"; return 1; }
    (( dead == 0 )) || { echo "after ${starts} starts ${dead} of 2 ended records remain: the questions never reach them"; return 1; }
    bound=$(( (7 + k - 1) / k ))
    (( starts <= bound )) || { echo "took ${starts} starts with at least ${k} questions each; the bound is ${bound}"; return 1; }
    [[ "$(_left '^\.mmry-formation-a0000.*-quiet-')" -eq 5 ]] || { echo "members were removed"; return 1; }
}

@test "reach r3: the record stale longest is asked first, whatever its name sorts as" {
    export MMRY_FORMATION_SWEEP_BUDGET=600
    local cap; cap="$(_shipped_cap)"
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || { echo "no usable cap default: [$cap]"; return 1; }
    _quiet_and_dead "$cap" 1
    _backdate "${TMPDIR}/.mmry-formation-z00001-dead-$$" $(( PERIOD + 7200 ))
    _session_start "$ME"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    echo "cap ${cap}, questions $(_asked)" >&3
    [[ ! -e "${TMPDIR}/.mmry-formation-z00001-dead-$$" ]] || { echo "the oldest record was not reached at the first start: $(_asked) questions went to newer ones"; return 1; }
    [[ "$(_left '^\.mmry-formation-a0000.*-quiet-')" -eq "$cap" ]] || { echo "members were removed"; return 1; }
}

# What stat prints for a record whose name carries "\n1 <path>": the genuine line, then forged ones.
_forged_stat() {   # $1 = bin dir, $2 = the genuine record, $3... = forged paths
    local bin="$1" real="$2" old p
    shift 2
    old=$(( $(date +%s) - PERIOD - 3600 ))
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s %%s\\n" %s "%s"\n' "$old" "$real"
        for p in "$@"; do printf 'printf "%%s %%s\\n" 1 "%s"\n' "$p"; done
    } > "${bin}/stat"
    chmod +x "${bin}/stat"
}

@test "inject r3: a forged line in stat's output never removes a file that is not a collected record" {
    local work="${BATS_TEST_TMPDIR}/work" bin="${BATS_TEST_TMPDIR}/forge"
    mkdir -p "$work" "$bin"
    printf 'project notes\n' > "${work}/CLAUDE.md"
    printf '4242\n' > "${BATS_TEST_TMPDIR}/numeric-outside"
    printf 'keep\n' > "${TMPDIR}/unrelated-file"
    _member "$OTHER" 4242
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 3600 ))
    _service_says_in 4242 "$OTHER" false
    # A relative path is the working directory's. The fake's default answer is "not a member".
    _forged_stat "$bin" "${TMPDIR}/.mmry-formation-${OTHER}" \
        "CLAUDE.md" "${BATS_TEST_TMPDIR}/numeric-outside" "${TMPDIR}/unrelated-file"
    run env HOME="${BATS_TEST_TMPDIR}/fc-home" TMPDIR="$TMPDIR" PATH="${bin}:${SVC}:${PATH}" FC_LOG="$FC_LOG" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash -c "cd '${work}' && source '${HANDLERS}/mmry-client.sh' && source '${HANDLERS}/formation-state.sh' && mmry_formation_sweep '${ME}'"
    [[ "$status" -eq 0 ]] || { echo "sweep exited $status: $output"; return 1; }
    [[ -f "${work}/CLAUDE.md" ]] || { echo "the sweep removed CLAUDE.md in the working directory"; return 1; }
    [[ -f "${BATS_TEST_TMPDIR}/numeric-outside" ]] || { echo "the sweep removed a file outside TMPDIR"; return 1; }
    [[ -f "${TMPDIR}/unrelated-file" ]] || { echo "the sweep removed a TMPDIR file that is not a record"; return 1; }
    if grep -q 'numeric-outside\|unrelated-file\|CLAUDE' "$FC_LOG"; then echo "the service was asked about a forged path:"; cat "$FC_LOG"; return 1; fi
    # CONTROL: the sweep ran on the forged output and acted on its genuine line.
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "control: the genuine ended record was not removed, so the forged stat proved nothing"; return 1; }
}

@test "inject r3: a stale record that names no formation is removed without a question; a fresh one is kept" {
    local blank="blank-$$-${BATS_TEST_NUMBER}"
    printf 'not-a-number\n' > "${TMPDIR}/.mmry-formation-${OTHER}"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 3600 ))
    : > "${TMPDIR}/.mmry-formation-${blank}"
    _backdate "${TMPDIR}/.mmry-formation-${blank}" $(( PERIOD + 3600 ))
    printf 'not-a-number\n' > "${TMPDIR}/.mmry-formation-${LIVE}"
    _session_start "$ME"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "a stale record naming no formation was kept"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${blank}" ]] || { echo "a stale empty record was kept"; return 1; }
    [[ -f "${TMPDIR}/.mmry-formation-${LIVE}" ]] || { echo "a record inside the period was removed"; return 1; }
    [[ "$(_asked)" -eq 0 ]] || { echo "the service was asked $(_asked) times about records that name no formation"; return 1; }
}

@test "inject r3: a record name with a byte outside A-Za-z0-9._- is never considered, let alone removed" {
    local odd="${TMPDIR}/.mmry-formation-odd name-$$"
    printf '4242\n' > "$odd"
    _backdate "$odd" $(( PERIOD + 3600 ))
    # CONTROL: an ordinary ended record beside it is asked about and removed.
    _member "$OTHER" 4242
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 3600 ))
    _session_start "$ME"
    _started || { echo "session start failed: status $status, output [$output]"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "control: the ordinary ended record was not removed"; return 1; }
    [[ -f "$odd" ]] || { echo "a record whose name has a space was removed"; return 1; }
    if grep -q 'odd' "$FC_LOG"; then echo "the service was asked about the odd name:"; cat "$FC_LOG"; return 1; fi
}

# =============================================================================================
# TEST CASE 2: AN ACTIVE MEMBER'S FILE IS REFRESHED AND SURVIVES ACROSS A LONG IDLE PERIOD
# =============================================================================================

@test "refresh 2: a member's own check refreshes its file on every event, and the refreshed file survives the sweep" {
    _idle_fixture
    _member "$ME" 4242
    _fc_env
    local ev age
    for ev in prompt tool start; do
        _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD + 60 ))
        run env "${FC_ENV[@]}" MMRY_FORMATION_MODE="$ev" bash "${HANDLERS}/formation-check.sh" < /dev/null
        age="$(_age "${TMPDIR}/.mmry-formation-${ME}")"
        echo "$ev: status $status, file age after the check ${age} s" >&3
        (( age < 60 )) || { echo "$ev did not refresh the membership file (age ${age} s)"; return 1; }
    done
    _session_start "$OTHER"
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the active member's refreshed file was swept"; return 1; }
}

@test "refresh 2: refreshing changes nothing in the file but its time (formation, last seen, owed ids)" {
    _idle_fixture
    printf '4242\n2026-10-08T01:00:00\n77,78\n' > "${TMPDIR}/.mmry-formation-${ME}"
    _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD + 60 ))
    # A service that cannot be reached: no poll succeeds, so nothing but the refresh can have
    # written the file.
    printf '#!/usr/bin/env bash\nprintf 000\nexit 7\n' > "${SVC}/curl"; chmod +x "${SVC}/curl"
    _fc_env
    run env "${FC_ENV[@]}" MMRY_FORMATION_MODE=prompt bash "${HANDLERS}/formation-check.sh" < /dev/null
    local got; got="$(cat "${TMPDIR}/.mmry-formation-${ME}")"
    [[ "$got" == $'4242\n2026-10-08T01:00:00\n77,78' ]] || { echo "the refresh altered the record: [$got]"; return 1; }
    (( $(_age "${TMPDIR}/.mmry-formation-${ME}") < 60 )) || { echo "a check with the service down did not refresh"; return 1; }
}

@test "refresh 2: an idle member survives the sweep across an idle period longer than the stale period" {
    # The idle watch is the member's only activity while nobody types. Its file is aged past the
    # period - as if the member had sat idle that long - while the watch runs, and another session
    # starts on the machine. The member must still be a member afterwards, with a fresh file, so
    # the sweep after the watch ends keeps it too.
    _idle_fixture
    _member "$ME" 4242
    _fc_env
    env "${FC_ENV[@]}" FC_SENT='{"member":true,"sent":[]}' MMRY_FORMATION_MODE=idle \
        MMRY_IDLE_POLL_SECONDS=14 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "${HANDLERS}/formation-check.sh" < /dev/null > /dev/null 2>&1 &
    BG_PID=$!
    local i
    for i in $(seq 1 50); do [[ -f "${TMPDIR}/.mmry-formation-poll-${ME}/pid" ]] && break; sleep 0.2; done
    [[ -f "${TMPDIR}/.mmry-formation-poll-${ME}/pid" ]] || { echo "the idle watch never started"; return 1; }
    _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD * 2 ))
    _session_start "$OTHER"
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the sweep removed an idle member whose watch was running"; return 1; }
    sleep 3
    local age; age="$(_age "${TMPDIR}/.mmry-formation-${ME}")"
    echo "file age 3 s after being aged $(( PERIOD * 2 )) s, with the watch running: ${age} s" >&3
    (( age < 30 )) || { echo "the idle watch did not refresh the membership file (age ${age} s)"; return 1; }
    _backdate "${TMPDIR}/.mmry-formation-${ME}" $(( PERIOD * 2 ))
    sleep 3
    age="$(_age "${TMPDIR}/.mmry-formation-${ME}")"
    (( age < 30 )) || { echo "second idle stretch: not refreshed (age ${age} s)"; return 1; }
    kill "$BG_PID" 2>/dev/null || true; wait "$BG_PID" 2>/dev/null || true; BG_PID=""
    # The watch is gone, as when it stops to be renewed. The file it kept fresh is inside the period,
    # so the next session start keeps it.
    _session_start "$OTHER"
    [[ -f "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "the refreshed member was swept after its watch ended"; return 1; }
}

@test "refresh 2: the idle watch refreshes in the touch it already makes, and touch -c never re-creates" {
    # The membership file rides on the touch the watch already runs for its own lock: one process,
    # two paths, and -c so that a file removed by leaving is never brought back by a refresh.
    grep -qE 'touch -c "\$_poller_dir" "\$MMRY_FS_PATH"' "${HANDLERS}/formation-check.sh" || {
        echo "the idle loop does not refresh the membership file in its existing touch"; return 1; }
    [[ "$(grep -cE '^[^#]*\btouch ' "${HANDLERS}/formation-check.sh")" -eq 1 ]] || {
        echo "formation-check.sh now runs touch more than once:"; grep -nE '^[^#]*\btouch ' "${HANDLERS}/formation-check.sh"; return 1; }
}

@test "refresh 2: a check for a session with no membership file creates none" {
    _idle_fixture
    _fc_env
    run env "${FC_ENV[@]}" MMRY_FORMATION_MODE=prompt bash "${HANDLERS}/formation-check.sh" < /dev/null
    [[ ! -e "${TMPDIR}/.mmry-formation-${ME}" ]] || { echo "a check for a non-member created a membership file"; return 1; }
}

# =============================================================================================
# TEST CASE 3: A SEEDED MACHINE; A SESSION IN NO FORMATION STARTS NO FURTHER PROCESS
# =============================================================================================

# What the PM found on a real machine: ended sessions' membership files, delivery lock DIRECTORIES,
# and entries sharing the prefix that are FILES, not memberships.
_seed_machine() {
    local i n
    for i in 1 2 3 4 5 6; do
        _member "ended-${i}-$$" 37
        _backdate "${TMPDIR}/.mmry-formation-ended-${i}-$$" $(( PERIOD + 3600 * i ))
        mkdir -p "${TMPDIR}/.mmry-formation-cs-ended-${i}-$$" "${TMPDIR}/.mmry-formation-poll-ended-${i}-$$"
    done
    for n in cs poll handover renewed; do printf '1234\n' > "${TMPDIR}/.mmry-formation-${n}-asfile-$$"; done
}

@test "seeded 3: a session in no formation starts no further process, on every Claude Code registration" {
    _standins
    _seed_machine
    _session_start "$ME"
    local ev
    for ev in SessionStart UserPromptSubmit PostToolUse Stop; do
        _run_counted "$(_command_for "${HOOKS}/hooks.json" "$ev")" "$ME"
        echo "$ev: status $status, output [$output], launches $LAUNCHES" >&3
        [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
            echo "$ev: status $status, output [$output], launches $LAUNCHES: $(cat "$GATE_LOG")"; return 1; }
    done
}

@test "seeded 3: with ANOTHER session on the machine genuinely in a formation, a non-member still starts nothing" {
    # The case no machine-wide gate can meet: a live, fresh membership file belongs to somebody else.
    _standins
    _seed_machine
    _member "$LIVE" 37
    _session_start "$ME"
    [[ -f "${TMPDIR}/.mmry-formation-${LIVE}" ]] || { echo "control: the live member was swept"; return 1; }
    local ev
    for ev in SessionStart UserPromptSubmit PostToolUse Stop; do
        _run_counted "$(_command_for "${HOOKS}/hooks.json" "$ev")" "$ME"
        echo "$ev: launches $LAUNCHES" >&3
        [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
            echo "$ev: a live member elsewhere opened this session's gate: launches $LAUNCHES, output [$output]"; return 1; }
    done
    # POSITIVE CONTROL: the live member itself, on the same machine and the same command, is let in.
    _run_counted "$(_command_for "${HOOKS}/hooks.json" PostToolUse)" "$LIVE"
    [[ "$output" == *"GUARD-REACHED formation-check"* && "$LAUNCHES" -eq 2 ]] || {
        echo "the live member was not let through: launches $LAUNCHES, output [$output]"; return 1; }
}

@test "seeded 3: without a host session id, lock directories and lock FILES never open the fallback gate" {
    # No sweep here: what is left is only entries that are not membership files, which must not count
    # as membership on Codex or on a Claude Code that gives no session id.
    _standins
    local i n
    for i in 1 2 3; do mkdir -p "${TMPDIR}/.mmry-formation-cs-x${i}" "${TMPDIR}/.mmry-formation-poll-x${i}"; done
    for n in cs poll handover renewed; do printf '1\n' > "${TMPDIR}/.mmry-formation-${n}-asfile"; done
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" ""
    [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
        echo "claude fallback: a lock opened the gate: launches $LAUNCHES, output [$output]"; return 1; }
    local ev
    for ev in SessionStart UserPromptSubmit PostToolUse; do
        _run_counted "$(_codex_command_for "$ev" "$FAKE_ROOT")" ""
        [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
            echo "codex $ev: a lock opened the gate: launches $LAUNCHES, output [$output]"; return 1; }
    done
    # POSITIVE CONTROL: one real membership file among them opens both.
    _member "$OTHER"
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" ""
    [[ "$output" == *GUARD-REACHED* ]] || { echo "claude fallback missed a real membership: $output"; return 1; }
    _run_counted "$(_codex_command_for UserPromptSubmit "$FAKE_ROOT")" ""
    [[ "$output" == *LAUNCHER-REACHED* ]] || { echo "codex missed a real membership: $output"; return 1; }
}

@test "seeded 3: a session id the gate cannot use as a file name falls back to the scan rather than closing" {
    # formation-state.sh maps unsafe bytes to "_" with tr, which the gate cannot do without a process.
    # So an id that is not already safe is never looked up as it stands - it would miss its own file
    # and drop the member's messages - it is answered by the scan instead.
    _standins
    local odd='odd id/with:bytes'
    TMPDIR="$TMPDIR" bash "${HANDLERS}/formation-state.sh" set 4242 "$odd"
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" "$odd"
    [[ "$output" == *"GUARD-REACHED formation-check"* ]] || { echo "a member with an unsafe id was shut out: $output"; return 1; }
}

@test "seeded 3 windows: the OS counts no extra process for a non-member on a seeded machine" {
    _is_windows || skip "Windows only: counts processes with a Windows job object"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    _standins
    _seed_machine
    _member "$LIVE" 37
    _session_start "$ME"
    local counter; counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    local winbash; winbash="$(cygpath -w "$REAL_BASH")"
    local script; script="$(cygpath -w "${BATS_TEST_TMPDIR}/registered.sh")"
    _count() {
        printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/registered.sh"
        env HOME="$FAKE_HOME" TMPDIR="$TMPDIR" CLAUDE_CODE_SESSION_ID="$2" \
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$counter" \
            -CommandLine "\"${winbash}\" \"${script}\"" < /dev/null | tr -d '\r'
    }
    local base gated open
    base="$(_count "sh -c 'exit 0'" "$ME")"
    gated="$(_count "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" "$ME")"
    open="$(_count "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)" "$LIVE")"
    echo "one no-op sh: $base | non-member, seeded machine, live member present: $gated | the live member: $(tr '\n' ' ' <<< "$open")" >&3
    local nb ng no
    nb="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$base")"
    ng="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$gated")"
    no="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$open")"
    [[ -n "$nb" && -n "$ng" && -n "$no" ]] || { echo "the counter did not answer"; return 1; }
    (( ng == nb )) || { echo "non-member: $ng processes against $nb for one no-op sh"; return 1; }
    (( no > ng )) || { echo "control: the live member's count did not rise ($no vs $ng)"; return 1; }
}

@test "seeded 3 windows codex: lock FILES never open the cmd launcher; a membership file does" {
    _is_windows || skip "Windows only: needs cmd.exe"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    _standins
    local cmdline; cmdline="$(_codex_windows_command_for UserPromptSubmit)"
    cmdline="${cmdline//\$\{PLUGIN_ROOT\}/$(cygpath -w "$FAKE_ROOT")}"
    local wtmp; wtmp="$(cygpath -w "$TMPDIR")"
    local n out
    for n in cs poll handover renewed; do printf '1\n' > "${TMPDIR}/.mmry-formation-${n}-asfile"; done
    mkdir -p "${TMPDIR}/.mmry-formation-cs-dir"
    out="$(env TMPDIR="$wtmp" powershell.exe -NoProfile -Command "$cmdline" < /dev/null 2>&1 | tr -d '\r')"
    [[ "$out" != *REACHED* ]] || { echo "a lock file opened the cmd gate: $out"; return 1; }
    _member "$OTHER"
    out="$(env TMPDIR="$wtmp" powershell.exe -NoProfile -Command "$cmdline" < /dev/null 2>&1 | tr -d '\r')"
    [[ "$out" == *"LAUNCHER-REACHED formation-check"* ]] || { echo "the cmd gate missed a membership file: $out"; return 1; }
    # With TMPDIR unset, the user-temp branch filters the same way.
    local a="${BATS_TEST_TMPDIR}/ua"; mkdir -p "$a"
    for n in cs poll handover renewed; do printf '1\n' > "${a}/.mmry-formation-${n}-asfile"; done
    local wa; wa="$(cygpath -w "$a")"
    out="$(env -u TMPDIR TEMP="$wa" TMP="$wa" LOCALAPPDATA="$wa" powershell.exe -NoProfile -Command "$cmdline" < /dev/null 2>&1 | tr -d '\r')"
    [[ "$out" != *REACHED* ]] || { echo "user-temp branch: a lock file opened the cmd gate: $out"; return 1; }
    printf '4242\n' > "${a}/.mmry-formation-${OTHER}"
    out="$(env -u TMPDIR TEMP="$wa" TMP="$wa" LOCALAPPDATA="$wa" powershell.exe -NoProfile -Command "$cmdline" < /dev/null 2>&1 | tr -d '\r')"
    [[ "$out" == *REACHED* ]] || { echo "user-temp branch: missed a membership file: $out"; return 1; }
}
