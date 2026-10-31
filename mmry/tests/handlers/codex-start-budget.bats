#!/usr/bin/env bats
# codex-start-budget.bats - the Codex session start fits Codex's time limit (#33062).
#
# THE DEFECT. Codex gives the SessionStart hook the number of seconds hooks/codex-hooks.json declares
# (30) and then cuts it off, and a hook that is cut off delivers nothing: the conversation started
# with no memories and no warning. On a slow Windows machine the step took 34 s to 75 s, nearly all
# of it the plugin's own helper steps (installing the handlers, the update check, registering the
# session) run BEFORE the memories were handed over. The service answered in a fraction of a second.
#
# WHAT THIS FILE PROVES, each against the command Codex really runs (taken from codex-hooks.json):
#   - the elapsed time of the whole Codex session start, first session after install and a later
#     one, is MEASURED and must be under the declared limit, with the memories delivered (R1);
#   - the memories are handed over before the update check, the session registration and the
#     handler install finish, and those still complete afterwards (R1, R4);
#   - when the start still cannot finish in its budget, the conversation is told that the memories
#     were not loaded, inside the limit, instead of starting silently without them (R2);
#   - Claude Code's session start is untouched: it still finishes all of that before it returns (R3).
#
# Elapsed time is measured with perl's Time::HiRes, which macOS, Linux and Git for Windows all ship;
# the stock macOS bash 3.2 has no sub-second clock of its own.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    unset MMRY_HOST CODEX_HOME || true
    CX="$TEST_TMPDIR/codexhome"
    mkdir -p "$CX"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key-12345"}' > "$CX/mmry-config.json"
    LIMIT="$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$PLUGIN_ROOT/hooks/codex-hooks.json")"
    [[ "$LIMIT" =~ ^[0-9]+$ ]]
    ROOT="$(_installed_plugin_root)"
}

# Nothing a test started may outlive it: the deferred work runs after the hook returns, so wait for
# the probe self-update, which is the last step, to finish (bounded), then stop any slow stand-in.
teardown() {
    _wait_for "$TEST_TMPDIR/su-finished" 60 || true
    local p
    for p in $(cat "$TEST_TMPDIR/slow-pids" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# _wait_for FILE SECONDS - true once FILE exists.
_wait_for() {
    local i=0
    while (( i < $2 * 4 )); do
        [[ -e "$1" ]] && return 0
        sleep 0.25; i=$((i + 1))
    done
    return 1
}

# A copy of the plugin where Codex installs one (no .git, so the first-session install, the version
# check and the mirror all run), with the update check replaced by a probe that records when it
# starts and finishes. MMRY_TEST_SU_SLEEP makes the probe slow, standing in for a slow network.
_installed_plugin_root() {
    local root="$CX/plugins/cache/mmry-plugin/mmry/test"
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/setup" "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_ROOT/hooks" "$root/"
    cp "$PLUGIN_ROOT/release-files.txt" "$root/"
    cat > "$root/hooks-handlers/self-update.sh" <<EOF
#!/usr/bin/env bash
: > "$TEST_TMPDIR/su-started"
sleep "\${MMRY_TEST_SU_SLEEP:-0}"
: > "$TEST_TMPDIR/su-finished"
EOF
    printf '%s' "$root"
}

# A curl that is slow for one endpoint: _slow_curl PATTERN SECONDS. It records start and finish, so
# a test can tell whether the hook waited for it, and its pid, so teardown can stop it.
_slow_curl() {
    local dir="$TEST_TMPDIR/slow-bin"
    mkdir -p "$dir"
    cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"$1"*)
        echo \$\$ >> "$TEST_TMPDIR/slow-pids"
        : > "$TEST_TMPDIR/slow-started"
        sleep $2
        "$TEST_TMPDIR/mock-bin/curl" "\$@"; rc=\$?
        : > "$TEST_TMPDIR/slow-finished"
        exit \$rc ;;
esac
exec "$TEST_TMPDIR/mock-bin/curl" "\$@"
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
}

# The Codex session start, run the way Codex runs it on macOS and Linux: the registered command
# from codex-hooks.json, by sh, with PLUGIN_ROOT set and the SessionStart payload on stdin. Its
# stdout and stderr both stay on the pipe `run` reads, so a step that kept either open after the
# hook said it was done would hold this up exactly as it would hold up Codex. Sets ELAPSED (seconds)
# and JSON (the hook's JSON line).
#
# ON WINDOWS Codex runs codex-hook.cmd instead, which stamps MMRY_CODEX_HOOK_STARTED with %TIME% as
# it starts, so the budget counts from Codex starting the hook. The .cmd itself cannot run here (Git's
# bash launcher puts its own curl ahead of the mock), so the stamp it would make is made at the
# moment the clock below starts. A test that needs a particular stamp sets LAUNCH_STAMP.
_codex_start() {
    local cmd payload t0 t1 stamp="${LAUNCH_STAMP:-}"
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/codex-hooks.json")"
    payload="{\"session_id\":\"budget-${1:-1}\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$TEST_TMPDIR\"}"
    if [[ -z "$stamp" ]]; then
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*) printf -v stamp '%(%H:%M:%S)T.00' -1 ;;
        esac
    fi
    t0="$(_now)"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$ROOT" MMRY_CODEX_HOOK_STARTED="$stamp" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$cmd" "$TEST_TMPDIR"
    t1="$(_now)"
    ELAPSED="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
    echo "# elapsed ${ELAPSED}s of a ${LIMIT}s limit" >&3
}

_within_limit() {
    awk -v e="$ELAPSED" -v l="${2:-$LIMIT}" 'BEGIN { exit !(e < l) }' || {
        echo "the Codex ${1:-session start} took ${ELAPSED}s; Codex cuts it off at ${2:-$LIMIT}s"
        return 1
    }
}

# The conversation's first prompt, run the way Codex runs it: the UserPromptSubmit entry of
# codex-hooks.json that delivers late startup memories, by sh, with the prompt payload on stdin.
# _codex_prompt SESSION-NUMBER. Sets ELAPSED, JSON and PLIMIT (that entry's declared timeout).
_codex_prompt() {
    local cmd payload t0 t1
    cmd="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("codex-first-prompt"))][0].command // empty' "$ROOT/hooks/codex-hooks.json")"
    PLIMIT="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("codex-first-prompt"))][0].timeout // empty' "$ROOT/hooks/codex-hooks.json")"
    [[ -n "$cmd" && "$PLIMIT" =~ ^[0-9]+$ ]] || {
        echo "codex-hooks.json registers no UserPromptSubmit hook that delivers late startup memories"
        return 1
    }
    payload="{\"session_id\":\"budget-${1:-1}\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\",\"cwd\":\"$TEST_TMPDIR\"}"
    t0="$(_now)"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$ROOT" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$cmd" "$TEST_TMPDIR"
    t1="$(_now)"
    ELAPSED="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
    PROMPT_OUT="$output"
    echo "# first prompt: elapsed ${ELAPSED}s of a ${PLIMIT}s limit" >&3
}

# What a failing first-prompt check needs to show: the hook's whole output (stdout and stderr), the
# late markers and hand-offs in the temp folder, and the handler's own log.
_prompt_diag() {
    local t="${TMPDIR:-/tmp}"
    echo "first-prompt hook output (stdout+stderr): ${PROMPT_OUT:-<none>}"
    echo "late files in $t: $(ls -a "$t" 2>/dev/null | grep -E '^\.mmry-codex-(late|start)' | tr '\n' ' ')"
    echo "handler log: $(tail -3 "$t/mmry-codex-first-prompt.log" 2>/dev/null | tr '\n' ' ')"
    echo "sh is: $(sh -c 'echo ${BASH_VERSION:-not bash}')"
}

_context() { printf '%s' "$JSON" | jq -r '.hookSpecificOutput.additionalContext // empty'; }

# ---------------------------------------------------------------------------------------------
# R1: THE TIME BUDGET, MEASURED
# ---------------------------------------------------------------------------------------------

@test "R1: the first Codex session after install hands over the startup memories within the Codex limit (measured)" {
    [ ! -d "$CX/mmry" ]
    _codex_start 1
    assert_success
    _within_limit
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
}

@test "R1: a later Codex session does too (measured)" {
    _codex_start 1
    _wait_for "$TEST_TMPDIR/su-finished" 60
    rm -f "$TEST_TMPDIR/su-started" "$TEST_TMPDIR/su-finished"
    _codex_start 2
    assert_success
    _within_limit
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
}

# ---------------------------------------------------------------------------------------------
# R1: THE MEMORIES FIRST, THE HOUSEKEEPING AFTER
# ---------------------------------------------------------------------------------------------

@test "R1: the memories are handed over before the plugin update check finishes, and the check still runs" {
    export MMRY_TEST_SU_SLEEP=8
    _codex_start 1
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\.'
    [ ! -e "$TEST_TMPDIR/su-finished" ] || {
        echo "the hook waited for the update check before Codex got the memories"
        return 1
    }
    _wait_for "$TEST_TMPDIR/su-finished" 60 || { echo "the update check never ran"; return 1; }
}

@test "R1/R4: the memories are handed over before the session is registered and the handlers installed, and both still happen" {
    _slow_curl "/api/sessions" 8
    _codex_start 7
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\.'
    [ ! -e "$TEST_TMPDIR/slow-finished" ] || {
        echo "the hook waited for the session registration before Codex got the memories"
        return 1
    }
    # And the housekeeping still completes: the session is registered under the payload's id, and
    # the first-session install puts the handlers and the host marker where the model runs them.
    _wait_for "$TEST_TMPDIR/su-finished" 60 || { echo "the deferred steps never finished"; return 1; }
    grep -q 'POST .*/api/sessions.*budget-7' "$TEST_TMPDIR/curl-log.txt"
    # Once each: the memories are fetched by one session-start.sh, not by a second run after the install.
    [ "$(grep -c 'GET .*/api/memories/startup' "$TEST_TMPDIR/curl-log.txt")" = "1" ]
    [ "$(grep -c 'POST .*/api/sessions' "$TEST_TMPDIR/curl-log.txt")" = "1" ]
    [ -f "$CX/mmry/hooks-handlers/save-memory.sh" ]
    grep -q '^codex$' "$CX/mmry/.mmry-host"
}

# ---------------------------------------------------------------------------------------------
# R1: A START THAT RUNS OUT OF TIME STILL GETS ITS MEMORIES, WITH THE FIRST PROMPT
# ---------------------------------------------------------------------------------------------
# Measured on a heavily loaded Windows machine (76 to 88 bash processes), the start took 23 to 32 s
# and the live spec got the out-of-time notice instead of the memories in 4 runs of 5. The memories
# are not lost when that happens: the work goes on after the hook returns, and Codex runs the
# UserPromptSubmit hooks before the model answers the first prompt. So the first prompt delivers them.

@test "R1: a start forced past its budget still hands the memories to the conversation with the first prompt" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 8
    _codex_start 3
    assert_success
    _within_limit
    # It returned at its budget, not when the late answer was finally collected for the first prompt.
    [ ! -e "$TEST_TMPDIR/slow-finished" ] || { echo "the session start waited for the late answer"; return 1; }
    run _context
    assert_output --partial "MMRY AI could not load your memories in time"
    assert_output --partial "first message"
    refute_output --partial "MMRY AI loaded"
    # The first prompt, sent at once, as `codex exec` does: it waits for the memories that are still
    # on their way and hands them over, inside its own declared limit, before the model answers.
    _codex_prompt 3
    assert_success
    _within_limit "first prompt" "$PLIMIT"
    printf '%s' "$JSON" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null || {
        echo "the first prompt's answer is not a UserPromptSubmit context Codex will accept: $JSON"
        _prompt_diag
        return 1
    }
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    # The file the conversation is told to read holds the memories.
    local f="${output##*Read them now: }"
    [ -s "$(cygpath -u "$f" 2>/dev/null || printf '%s' "$f")" ]
}

@test "R1: the late memories are handed over once, not on every prompt" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _codex_start 4
    _codex_prompt 4
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\.'
    _codex_prompt 4
    assert_success
    [ -z "$JSON" ] || { echo "the second prompt delivered the startup memories again: $JSON"; return 1; }
}

@test "R1: a start that finished in time leaves nothing for the first prompt to deliver" {
    _codex_start 5
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\.'
    _codex_prompt 5
    assert_success
    [ -z "$JSON" ] || { echo "the memories were delivered twice, at the start and with the first prompt: $JSON"; return 1; }
}

@test "R1: one conversation's late memories never reach another conversation" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _codex_start 6
    _codex_prompt 66
    assert_success
    [ -z "$JSON" ] || { echo "conversation 66 was handed conversation 6's startup memories: $JSON"; return 1; }
    # And the conversation they belong to still gets them.
    _codex_prompt 6
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\.'
}

@test "R2: when the memories still have not arrived by the first prompt's longest wait, the person is told they were not loaded" {
    # The work is still running, so it is the longest wait (shortened to 3 s here) that ends this one.
    export MMRY_CODEX_START_BUDGET=3 MMRY_CODEX_FIRST_PROMPT_BUDGET=3 MMRY_CODEX_FIRST_PROMPT_CEILING=3
    _slow_curl "/api/memories/startup" 40
    _codex_start 8
    _codex_prompt 8
    assert_success
    _within_limit "first prompt" "$PLIMIT"
    printf '%s' "$JSON" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    run _context
    assert_output --partial "were not loaded"
    assert_output --partial "tell the user"
    assert_output --partial "Load them now with the mmry_plugin memory_load tool before you answer"
    refute_output --partial "MMRY AI loaded"
}

@test "R2: on Windows the first prompt's budget counts from when codex-hook.cmd started" {
    # Same reason as the session start's: cmd.exe and Git's bash took seconds before this shell ran.
    # Launcher stamped 15 s ago, budget 25: the notice must come after about 10 s, not about 25 s.
    printf -v _probe '%(%H)T' -1 2>/dev/null || skip "bash $BASH_VERSION has no printf clock; codex-hook.cmd runs only on Windows, under Git's bash 5"
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 60
    _codex_start 9
    local now t
    printf -v now '%(%s)T' -1
    printf -v t '%(%H:%M:%S)T' $(( now - 15 ))
    export MMRY_CODEX_FIRST_PROMPT_BUDGET=25 MMRY_CODEX_FIRST_PROMPT_CEILING=25 MMRY_CODEX_HOOK_STARTED="${t#0}.50"
    _codex_prompt 9
    run _context
    assert_output --partial "were not loaded"
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 20) }' || {
        echo "the first prompt's notice took ${ELAPSED}s: the 15 s the launcher had already spent were not counted"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# FIX ROUND 2: WHAT A REAL CODEX ON A HEAVILY LOADED WINDOWS MACHINE SHOWED (#33062)
#
# Reproduced with a real Codex (0.165.0) at 157 to 177 bash processes, three runs of three missing:
#   - the first prompt waited a fixed 90 s and gave up, while the memories it was waiting for were
#     still being prepared; they were ready 142 to 163 s after it started, 50 to 70 s too late;
#   - Codex counts a hook's limit from when it spawns the hook, and codex-hook.cmd's clock starts only
#     when cmd.exe runs its first line. Codex spawns the prompt's eight hooks together and their cmd.exe
#     starts came about 2.7 s apart, so the first-prompt hook began 19 s into Codex's 120. Its wait and
#     exit ran past the limit and Codex dropped its answer: the conversation got no MMRY message at all.
# ---------------------------------------------------------------------------------------------

@test "R1: a start still working when the first prompt's fixed wait is up is waited for, and its memories delivered" {
    # The fixed wait is 3 s and the work takes about 12: the first prompt must see that the work is
    # still running and wait for it, not tell the person their memories were not loaded.
    export MMRY_CODEX_START_BUDGET=3 MMRY_CODEX_FIRST_PROMPT_BUDGET=3
    _slow_curl "/api/memories/startup" 12
    _codex_start 21
    run _context
    assert_output --partial "will be delivered with the user's first message"
    _codex_prompt 21
    assert_success
    _within_limit "first prompt" "$PLIMIT"
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: ' || { _prompt_diag; return 1; }
}

@test "R1/R2: the first prompt's longest wait leaves a minute of its declared limit for Codex to launch the hook" {
    # Its longest wait, counted from codex-hook.cmd's start, plus 60 s for Codex's launch of the hook
    # (19 s measured), must fit in the limit codex-hooks.json declares, or Codex drops the answer. The
    # launcher is said to have started 180 s ago and the work outlasts the wait (45 s), and still ends inside the teardown's wait for it.
    printf -v _probe '%(%H)T' -1 2>/dev/null || skip "bash $BASH_VERSION has no printf clock; codex-hook.cmd runs only on Windows, under Git's bash 5"
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 45
    _codex_start 22
    local now t ago=180
    printf -v now '%(%s)T' -1
    printf -v t '%(%H:%M:%S)T' $(( now - ago ))
    export MMRY_CODEX_HOOK_STARTED="${t#0}.50"
    _codex_prompt 22
    assert_success
    run _context
    assert_output --partial "were not loaded" || { _prompt_diag; return 1; }
    awk -v a="$ago" -v e="$ELAPSED" -v l="$PLIMIT" 'BEGIN { exit !(a + e + 60 <= l) }' || {
        echo "the first prompt answered ${ago}s + ${ELAPSED}s after codex-hook.cmd started: with a minute for Codex to launch it, that is past the ${PLIMIT}s Codex allows, and Codex drops a late answer"
        return 1
    }
}

@test "R2: a start whose work has stopped is not waited for: the person is told at once" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 30
    _codex_start 23
    local pf
    pf="$(ls "${TMPDIR:-/tmp}"/.mmry-codex-start.budget-23.*.pid 2>/dev/null | head -1)"
    [ -s "$pf" ] || { echo "the session start recorded no work for the first prompt to watch: $(ls -a "${TMPDIR:-/tmp}" | grep mmry-codex | tr '\n' ' ')"; return 1; }
    kill "$(cat "$pf")"
    _codex_prompt 23
    assert_success
    run _context
    assert_output --partial "were not loaded" || { _prompt_diag; return 1; }
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 30) }' || {
        echo "the first prompt waited ${ELAPSED}s for work that had already stopped"
        return 1
    }
}

@test "R1: a first prompt that comes before the session start has settled still gets the memories" {
    # Codex stops waiting for the session start at its own 30 s and runs the first prompt, whatever the
    # hook is doing. Measured at 112 to 177 bash processes, the hook got to its deadline within a
    # fraction of a second of that, and once Codex dropped its notice altogether. So the hand-off must
    # be armed from the start: here the first prompt comes while the start is still waiting for the
    # service, long before its deadline.
    local cmd payload
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/codex-hooks.json")"
    payload="{\"session_id\":\"budget-24\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$TEST_TMPDIR\"}"
    _slow_curl "/api/memories/startup" 10
    env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$ROOT" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$cmd" "$TEST_TMPDIR" \
        > "$TEST_TMPDIR/bg-start.out" 2>&1 3>&- &
    local bg=$!
    _wait_for "$TEST_TMPDIR/slow-started" 60 || { echo "the session start never reached the service"; return 1; }
    _codex_prompt 24
    wait "$bg" || true
    assert_success
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: ' || { _prompt_diag; return 1; }
}

@test "R1: a session start that starts no work leaves the first prompt nothing to wait for" {
    # The marker is armed before anything else; a way out that starts no work must settle it.
    rm -f "$ROOT/hooks-handlers/session-init.sh"
    _codex_start 25
    assert_success
    _codex_prompt 25
    assert_success
    [ -z "$JSON" ] || { echo "the first prompt said something about a start that did nothing: $JSON"; return 1; }
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 20) }' || {
        echo "the first prompt waited ${ELAPSED}s for a start that had started no work"
        return 1
    }
}

@test "R1: with no late start pending, the first-prompt hook starts no MMRY process at all (sh gate)" {
    # It runs on every prompt of every conversation, so the common case must cost one file lookup.
    local cmd
    cmd="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("codex-first-prompt"))][0].command // empty' "$ROOT/hooks/codex-hooks.json")"
    [ -n "$cmd" ]
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    run env PLUGIN_ROOT="$ROOT" TMPDIR="$TEST_TMPDIR/gate-tmp" sh -c "mkdir -p \"\$TMPDIR\" && $cmd" </dev/null
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate let the hook run with nothing pending"; return 1; }
    # And a pending late start opens it.
    : > "$TEST_TMPDIR/gate-tmp/.mmry-codex-late.x"
    run env PLUGIN_ROOT="$ROOT" TMPDIR="$TEST_TMPDIR/gate-tmp" sh -c "$cmd" </dev/null
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate stayed shut with a late start pending"; return 1; }
}

@test "R1: on Windows, with no late start pending, codex-hook.cmd exits before it looks for bash" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "codex-hook.cmd runs only on Windows" ;; esac
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    mkdir -p "$TEST_TMPDIR/gate-tmp"
    local wtmp; wtmp="$(cygpath -w "$TEST_TMPDIR/gate-tmp")"
    run env TMPDIR="$wtmp" cmd //d //c "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")" codex-first-prompt </dev/null 3>&-
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "codex-hook.cmd started bash with nothing pending"; return 1; }
    : > "$TEST_TMPDIR/gate-tmp/.mmry-codex-late.x"
    run env TMPDIR="$wtmp" cmd //d //c "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")" codex-first-prompt </dev/null 3>&-
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "codex-hook.cmd stayed shut with a late start pending"; return 1; }
}

@test "R1: on Windows, codex-hook.cmd delivers the late memories through the real codex-hook.sh" {
    # The way Codex runs it on Windows: cmd.exe, the launcher, Git's bash, and codex-hook.sh started by
    # its Windows path (C:\...\codex-hook.sh). A late start and its finished hand-off are waiting.
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "codex-hook.cmd runs only on Windows" ;; esac
    local g="$TEST_TMPDIR/gate-tmp" wtmp
    mkdir -p "$g"; wtmp="$(cygpath -w "$g")"
    printf '4242' > "$g/.mmry-codex-late.win-1"
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI loaded 3 memories. Read them now: C:\\x\\mmry-memories.md"}}' > "$g/.mmry-codex-start.win-1.4242.out"
    : > "$g/.mmry-codex-start.win-1.4242.ready"
    run bash -c 'printf "%s" "{\"session_id\":\"win-1\",\"prompt\":\"hi\"}" | env TMPDIR="$1" cmd //d //c "$2" codex-first-prompt 3>&-' _ "$wtmp" "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")"
    assert_success
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
    printf '%s' "$JSON" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null || {
        echo "codex-hook.cmd delivered nothing a UserPromptSubmit hook can carry: $output"
        return 1
    }
    run _context
    assert_output --regexp '^MMRY AI loaded 3 memories\. Read them now: '
    [ ! -e "$g/.mmry-codex-late.win-1" ] || { echo "the late marker was left behind"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# R2: OUT OF TIME IS SAID, NOT SILENT
# ---------------------------------------------------------------------------------------------

@test "R2: a session start forced past its budget says, inside the limit, that the memories are late and arriving with the first message" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 15
    _codex_start 1
    assert_success
    _within_limit
    # Valid JSON on the one channel Codex reads, so the notice is not discarded.
    printf '%s' "$JSON" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
    run _context
    assert_output --partial "MMRY AI could not load your memories in time"
    assert_output --partial "will be delivered with the user's first message"
    refute_output --partial "MMRY AI loaded"
}

@test "R2: the notice tells the assistant to load them itself, and tell the person, if they are not there by the first answer" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 15
    _codex_start 1
    run _context
    assert_output --partial "tell the user"
    # On Codex that is the memory_load tool; there is no slash command to type. The notice spells it
    # out rather than start a process after the budget, so it is held to what lib-host.sh says.
    local ref
    ref="$(env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" \
        bash -c 'source "$1/hooks-handlers/lib-host.sh" && mmry_host_command_ref load-memories' _ "$ROOT")"
    [ -n "$ref" ]
    assert_output --partial "load them with ${ref} before you answer"
}

@test "R2: on Windows the budget counts from when codex-hook.cmd started, not only from bash's start" {
    # codex-hook.cmd records %TIME% as it starts; on a loaded machine finding and starting Git's bash
    # took 4 to 7 s of Codex's 30 before codex-hook.sh could count anything. Here the launcher is
    # said to have started 15 s ago with a 25 s budget, so the notice must come after about 10 s,
    # not after about 25 s. printf's clock is bash 4.2+; the stock macOS bash never runs the .cmd.
    printf -v _probe '%(%H)T' -1 2>/dev/null || skip "bash $BASH_VERSION has no printf clock; codex-hook.cmd runs only on Windows, under Git's bash 5"
    local now t
    printf -v now '%(%s)T' -1
    printf -v t '%(%H:%M:%S)T' $(( now - 15 ))
    export MMRY_CODEX_START_BUDGET=25
    LAUNCH_STAMP="${t#0}.50"
    _slow_curl "/api/memories/startup" 30
    _codex_start 1
    assert_success
    run _context
    assert_output --partial "MMRY AI could not load your memories in time"
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 20) }' || {
        echo "the notice took ${ELAPSED}s: the 15 s the launcher had already spent were not counted"
        return 1
    }
}

@test "R2: a start that finishes in time carries no out-of-time notice" {
    _codex_start 1
    run _context
    refute_output --partial "could not load your memories in time"
}

# ---------------------------------------------------------------------------------------------
# R3: CLAUDE CODE IS UNCHANGED
# ---------------------------------------------------------------------------------------------

@test "R3 control: Claude Code's session start still finishes the update check before it returns" {
    export MMRY_TEST_SU_SLEEP=2
    local cmd payload
    mkdir -p "$HOME/.claude"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key-12345"}' > "$HOME/.claude/mmry-config.json"
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
    payload='{"session_id":"claude-1","hook_event_name":"SessionStart","source":"startup"}'
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CODEX_HOME -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CLAUDE_PLUGIN_ROOT="$ROOT" \
        bash -c 'printf "%s" "$1" | bash -c "$2"' _ "$payload" "$cmd"
    assert_success
    [ -e "$TEST_TMPDIR/su-finished" ]
    grep -q 'POST .*/api/sessions.*claude-1' "$TEST_TMPDIR/curl-log.txt"
    printf '%s\n' "$output" | grep '^{' | tail -1 | jq -e '.hookSpecificOutput.additionalContext | startswith("MMRY AI loaded 1 memories.")' >/dev/null
}
