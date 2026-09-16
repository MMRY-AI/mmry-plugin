#!/usr/bin/env bats
# lib-host.bats — the host resolver (#31245).
#
# THE POINT OF THIS FILE is requirement 4: the existing Claude Code experience must be preserved
# unchanged while the shared scripts are reworked to serve two hosts. "Preserved" is not an
# intention, it is a set of literal strings, and every one of them is asserted here against the
# exact value the callers used to have hard-coded. An edit that drifts the Claude path by one
# character fails here rather than reaching a customer.
#
# Every assertion below was confirmed to REFUSE before it was kept: see
# tests/structural/codex-mutation-manifest.md for the mutation applied to each and what it broke.

load '../helpers/test-helper'

LIB=""

setup() {
    LIB="$PLUGIN_ROOT/hooks-handlers/lib-host.sh"
    # A known HOME, so an assertion about a path is about the resolver and not about this machine.
    export HOME="/home/testuser"
    unset MMRY_HOST CODEX_HOME || true
}

# Sourcing in a subshell each time: these functions are pure, but MMRY_HOST is process state and a
# leak between tests would make a passing run meaningless.
host_eval() {
    # Usage: host_eval <MMRY_HOST value or empty> <expression>
    local host="$1" expr="$2"
    if [[ -n "$host" ]]; then
        MMRY_HOST="$host" bash -c "source '$LIB'; $expr"
    else
        env -u MMRY_HOST bash -c "HOME='$HOME'; source '$LIB'; $expr"
    fi
}

# ---------------------------------------------------------------------------------------------
# The Claude Code answers. These are the literals the callers carried before this file existed.
# ---------------------------------------------------------------------------------------------

@test "req4: with MMRY_HOST unset the host is claude" {
    run host_eval "" 'mmry_host'
    assert_output "claude"
}

@test "req4: the Claude config dir is exactly \${HOME}/.claude" {
    run host_eval "" 'mmry_host_config_dir'
    assert_output "/home/testuser/.claude"
}

@test "req4: the Claude state dir is exactly \${HOME}/.claude/mmry" {
    run host_eval "" 'mmry_host_state_dir'
    assert_output "/home/testuser/.claude/mmry"
}

@test "req4: the Claude credential file is exactly \${HOME}/.claude/mmry-config.json" {
    run host_eval "" 'mmry_host_config_file'
    assert_output "/home/testuser/.claude/mmry-config.json"
}

@test "req4: the Claude client name is exactly claude-code, the string sent to /api/sessions" {
    run host_eval "" 'mmry_host_client_name'
    assert_output "claude-code"
}

@test "req4: the Claude setup hint is the literal the messages used to carry" {
    run host_eval "" 'mmry_host_setup_hint'
    assert_output 'bash ~/.claude/mmry/setup/mmry-setup.sh'
}

@test "req4: on Claude a script reference is still the unexpanded \${CLAUDE_PLUGIN_ROOT} form" {
    # stop-check.sh's directive relies on the MODEL expanding this, so it must reach the model
    # unexpanded. A resolver that helpfully expanded it here would break the Claude Code directive.
    run host_eval "" 'mmry_host_script_ref save-memory.sh'
    assert_output '${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh'
}

@test "req4: an unrecognised MMRY_HOST resolves to claude, not to an error or an empty path" {
    run host_eval "gemini" 'mmry_host_config_dir'
    assert_output "/home/testuser/.claude"
}

@test "req4: sourcing lib-host.sh twice is a no-op, not a redefinition" {
    run bash -c "source '$LIB'; source '$LIB'; mmry_host_config_dir"
    assert_success
    assert_output "/home/testuser/.claude"
}

# ---------------------------------------------------------------------------------------------
# The Codex answers.
# ---------------------------------------------------------------------------------------------

@test "codex: MMRY_HOST=codex resolves the host to codex" {
    run host_eval "codex" 'mmry_host'
    assert_output "codex"
}

@test "codex: the config dir defaults to \${HOME}/.codex" {
    run env -u CODEX_HOME bash -c "HOME='$HOME'; MMRY_HOST=codex; source '$LIB'; mmry_host_config_dir"
    assert_output "/home/testuser/.codex"
}

@test "codex: CODEX_HOME wins over the default, because it is Codex's own documented override" {
    run bash -c "HOME='$HOME'; MMRY_HOST=codex CODEX_HOME=/opt/codexhome; source '$LIB'; mmry_host_config_dir"
    assert_output "/opt/codexhome"
}

@test "codex: the credential file follows CODEX_HOME rather than HOME" {
    run bash -c "HOME='$HOME'; MMRY_HOST=codex CODEX_HOME=/opt/codexhome; source '$LIB'; mmry_host_config_file"
    assert_output "/opt/codexhome/mmry-config.json"
}

@test "codex: the client name is codex, so the customer can find the session in their own list" {
    run host_eval "codex" 'mmry_host_client_name'
    assert_output "codex"
}

@test "codex: a script reference is an ABSOLUTE path, never \${CLAUDE_PLUGIN_ROOT}" {
    # Codex exports CLAUDE_PLUGIN_ROOT to hook processes (discovery.rs line 267) but not to the
    # shell the model runs its own commands in. A directive naming the variable would expand to
    # nothing there and the model would report a missing file.
    run env -u CODEX_HOME bash -c "HOME='$HOME'; MMRY_HOST=codex; source '$LIB'; mmry_host_script_ref save-memory.sh"
    assert_output "/home/testuser/.codex/mmry/hooks-handlers/save-memory.sh"
    refute_output --partial 'CLAUDE_PLUGIN_ROOT'
}

@test "codex: the host label is Codex, so a message does not name the wrong product" {
    run host_eval "codex" 'mmry_host_label'
    assert_output "Codex"
}

@test "req4: the Claude host label is Claude Code" {
    run host_eval "" 'mmry_host_label'
    assert_output "Claude Code"
}
