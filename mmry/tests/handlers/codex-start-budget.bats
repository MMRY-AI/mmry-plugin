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
# Elapsed time is measured with EPOCHREALTIME where the shell has it and perl otherwise (the stock
# macOS bash 3.2 has no EPOCHREALTIME; macOS and Linux both ship perl).

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

_now() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then printf '%s' "${EPOCHREALTIME/,/.}"
    else perl -MTime::HiRes=time -e 'printf "%.3f", time'; fi
}

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
_codex_start() {
    local cmd payload t0 t1
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/codex-hooks.json")"
    payload="{\"session_id\":\"budget-${1:-1}\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$TEST_TMPDIR\"}"
    t0="$(_now)"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$ROOT" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$cmd" "$TEST_TMPDIR"
    t1="$(_now)"
    ELAPSED="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
    echo "# elapsed ${ELAPSED}s of a ${LIMIT}s limit" >&3
}

_within_limit() {
    awk -v e="$ELAPSED" -v l="$LIMIT" 'BEGIN { exit !(e < l) }' || {
        echo "the Codex session start took ${ELAPSED}s; Codex cuts it off at ${LIMIT}s"
        return 1
    }
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
    [ -f "$CX/mmry/hooks-handlers/save-memory.sh" ]
    grep -q '^codex$' "$CX/mmry/.mmry-host"
}

# ---------------------------------------------------------------------------------------------
# R2: OUT OF TIME IS SAID, NOT SILENT
# ---------------------------------------------------------------------------------------------

@test "R2: a session start forced past its budget tells the person the memories were not loaded, inside the limit" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 15
    _codex_start 1
    assert_success
    _within_limit
    # Valid JSON on the one channel Codex reads, so the notice is not discarded.
    printf '%s' "$JSON" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
    run _context
    assert_output --partial "MMRY AI could not load your memories in time"
    assert_output --partial "this conversation started without them"
    refute_output --partial "MMRY AI loaded"
}

@test "R2: the notice tells the assistant how the person can load them now" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 15
    _codex_start 1
    run _context
    assert_output --partial "Tell the user"
    # On Codex that is the memory_load tool; there is no slash command to type.
    assert_output --partial "memory_load"
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
