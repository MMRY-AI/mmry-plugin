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

# A session start: the shipped session-init.sh, run against a copy of the plugin whose memory-loading
# delegate is a probe. session-init.sh's own job is installing files and, since #31844, the sweep;
# what session-start.sh then does is not under test here.
_session_start() {
    # $1 = the starting session's CLAUDE_CODE_SESSION_ID ("" for none)
    local root="${BATS_TEST_TMPDIR}/plugin"
    if [[ ! -d "$root" ]]; then
        mkdir -p "$root"
        cp -R "$HANDLERS" "$root/"
        [[ -d "${PLUGIN_ROOT}/setup" ]] && cp -R "${PLUGIN_ROOT}/setup" "$root/"
        printf '#!/usr/bin/env bash\necho SESSION-START-REACHED\n' > "$root/hooks-handlers/session-start.sh"
    fi
    local home="${BATS_TEST_TMPDIR}/ss-home"; mkdir -p "$home"
    if [[ -n "${1:-}" ]]; then
        run env HOME="$home" TMPDIR="$TMPDIR" CLAUDE_PLUGIN_ROOT="$root" CLAUDE_CODE_SESSION_ID="$1" \
            bash "$root/hooks-handlers/session-init.sh" < /dev/null
    else
        run env HOME="$home" TMPDIR="$TMPDIR" CLAUDE_PLUGIN_ROOT="$root" \
            bash "$root/hooks-handlers/session-init.sh" < /dev/null
    fi
}

# A fake service for the formation check: transmissions answer $FC_TX (default an empty list), the
# membership question answers $FC_SENT. With FC_SWITCH set, the membership question first rewrites
# the asking session's record to name formation FC_SWITCH (a join elsewhere at that very moment).
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
        echo 'case "$url" in'
        echo '    */transmissions/sent*)'
        echo '        answer="${FC_SENT:-}"'
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
    echo "session-init: status $status, output [$output]" >&3
    [[ "$status" -eq 0 ]] || { echo "session-init exited $status: $output"; return 1; }
    [[ "$output" == *SESSION-START-REACHED* ]] || { echo "session-init did not go on to load memories: $output"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "the stale membership file survived the session start"; return 1; }
}

@test "stale 1: the same sweep runs at a session start that has no session id from the host" {
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 60 ))
    _session_start ""
    [[ "$status" -eq 0 ]] || { echo "session-init exited $status: $output"; return 1; }
    [[ ! -e "${TMPDIR}/.mmry-formation-${OTHER}" ]] || { echo "no host session id: the stale file was kept"; return 1; }
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

@test "stale 1: the sweep never makes a session start fail, even when stat and rm both fail" {
    _session_start "$ME"   # builds the probe plugin
    _member "$OTHER"
    _backdate "${TMPDIR}/.mmry-formation-${OTHER}" $(( PERIOD + 60 ))
    local bin="${BATS_TEST_TMPDIR}/badbin" root="${BATS_TEST_TMPDIR}/plugin"
    mkdir -p "$bin"
    printf '#!/bin/sh\necho broken >&2\nexit 1\n' > "$bin/stat"
    printf '#!/bin/sh\necho broken >&2\nexit 1\n' > "$bin/rm"
    chmod +x "$bin/stat" "$bin/rm"
    run env PATH="${bin}:${PATH}" HOME="${BATS_TEST_TMPDIR}/ss-home" TMPDIR="$TMPDIR" CLAUDE_PLUGIN_ROOT="$root" \
        CLAUDE_CODE_SESSION_ID="$ME" bash "$root/hooks-handlers/session-init.sh" < /dev/null
    [[ "$status" -eq 0 && "$output" == *SESSION-START-REACHED* ]] || {
        echo "a failing sweep broke the session start: status $status, output [$output]"; return 1; }
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
