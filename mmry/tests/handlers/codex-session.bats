#!/usr/bin/env bats
# codex-session.bats — session-init.sh and session-start.sh on Codex (#31245 QA round 2).
#
# WHY THIS FILE EXISTS. Both reviewers found, independently, that these two handlers had NO
# coverage of their Codex behaviour and no mutation coverage at all - while session-init.sh is the
# script that decides WHERE a Codex install puts its files, and session-start.sh is the script that
# tells a Codex customer how to set up, names the session in their own session list, and is the one
# place in the plugin with a channel to the model. Everything asserted here was previously carried
# by reading the diff.
#
# Every assertion in this file was seen to REFUSE under tests/structural/run-codex-mutations.sh;
# the mutation applied to each is recorded in tests/structural/CODEX-MUTATIONS.md.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    unset MMRY_HOST CODEX_HOME || true
}

# A plugin root that is a faithful copy of the real one, except that the delegate session-init
# hands over to is a probe. session-init.sh's job is to put files in the right place; running the
# real memory load afterwards would be testing something else.
_fake_plugin_root() {
    local root="$TEST_TMPDIR/plugin"
    mkdir -p "$root/hooks-handlers" "$root/setup"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.cmd "$root/hooks-handlers/" 2>/dev/null || true
    cp "$PLUGIN_ROOT"/setup/*.sh "$root/setup/"
    printf '#!/usr/bin/env bash\necho "DELEGATE RAN"\n' > "$root/hooks-handlers/session-start.sh"
    printf '%s' "$root"
}

# ---------------------------------------------------------------------------------------------
# session-init.sh — WHERE A CODEX INSTALL PUTS ITS FILES
# ---------------------------------------------------------------------------------------------

@test "codex: session-init installs the handlers under ~/.codex, not ~/.claude" {
    local root; root="$(_fake_plugin_root)"
    run env MMRY_HOST=codex HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    assert_success
    [ -f "$HOME/.codex/mmry/hooks-handlers/save-memory.sh" ]
    [ ! -d "$HOME/.claude/mmry" ]
}

@test "req4: with no host declared session-init still installs under ~/.claude, as it always did" {
    # The control. Without it the test above is satisfied by any change that sends both hosts to
    # the Codex directory.
    local root; root="$(_fake_plugin_root)"
    run env -u MMRY_HOST HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    assert_success
    [ -f "$HOME/.claude/mmry/hooks-handlers/save-memory.sh" ]
    [ ! -d "$HOME/.codex/mmry" ]
}

@test "codex: session-init copies the Windows entry point, which is the whole Codex hot path there" {
    # codex-hook.cmd is what every Codex hook runs through on Windows. If the copy line that
    # carries .cmd files is lost, a Windows Codex install has hook registrations pointing at a file
    # that is not there - and every one of them fails open, silently.
    local root; root="$(_fake_plugin_root)"
    run env MMRY_HOST=codex HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    assert_success
    [ -f "$HOME/.codex/mmry/hooks-handlers/codex-hook.cmd" ]
}

@test "codex: session-init installs the setup script the customer is told to run" {
    # docs/codex.md tells a Codex customer to run ~/.codex/mmry/setup/mmry-setup.sh. That file gets
    # there by this copy and by no other route.
    local root; root="$(_fake_plugin_root)"
    run env MMRY_HOST=codex HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    assert_success
    [ -f "$HOME/.codex/mmry/setup/mmry-setup.sh" ]
}

@test "codex: session-init still hands over to session-start when it is done" {
    local root; root="$(_fake_plugin_root)"
    run env MMRY_HOST=codex HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    assert_success
    assert_output --partial "DELEGATE RAN"
}

@test "codex: when the plugin root cannot be found the advice names the Codex setup command" {
    # The fallback search is host-scoped too: looking in ~/.claude/plugins from a Codex session
    # finds another product's install, or nothing at all.
    local root; root="$(_fake_plugin_root)"
    run env -u CLAUDE_PLUGIN_ROOT MMRY_HOST=codex HOME="$HOME" \
        bash "$root/hooks-handlers/session-init.sh"
    assert_success
    assert_output --partial "bash ~/.codex/mmry/setup/mmry-setup.sh"
}

# ---------------------------------------------------------------------------------------------
# session-start.sh — WHAT A CODEX SESSION IS TOLD, AND WHAT THE API IS TOLD ABOUT IT
# ---------------------------------------------------------------------------------------------

@test "codex: the session is registered as codex, so the customer can find it in their own list" {
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    run env MMRY_HOST=codex HOME="$HOME" CLAUDE_SESSION_ID="s-codex-1" \
        bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    assert_success
    grep -q 'codex' "$TEST_TMPDIR/curl-log.txt"
    run grep -c 'claude-code' "$TEST_TMPDIR/curl-log.txt"
    assert_output "0"
}

@test "req4: a Claude session is still registered as claude-code" {
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    run env -u MMRY_HOST HOME="$HOME" CLAUDE_SESSION_ID="s-claude-1" \
        bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    assert_success
    grep -q 'claude-code' "$TEST_TMPDIR/curl-log.txt"
}

@test "codex: an unconfigured Codex session is told how to set up, in Codex's own terms" {
    # And it is told WITHOUT the client being sourced: on a machine with both products installed,
    # sourcing it here is what used to reach for the Claude credential (#31245 QA round 2).
    mkdir -p "$HOME/.claude"
    printf '%s' '{"apiUrl":"https://claude.example","authMethod":"apikey","apiKey":"claude-sentinel"}' \
        > "$HOME/.claude/mmry-config.json"
    run env -u MMRY_CONFIG_FILE -u MMRY_API_KEY MMRY_HOST=codex HOME="$HOME" \
        bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    assert_success
    assert_output --partial "hookSpecificOutput"
    assert_output --partial "bash ~/.codex/mmry/setup/mmry-setup.sh"
    assert_output --partial "Restart Codex"
    refute_output --partial "/mmry:help"
    refute_output --partial "claude-sentinel"
    # And nothing was fetched with a borrowed credential - the client was never even sourced, so
    # there is usually no curl log at all.
    [ ! -f "$TEST_TMPDIR/curl-log.txt" ] || ! grep -q 'memories/startup' "$TEST_TMPDIR/curl-log.txt"
}

@test "req4: an unconfigured Claude session still gets the Claude message it always got" {
    create_empty_config
    run env -u MMRY_HOST MMRY_API_KEY="" HOME="$HOME" \
        bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh"
    assert_success
    assert_output --partial "bash ~/.claude/mmry/setup/mmry-setup.sh"
    assert_output --partial "Restart Claude Code"
    assert_output --partial "/mmry:help"
}

# ---------------------------------------------------------------------------------------------
# THE PAYLOAD FIELD NAMES ARE AN ASSUMPTION, AND AN ASSUMPTION MUST SAY SO
#
# session_id and hook_event_name are CLAUDE CODE's field names. No captured Codex hook payload
# exists yet. If Codex spells them differently, session registration degrades to the literal
# "unknown" and formation delivery exits 0 on every event - installed, quiet, useless. These assert
# that a payload which arrives and parses but does not carry the field is REPORTED rather than
# absorbed.
# ---------------------------------------------------------------------------------------------

@test "a payload with no session_id field is reported to the model, naming the fields it did carry" {
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    run env -u CLAUDE_SESSION_ID MMRY_HOST=codex HOME="$HOME" \
        bash -c "printf '%s' '{\"conversation_id\":\"abc\",\"event\":\"SessionStart\"}' | bash \"$PLUGIN_ROOT/hooks-handlers/session-start.sh\""
    assert_success
    assert_output --partial "carried no 'session_id' field"
    assert_output --partial "conversation_id"
}

@test "and a payload that DOES carry session_id is not warned about" {
    # The control. Without it the warning above is satisfied by a handler that always warns.
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    run env -u CLAUDE_SESSION_ID MMRY_HOST=codex HOME="$HOME" \
        bash -c "printf '%s' '{\"session_id\":\"real-id-42\",\"hook_event_name\":\"SessionStart\"}' | bash \"$PLUGIN_ROOT/hooks-handlers/session-start.sh\""
    assert_success
    refute_output --partial "carried no 'session_id' field"
    grep -q 'real-id-42' "$TEST_TMPDIR/curl-log.txt"
}

@test "req4: the same warning fires on Claude Code, naming Claude Code" {
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    run env -u MMRY_HOST -u CLAUDE_SESSION_ID HOME="$HOME" \
        bash -c "printf '%s' '{\"conversation_id\":\"abc\"}' | bash \"$PLUGIN_ROOT/hooks-handlers/session-start.sh\""
    assert_success
    assert_output --partial "Claude Code hook payload was read successfully"
}
