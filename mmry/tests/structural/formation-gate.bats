#!/usr/bin/env bats
# The formation check depends on being in a formation (#31746, requirement added by Eric Barone on
# 2026-10-07).
#
# Evidence that started it: a session in no formation showed the formation-check UserPromptSubmit
# hook timing out at 20 seconds on the same prompt as the Foundation hook. The check is registered
# on every prompt, every tool call, every idle and every session start, and nearly every session is
# in no formation. So the first thing each registered formation-check command does is look for a
# membership file, .mmry-formation-<session id> in MMRY's temp folder, and exit 0 with no output
# when there is none: before any library is sourced, before the payload is read, before any further
# script starts.
#
# What this file proves, one block per test case on the ticket:
#   1. No membership file: exit 0, no output, and no further process. COUNTED, not inferred: every
#      program the command could start is reachable only through a recording shim on PATH, and a
#      Windows job object counts every process the OS created (helpers/count-processes.ps1).
#   2. A membership file for this session: messages are still delivered on prompt, tool use, idle
#      and session start, through the registered command strings themselves.
#   3. The gate resolves the same temp folder as formation-state.sh, the file that writes the
#      membership file, under every TMPDIR shape, and on Windows Codex's cmd launcher as well.
#   4. The gate is present and identical in hooks/hooks.json and hooks/codex-hooks.json.
#
# Every assertion runs the command lifted out of the shipped hooks file, never a copy of it, so the
# file and the test cannot drift apart.

setup() {
    PLUGIN_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    HANDLERS="${PLUGIN_ROOT}/hooks-handlers"
    HOOKS="${MMRY_GATE_HOOKS_DIR:-${PLUGIN_ROOT}/hooks}"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$TMPDIR"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_FORMATION_MODE MMRY_JQ
    SID="gate-$$-${BATS_TEST_NUMBER}"
    # The real absolute paths of the shells, taken BEFORE any test narrows PATH.
    REAL_SH="$(command -v sh)"
    REAL_BASH="$(command -v bash)"
}

teardown() {
    [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null || true
}

# The canonical first step, spelled once here so that a change to it is a deliberate change to the
# test as well. Test 4 compares every registration to these AND, within each hooks file, to each
# other.
#
# SINCE #31844 THE TWO HOSTS' GATES DIFFER BY DESIGN. Claude Code (2.1.285 and later) gives every hook
# the session's id in CLAUDE_CODE_SESSION_ID, so its gate looks for THIS session's membership file
# only, and a member elsewhere on the machine no longer opens it; with no usable id it falls back to
# the scan. That variable and nothing else: formation-check.sh keys the session by the payload's
# session_id, which is the id Claude Code puts there. CLAUDE_SESSION_ID is not set by the host, and a
# value inherited from elsewhere can differ from the payload (macos-hook-payload.bats sets one),
# which would shut a real member out. Codex gives no such variable, so its gate is the scan. Both
# scans skip the locks and markers that share the prefix (GATE_SKIP), which used to open the gate
# on their own.
#
# Each opens with the membership test and closes with the exit taken when nothing matched. Neither
# contains & | < > ^ at all: a Claude Code that ran hooks through cmd.exe (it did until early 2026,
# which is why this file once forbade single quotes) would split the line at any of them.
CLAUDE_GATE_OPEN='sh -c '"'"'d="${TMPDIR:-/tmp}"; s="${CLAUDE_CODE_SESSION_ID:-}"; '
CODEX_GATE_OPEN='sh -c '"'"'for f in "${TMPDIR:-/tmp}"/.mmry-formation-*; do '
GATE_SKIP='case "${f##*/}" in .mmry-formation-cs-*) continue ;; .mmry-formation-poll-*) continue ;; .mmry-formation-handover-*) continue ;; .mmry-formation-renewed-*) continue ;; esac; '
GATE_CLOSE='; exit 0'"'"

# Every formation-check `command` in a hooks file, one per line, as "Event<TAB>command".
_registrations() {
    node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const [ev, gs] of Object.entries(d.hooks))
            for (const g of gs) for (const h of g.hooks)
                if (h.command.includes("formation-check")) console.log(ev + "\t" + h.command);
    ' "$1"
}

# The registered command for one event in one hooks file ("" if none).
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

# A directory holding ONLY recording stand-ins for the two shells. With PATH set to it alone, any
# program the command starts by name is either recorded here or fails as "not found", which writes
# to stderr and is caught by the no-output assertion. Nothing can start unseen.
_shim_dir() {
    local dir="${BATS_TEST_TMPDIR}/shim" name real
    mkdir -p "$dir"
    for name in sh bash; do
        real="$REAL_SH"; [[ "$name" == "bash" ]] && real="$REAL_BASH"
        printf '#!%s\nprintf "%%s\\n" "%s $*" >> "$GATE_LOG"\nexec "%s" "$@"\n' "$real" "$name" "$real" > "${dir}/${name}"
        chmod +x "${dir}/${name}"
    done
    printf '%s' "$dir"
}

# A fake HOME whose installed guard only says it was reached, and a fake Codex plugin root whose
# launcher does the same. They stand for "everything after the gate".
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

# Run a registered command the way the host does: its string handed to a shell's -c, the hook
# payload on stdin. The outer shell is the host's and is not counted; everything it starts is.
_run_counted() {
    local cmd="$1"
    GATE_LOG="${BATS_TEST_TMPDIR}/launches.log"
    : > "$GATE_LOG"
    printf '%s' "{\"session_id\":\"${SID}\",\"hook_event_name\":\"UserPromptSubmit\"}" > "${BATS_TEST_TMPDIR}/payload.json"
    run env PATH="$(_shim_dir)" HOME="$FAKE_HOME" TMPDIR="$TMPDIR" GATE_LOG="$GATE_LOG" \
        "$REAL_BASH" -c "$cmd" < "${BATS_TEST_TMPDIR}/payload.json"
    LAUNCHES="$(grep -c . "$GATE_LOG" || true)"
}

# =============================================================================================
# TEST CASE 4: THE GATE IS PRESENT AND IDENTICAL IN BOTH HOOKS FILES
# =============================================================================================

@test "gate 4: every formation-check registration in BOTH hooks files opens with the same membership gate" {
    local f ev cmd n_claude=0 n_codex=0 first open
    for f in hooks.json codex-hooks.json; do
        first=""
        open="$CODEX_GATE_OPEN"; [[ "$f" == hooks.json ]] && open="$CLAUDE_GATE_OPEN"
        while IFS=$'\t' read -r ev cmd; do
            cmd="${cmd%$'\r'}"
            [[ -n "$cmd" ]] || continue
            [[ "$cmd" == "$open"* ]] || {
                echo "${f} ${ev} does not START with the membership gate:"; echo "  $cmd"; return 1; }
            [[ "$cmd" == *"$GATE_CLOSE"* ]] || {
                echo "${f} ${ev} does not end the gate with its exit when no file matched:"; echo "  $cmd"; return 1; }
            [[ "$cmd" == *"$GATE_SKIP"* ]] || {
                echo "${f} ${ev} does not skip the locks and markers that share the prefix:"; echo "  $cmd"; return 1; }
            # Identical to each other within the file, not merely each similar to the constants.
            [[ -z "$first" ]] && first="$cmd"
            [[ "$cmd" == "$first" ]] || { echo "${f} ${ev} gate differs:"; echo "  $cmd"; echo "  $first"; return 1; }
            # Nothing cmd.exe would act on, so an older Windows runner cannot split the line.
            [[ "$cmd" != *[\&\|\<\>^]* ]] || { echo "${f} ${ev} carries a cmd.exe operator: $cmd"; return 1; }
            if [[ "$f" == "hooks.json" ]]; then n_claude=$((n_claude + 1)); else n_codex=$((n_codex + 1)); fi
        done < <(_registrations "${HOOKS}/${f}")
    done
    echo "gated registrations: hooks.json ${n_claude}, codex-hooks.json ${n_codex}" >&3
    # SAMPLE SIZE: Claude Code registers the check on four events, Codex on three. A file that lost
    # a registration, or a parse that found none, must not pass by having nothing to compare.
    (( n_claude == 4 )) || { echo "hooks.json: ${n_claude} formation-check registrations, expected 4"; return 1; }
    (( n_codex == 3 )) || { echo "codex-hooks.json: ${n_codex} formation-check registrations, expected 3"; return 1; }
}

@test "gate 4: the Windows Codex launcher's first step for formation-check is the same membership check" {
    # commandWindows is run by PowerShell, or cmd where PowerShell is absent, so it cannot carry the
    # sh line. The launcher it names carries the same check in cmd: same file name pattern, same
    # folder rule, and it comes before ANY line that can start a program.
    local cmdf="${HANDLERS}/codex-hook.cmd" code gate_line first_prog
    code="$(tr -d '\r' < "$cmdf" | grep -n -v -i '^[[:space:]]*rem\b' | grep -v -i '^[0-9]*:[[:space:]]*rem$')"
    gate_line="$(grep -m1 'if /i not "%~1"=="formation-check" goto :after_formation_gate' <<< "$code" | cut -d: -f1)"
    first_prog="$(grep -m1 -i -E 'where\.exe|reg\.exe|findstr|bash\.exe|codex-hook\.sh' <<< "$code" | cut -d: -f1)"
    [[ -n "$gate_line" && -n "$first_prog" ]] || { echo "gate line [$gate_line] or first program line [$first_prog] not found"; return 1; }
    (( gate_line < first_prog )) || { echo "the gate (line $gate_line) comes after a program is started (line $first_prog)"; return 1; }
    grep -q '%MMRY_GATE_DIR%\\.mmry-formation-\*' <<< "$code" || { echo "the TMPDIR branch does not look for .mmry-formation-*"; return 1; }
    grep -q '%TEMP%\\.mmry-formation-\*' <<< "$code" || { echo "the /tmp branch does not look in the user temp folder"; return 1; }
    grep -q 'if not defined MMRY_MEMBER exit /b 0' <<< "$code" || { echo "no exit when no membership file is found"; return 1; }
}

# =============================================================================================
# TEST CASE 1: NO MEMBERSHIP FILE: EXIT 0, NO OUTPUT, NO FURTHER PROCESS (MEASURED)
# =============================================================================================

@test "gate 1 claude: no membership file, every registration exits 0, prints nothing, starts only its own sh" {
    _standins
    local ev cmd
    for ev in SessionStart UserPromptSubmit PostToolUse Stop; do
        cmd="$(_command_for "${HOOKS}/hooks.json" "$ev")"
        [[ -n "$cmd" ]] || { echo "no $ev registration"; return 1; }
        _run_counted "$cmd"
        echo "$ev: status $status, output [${output}], launches ${LAUNCHES}: $(tr '\n' '|' < "$GATE_LOG")" >&3
        [[ "$status" -eq 0 ]] || { echo "$ev exited $status"; return 1; }
        [[ -z "$output" ]] || { echo "$ev printed: $output"; return 1; }
        # Exactly one launch, and it is the registration's own `sh -c`. No bash, no guard, nothing.
        [[ "$LAUNCHES" -eq 1 ]] || { echo "$ev started ${LAUNCHES} programs: $(cat "$GATE_LOG")"; return 1; }
        grep -q '^sh -c d=' "$GATE_LOG" || { echo "$ev: the one launch was not the gate: $(cat "$GATE_LOG")"; return 1; }
    done
}

@test "gate 1 codex: no membership file, every registration exits 0, prints nothing, starts only its own sh" {
    _standins
    local ev cmd
    for ev in SessionStart UserPromptSubmit PostToolUse; do
        cmd="$(_codex_command_for "$ev" "$FAKE_ROOT")"
        [[ -n "$cmd" ]] || { echo "no $ev registration"; return 1; }
        _run_counted "$cmd"
        echo "$ev: status $status, output [${output}], launches ${LAUNCHES}: $(tr '\n' '|' < "$GATE_LOG")" >&3
        [[ "$status" -eq 0 ]] || { echo "$ev exited $status"; return 1; }
        [[ -z "$output" ]] || { echo "$ev printed: $output"; return 1; }
        [[ "$LAUNCHES" -eq 1 ]] || { echo "$ev started ${LAUNCHES} programs: $(cat "$GATE_LOG")"; return 1; }
    done
}

@test "gate 1 control: the same count sees the launches when a membership file exists" {
    # POSITIVE CONTROL. Without it, "one launch" could be a shim that records nothing past the first.
    # Same commands, same shims, one membership file: the guard and the launcher are reached, and the
    # log shows the second shell that reached them.
    _standins
    printf '4242\n' > "${TMPDIR}/.mmry-formation-${SID}"
    _run_counted "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)"
    echo "claude: launches ${LAUNCHES}: $(tr '\n' '|' < "$GATE_LOG") output [$output]" >&3
    [[ "$output" == *"GUARD-REACHED formation-check"* ]] || { echo "the guard was not reached: $output"; return 1; }
    [[ "$LAUNCHES" -eq 2 ]] || { echo "expected the gate and one bash, got ${LAUNCHES}: $(cat "$GATE_LOG")"; return 1; }
    _run_counted "$(_codex_command_for UserPromptSubmit "$FAKE_ROOT")"
    echo "codex: launches ${LAUNCHES}: $(tr '\n' '|' < "$GATE_LOG") output [$output]" >&3
    [[ "$output" == *"LAUNCHER-REACHED formation-check"* ]] || { echo "the launcher was not reached: $output"; return 1; }
    [[ "$LAUNCHES" -eq 2 ]] || { echo "expected the gate and one sh, got ${LAUNCHES}: $(cat "$GATE_LOG")"; return 1; }
}

@test "gate 1: a delivery lock DIRECTORY is not a membership file and does not open the gate" {
    # .mmry-formation-cs-<sid> and .mmry-formation-poll-<sid> share the prefix and are directories.
    # A lock left behind must not make every later session pay for the check.
    _standins
    mkdir -p "${TMPDIR}/.mmry-formation-cs-${SID}" "${TMPDIR}/.mmry-formation-poll-${SID}"
    _run_counted "$(_command_for "${HOOKS}/hooks.json" PostToolUse)"
    [[ "$status" -eq 0 && -z "$output" && "$LAUNCHES" -eq 1 ]] || {
        echo "a lock directory opened the gate: status $status, output [$output], launches $LAUNCHES"; return 1; }
}

@test "gate 1 windows: the OS counts one process for a gated command and more for an ungated one" {
    # The PATH shims above see every program started BY NAME. This sees every process the operating
    # system created, by any route: the command is started suspended inside a job object, so nothing
    # can escape the count. Windows only, because that is where the counter is.
    _is_windows || skip "Windows only: counts processes with a Windows job object"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    _standins
    local counter; counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    local winbash; winbash="$(cygpath -w "$REAL_BASH")"
    _count() {
        # The registered command goes in a file the outer bash reads as its script, which is what
        # -c does with a string, without a second layer of Windows command-line quoting.
        printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/registered.sh"
        env HOME="$FAKE_HOME" TMPDIR="$TMPDIR" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$counter" \
            -CommandLine "\"${winbash}\" \"$(cygpath -w "${BATS_TEST_TMPDIR}/registered.sh")\"" < /dev/null | tr -d '\r'
    }
    # The baseline is the host's shell starting ONE sh that does nothing. On Windows one launch is
    # two processes, because Cygwin's fork and exec are each a process, so the honest comparison is
    # one launch against one launch, not against a shell that starts nothing.
    local base gated open
    base="$(_count "sh -c 'exit 0'")"
    gated="$(_count "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)")"
    printf '4242\n' > "${TMPDIR}/.mmry-formation-${SID}"
    open="$(_count "$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)")"
    echo "host shell starting one no-op sh: $base | no membership: $gated | membership: $(tr '\n' ' ' <<< "$open")" >&3
    local nb ng no
    nb="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$base")"
    ng="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$gated")"
    no="$(sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' <<< "$open")"
    [[ -n "$nb" && -n "$ng" && -n "$no" ]] || { echo "the counter did not answer"; return 1; }
    # The host's shell, plus the registration's own sh. Nothing else.
    (( ng == nb )) || { echo "no membership: $ng processes against $nb for one no-op sh"; return 1; }
    (( no > ng )) || { echo "control: with membership the count did not rise ($no vs $ng)"; return 1; }
    [[ "$gated" == *"EXIT=0"* ]] || { echo "gated command did not exit 0: $gated"; return 1; }
}

@test "gate 1 windows codex: the cmd launcher starts nothing at all when there is no membership file" {
    _is_windows || skip "Windows only: needs cmd.exe"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    _standins
    local counter; counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    local cmdline; cmdline="$(_codex_windows_command_for PostToolUse)"
    cmdline="${cmdline//\$\{PLUGIN_ROOT\}/$(cygpath -w "$FAKE_ROOT")}"
    [[ "$cmdline" == "cmd /d /c "* ]] || { echo "unexpected commandWindows: $cmdline"; return 1; }
    local wtmp; wtmp="$(cygpath -w "$TMPDIR")"
    _countw() {
        env TMPDIR="$wtmp" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$counter" \
            -CommandLine "$1" < /dev/null | tr -d '\r'
    }
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
    # cmd itself and nothing else: no where.exe, no reg.exe, no bash.
    (( ng == nb )) || { echo "no membership: the launcher made $ng processes, bare cmd makes $nb"; return 1; }
    (( no > ng )) || { echo "control: with membership the count did not rise ($no vs $ng)"; return 1; }
    [[ "$gated" == *"EXIT=0"* ]] || { echo "gated launcher did not exit 0: $gated"; return 1; }
}

# =============================================================================================
# TEST CASE 3: SAME TEMP FOLDER AS formation-state.sh
# =============================================================================================
# formation-state.sh is the file that WRITES the membership file, so it is the authority. Each case
# writes membership with it, under a given TMPDIR, and asks the registered gate whether it sees it;
# then clears it with it, and asks again. Run on every CI platform: Windows here, Linux and macOS in
# .github/workflows/test.yml.

_state() { env TMPDIR="$1" bash "${HANDLERS}/formation-state.sh" "${@:2}"; }

_gate_sees() {
    # $1 = TMPDIR value to give the command, or the word UNSET. Echoes OPEN or CLOSED per file.
    local tmp="$1" f ev cmd out
    for f in claude codex; do
        if [[ "$f" == claude ]]; then cmd="$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)"
        else cmd="$(_codex_command_for UserPromptSubmit "$FAKE_ROOT")"; fi
        if [[ "$tmp" == UNSET ]]; then
            out="$(env -u TMPDIR HOME="$FAKE_HOME" "$REAL_BASH" -c "$cmd" < /dev/null 2>&1)"
        else
            out="$(env TMPDIR="$tmp" HOME="$FAKE_HOME" "$REAL_BASH" -c "$cmd" < /dev/null 2>&1)"
        fi
        case "$out" in *REACHED*) printf '%s=OPEN ' "$f" ;; *) printf '%s=CLOSED ' "$f" ;; esac
    done
}

@test "gate 3: under every TMPDIR shape, the gate opens on formation-state.sh's file and closes when it clears" {
    _standins
    local base="${BATS_TEST_TMPDIR}/shapes" t got
    mkdir -p "$base/plain" "$base/with space" "$base/trailing"
    local shapes=("$base/plain" "$base/with space" "$base/trailing/")
    for t in "${shapes[@]}"; do
        got="$(_gate_sees "$t")"
        [[ "$got" == "claude=CLOSED codex=CLOSED " ]] || { echo "[$t] before join: $got"; return 1; }
        _state "$t" set 4242 "$SID"
        got="$(_gate_sees "$t")"
        echo "[$t] joined: $got" >&3
        [[ "$got" == "claude=OPEN codex=OPEN " ]] || { echo "[$t] after formation-state.sh set: $got"; return 1; }
        _state "$t" clear "$SID"
        got="$(_gate_sees "$t")"
        [[ "$got" == "claude=CLOSED codex=CLOSED " ]] || { echo "[$t] after formation-state.sh clear: $got"; return 1; }
    done
}

@test "gate 3: with TMPDIR empty or unset, both resolve /tmp" {
    # formation-state.sh's rule is ${TMPDIR:-/tmp}, so an EMPTY TMPDIR means /tmp too. The gate must
    # not read empty as "the current folder".
    _standins
    local sid="gate-unset-$$-${RANDOM}"
    env -u TMPDIR bash "${HANDLERS}/formation-state.sh" set 4242 "$sid"
    [[ -f "/tmp/.mmry-formation-${sid}" ]] || { echo "formation-state.sh did not write to /tmp with TMPDIR unset"; return 1; }
    local got_unset got_empty
    got_unset="$(_gate_sees UNSET)"
    got_empty="$(_gate_sees "")"
    env -u TMPDIR bash "${HANDLERS}/formation-state.sh" clear "$sid"
    echo "unset: $got_unset | empty: $got_empty" >&3
    [[ "$got_unset" == "claude=OPEN codex=OPEN " ]] || { echo "TMPDIR unset: $got_unset"; return 1; }
    [[ "$got_empty" == "claude=OPEN codex=OPEN " ]] || { echo "TMPDIR empty: $got_empty"; return 1; }
    # /tmp on a working machine can hold other sessions' membership files, so the CLOSED half of this
    # case is not asserted here; the shapes test above proves it on folders this test owns.
}

@test "gate 3 windows codex: the cmd launcher sees formation-state.sh's file in the same folder" {
    _is_windows || skip "Windows only: needs cmd.exe"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    _standins
    local cmdline; cmdline="$(_codex_windows_command_for UserPromptSubmit)"
    cmdline="${cmdline//\$\{PLUGIN_ROOT\}/$(cygpath -w "$FAKE_ROOT")}"
    _ps() { env "$@" powershell.exe -NoProfile -Command "$cmdline" < /dev/null 2>&1 | tr -d '\r'; }

    # TMPDIR set, as a Git Bash path. Cygwin hands it to the Windows side converted, measured, so
    # the launcher must see what formation-state.sh wrote.
    local t="${BATS_TEST_TMPDIR}/win tmp"; mkdir -p "$t"
    [[ "$(_ps TMPDIR="$t")" != *REACHED* ]] || { echo "TMPDIR set, no membership: the launcher went on"; return 1; }
    _state "$t" set 4242 "$SID"
    [[ "$(_ps TMPDIR="$t")" == *"LAUNCHER-REACHED formation-check"* ]] || { echo "TMPDIR set: membership written by formation-state.sh not seen"; return 1; }
    _state "$t" clear "$SID"
    [[ "$(_ps TMPDIR="$t")" != *REACHED* ]] || { echo "TMPDIR set: still open after clear"; return 1; }

    # TMPDIR unset: Git Bash's /tmp is the usertemp mount. Proven the same folder as the launcher's
    # by a marker bash writes in /tmp and cmd finds in %TEMP%, so this does not depend on /tmp
    # holding no other session's membership.
    local mark=".mmry-gate-probe-$$-${RANDOM}"
    : > "/tmp/${mark}"
    local seen
    printf '@echo off\r\nif exist "%%TEMP%%\\%s" (echo SAME) else (echo DIFFERENT)\r\n' "$mark" > "${BATS_TEST_TMPDIR}/probe.cmd"
    seen="$(env -u TMPDIR cmd //d //c "$(cygpath -w "${BATS_TEST_TMPDIR}/probe.cmd")" < /dev/null | tr -d '\r')"
    rm -f "/tmp/${mark}"
    echo "TMPDIR unset: /tmp vs %TEMP%: $seen" >&3
    [[ "$seen" == *SAME* ]] || { echo "Git Bash /tmp is not the launcher's %TEMP%: $seen"; return 1; }

    # And with TMPDIR unset each of the three folders the launcher reads is honoured, and none of
    # them when all are empty.
    local a="${BATS_TEST_TMPDIR}/ta" b="${BATS_TEST_TMPDIR}/tb" c="${BATS_TEST_TMPDIR}/tc"
    mkdir -p "$a" "$b" "$c/Temp"
    local wa wb wc; wa="$(cygpath -w "$a")"; wb="$(cygpath -w "$b")"; wc="$(cygpath -w "$c")"
    _psu() { env -u TMPDIR TEMP="$wa" TMP="$wb" LOCALAPPDATA="$wc" powershell.exe -NoProfile -Command "$cmdline" < /dev/null 2>&1 | tr -d '\r'; }
    [[ "$(_psu)" != *REACHED* ]] || { echo "TMPDIR unset, all three folders empty: the launcher went on"; return 1; }
    local d
    for d in "$a" "$b" "$c/Temp"; do
        printf '4242\n' > "${d}/.mmry-formation-${SID}"
        [[ "$(_psu)" == *REACHED* ]] || { echo "TMPDIR unset: membership in $d not seen"; return 1; }
        rm -f "${d}/.mmry-formation-${SID}"
    done
}

# =============================================================================================
# TEST CASE 2: WITH A MEMBERSHIP FILE, DELIVERY STILL WORKS ON EVERY EVENT
# =============================================================================================
# Through the registered command, end to end: the gate, the guard or launcher, the real handler
# copied where the host installs it, the real payload on stdin, and a fake service answering with
# two messages. Prompt, tool use, idle and session start on Claude Code; Codex registers no idle
# check (it has no asyncRewake), so its three.

BODY='[{"senderRole":"lead","senderSessionID":"lead-1","senderUserID":1,"content":"GATE-MSG-ONE review the claim","sentDate":"2026-10-07T01:00:00"},{"senderRole":"member","senderSessionID":"dev-2","senderUserID":2,"content":"GATE-MSG-TWO take the slot","sentDate":"2026-10-07T01:05:00"}]'

_fake_service() {
    local dir="${BATS_TEST_TMPDIR}/svc"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
answer="${GATE_BODY:-}"
case "$url" in *since=) ;; *since=*) answer='[]' ;; esac
[[ -n "$out" ]] && printf '%s' "$answer" > "$out"
printf '200'
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

_install_claude() {
    FAKE_HOME="${BATS_TEST_TMPDIR}/installed-home"
    mkdir -p "${FAKE_HOME}/.claude/mmry"
    cp -R "$HANDLERS" "${FAKE_HOME}/.claude/mmry/"
}

_deliver() {
    # $1 = registered command, $2 = event name. Leaves $status and $output.
    local svc; svc="$(_fake_service)"
    printf '%s' "{\"session_id\":\"${SID}\",\"hook_event_name\":\"$2\"}" > "${BATS_TEST_TMPDIR}/payload.json"
    run env HOME="$FAKE_HOME" TMPDIR="$TMPDIR" PATH="${svc}:${PATH}" GATE_BODY="$BODY" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_IDLE_POLL_SECONDS=3 MMRY_IDLE_POLL_INTERVAL=1 \
        "$REAL_BASH" -c "$1" < "${BATS_TEST_TMPDIR}/payload.json"
}

@test "gate 2 claude: with membership, prompt, tool use, idle and session start all still deliver" {
    _install_claude
    local ev want cmd
    for ev in UserPromptSubmit PostToolUse Stop SessionStart; do
        bash "${HANDLERS}/formation-state.sh" clear "$SID"
        TMPDIR="$TMPDIR" bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
        cmd="$(_command_for "${HOOKS}/hooks.json" "$ev")"
        _deliver "$cmd" "$ev"
        echo "$ev: status $status, $(printf '%s' "$output" | grep -o 'GATE-MSG-[A-Z]*' | sort | tr '\n' ' ')" >&3
        # The route each event delivers on: additionalContext and exit 0 for prompt and start, stderr
        # and exit 2 for tool use and idle (formation-check.sh's header has why).
        case "$ev" in
            UserPromptSubmit|SessionStart) want=0
                [[ "$output" == *"\"hookEventName\":\"${ev}\""* || "$output" == *"\"hookEventName\": \"${ev}\""* ]] || {
                    echo "$ev: not additionalContext for $ev: $output"; return 1; } ;;
            *) want=2 ;;
        esac
        [[ "$status" -eq "$want" ]] || { echo "$ev exited $status, expected $want: $output"; return 1; }
        [[ "$output" == *GATE-MSG-ONE* && "$output" == *GATE-MSG-TWO* ]] || { echo "$ev did not deliver both messages: $output"; return 1; }
    done
}

@test "gate 2 codex: with membership, prompt, tool use and session start all still deliver" {
    local ev cmd
    FAKE_HOME="${BATS_TEST_TMPDIR}/codex-home"
    mkdir -p "$FAKE_HOME/.codex"
    for ev in UserPromptSubmit PostToolUse SessionStart; do
        bash "${HANDLERS}/formation-state.sh" clear "$SID"
        TMPDIR="$TMPDIR" bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
        cmd="$(_codex_command_for "$ev" "$PLUGIN_ROOT")"
        _deliver "$cmd" "$ev"
        echo "$ev: status $status, $(printf '%s' "$output" | grep -o 'GATE-MSG-[A-Z]*' | sort | tr '\n' ' ')" >&3
        # Codex delivers every one of these as additionalContext with exit 0.
        [[ "$status" -eq 0 ]] || { echo "$ev exited $status: $output"; return 1; }
        [[ "$output" == *hookSpecificOutput* ]] || { echo "$ev: not additionalContext: $output"; return 1; }
        [[ "$output" == *GATE-MSG-ONE* && "$output" == *GATE-MSG-TWO* ]] || { echo "$ev did not deliver both messages: $output"; return 1; }
    done
}

@test "gate 2 control: the same delivery run, with no membership file, delivers nothing" {
    # Without this, "delivered" above could come from something other than membership.
    _install_claude
    bash "${HANDLERS}/formation-state.sh" clear "$SID"
    _deliver "$(_command_for "${HOOKS}/hooks.json" PostToolUse)" PostToolUse
    [[ "$status" -eq 0 && -z "$output" ]] || { echo "no membership, yet: status $status, output [$output]"; return 1; }
}

@test "gate 1 windows: the Claude Code line also runs whole under cmd.exe, an older client's runner" {
    # Claude Code runs hooks with Git Bash today. Until early 2026 it ran them through cmd.exe, which
    # splits a line at & | < > ^; the gate carries none, and its ~ is expanded by sh, not the host.
    # The line is run as cmd would run it: as a line of a batch file.
    _is_windows || skip "Windows only: needs cmd.exe"
    _standins
    local cmd; cmd="$(_command_for "${HOOKS}/hooks.json" UserPromptSubmit)"
    printf '@echo off\r\n%s\r\n' "$cmd" > "${BATS_TEST_TMPDIR}/line.cmd"
    local w; w="$(cygpath -w "${BATS_TEST_TMPDIR}/line.cmd")"
    run env HOME="$FAKE_HOME" TMPDIR="$TMPDIR" cmd //d //c "$w" < /dev/null
    [[ "$status" -eq 0 && -z "$output" ]] || { echo "no membership under cmd: status $status, output [$output]"; return 1; }
    printf '4242\n' > "${TMPDIR}/.mmry-formation-${SID}"
    run env HOME="$FAKE_HOME" TMPDIR="$TMPDIR" cmd //d //c "$w" < /dev/null
    [[ "$output" == *"GUARD-REACHED formation-check"* ]] || { echo "membership under cmd did not reach the guard: $output"; return 1; }
}
