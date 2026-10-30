#!/usr/bin/env bats
# session-start-live.bats - J-011@claude-code, live (#33030).
#
# THE JOURNEY. A subscriber starts a new Claude Code session and their memories load on their own:
# the account's startup memories, its Foundation memories among them, reach the session, and the
# assistant is told to read them. handlers/session-start.bats proves the handler against a mocked
# service. This file proves the journey against the real service (Integration, never production):
#
#   1. A Foundation memory with a marker unique to this run is planted in the test account (A), and
#      another in a second account (B).
#   2. A session is started through the REAL entry point, the SessionStart command that
#      hooks/hooks.json registers, run the way Claude Code runs it: by a shell, with
#      CLAUDE_PLUGIN_ROOT set and the SessionStart payload on stdin. Nothing below it is replaced.
#   3. What the session was handed is read back: the hook's JSON, the memories file it names, and
#      the Foundation copy the per-prompt hook restates.
#
# Each check fails if the plugin delivers nothing (no JSON, no file) or another account's memories
# (account B's key sits in this machine's Codex config, ~/.codex/mmry-config.json, where a plugin
# reading the wrong credential would find it). tests/mutation/run-33030-mutations.sh shows both.
#
# Run: MMRY_INTEGRATION_API_KEY=... MMRY_INTEGRATION_OTHER_API_KEY=... \
#        mmry/tests/libs/bats-core/bin/bats mmry/tests/integration/session-start-live.bats
# Everything runs in a private HOME and TMPDIR (setup_suite.bash and BATS_FILE_TMPDIR); the
# machine's real ~/.claude, plugin cache and temporary folder are never read or written.

load '../libs/bats-support/load'
load '../libs/bats-assert/load'
load '../helpers/live-journey'

setup_file() {
    export PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
    export LIVE_SPEC_NAME="session-start-live.bats"
    live_require_accounts || return 1
    export LIVE_JQ LIVE_URL

    local S="$BATS_FILE_TMPDIR"
    mkdir -p "$S/state" "$S/home" "$S/tmp" "$S/work"
    live_plant_both "$S/state" || return 1

    # The private machine: account A configured for Claude Code where setup writes it, and account
    # B configured for Codex beside it - the other product's credential on the same machine.
    live_write_config "$S/home/.claude/mmry-config.json" "$MMRY_INTEGRATION_API_KEY"
    live_write_config "$S/home/.codex/mmry-config.json" "$MMRY_INTEGRATION_OTHER_API_KEY"

    # The command Claude Code runs at SessionStart, taken from hooks.json rather than retyped, so
    # a change to the registration is what gets tested.
    local cmd
    cmd="$("$LIVE_JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")"
    printf '%s' "$cmd" > "$S/state/command"
    [[ "$cmd" == *session-init.sh* ]] || { echo "hooks.json SessionStart[0] is not session-init.sh: $cmd" >&2; return 1; }

    local sid="j011-live-$$-${RANDOM}"
    local payload
    payload="$("$LIVE_JQ" -cn --arg s "$sid" --arg c "$S/work" \
        '{session_id:$s,transcript_path:"",cwd:$c,hook_event_name:"SessionStart",source:"startup"}')"

    # MMRY_NO_SELF_UPDATE: the session must run the code under test. Self-update would replace a
    # copy without .git (the mutation runner's) with the released plugin.
    ( cd "$S/work" && printf '%s' "$payload" | live_timeout 120 env \
        -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u MMRY_HOST -u CODEX_HOME \
        HOME="$S/home" TMPDIR="$S/tmp" MMRY_TMPDIR="$S/tmp" TEMP="$S/tmp" TMP="$S/tmp" \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" MMRY_NO_SELF_UPDATE=1 \
        MMRY_CONFIG_FILE= MMRY_API_URL= MMRY_API_KEY= MMRY_AUTH_METHOD= \
        bash -c "$cmd" ) > "$S/state/hook.out" 2> "$S/state/hook.err" || true

    # What the account should have been given: the service's own answer for the same directory.
    ( cd "$S/work" && live_startup_ids "$MMRY_INTEGRATION_API_KEY" "$(pwd)" ) > "$S/state/expected-ids" || return 1
}

teardown_file() {
    live_resolve_jq >/dev/null 2>&1 || true
    live_service_url >/dev/null 2>&1 || return 0
    live_retire_both "$BATS_FILE_TMPDIR/state"
}

_s() { printf '%s' "$BATS_FILE_TMPDIR/state"; }

# The additionalContext the hook handed Claude Code, or nothing.
_context() {
    "$LIVE_JQ" -r '.hookSpecificOutput.additionalContext // empty' "$(_s)/hook.out" 2>/dev/null | tail -1
}

# The memories file the context tells the assistant to read.
_delivered_file() {
    local ctx p
    ctx="$(_context)"
    p="${ctx##*Read them now: }"
    [[ -n "$ctx" && "$p" != "$ctx" ]] || return 1
    live_unix_path "$p"
}

@test "J-011 claude-code: the SessionStart hook hands the session a context that says memories loaded" {
    run "$LIVE_JQ" -r '.hookSpecificOutput.hookEventName // empty' "$(_s)/hook.out"
    assert_output "SessionStart"
    run _context
    # Anchored, and no warning: a clean new session is told only that its memories loaded. A
    # "WARNING FROM MMRY AI" ahead of it (Foundation not stored, payload unreadable) is a failure.
    assert_output --regexp '^MMRY AI loaded [0-9]+ memories\. Read them now: ' || {
        echo "hook stderr: $(tail -5 "$(_s)/hook.err")"
        return 1
    }
    refute_output --partial 'WARNING FROM MMRY AI'
}

@test "J-011 claude-code: the session gets exactly the account's startup memories" {
    local f n expected
    f="$(_delivered_file)" || { echo "the hook named no memories file; context: $(_context)"; return 1; }
    [[ -f "$f" ]] || { echo "the memories file the session was told to read does not exist: $f"; return 1; }
    expected="$(cat "$(_s)/expected-ids")"
    [[ -n "$expected" ]] || { echo "the service returned no startup memories for account A"; return 1; }
    run live_file_ids "$f"
    assert_output "$expected"
    n="$(printf '%s\n' "$expected" | wc -l | tr -d ' ')"
    run _context
    assert_output --partial "MMRY AI loaded ${n} memories."
}

@test "J-011 claude-code: the planted Foundation memory is among them" {
    local f na ia
    f="$(_delivered_file)" || { echo "the hook named no memories file; context: $(_context)"; return 1; }
    na="$(cat "$(_s)/nonce-a")"; ia="$(cat "$(_s)/id-a")"
    run grep -c "Marker ${na}\." "$f"
    assert_output "1"
    run grep -x "id: ${ia}" "$f"
    assert_success
}

@test "J-011 claude-code: the Foundation copy restated on each prompt holds the planted directive" {
    local na sets
    na="$(cat "$(_s)/nonce-a")"
    sets="$(ls "$BATS_FILE_TMPDIR"/tmp/mmry-foundation-set.*.md 2>/dev/null)"
    [[ -n "$sets" ]] || { echo "no Foundation copy was written for this session"; return 1; }
    run grep -l "Marker ${na}\." $sets
    assert_success
}

@test "J-011 claude-code: nothing of another account reaches the session" {
    local nb ib f
    nb="$(cat "$(_s)/nonce-b")"; ib="$(cat "$(_s)/id-b")"
    f="$(_delivered_file)" || { echo "the hook named no memories file; context: $(_context)"; return 1; }
    run grep -rl -e "$nb" "$f" "$(_s)/hook.out" "$BATS_FILE_TMPDIR/tmp"
    assert_failure 1
    run grep -x "id: ${ib}" "$f"
    assert_failure 1
}
