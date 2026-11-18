#!/usr/bin/env bats
# codex-approval-gate.bats - Codex runs the approval hook only for Formation members (#33903).
#
# THE FINDING (33452 QA, b9). hooks/codex-hooks.json registered PermissionRequest as a plain
# `sh codex-hook.sh formation-waiting`, so every Codex approval prompt, for every person, started the
# launcher, Git's bash, the library and formation-waiting.sh before formation-waiting.sh found there was
# no Formation and stopped. QA measured 0.4 to 1.1 seconds of that per prompt for a person in no
# Formation. Every other Codex Formation hook opens with a membership-file check and stops there.
#
# WHAT THIS FILE PROVES, one block per test case on the ticket:
#   TC1  a non-member's PermissionRequest, run through the command Codex runs, makes no service call
#        and starts no Formation work: on the sh form nothing past the gate's own sh starts (counted
#        through recording shims), formation-waiting.sh is never started, no request leaves; on Windows
#        the cmd launcher starts no process at all beyond cmd (counted by a Windows job object).
#   TC2  a member's PermissionRequest still makes exactly one waiting call, through both forms, and
#        prints nothing (Codex reads this hook's stdout as an approval decision).
#   gate the PermissionRequest gate is the SAME gate the formation-check registrations carry, byte for
#        byte, so the two cannot drift apart and the skip list for locks and markers applies to both.
#
# Every assertion runs the command lifted out of the shipped hooks file, never a copy of it.

load '../helpers/test-helper'

setup() {
    HOOKS="${PLUGIN_ROOT}/hooks/codex-hooks.json"
    HANDLERS="${PLUGIN_ROOT}/hooks-handlers"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID MMRY_HOST MMRY_FORMATION_MODE MMRY_JQ CODEX_HOME
    export MMRY_NO_SELF_UPDATE=1
    SID="cdx33903-$$-${BATS_TEST_NUMBER}"
    REAL_SH="$(command -v sh)"
    REAL_BASH="$(command -v bash)"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
    return 1
}

# The registered `command` (or `commandWindows`) for one event and handler, "" if none.
_registered() { # $1 event, $2 handler word, $3 field (command|commandWindows)
    node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const g of (d.hooks[process.argv[2]] || [])) for (const h of g.hooks)
            if (h.command.includes(process.argv[3])) { process.stdout.write(h[process.argv[4]] || ""); process.exit(0); }
    ' "$HOOKS" "$1" "$2" "$3"
}

_with_root() { local c="$1"; printf '%s' "${c//\$\{PLUGIN_ROOT\}/$2}"; }

_payload() {
    printf '{"session_id":"%s","transcript_path":null,"cwd":"/x","hook_event_name":"PermissionRequest","model":"gpt-5","permission_mode":"default","turn_id":"t1","tool_name":"Bash","tool_input":{"command":"ls","description":"run it"}}' "$SID" \
        > "${TEST_TMPDIR}/payload.json"
}

# A directory holding ONLY recording stand-ins for the two shells. With PATH set to it alone, any
# program the command starts by name is recorded, or fails as "not found" on stderr, which the
# no-output assertion catches.
_shim_dir() {
    local dir="${TEST_TMPDIR}/shim" name real
    mkdir -p "$dir"
    for name in sh bash; do
        real="$REAL_SH"; [[ "$name" == "bash" ]] && real="$REAL_BASH"
        printf '#!%s\nprintf "%%s\\n" "%s $*" >> "$GATE_LOG"\nexec "%s" "$@"\n' "$real" "$name" "$real" > "${dir}/${name}"
        chmod +x "${dir}/${name}"
    done
    printf '%s' "$dir"
}

# A fake Codex plugin root whose launcher only says it was reached: "everything after the gate".
_standin_root() {
    FAKE_ROOT="${TEST_TMPDIR}/standin-root"
    mkdir -p "${FAKE_ROOT}/hooks-handlers"
    printf '#!/usr/bin/env bash\necho "LAUNCHER-REACHED $*"\n' > "${FAKE_ROOT}/hooks-handlers/codex-hook.sh"
    cp "${HANDLERS}/codex-hook.cmd" "${FAKE_ROOT}/hooks-handlers/"
    chmod +x "${FAKE_ROOT}/hooks-handlers/codex-hook.sh"
}

# The real plugin, with formation-waiting.sh wrapped so every start of it is recorded, and a fake MMRY
# service that records every request.
_real_root() {
    REAL_ROOT="${TEST_TMPDIR}/real-root"
    mkdir -p "$REAL_ROOT"
    cp -R "$HANDLERS" "${REAL_ROOT}/"
    mv "${REAL_ROOT}/hooks-handlers/formation-waiting.sh" "${REAL_ROOT}/hooks-handlers/formation-waiting.real.sh"
    cat > "${REAL_ROOT}/hooks-handlers/formation-waiting.sh" <<'WRAP'
#!/usr/bin/env bash
printf 'formation-waiting %s\n' "$*" >> "$WAITING_LOG"
exec bash "${BASH_SOURCE[0]%/*}/formation-waiting.real.sh" "$@"
WRAP
    BIN="${TEST_TMPDIR}/fake-bin"
    mkdir -p "$BIN"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; method="GET"; url=""; prev=""
for arg in "$@"; do
    case "$prev" in -o) out="$arg" ;; -X) method="$arg" ;; esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_URL_LOG"
resp='{}'
case "$method $url" in
    "GET "*/api/formations/4242)
        resp='{"formation":{"id":4242},"members":[{"id":12,"sessionId":null,"role":"Lead","leftDate":null},{"id":31,"sessionId":"'"${FAKE_OWN_SID:-}"'","role":"Wingman","leftDate":null}]}' ;;
    "PUT "*/members/*/waiting)
        resp='{"formationId":4242,"memberId":31,"waiting":true,"waitingSince":"2026-11-18T14:05:00","toolName":"Bash","leadTold":true,"outcome":"Set"}' ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '200'
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    WAITING_LOG="${TEST_TMPDIR}/waiting.log"; : > "$WAITING_LOG"
    FAKE_URL_LOG="${TEST_TMPDIR}/urls.log"; : > "$FAKE_URL_LOG"
}

# Run the registered sh command against the real plugin. Leaves $status, $output.
_run_real() {
    _payload
    local cmd; cmd="$(_with_root "$(_registered PermissionRequest formation-waiting command)" "$REAL_ROOT")"
    [[ -n "$cmd" ]] || { echo "no PermissionRequest registration"; return 1; }
    run env PATH="${BIN}:${PATH}" TMPDIR="$TMPDIR" HOME="$HOME" WAITING_LOG="$WAITING_LOG" FAKE_URL_LOG="$FAKE_URL_LOG" \
        FAKE_OWN_SID="$SID" MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD=apikey \
        "$REAL_BASH" -c "$cmd" < "${TEST_TMPDIR}/payload.json"
}

# =============================================================================================
# TC1: A NON-MEMBER MAKES NO SERVICE CALL AND STARTS NO FORMATION WORK
# =============================================================================================

@test "33903 TC1: no membership, the registered PermissionRequest starts only its own sh and never the launcher" {
    _standin_root
    _payload
    local cmd; cmd="$(_with_root "$(_registered PermissionRequest formation-waiting command)" "$FAKE_ROOT")"
    [[ -n "$cmd" ]] || { echo "no PermissionRequest registration"; return 1; }
    GATE_LOG="${TEST_TMPDIR}/launches.log"; : > "$GATE_LOG"
    run env PATH="$(_shim_dir)" TMPDIR="$TMPDIR" GATE_LOG="$GATE_LOG" "$REAL_BASH" -c "$cmd" < "${TEST_TMPDIR}/payload.json"
    local launches; launches="$(grep -c . "$GATE_LOG" || true)"
    echo "status $status, output [$output], launches ${launches}: $(tr '\n' '|' < "$GATE_LOG")" >&3
    [[ "$status" -eq 0 ]] || { echo "exited $status"; return 1; }
    [[ "$output" != *LAUNCHER-REACHED* ]] || { echo "a non-member's approval prompt reached the launcher: $output"; return 1; }
    [[ -z "$output" ]] || { echo "printed (Codex would read it as a decision): $output"; return 1; }
    [[ "$launches" -eq 1 ]] || { echo "started ${launches} programs: $(cat "$GATE_LOG")"; return 1; }
}

@test "33903 TC1: no membership, the real plugin makes no service call and never starts formation-waiting.sh" {
    _real_root
    _run_real
    echo "status $status, output [$output], waiting starts $(grep -c . "$WAITING_LOG" || true), requests $(grep -c . "$FAKE_URL_LOG" || true)" >&3
    [[ "$status" -eq 0 && -z "$output" ]] || { echo "status $status, output [$output]"; return 1; }
    [[ ! -s "$WAITING_LOG" ]] || { echo "formation-waiting.sh was started: $(cat "$WAITING_LOG")"; return 1; }
    [[ ! -s "$FAKE_URL_LOG" ]] || { echo "service called: $(cat "$FAKE_URL_LOG")"; return 1; }
    compgen -G "${TMPDIR}/.mmry-waiting-*" >/dev/null && { echo "a waiting marker was written"; return 1; }
    return 0
}

@test "33903 TC1: a lock or marker sharing the prefix does not open the approval gate" {
    # The same skip list as the formation-check gate (#31844): locks and markers named
    # .mmry-formation-cs-*, -poll-*, -handover-*, -renewed-* are not membership.
    _standin_root
    _payload
    : > "${TMPDIR}/.mmry-formation-cs-${SID}"
    : > "${TMPDIR}/.mmry-formation-poll-${SID}"
    : > "${TMPDIR}/.mmry-formation-handover-${SID}"
    : > "${TMPDIR}/.mmry-formation-renewed-${SID}"
    : > "${TMPDIR}/.mmry-waiting-${SID}"
    local cmd; cmd="$(_with_root "$(_registered PermissionRequest formation-waiting command)" "$FAKE_ROOT")"
    run env TMPDIR="$TMPDIR" "$REAL_BASH" -c "$cmd" < "${TEST_TMPDIR}/payload.json"
    [[ "$status" -eq 0 && -z "$output" ]] || { echo "a lock or marker opened the gate: status $status, output [$output]"; return 1; }
}

# =============================================================================================
# TC2: A MEMBER STILL MAKES ONE WAITING CALL
# =============================================================================================

@test "33903 TC2: with membership, the registered PermissionRequest makes exactly one waiting call and prints nothing" {
    _real_root
    TMPDIR="$TMPDIR" bash "${HANDLERS}/formation-state.sh" set 4242 "$SID" >/dev/null
    _run_real
    local puts; puts="$(grep -c '^PUT .*/api/formations/4242/members/31/waiting$' "$FAKE_URL_LOG" || true)"
    echo "status $status, output [$output], waiting starts $(grep -c . "$WAITING_LOG" || true), PUTs ${puts}: $(tr '\n' '|' < "$FAKE_URL_LOG")" >&3
    [[ "$status" -eq 0 ]] || { echo "exited $status"; return 1; }
    [[ -z "$output" ]] || { echo "printed (Codex would read it as a decision): $output"; return 1; }
    [[ "$(grep -c . "$WAITING_LOG")" -eq 1 ]] || { echo "formation-waiting.sh starts: $(cat "$WAITING_LOG")"; return 1; }
    [[ "$puts" -eq 1 ]] || { echo "expected one waiting call: $(cat "$FAKE_URL_LOG")"; return 1; }
    [[ "$(grep -c '^PUT ' "$FAKE_URL_LOG")" -eq 1 ]] || { echo "more than one PUT: $(cat "$FAKE_URL_LOG")"; return 1; }
}

@test "33903 TC2 control: with membership, the stand-in launcher is reached through the same gate" {
    # POSITIVE CONTROL for the shim count in TC1: one membership file and the launcher is reached.
    _standin_root
    _payload
    printf '4242\n' > "${TMPDIR}/.mmry-formation-${SID}"
    local cmd; cmd="$(_with_root "$(_registered PermissionRequest formation-waiting command)" "$FAKE_ROOT")"
    run env TMPDIR="$TMPDIR" "$REAL_BASH" -c "$cmd" < "${TEST_TMPDIR}/payload.json"
    [[ "$output" == *"LAUNCHER-REACHED formation-waiting"* ]] || { echo "the launcher was not reached: $output"; return 1; }
}

# =============================================================================================
# THE GATE IS THE FORMATION-CHECK GATE, BYTE FOR BYTE
# =============================================================================================

@test "33903 gate: the PermissionRequest command is the formation-check gate, naming formation-waiting" {
    local pr fc
    pr="$(_registered PermissionRequest formation-waiting command)"
    fc="$(_registered UserPromptSubmit formation-check command)"
    [[ -n "$pr" && -n "$fc" ]] || { echo "registration missing: [$pr] [$fc]"; return 1; }
    [[ "${pr/ formation-waiting/ formation-check}" == "$fc" ]] || {
        echo "PermissionRequest: $pr"; echo "formation-check:   $fc"; return 1; }
    # And the Windows form still goes through the launcher, which carries the gate in cmd.
    [[ "$(_registered PermissionRequest formation-waiting commandWindows)" == 'cmd /d /c "${PLUGIN_ROOT}\hooks-handlers\codex-hook.cmd" formation-waiting' ]]
}

@test "33903 gate: the Windows launcher sends formation-waiting through the membership gate before any program starts" {
    local code wait_line gate_line first_prog
    code="$(tr -d '\r' < "${HANDLERS}/codex-hook.cmd" | grep -n -v -i '^[[:space:]]*rem\b' | grep -v -i '^[0-9]*:[[:space:]]*rem$')"
    wait_line="$(grep -m1 'if /i "%~1"=="formation-waiting" goto :formation_gate' <<< "$code" | cut -d: -f1)"
    gate_line="$(grep -m1 'if /i not "%~1"=="formation-check" goto :after_formation_gate' <<< "$code" | cut -d: -f1)"
    first_prog="$(grep -m1 -i -E 'where\.exe|reg\.exe|findstr|bash\.exe|codex-hook\.sh' <<< "$code" | cut -d: -f1)"
    [[ -n "$wait_line" && -n "$gate_line" && -n "$first_prog" ]] || { echo "lines not found: [$wait_line] [$gate_line] [$first_prog]"; return 1; }
    (( wait_line < gate_line && gate_line < first_prog )) || { echo "order: waiting $wait_line, gate $gate_line, first program $first_prog"; return 1; }
}

# =============================================================================================
# WINDOWS: THE CMD LAUNCHER, COUNTED BY THE OPERATING SYSTEM
# =============================================================================================

@test "33903 TC1+TC2 windows: the cmd launcher starts nothing for a non-member and reaches the handler for a member" {
    _is_windows || skip "Windows only: needs cmd.exe"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    _standin_root
    local counter; counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    local cmdline; cmdline="$(_registered PermissionRequest formation-waiting commandWindows)"
    cmdline="${cmdline//\$\{PLUGIN_ROOT\}/$(cygpath -w "$FAKE_ROOT")}"
    [[ "$cmdline" == "cmd /d /c "* ]] || { echo "unexpected commandWindows: $cmdline"; return 1; }
    local wtmp; wtmp="$(cygpath -w "$TMPDIR")"
    _countw() { env TMPDIR="$wtmp" pwsh -NoProfile -File "$counter" -CommandLine "$1" < /dev/null | tr -d '\r'; }
    local base gated open
    base="$(_countw 'cmd.exe /d /c exit 0')"
    gated="$(_countw "${cmdline/cmd /cmd.exe }")"
    printf '4242\n' > "${TMPDIR}/.mmry-formation-${SID}"
    open="$(_countw "${cmdline/cmd /cmd.exe }")"
    echo "cmd alone: $base | no membership: $gated | membership: $open" >&3
    local nb ng no
    nb="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$base")"
    ng="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$gated")"
    no="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$open")"
    [[ -n "$nb" && -n "$ng" && -n "$no" ]] || { echo "the counter did not answer"; return 1; }
    (( ng == nb )) || { echo "no membership: the launcher made $ng processes, bare cmd makes $nb"; return 1; }
    (( no > ng )) || { echo "control: with membership the count did not rise ($no vs $ng)"; return 1; }
    [[ "$gated" == *"EXIT=0"* ]] || { echo "gated launcher did not exit 0: $gated"; return 1; }
    # And the member's prompt really reaches the handler through the launcher.
    rm -f "${TMPDIR}/.mmry-formation-${SID}"
    local out
    out="$(env TMPDIR="$wtmp" cmd //d //c "$(cygpath -w "${FAKE_ROOT}/hooks-handlers/codex-hook.cmd")" formation-waiting < /dev/null 2>&1 | tr -d '\r')"
    [[ "$out" != *REACHED* ]] || { echo "no membership: the launcher went on: $out"; return 1; }
    printf '4242\n' > "${TMPDIR}/.mmry-formation-${SID}"
    out="$(env TMPDIR="$wtmp" cmd //d //c "$(cygpath -w "${FAKE_ROOT}/hooks-handlers/codex-hook.cmd")" formation-waiting < /dev/null 2>&1 | tr -d '\r')"
    [[ "$out" == *"LAUNCHER-REACHED formation-waiting"* ]] || { echo "membership: the launcher did not reach the handler: $out"; return 1; }
}
