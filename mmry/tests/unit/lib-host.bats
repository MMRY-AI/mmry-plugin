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
# tests/structural/CODEX-MUTATIONS.md, committed beside run-codex-mutations.sh, for the mutation
# applied to each, what it broke, and the run it was observed in.

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

@test "req4: sourcing lib-host.sh twice does not clobber a caller's own override" {
    # THIS ASSERTION USED TO BE UNFALSIFIABLE (#31245 QA round 2). It sourced the file twice and
    # checked that a path still came out, which it does with the double-source guard replaced by a
    # no-op, because every function here is idempotent. It proved nothing.
    #
    # What the guard actually protects is a caller that defines its own fallback and then pulls in
    # a library that transitively sources this file again - which is exactly what hook-guard.sh and
    # stop-check.sh do with their missing-resolver fallbacks. Without the guard the second source
    # silently redefines the caller's function out from under it.
    run bash -c "source '$LIB'
        mmry_host_label() { printf 'CALLER-OWN-DEFINITION'; }
        source '$LIB'
        mmry_host_label"
    assert_success
    assert_output "CALLER-OWN-DEFINITION"
}

@test "req4: and the second source still returns success, so a caller under set -e survives it" {
    run bash -c "set -e; source '$LIB'; source '$LIB'; mmry_host_config_dir"
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

# ---------------------------------------------------------------------------------------------
# WHEN NOBODY DECLARED A HOST AND THE HOME WAS MOVED (#31245 QA round 3)
#
# THE DEFECT THESE COVER, REPRODUCED WITH SENTINEL CREDENTIALS ON 2026-09-16:
#
#   1. A Codex home relocated to a path with no ".codex" segment, in a shell where CODEX_HOME was
#      not exported - which is EVERY shell the model runs a handler in, because Codex sets
#      CODEX_HOME for its own hook processes and not for the model's commands - resolved the host
#      as Claude and loaded the Claude account's credential.
#   2. With CODEX_HOME set, but spelled the way Windows spells it (C:\Users\x\codexhome) against a
#      self-path from `pwd` (/c/Users/x/codexhome), the prefix comparison was dead and did the
#      same thing. The variable was set and made no difference.
#
# These use a REAL directory tree rather than a stubbed HOME, because both defects were properties
# of where the file physically sat.
# ---------------------------------------------------------------------------------------------

# Build an install tree: $1 = root, $2 = config dir name, $3 = marker contents ("" for none).
_install_at() {
    local root="$1" cfg="$2" marker="${3:-}"
    mkdir -p "${root}/${cfg}/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "${root}/${cfg}/mmry/hooks-handlers/"
    [[ -z "$marker" ]] || printf '%s\n' "$marker" > "${root}/${cfg}/mmry/.mmry-host"
    printf '%s' "${root}/${cfg}/mmry/hooks-handlers/lib-host.sh"
}

# Source a copy of the library at $1 with a clean environment, then evaluate $2.
_eval_installed() {
    local lib="$1" expr="$2"; shift 2
    env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE "$@" bash -c "source '$lib'; $expr"
}

@test "codex: a RELOCATED Codex home with nothing exported is resolved from the install marker" {
    local lib; lib="$(_install_at "$TEST_TMPDIR/reloc" "mycodex" "codex")"
    run _eval_installed "$lib" 'mmry_host' HOME="$TEST_TMPDIR/reloc"
    assert_output "codex"
}

@test "codex: and the credential is looked for where the marker IS, not in ~/.codex" {
    # Resolving the host and then looking in the default home is a refusal, not a fix: the
    # credential is in the relocated directory. The marker's own location is what names it.
    local lib; lib="$(_install_at "$TEST_TMPDIR/reloc2" "mycodex" "codex")"
    run _eval_installed "$lib" 'mmry_host_config_file' HOME="$TEST_TMPDIR/reloc2"
    assert_output "$TEST_TMPDIR/reloc2/mycodex/mmry-config.json"
}

@test "req4: a marker reading claude changes nothing at all" {
    local lib; lib="$(_install_at "$TEST_TMPDIR/cl" ".claude" "claude")"
    run _eval_installed "$lib" 'mmry_host; printf " "; mmry_host_config_file' HOME="$TEST_TMPDIR/cl"
    assert_output "claude $TEST_TMPDIR/cl/.claude/mmry-config.json"
}

@test "req4: so does a marker containing rubbish, an empty one, or none" {
    local lib
    lib="$(_install_at "$TEST_TMPDIR/junk" ".claude" "not-a-host")"
    run _eval_installed "$lib" 'mmry_host' HOME="$TEST_TMPDIR/junk"
    assert_output "claude"
    lib="$(_install_at "$TEST_TMPDIR/empty" ".claude" "")"
    : > "$TEST_TMPDIR/empty/.claude/mmry/.mmry-host"
    run _eval_installed "$lib" 'mmry_host' HOME="$TEST_TMPDIR/empty"
    assert_output "claude"
    lib="$(_install_at "$TEST_TMPDIR/none" ".claude" "")"
    run _eval_installed "$lib" 'mmry_host' HOME="$TEST_TMPDIR/none"
    assert_output "claude"
}

@test "codex: a marker is read tolerantly - trailing whitespace and CRLF still say codex" {
    # It is written by a shell script on three platforms and copied around by installers. A
    # carriage return must not be the difference between the right credential and the wrong one.
    local lib; lib="$(_install_at "$TEST_TMPDIR/crlf" "mycodex" "")"
    printf 'codex\r\n' > "$TEST_TMPDIR/crlf/mycodex/mmry/.mmry-host"
    run _eval_installed "$lib" 'mmry_host' HOME="$TEST_TMPDIR/crlf"
    assert_output "codex"
}

@test "codex: CODEX_HOME spelled the Windows way still matches a path resolved by pwd" {
    # C:\Users\x\codexhome vs /c/Users/x/codexhome. Both sides are normalised before comparison.
    local lib; lib="$(_install_at "$TEST_TMPDIR/win" "mycodex" "")"
    local posix="$TEST_TMPDIR/win/mycodex" windows
    if command -v cygpath >/dev/null 2>&1; then
        windows="$(cygpath -w "$posix")"
    else
        skip "cygpath is not available; the drive-letter spelling only exists on Windows"
    fi
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/win" CODEX_HOME="$windows" \
        bash -c "source '$lib'; mmry_host"
    assert_output "codex"
}

@test "req4: a Claude install is NOT captured by a CODEX_HOME pointing somewhere else" {
    # The resolver must stay a fact about where this copy is installed. A developer who has Codex
    # on the machine still runs Claude Code sessions.
    local lib; lib="$(_install_at "$TEST_TMPDIR/dev" ".claude" "claude")"
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/dev" \
        CODEX_HOME="$TEST_TMPDIR/dev/elsewhere" bash -c "source '$lib'; mmry_host"
    assert_output "claude"
}

@test "the path normaliser puts a Windows spelling into the form pwd produces" {
    # Flipping the backslashes is not enough: "C:/Users/x" and "/c/Users/x" are still two different
    # strings, and the prefix comparison that decides which product a credential belongs to was
    # being made between them.
    # The STRING half is tested directly. Going through _mmry_norm_path on this machine would ask
    # cygpath and never exercise the expression that was wrong - which is the half Linux and macOS
    # run, and the half that silently deleted every separator.
    run bash -c "source '$LIB'; _mmry_norm_path_str 'C:\Users\x\codexhome'"
    assert_output "/c/Users/x/codexhome"
    run bash -c "source '$LIB'; _mmry_norm_path_str 'relative\with\backslashes'"
    assert_output "relative/with/backslashes"
    run bash -c "source '$LIB'; _mmry_norm_path_str '/c/already/posix/'"
    assert_output "/c/already/posix"
}
