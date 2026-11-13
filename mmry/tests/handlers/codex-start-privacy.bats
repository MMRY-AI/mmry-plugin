#!/usr/bin/env bats
# codex-start-privacy.bats - the files that carry a Codex session start to its first prompt can be read
# and changed only by the person who owns the conversation, and nothing another user of the machine
# plants is ever delivered (#33231).
#
# THE DEFECT, new requirement 1 of the independent QA of #33062 (security and privacy reviewers,
# 2026-11-01). The late marker (.mmry-codex-late.<key>.<sid>), the hand-off
# (.mmry-codex-start.<key>.<sid>.<pid>.{out,ready,pid,claim}), the saved payload and the two fixed-name
# logs were written to ${TMPDIR:-/tmp} with the default umask and predictable names. On a shared Linux
# /tmp another local user could read them, plant a .ready/.out pair to inject text into a conversation,
# or put a symlink at a path the hook would write through.
#
# THE RULE (DD-182): those files live in a per-user folder, <CODEX_HOME, else $HOME/.codex>/mmry-handoff,
# created with owner-only permissions (mkdir -m 700) only when it is absent, and used only when it is a
# directory, not a link, and owned by the caller. The reader also requires the marker, .out and .ready
# to be regular files, not links, owned by the caller. Everything written there is 600 (umask 077).
# The sh gate in codex-hooks.json and the cmd gate in codex-hook.cmd glob the new folder with no
# process. The memories arrive at the start or with the first prompt, exactly once, as before.
#
# WHERE EACH CHECK CAN RUN. Modes, ownership and symlinks are not observable under Git Bash on Windows
# (chmod and ln -s are not POSIX there), so those cases run on the Linux and macOS CI legs and SKIP on
# Windows, saying so. "Planted by another user" needs passwordless sudo to chown a folder to another
# user; the GitHub runners have it, and the case skips, saying so, where it is absent. The location,
# gate and exactly-once cases run everywhere.

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    unset MMRY_HOST CODEX_HOME || true
    # The umask a shared Linux machine commonly has. The plugin must not depend on the caller's.
    umask 022
    CX="$TEST_TMPDIR/codexhome"
    mkdir -p "$CX"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key-12345"}' > "$CX/mmry-config.json"
    KEY="$(FND_CONFIG_OVERRIDE="$CX/mmry-config.json" fnd_acct)"
    [[ "$KEY" =~ ^[0-9a-f]{16}$ ]]
    ROOT="$(_installed_plugin_root)"
    SS_CMD="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/codex-hooks.json")"
    FP_CMD="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("codex-first-prompt"))][0].command // empty' "$ROOT/hooks/codex-hooks.json")"
    [[ -n "$SS_CMD" && -n "$FP_CMD" ]]
    STARTS=0
    # The per-user folder the plugin keeps the hand-off in (DD-182).
    HAND="$CX/mmry-handoff"
}

teardown() {
    local i=0 n
    while (( i < 240 )); do
        n=0
        [[ -f "$TEST_TMPDIR/su-finished-list" ]] && n="$(wc -l < "$TEST_TMPDIR/su-finished-list" | tr -d ' ')"
        [[ "${n:-0}" -ge "${STARTS:-0}" ]] && break
        sleep 0.25; i=$((i + 1))
    done
    _wait_drains 60 || true
    local p
    for p in $(cat "$TEST_TMPDIR/slow-pids" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    # A folder a test handed to another user is taken back so the scratch folder can go.
    if [[ -n "${FOREIGN:-}" && -e "$FOREIGN" ]]; then sudo -n chown -R "$(id -u)" "$FOREIGN" 2>/dev/null || true; fi
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_modes_observable() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 1 ;; esac; return 0; }
_mode() { case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac; }
_can_chown_away() { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && id -u nobody >/dev/null 2>&1; }

# True once every drain a start recorded (.pid in the hand-off folder, or the old temp name) has ended.
_wait_drains() {
    local i=0 f p alive
    while (( i < $1 * 4 )); do
        alive=0
        for f in "$HAND"/.mmry-codex-start.*.pid "$TMPDIR"/.mmry-codex-start.*.pid; do
            [[ -f "$f" ]] || continue
            p="$(cat "$f" 2>/dev/null | tr -d '\r\n')"
            [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && alive=1
        done
        (( alive == 0 )) && return 0
        sleep 0.25; i=$((i + 1))
    done
    return 1
}

_installed_plugin_root() {
    local root="$TEST_TMPDIR/plugins/cache/mmry-plugin/mmry/test"
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/setup" "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_ROOT/hooks" "$root/"
    cp "$PLUGIN_ROOT/release-files.txt" "$root/"
    cat > "$root/hooks-handlers/self-update.sh" <<EOF
#!/usr/bin/env bash
echo done >> "$TEST_TMPDIR/su-finished-list"
EOF
    printf '%s' "$root"
}

_slow_curl() {
    local dir="$TEST_TMPDIR/slow-bin"
    mkdir -p "$dir"
    cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"$1"*)
        echo \$\$ >> "$TEST_TMPDIR/slow-pids"
        sleep $2
        exec "$TEST_TMPDIR/mock-bin/curl" "\$@" ;;
esac
exec "$TEST_TMPDIR/mock-bin/curl" "\$@"
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
}

# The Codex session start, by the registered command, by sh, for the account in $CX. Sets JSON.
#   _start <sid> [plugin root]
_start() {
    local payload stamp="" root="${2:-$ROOT}"
    payload="{\"session_id\":\"$1\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$TEST_TMPDIR\"}"
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) printf -v stamp '%(%H:%M:%S)T.00' -1 ;; esac
    STARTS=$((STARTS + 1))
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$root" MMRY_CODEX_HOOK_STARTED="$stamp" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$SS_CMD" "$TEST_TMPDIR"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
}
# The first prompt, by the registered gate line, by sh. Sets JSON.
#   _prompt <sid> [plugin root]
_prompt() {
    local payload root="${2:-$ROOT}"
    payload="{\"session_id\":\"$1\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\",\"cwd\":\"$TEST_TMPDIR\"}"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$root" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$FP_CMD" "$TEST_TMPDIR"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
}
_context() { printf '%s' "$JSON" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
# True once every start this test made has finished its deferred work (the probe self-update is its
# last step), or after $1 seconds: a check of what a start left behind must not race its housekeeping.
_wait_starts() {
    local i=0 n
    while (( i < $1 * 4 )); do
        n=0
        [[ -f "$TEST_TMPDIR/su-finished-list" ]] && n="$(wc -l < "$TEST_TMPDIR/su-finished-list" | tr -d ' ')"
        (( ${n:-0} >= STARTS )) && return 0
        sleep 0.25; i=$((i + 1))
    done
    return 1
}
_listing() { ls -a "$1" 2>/dev/null | grep -v '^\.\.\?$' | tr '\n' ' '; }
_old_names_in_tmp() { ls -a "$TMPDIR" 2>/dev/null | grep -E '^\.mmry-codex-(late|start)|^mmry-codex-(session-start|first-prompt)\.log$' | tr '\n' ' '; }

# A planted hand-off for $KEY and sid $1 under folder $2, as if a start with pid 4242 had finished.
_plant() {
    printf '4242\n' > "$2/.mmry-codex-late.${KEY}.$1"
    printf '%s' "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"PLANTED-BY-ANOTHER-USER Read them now: /x/mmry-memories.${KEY}.$1.md\"}}" > "$2/.mmry-codex-start.${KEY}.$1.4242.out"
    : > "$2/.mmry-codex-start.${KEY}.$1.4242.ready"
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 1: the files can be read and changed only by their owner. Every file and folder the
# start creates has owner-only permissions. (Linux and macOS CI.)
# ---------------------------------------------------------------------------------------------
@test "#33231: every file and folder a late Codex start creates for its hand-off is owner-only: the folder 700, the marker, hand-off, pid, payload and logs 600" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _start priv-1
    assert_success
    run _context
    assert_output --partial "could not load your memories in time"
    [ -d "$HAND" ] || { echo "no per-user hand-off folder at $HAND; temp folder holds: $(_old_names_in_tmp)"; return 1; }
    [[ "$(_mode "$HAND")" == "700" ]] || { echo "the hand-off folder is mode $(_mode "$HAND"), not 700"; return 1; }
    _wait_drains 30 || { echo "the start's work did not finish"; return 1; }
    local f n=0 bad=""
    for f in "$HAND"/.mmry-codex-late.* "$HAND"/.mmry-codex-start.* "$HAND"/mmry-codex-session-start.log; do
        [[ -e "$f" ]] || continue
        n=$((n + 1))
        [[ "$(_mode "$f")" == "600" ]] || bad+="${f##*/}=$(_mode "$f") "
    done
    (( n >= 4 )) || { echo "expected the marker, the hand-off (.out, .ready, .pid) and the log; found $n: $(_listing "$HAND")"; return 1; }
    [[ -z "$bad" ]] || { echo "not owner-only: $bad"; return 1; }
    # The first prompt's own files (its claim while it runs, and its log) are owner-only too.
    _prompt priv-1
    assert_success
    [[ -f "$HAND/mmry-codex-first-prompt.log" ]] || { echo "no first-prompt log in the folder: $(_listing "$HAND")"; return 1; }
    [[ "$(_mode "$HAND/mmry-codex-first-prompt.log")" == "600" ]] || { echo "the first-prompt log is $(_mode "$HAND/mmry-codex-first-prompt.log")"; return 1; }
    echo "# $n hand-off files checked, all 600; folder 700" >&3
}

@test "#33231: the marker, hand-off, saved payload and both logs are kept in the per-user folder, and nothing of them is written to the shared temp folder" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _start priv-2
    assert_success
    [ -f "$HAND/.mmry-codex-late.${KEY}.priv-2" ] || { echo "no late marker in $HAND: $(_listing "$HAND"); temp folder: $(_old_names_in_tmp)"; return 1; }
    [ -f "$HAND/mmry-codex-session-start.log" ] || { echo "the session-start log is not in the folder: $(_listing "$HAND")"; return 1; }
    _wait_drains 30 || { echo "the start's work did not finish"; return 1; }
    ls "$HAND"/.mmry-codex-start.${KEY}.priv-2.*.ready >/dev/null 2>&1 || { echo "no hand-off in the folder: $(_listing "$HAND")"; return 1; }
    _prompt priv-2
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    [ -f "$HAND/mmry-codex-first-prompt.log" ] || { echo "the first-prompt log is not in the folder"; return 1; }
    local old; old="$(_old_names_in_tmp)"
    [ -z "$old" ] || { echo "written to the shared temp folder: $old"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENTS 2 AND 3: text supplied by another user is never delivered; a location that is a link, or
# belongs to another user, is refused and nothing is delivered from it.
# ---------------------------------------------------------------------------------------------
@test "#33231: a ready and out pair planted by another user (the folder theirs, world-writable) is refused: the first prompt delivers nothing from it, and the start writes nothing into it" {
    _modes_observable || skip "ownership is not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _can_chown_away || skip "planting as another user needs passwordless sudo and a 'nobody' user (the GitHub runners have both)"
    mkdir -p "$HAND"
    _plant planted-1 "$HAND"
    chmod 777 "$HAND"
    sudo -n chown -R nobody "$HAND"
    FOREIGN="$HAND"
    local before; before="$(ls -lA "$HAND" | tail -n +2)"
    _prompt planted-1
    assert_success
    [[ "$output" != *"PLANTED-BY-ANOTHER-USER"* ]] || { echo "another user's text was delivered: $output"; return 1; }
    [[ "$output" != *"Read them now"* ]] || { echo "a planted memories path was delivered: $output"; return 1; }
    [ -z "$JSON" ] || { echo "the first prompt said something from a folder that is not its owner's: $JSON"; return 1; }
    # And a start finds the folder is not its own: it arms nothing there and still answers in time.
    _start planted-2
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    local after; after="$(ls -lA "$HAND" | tail -n +2)"
    [[ "$after" == "$before" ]] || { echo "the start wrote into another user's folder: before [$before] after [$after]"; return 1; }
    _wait_starts 60 || true
    [ -z "$(_old_names_in_tmp)" ] || { echo "the start fell back to the shared temp folder: $(_old_names_in_tmp)"; return 1; }
}

@test "#33231: a hand-off folder that is a symlink is refused: nothing is delivered from the pair behind it, and the start writes nothing through it" {
    _modes_observable || skip "symlinks cannot be made as a plain user under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local elsewhere="$TEST_TMPDIR/elsewhere"
    (umask 077 && mkdir "$elsewhere")
    _plant link-1 "$elsewhere"
    ln -s "$elsewhere" "$HAND"
    local before; before="$(ls -lA "$elsewhere" | tail -n +2)"
    _prompt link-1
    assert_success
    [[ "$output" != *"PLANTED-BY-ANOTHER-USER"* ]] || { echo "text behind a symlinked folder was delivered: $output"; return 1; }
    [ -z "$JSON" ] || { echo "the first prompt said something through a link: $JSON"; return 1; }
    _start link-2
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    local after; after="$(ls -lA "$elsewhere" | tail -n +2)"
    [[ "$after" == "$before" ]] || { echo "the start wrote through the link: before [$before] after [$after]"; return 1; }
    [ -L "$HAND" ] || { echo "the link was replaced"; return 1; }
}

@test "#33231: a hand-off location that is not a directory (a plain file at its name) is refused on every platform: the start arms nothing, writes nothing beside it, answers in time with its session id, and the first prompt says nothing" {
    # The refused path exercised where symlinks and ownership cannot be made: a file squatting the name.
    printf 'squatter\n' > "$HAND"
    _start file-1
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    # The start still learned its session id from the payload (the hook drains stdin for it, so it must
    # be handed on privately even with no folder): no warning, and the memories file is named by it.
    refute_output --partial "could not be read from stdin"
    assert_output --partial "mmry-memories.${KEY}.file-1.md"
    [ -f "$HAND" ] && [[ "$(cat "$HAND")" == "squatter" ]] || { echo "the squatting file was replaced or removed"; return 1; }
    _wait_starts 60 || true
    [ -z "$(_old_names_in_tmp)" ] || { echo "the start wrote hand-off files to the shared temp folder: $(_old_names_in_tmp)"; return 1; }
    _prompt file-1
    assert_success
    [ -z "$JSON" ] || { echo "the first prompt said something with no folder: $JSON"; return 1; }
}

@test "#33231: a marker or hand-off file that is itself a link is refused, even inside the owner's own folder" {
    _modes_observable || skip "symlinks cannot be made as a plain user under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    (umask 077 && mkdir "$HAND")
    local elsewhere="$TEST_TMPDIR/elsewhere"
    (umask 077 && mkdir "$elsewhere")
    _plant flink-1 "$elsewhere"
    ln -s "$elsewhere/.mmry-codex-late.${KEY}.flink-1" "$HAND/.mmry-codex-late.${KEY}.flink-1"
    ln -s "$elsewhere/.mmry-codex-start.${KEY}.flink-1.4242.out" "$HAND/.mmry-codex-start.${KEY}.flink-1.4242.out"
    ln -s "$elsewhere/.mmry-codex-start.${KEY}.flink-1.4242.ready" "$HAND/.mmry-codex-start.${KEY}.flink-1.4242.ready"
    _prompt flink-1
    assert_success
    [[ "$output" != *"PLANTED-BY-ANOTHER-USER"* ]] || { echo "text behind a linked hand-off was delivered: $output"; return 1; }
    [[ "$output" != *"Read them now"* ]] || { echo "a linked memories path was delivered: $output"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# THE sh GATE follows the new location without starting a process.
# ---------------------------------------------------------------------------------------------
@test "#33231: the sh gate in codex-hooks.json opens for a marker in the per-user folder, stays shut with none, and no longer opens for one in the temp folder" {
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    mkdir -p "$TEST_TMPDIR/gate-tmp"
    run env PLUGIN_ROOT="$ROOT" CODEX_HOME="$CX" TMPDIR="$TEST_TMPDIR/gate-tmp" sh -c "$FP_CMD" </dev/null
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate let the hook run with nothing pending"; return 1; }
    # A marker in the OLD place (the shared temp folder) must not open it: nothing is read from there.
    : > "$TEST_TMPDIR/gate-tmp/.mmry-codex-late.${KEY}.gate-1"
    run env PLUGIN_ROOT="$ROOT" CODEX_HOME="$CX" TMPDIR="$TEST_TMPDIR/gate-tmp" sh -c "$FP_CMD" </dev/null
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate opened for a marker in the shared temp folder"; return 1; }
    # A marker in the per-user folder opens it.
    mkdir -p "$HAND"
    : > "$HAND/.mmry-codex-late.${KEY}.gate-1"
    run env PLUGIN_ROOT="$ROOT" CODEX_HOME="$CX" TMPDIR="$TEST_TMPDIR/gate-tmp" sh -c "$FP_CMD" </dev/null
    assert_success
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate stayed shut with a marker in the per-user folder"; return 1; }
    # With no CODEX_HOME the folder is under $HOME/.codex, the same default lib-codex-key.sh applies.
    rm -f "$TEST_TMPDIR/probe-ran"
    mkdir -p "$HOME/.codex/mmry-handoff"
    : > "$HOME/.codex/mmry-handoff/.mmry-codex-late.${KEY}.gate-2"
    run env -u CODEX_HOME PLUGIN_ROOT="$ROOT" HOME="$HOME" TMPDIR="$TEST_TMPDIR/gate-tmp" sh -c "$FP_CMD" </dev/null
    assert_success
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate stayed shut with a marker under \$HOME/.codex/mmry-handoff"; return 1; }
}

@test "#33231: the gate line is builtins only (no command substitution, pipe or external command before the exec), and names the same folder lib-codex-key.sh resolves" {
    [[ "$FP_CMD" != *'$('* && "$FP_CMD" != *'`'* && "$FP_CMD" != *'|'* ]] || { echo "the gate starts a process: $FP_CMD"; return 1; }
    [[ "$FP_CMD" == *'/mmry-handoff/.mmry-codex-late.*'* ]] || { echo "the gate does not look in the per-user folder: $FP_CMD"; return 1; }
    [[ "$FP_CMD" != *'TMPDIR'* ]] || { echo "the gate still looks in the temp folder: $FP_CMD"; return 1; }
    [[ "$FP_CMD" == *'${CODEX_HOME:-$HOME/.codex}'* ]] || { echo "the gate's folder rule is not CODEX_HOME, else \$HOME/.codex: $FP_CMD"; return 1; }
    # The library resolves the same folder for the same environment.
    local lib
    lib="$(env -u MMRY_CONFIG_FILE CODEX_HOME="$CX" bash -c 'source "$1/hooks-handlers/lib-codex-key.sh" && mmry_codex_private_dir_v && printf "%s" "$_MMRY_CODEX_DIR"' _ "$ROOT")"
    [[ "$lib" == "$CX/mmry-handoff" ]] || { echo "lib-codex-key.sh resolves '$lib', not $CX/mmry-handoff"; return 1; }
    lib="$(env -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$HOME" bash -c 'source "$1/hooks-handlers/lib-codex-key.sh" && mmry_codex_private_dir_v && printf "%s" "$_MMRY_CODEX_DIR"' _ "$ROOT")"
    [[ "$lib" == "$HOME/.codex/mmry-handoff" ]] || { echo "lib-codex-key.sh resolves '$lib' with no CODEX_HOME, not $HOME/.codex/mmry-handoff"; return 1; }
}

_count_sh_script() {
    # The processes a Windows job object sees when Git's sh runs script $1, into _N.
    local counter ws
    counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    ws="$(cygpath -w "$(command -v sh)")"
    CODEX_HOME="$CX" PLUGIN_ROOT="$ROOT" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$counter" \
        -CommandLine "\"$ws\" \"$(cygpath -w "$1")\"" < /dev/null > "$TEST_TMPDIR/count.txt" 2>&1 3>&- || true
    _N="$(tr -d '\r' < "$TEST_TMPDIR/count.txt" | sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p')"
    [[ "$_N" =~ ^[0-9]+$ ]] || { echo "the counter did not answer: $(cat "$TEST_TMPDIR/count.txt")"; return 1; }
}

@test "#33231 (Windows): the gate line, run by sh with nothing pending, starts the inner shell it names and nothing else (job-object count against a measured baseline)" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "Windows only: counts processes with a Windows job object" ;; esac
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    # The baseline: what Git's sh costs to run a script whose only line starts an inner `sh -c` that does
    # nothing. On Windows that inner shell is two processes (MSYS forks, then execs), measured: an empty
    # script is 1, `sh -c 'exit 0'` is 3. The registered line, verbatim, as a script's body, must cost
    # exactly the same: its own `sh -c` and nothing else.
    printf "sh -c 'exit 0'\n" > "$TEST_TMPDIR/base.sh"
    _count_sh_script "$TEST_TMPDIR/base.sh" || return 1
    local base="$_N"
    printf '%s\n' "$FP_CMD" > "$TEST_TMPDIR/gate.sh"
    _count_sh_script "$TEST_TMPDIR/gate.sh" || return 1
    echo "# gate line: $_N process(es) against a baseline of $base for a script that only starts sh -c" >&3
    (( _N <= base )) || { echo "the gate started $(( _N - base )) process(es) beyond its own sh -c"; return 1; }
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate let the hook run with nothing pending"; return 1; }
}

@test "#33231 (Windows): codex-hook.cmd opens for a marker in the per-user folder and stays shut with none" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "codex-hook.cmd runs only on Windows" ;; esac
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    local wcx; wcx="$(cygpath -w "$CX")"
    run env CODEX_HOME="$wcx" cmd //d //c "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")" codex-first-prompt </dev/null 3>&-
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "codex-hook.cmd started bash with nothing pending"; return 1; }
    mkdir -p "$HAND"
    : > "$HAND/.mmry-codex-late.${KEY}.wgate-1"
    run env CODEX_HOME="$wcx" cmd //d //c "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")" codex-first-prompt </dev/null 3>&-
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "codex-hook.cmd stayed shut with a marker in the per-user folder"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 4: the memories still arrive at the start or with the first prompt, exactly once.
# ---------------------------------------------------------------------------------------------
@test "#33231: a late start's memories come with the first prompt, exactly once: the second prompt says nothing and the folder is cleared of them" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _start once-1
    assert_success
    run _context
    assert_output --partial "will be delivered with the user's first message"
    _prompt once-1
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    assert_output --partial "were late to load"
    sleep 1
    local left; left="$(ls -a "$HAND" 2>/dev/null | grep -E "^\.mmry-codex-(late|start)\..*once-1" | tr '\n' ' ')"
    [ -z "$left" ] || { echo "left behind after delivery: $left"; return 1; }
    _prompt once-1
    assert_success
    [ -z "$JSON" ] || { echo "the second prompt delivered the startup memories again: $JSON"; return 1; }
}

@test "#33231: a start that delivers in time leaves nothing for the first prompt, which says nothing" {
    _start intime-1
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    _wait_drains 30 || true
    _prompt intime-1
    assert_success
    [ -z "$JSON" ] || { echo "the first prompt delivered after an in-time start: $JSON"; return 1; }
}

@test "#33231: the sweep clears half-day-old markers and hand-offs in the per-user folder and the old temp-folder names, and keeps fresh ones" {
    mkdir -p "$HAND"
    local f
    for f in ".mmry-codex-late.${KEY}.old-1" ".mmry-codex-start.${KEY}.old-1.77.out"; do
        printf 'old\n' > "$HAND/$f"; touch -t 202001010000 "$HAND/$f"
        printf 'old\n' > "$TMPDIR/$f"; touch -t 202001010000 "$TMPDIR/$f"
    done
    printf 'fresh\n' > "$HAND/.mmry-codex-late.${KEY}.fresh-1"
    _prompt nothing-late-here
    assert_success
    for f in ".mmry-codex-late.${KEY}.old-1" ".mmry-codex-start.${KEY}.old-1.77.out"; do
        [ ! -e "$HAND/$f" ] || { echo "the half-day-old $f was kept in the folder"; return 1; }
        [ ! -e "$TMPDIR/$f" ] || { echo "the half-day-old $f was kept in the temp folder"; return 1; }
    done
    [ -f "$HAND/.mmry-codex-late.${KEY}.fresh-1" ] || { echo "the fresh marker was swept"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# MUTATION CONTROLS (the ticket: removing the permission setting, and removing the link check, each
# turn a test red). A copy of the plugin with one thing removed, driven the same way: the checks above
# must then fail. Pure string replacement on the copy, as tests/mutation/run-33617-mutations.sh does.
# ---------------------------------------------------------------------------------------------
_rep_all() {
    # _rep_all <file> <from> <to>: every occurrence; fails when <from> is absent (a no-op mutation).
    # Prefix and suffix, not ${t/"$2"/"$3"}: the stock macOS bash 3.2 keeps the quotes around the
    # operands of that form literally (the macOS CI leg wrote a mutant whose quoting was broken), while
    # the quoted-variable pattern in ${t%%"$2"*} and ${t#*"$2"} is the form lib-foundation-key.sh runs
    # on bash 3.2 every prompt.
    local t pre post; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    while [[ "$t" == *"$2"* ]]; do pre="${t%%"$2"*}"; post="${t#*"$2"}"; t="${pre}${3}${post}"; done
    printf '%s' "$t" > "$1"
}
_mutant_root() {
    local root="$TEST_TMPDIR/mutant"
    mkdir -p "$root"
    cp -R "$ROOT/hooks-handlers" "$ROOT/setup" "$ROOT/.claude-plugin" "$ROOT/hooks" "$root/"
    cp "$ROOT/release-files.txt" "$root/"
    printf '%s' "$root"
}

@test "#33231 control: with the permission setting removed from a copy (umask 077 and mkdir -m 700), the folder and files are NOT owner-only (the check bites)" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local root f; root="$(_mutant_root)"
    for f in "$root"/hooks-handlers/*.sh; do _rep_all "$f" $'\numask 077' $'\n: umask-removed' || true; done
    _rep_all "$root/hooks-handlers/lib-codex-key.sh" 'mkdir -m 700' 'mkdir' || { echo "no 'mkdir -m 700' to remove: the mutation is a no-op"; return 1; }
    grep -q '^umask 077' "$ROOT/hooks-handlers/codex-hook.sh" || { echo "codex-hook.sh sets no umask 077: the mutation is a no-op"; return 1; }
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _start mut-perm-1 "$root"
    assert_success
    [ -d "$HAND" ] || { echo "the mutant made no folder"; return 1; }
    [[ "$(_mode "$HAND")" != "700" ]] || { echo "the mutant's folder is still 700: the mode check would not notice the setting going"; return 1; }
    _wait_drains 30 || true
    local seen=0
    for f in "$HAND"/.mmry-codex-late.*; do
        [[ -f "$f" ]] || continue
        seen=1
        [[ "$(_mode "$f")" != "600" ]] || { echo "the mutant's marker is still 600"; return 1; }
    done
    (( seen == 1 )) || { echo "the mutant wrote no marker"; return 1; }
}

@test "#33231 control: with the link check removed from a copy, the pair behind a symlinked folder IS delivered (the link check bites)" {
    _modes_observable || skip "symlinks cannot be made as a plain user under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local root; root="$(_mutant_root)"
    _rep_all "$root/hooks-handlers/lib-codex-key.sh" '! -L "$d"' '-e "$d"' || { echo "no link check in lib-codex-key.sh to remove: the mutation is a no-op"; return 1; }
    _rep_all "$root/hooks-handlers/lib-codex-key.sh" '! -L "$1"' '-e "$1"' || { echo "no file link check in lib-codex-key.sh to remove: the mutation is a no-op"; return 1; }
    local elsewhere="$TEST_TMPDIR/elsewhere"
    (umask 077 && mkdir "$elsewhere")
    _plant mut-link-1 "$elsewhere"
    ln -s "$elsewhere" "$HAND"
    _prompt mut-link-1 "$root"
    assert_success
    [[ "$output" == *"PLANTED-BY-ANOTHER-USER"* ]] || { echo "the mutant still refused the symlinked folder: the link check is not what refuses it; output: $output"; return 1; }
}

@test "#33231 control: with the ownership check removed from a copy, the pair in another user's folder IS delivered (the ownership check bites)" {
    _modes_observable || skip "ownership is not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _can_chown_away || skip "planting as another user needs passwordless sudo and a 'nobody' user (the GitHub runners have both)"
    local root; root="$(_mutant_root)"
    _rep_all "$root/hooks-handlers/lib-codex-key.sh" '-O "$d"' '-e "$d"' || { echo "no ownership check in lib-codex-key.sh to remove: the mutation is a no-op"; return 1; }
    _rep_all "$root/hooks-handlers/lib-codex-key.sh" '-O "$1"' '-e "$1"' || { echo "no file ownership check in lib-codex-key.sh to remove: the mutation is a no-op"; return 1; }
    mkdir -p "$HAND"
    _plant mut-own-1 "$HAND"
    chmod 777 "$HAND"
    sudo -n chown -R nobody "$HAND"
    FOREIGN="$HAND"
    _prompt mut-own-1 "$root"
    assert_success
    [[ "$output" == *"PLANTED-BY-ANOTHER-USER"* ]] || { echo "the mutant still refused another user's folder: the ownership check is not what refuses it; output: $output"; return 1; }
}
