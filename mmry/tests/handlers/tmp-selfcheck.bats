#!/usr/bin/env bats
# tmp-selfcheck.bats - a session that cannot save its working files says so, plainly (#33468).
#
# THE DEFECT. The plugin keeps small working files in the computer's temporary folder (the startup
# memories, the Foundation set and its markers, the Formation watch). For four days in October that
# folder could not be written on one of our own machines and nothing said so: memories stopped
# loading at start, idle members stopped hearing their lead, and each looked like a different
# problem. A customer would have no way to tell what was wrong.
#
# WHAT THIS PROVES, on Claude Code and on Codex, with the folder the plugin resolves (TMPDIR, else
# /tmp) read-only, missing, and a file:
#   R1  the start tells the person, in the approved sentence word for word, naming that folder;
#   R2  two prompts after that start produce no second warning;
#   R3  a writable folder gives no warning, and leaves no marker behind;
#   R4  the failed start still exits 0, with one JSON object and no error lines (what 33628 builds on).
# The existing session-start.bats and codex-start-budget.bats are run unchanged beside this file.
#
# A read-only folder cannot be made where a write still succeeds (Windows, or root): those cases
# skip, naming why, rather than pass. The missing and file cases run everywhere.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    export CLAUDE_SESSION_ID="tmp-check-session"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    unset MMRY_HOST CODEX_HOME || true
    CX="$TEST_TMPDIR/codexhome"
    mkdir -p "$CX"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key-12345"}' > "$CX/mmry-config.json"
    RO="$TEST_TMPDIR/readonly"
    MISSING="$TEST_TMPDIR/no-such-folder"
    AFILE="$TEST_TMPDIR/a-file"
}

# Every permission a test changed is put back before the folder is removed.
teardown() {
    chmod -R u+rwx "$RO" 2>/dev/null || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

# _bad_folder KIND: sets BAD to a folder of that kind, or skips the test when it cannot be made.
_bad_folder() {
    case "$1" in
        readonly)
            mkdir -p "$RO"
            chmod 555 "$RO"
            if { : > "$RO/.probe"; } 2>/dev/null; then
                rm -f "$RO/.probe"
                chmod u+rwx "$RO"
                skip "a folder cannot be made read-only here (Windows, or running as root): writes still succeed"
            fi
            BAD="$RO" ;;
        missing) BAD="$MISSING" ;;
        file)    printf 'not a folder' > "$AFILE"; BAD="$AFILE" ;;
    esac
}

# The approved sentence (cmo-mmry, then Eric 2026-11-17), word for word. $1 the folder, $2 the host.
_sentence() {
    printf 'MMRY AI could not load your memories for this conversation because it cannot save its working files in %s. Make sure that folder exists and you can write to it, then restart %s. Until then, Formation messages may not reach this conversation. Your saved memories are safe.' "$1" "$2"
}

_payload() { printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$1" "$TEST_TMPDIR"; }

# The Claude Code start, run as the hook runs it. Sets OUT (stdout), ERR (stderr) and RC.
_cc_start() {
    local errf="$TEST_TMPDIR/start.err"
    OUT="$(env TMPDIR="$1" bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" < <(_payload tmp-check-session) 2>"$errf")" && RC=0 || RC=$?
    ERR="$(cat "$errf")"
}

# The Codex start, run the way Codex runs it on macOS and Linux (the registered command, by sh).
_cx_start() {
    local cmd errf="$TEST_TMPDIR/start.err"
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$PLUGIN_ROOT/hooks/codex-hooks.json")"
    OUT="$(env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$PLUGIN_ROOT" TMPDIR="$1" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$(_payload tmp-check-codex)" "$cmd" "$TEST_TMPDIR" 2>"$errf")" && RC=0 || RC=$?
    ERR="$(cat "$errf")"
}

_context() { printf '%s' "$OUT" | grep '^{' | tail -1 | jq -r '.hookSpecificOutput.additionalContext // empty'; }

# Every prompt hook the host registers, run once as the host would run it, in the same folder.
# $1 cc|cx, $2 the folder. Appends what they print to PROMPTS.
_prompts_once() {
    local cmd cmds
    if [[ "$1" == cc ]]; then
        cmds="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$PLUGIN_ROOT/hooks/hooks.json")"
    else
        cmds="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$PLUGIN_ROOT/hooks/codex-hooks.json")"
    fi
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if [[ "$1" == cc ]]; then
            PROMPTS+="$(env TMPDIR="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c "$cmd" \
                < <(printf '{"session_id":"tmp-check-session","hook_event_name":"UserPromptSubmit","prompt":"hello"}') 2>&1 || true)"
        else
            PROMPTS+="$(env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$PLUGIN_ROOT" TMPDIR="$2" \
                bash -c 'printf "%s" "$1" | sh -c "$2"' _ '{"session_id":"tmp-check-codex","hook_event_name":"UserPromptSubmit","prompt":"hello"}' "$cmd" 2>&1 || true)"
        fi
    done <<< "$cmds"
}

# ---------------------------------------------------------------------------------------------
# R1: THE WARNING, NAMING THE FOLDER, ON BOTH HOSTS
# ---------------------------------------------------------------------------------------------

@test "R1 Claude Code: a read-only temporary folder is named in the approved sentence" {
    _bad_folder readonly
    _cc_start "$BAD"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$BAD" "Claude Code")"
}

@test "R1 Claude Code: a missing temporary folder is named in the approved sentence" {
    _bad_folder missing
    _cc_start "$BAD"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$BAD" "Claude Code")"
}

@test "R1 Claude Code: a temporary folder that is a file is named in the approved sentence" {
    _bad_folder file
    _cc_start "$BAD"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$BAD" "Claude Code")"
}

@test "R1 Codex: a read-only temporary folder is named in the approved sentence" {
    _bad_folder readonly
    _cx_start "$BAD"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$BAD" "Codex")"
}

@test "R1 Codex: a missing temporary folder is named in the approved sentence" {
    _bad_folder missing
    _cx_start "$BAD"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$BAD" "Codex")"
}

@test "R1 Codex: a temporary folder that is a file is named in the approved sentence" {
    _bad_folder file
    _cx_start "$BAD"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$BAD" "Codex")"
}

@test "R1: the assistant is told to say the sentence to the person, word for word" {
    _bad_folder missing
    _cc_start "$BAD"
    run _context
    assert_output --partial 'Tell the user this sentence, word for word: "MMRY AI could not load your memories'
}

@test "R1: a folder name with a backslash and a quote still gives a parseable answer naming it" {
    local odd="$TEST_TMPDIR/odd\\na\"me"
    _cc_start "$odd"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --partial "$(_sentence "$odd" "Claude Code")"
}

# ---------------------------------------------------------------------------------------------
# R4: ONE CHECK, EXIT 0, ONE LOG LINE, NO STACK OF ERROR LINES
# ---------------------------------------------------------------------------------------------

@test "R4: the failed start is one JSON object with no error lines on either host, and the cause is recorded in one line" {
    _bad_folder missing
    _cc_start "$BAD"
    [ "$RC" -eq 0 ]
    [ -z "$ERR" ] || { echo "stderr: $ERR"; return 1; }
    [ "$(printf '%s\n' "$OUT" | grep -c '^{')" -eq 1 ]
    printf '%s' "$OUT" | jq -e . >/dev/null
    local rec="$HOME/.claude/mmry/mmry-tmp-unwritable.log"
    [ -f "$rec" ]
    [ "$(wc -l < "$rec" | tr -d ' ')" -eq 1 ]
    [[ "$(cat "$rec")" == *"$BAD"* ]] || return 1
    _cx_start "$BAD"
    [ "$RC" -eq 0 ]
    [ -z "$ERR" ] || { echo "stderr: $ERR"; return 1; }
    [ "$(printf '%s\n' "$OUT" | grep -c '^{')" -eq 1 ]
}

@test "R4: a failed start makes no request to the service and writes nothing in the folder" {
    _bad_folder readonly
    _cc_start "$BAD"
    [ ! -s "$TEST_TMPDIR/curl-log.txt" ]
    [ -z "$(ls -A "$RO")" ]
}

# ---------------------------------------------------------------------------------------------
# R2: TWO PROMPTS AFTER THE START GIVE NO SECOND WARNING
# ---------------------------------------------------------------------------------------------

@test "R2 Claude Code: two prompts after the start give no second warning" {
    _bad_folder missing
    _cc_start "$BAD"
    run _context
    assert_output --partial "cannot save its working files"
    PROMPTS=""
    _prompts_once cc "$BAD"
    _prompts_once cc "$BAD"
    [[ "$PROMPTS" != *"cannot save its working files"* ]] || { echo "prompts said: $PROMPTS"; return 1; }
}

@test "R2 Codex: two prompts after the start give no second warning" {
    _bad_folder missing
    _cx_start "$BAD"
    run _context
    assert_output --partial "cannot save its working files"
    PROMPTS=""
    _prompts_once cx "$BAD"
    _prompts_once cx "$BAD"
    [[ "$PROMPTS" != *"cannot save its working files"* ]] || { echo "prompts said: $PROMPTS"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# R3: A FOLDER THAT WORKS GIVES NO WARNING, AND LEAVES NOTHING BEHIND
# ---------------------------------------------------------------------------------------------

@test "R3 Claude Code: a writable folder gives no warning, loads the memories and leaves no marker" {
    local good="$TEST_TMPDIR/good"; mkdir -p "$good"
    _cc_start "$good"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    [[ "$OUT" != *"cannot save its working files"* ]] || return 1
    [ -z "$(ls -A "$good" | grep -i 'tmpcheck')" ]
    [ ! -e "$HOME/.claude/mmry/mmry-tmp-unwritable.log" ]
}

@test "R3 Codex: a writable folder gives no warning, loads the memories and leaves no marker" {
    local good="$TEST_TMPDIR/good"; mkdir -p "$good"
    _cx_start "$good"
    [ "$RC" -eq 0 ]
    run _context
    assert_output --regexp '^MMRY AI loaded 1 memories\. Read them now: '
    [[ "$OUT" != *"cannot save its working files"* ]] || return 1
    # The marker is removed as the start ends, after its output is closed: give that a moment.
    local i=0
    while [ -n "$(ls -A "$good" | grep -i 'tmpcheck')" ] && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    [ -z "$(ls -A "$good" | grep -i 'tmpcheck')" ]
    [ ! -e "$CX/mmry/mmry-tmp-unwritable.log" ]
}

@test "R3: a folder that works again clears yesterday's record" {
    local good="$TEST_TMPDIR/good"; mkdir -p "$good"
    printf 'yesterday\tsomewhere\n' > "$HOME/.claude/mmry/mmry-tmp-unwritable.log"
    _cc_start "$good"
    [ ! -e "$HOME/.claude/mmry/mmry-tmp-unwritable.log" ]
}
