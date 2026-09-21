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

# ---------------------------------------------------------------------------------------------
# #31245 QA ROUND 4.

@test "codex: a LOWERCASE Windows spelling of CODEX_HOME is the same directory, and resolves as one" {
    # THE DEFECT. The normaliser folded separators and the drive letter but not segment case, so
    # CODEX_HOME=c:\users\x\codexhome became /c/users/x/codexhome while pwd answered
    # /c/Users/x/codexhome. On a case-insensitive filesystem those are not two spellings of
    # equivalent paths, they are the same name. The prefix test compared them byte for byte,
    # failed, and the handler resolved the host as Claude and reached for the Claude credential.
    local lib; lib="$(_install_at "$TEST_TMPDIR/lower" "mycodex" "")"
    local posix="$TEST_TMPDIR/lower/mycodex" windows lowered
    if command -v cygpath >/dev/null 2>&1; then
        windows="$(cygpath -w "$posix")"
    else
        skip "cygpath is not available; the drive-letter spelling only exists on Windows"
    fi
    lowered="$(printf '%s' "$windows" | tr '[:upper:]' '[:lower:]')"
    # THE PREMISE, asserted rather than assumed: if the path had no uppercase to lose, this test
    # would pass for the wrong reason on a machine whose temp path is already lowercase.
    [[ "$lowered" != "$windows" ]] || skip "this temp path has no uppercase segments to fold"

    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/lower" CODEX_HOME="$lowered" \
        bash -c "source '$lib'; mmry_host"
    assert_output "codex"
}

@test "req4: case folding does NOT happen where the platform is case-sensitive" {
    # The other half. On Linux /home/A and /home/a are different directories, and a resolver that
    # folded them would claim a Codex install that is not there. OSTYPE is forced rather than
    # waited for, so this assertion runs on the Windows machine this was developed on.
    local lib; lib="$(_install_at "$TEST_TMPDIR/cs" "mycodex" "")"
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/cs" \
        CODEX_HOME="$TEST_TMPDIR/cs/MYCODEX" \
        bash -c "OSTYPE=linux-gnu; source '$lib'; mmry_host"
    assert_output "claude"
}

@test "codex: a trailing separator on CODEX_HOME is not part of the directory" {
    # CODEX_HOME=C:\Users\x\codexhome\ is what tab-completion in cmd hands you, and it produced a
    # credential path of "...\codexhome\/mmry-config.json".
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/ts" MMRY_HOST=codex \
        CODEX_HOME="/opt/codexhome/" bash -c "source '$LIB'; mmry_host_config_file"
    assert_output "/opt/codexhome/mmry-config.json"
}

@test "codex: and a trailing BACKSLASH is stripped too, which is the Windows spelling" {
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/tsb" MMRY_HOST=codex \
        CODEX_HOME='D:\work\codexhome\' bash -c "source '$LIB'; mmry_host_config_dir"
    assert_output 'D:\work\codexhome'
}

@test "codex: the setup hint names the directory the credential was ACTUALLY looked for in" {
    # THE SELF-CONTRADICTING REMEDY. The refusal prints the resolved path under "looked for" and
    # the hint under "create it". The hint was hardcoded to ~/.codex, so for the relocated-home
    # customer this whole feature exists for, the two lines disagreed and the one the customer was
    # told to run did not exist.
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/hint" MMRY_HOST=codex \
        CODEX_HOME="/opt/relocated" bash -c "source '$LIB'; mmry_host_setup_hint"
    assert_output "bash /opt/relocated/mmry/setup/mmry-setup.sh"
}

@test "codex: and the two lines of the refusal message agree with each other" {
    # Asserted on the MESSAGE, not on the two functions separately, because the defect was that
    # the two disagreed - which is invisible if each is only ever checked on its own.
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$TEST_TMPDIR/agree" MMRY_HOST=codex \
        CODEX_HOME="/opt/relocated" bash -c "source '$LIB'; mmry_host_assert_own_credential 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"looked for: /opt/relocated/mmry-config.json"* ]]
    [[ "$output" == *"create it:  bash /opt/relocated/mmry/setup/mmry-setup.sh"* ]]
    # And the hint must not name a directory the "looked for" line did not.
    [[ "$output" != *"~/.codex"* ]]
}

@test "req4: the Claude setup hint is still the tilde literal, byte for byte" {
    # The governing rule. The derived form must not change the string every existing message has
    # carried since before this ticket.
    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="/home/someone" \
        bash -c "source '$LIB'; mmry_host_setup_hint"
    assert_output "bash ~/.claude/mmry/setup/mmry-setup.sh"
}

# ---------------------------------------------------------------------------------------------
# THE SPELLING THE FILE IS SOURCED BY (#31245 QA round 6).
#
# ${BASH_SOURCE[0]%/*} strips to the last FORWARD slash. On Windows there often is not one:
# hooks.json invokes handlers as %CLAUDE_PLUGIN_ROOT%\hooks-handlers\..., so ${BASH_SOURCE[0]}
# arrives all backslashes, the strip matched nothing, and the resolver fell back to "." - THE
# CURRENT WORKING DIRECTORY, which has nothing to do with where the file is.
#
# The consequence is the exact defect this file exists to prevent, on the platform whose
# invocation spelling causes it: a Codex install with a valid marker beside it resolved as CLAUDE
# and pointed at the other product's credential. Found while measuring latency, which is why the
# measurement is worth keeping as well as the fix.
#
# THE TEST STAGES A REAL INSTALL and sources it from a FOREIGN WORKING DIRECTORY, because a test
# run from inside the staged directory passes against the defect: "." is the right answer there
# by accident. That accident is why this shipped.

_stage_install() {
    # Usage: _stage_install <marker-contents>   Echoes the staged <root>/mmry directory.
    local root="$TEST_TMPDIR/staged-$1-$$"
    rm -rf "$root"
    mkdir -p "$root/mmry/hooks-handlers"
    cp "$LIB" "$root/mmry/hooks-handlers/lib-host.sh"
    printf '%s\n' "$1" > "$root/mmry/.mmry-host"
    printf '%s' "$root"
}

@test "codex: a staged install resolves the same by its POSIX path and by its WINDOWS path" {
    command -v cygpath >/dev/null 2>&1 || skip "not a Windows shell: there is no second spelling"
    local root posix win out_posix out_win
    root="$(_stage_install codex)"
    posix="$root/mmry/hooks-handlers/lib-host.sh"
    win="$(cygpath -w "$posix")"
    # The two spellings really are different, or this test compares a thing with itself.
    [ "$win" != "$posix" ]
    [[ "$win" == *'\'* ]]

    # Sourced from a foreign working directory, which is the condition the defect needed.
    out_posix="$(cd / && env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE \
        bash -c "source '$posix'; printf '%s|%s' \"\${MMRY_HOST:-unset}\" \"\$(mmry_host_config_dir)\"")"
    out_win="$(cd / && env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE \
        bash -c "source '$win'; printf '%s|%s' \"\${MMRY_HOST:-unset}\" \"\$(mmry_host_config_dir)\"")"

    # Both must say codex. Before the fix the Windows one said "unset" and named ~/.claude.
    [[ "$out_posix" == codex\|* ]]
    [[ "$out_win"   == codex\|* ]]
    # And both must name the staged directory rather than a home this install has nothing to do
    # with. The two spellings of it need not be byte-identical - cygpath's 8.3 forms are real -
    # so the assertion is that neither points at the OTHER product.
    [[ "$out_posix" != *"/.claude"* ]]
    [[ "$out_win"   != *"/.claude"* ]]
}

@test "req4: a Claude install by its WINDOWS path is still claude, and still ~/.claude" {
    command -v cygpath >/dev/null 2>&1 || skip "not a Windows shell: there is no second spelling"
    local root win out
    root="$(_stage_install claude)"
    win="$(cygpath -w "$root/mmry/hooks-handlers/lib-host.sh")"
    out="$(cd / && env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="/home/testuser" \
        bash -c "source '$win'; printf '%s|%s|%s' \"\${MMRY_HOST:-unset}\" \"\$(mmry_host_config_dir)\" \"\$(mmry_host_setup_hint)\"")"
    [ "$out" = "unset|/home/testuser/.claude|bash ~/.claude/mmry/setup/mmry-setup.sh" ]
}

@test "codex: the Windows spelling costs no process to resolve" {
    # The other half of the same defect. "." failed the absolute test, so the resolver sent it
    # through `cd`/`pwd` - a fork - on EVERY source, which on this path is every tool call.
    # Asserted structurally: the separators are flipped BEFORE the strip, so a drive-lettered
    # path satisfies the absolute test and never reaches the resolve.
    grep -Fq '_mmry_self_src="${BASH_SOURCE[0]//' "$LIB"
    grep -Fq '_mmry_self_dir="${_mmry_self_src%/*}"' "$LIB"
    # And the resolve is still there for the spellings that genuinely need it - a relative path
    # or one with dot segments - rather than having been deleted along with the defect.
    grep -Fq '_mmry_self_dir="$(cd "$_mmry_self_dir" && pwd 2>/dev/null)"' "$LIB"
}

# ---------------------------------------------------------------------------------------------
# THE PLUGIN-ROOT RECOVERY REMEDY (#31245, after round 6).
#
# session-init.sh's one error branch. It printed mmry_host_setup_hint, which was the wrong
# derivation twice over: on Claude it replaced develop's "/mmry:setup" with a path (requirement 4),
# and on Codex it named a file that branch has not copied yet.
# ---------------------------------------------------------------------------------------------

@test "req4: the Claude plugin-root remedy is /mmry:setup, the develop literal, byte for byte" {
    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="/home/someone" \
        bash -c "source '$LIB'; mmry_host_plugin_recovery_ref"
    assert_output "/mmry:setup"
}

@test "codex: the plugin-root remedy is the reinstall, not a path under a directory not yet filled" {
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="/opt/relocated" HOME="/home/someone" \
        bash -c "source '$LIB'; mmry_host_plugin_recovery_ref"
    assert_output "codex plugin add mmry@mmry-plugin"
}

@test "codex: and that remedy names no setup script at all, on any spelling of the home" {
    # The regression direction. Any answer containing mmry-setup.sh is the defect coming back,
    # whether it spells the home as ~/.codex, as an absolute path, or as a relocated one.
    local home
    for home in "" "/opt/relocated"; do
        run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$home" HOME="/home/someone" \
            bash -c "source '$LIB'; mmry_host_plugin_recovery_ref"
        [[ "$output" != *"mmry-setup.sh"* ]] || {
            echo "CODEX_HOME='$home' produced a setup-script path: $output"
            return 1
        }
    done
}

# ---------------------------------------------------------------------------------------------
# HOME IS NOT GUARANTEED (#31245, 2026-09-20).
#
# A single unguarded "${HOME}" took the whole Codex feature down on Windows. codex-hook.sh runs
# under `set -euo pipefail`, so with HOME unset the expansion aborted the hook with
# "HOME: unbound variable", exit 1, and no output, before any of our code ran. Codex showed the
# customer "hook exited with code 1" every turn.
#
# HOME is a Git Bash convention. Windows sets USERPROFILE, and HOMEDRIVE plus HOMEPATH. Codex's
# terminal app sets none of them for the hook: running `codex --version` inside it prints
# "could not find home directory". Every test this suite ever ran was launched from Git Bash,
# which does set HOME, which is precisely why 836 green tests never saw it.
# ---------------------------------------------------------------------------------------------

@test "nohome: the config dir resolves from USERPROFILE when HOME is unset" {
    run env -u HOME -u CODEX_HOME -u MMRY_CONFIG_FILE USERPROFILE="C:\\Users\\someone" MMRY_HOST=codex \
        bash -c "set -euo pipefail; source '$LIB'; mmry_host_config_dir"
    assert_success
    [[ "$output" == *"/Users/someone/.codex" ]] || { echo "resolved to: $output"; return 1; }
}

@test "nohome: and from HOMEDRIVE plus HOMEPATH when that is all there is" {
    run env -u HOME -u CODEX_HOME -u MMRY_CONFIG_FILE -u USERPROFILE \
        HOMEDRIVE="C:" HOMEPATH="\\Users\\someone" MMRY_HOST=codex \
        bash -c "set -euo pipefail; source '$LIB'; mmry_host_config_dir"
    assert_success
    [[ "$output" == *"/Users/someone/.codex" ]] || { echo "resolved to: $output"; return 1; }
}

@test "nohome: sourcing the resolver with no home at all does not abort under set -u" {
    # The failure mode was not a wrong path, it was the shell dying on an unbound variable.
    run env -u HOME -u CODEX_HOME -u MMRY_CONFIG_FILE -u USERPROFILE -u HOMEDRIVE -u HOMEPATH \
        MMRY_HOST=codex bash -c "set -euo pipefail; source '$LIB'; echo SURVIVED"
    assert_success
    assert_output --partial "SURVIVED"
}

@test "req4: a customer's own HOME is never overridden by the fallback" {
    run env -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="/home/chosen" USERPROFILE="C:\\Users\\other" \
        bash -c "set -euo pipefail; source '$LIB'; mmry_home"
    assert_success
    assert_output "/home/chosen"
}

# ---------------------------------------------------------------------------------------------
# THE PATH THE MODEL IS TOLD TO OPEN (#31245, 2026-09-20).
#
# Observed in a live Codex session on Windows: "MMRY AI loaded 12 memories. Read them now:
# /tmp/mmry-memories.md". The model's shell there is PowerShell, which cannot resolve /tmp, so the
# single instruction attached to every memory load named a file the reader could not open.
# ---------------------------------------------------------------------------------------------

@test "codex: the memories path is spelled for the model's shell, not the handler's" {
    command -v cygpath >/dev/null 2>&1 || skip "cygpath is absent; this branch is Windows-only"
    run env MMRY_HOST=codex HOME="$HOME" bash -c "source '$LIB'; mmry_host_path_for_model /tmp/mmry-memories.md"
    assert_success
    [[ "$output" == *":\\"* ]] || { echo "not a Windows path: $output"; return 1; }
    [[ "$output" != /tmp/* ]] || { echo "still a POSIX path: $output"; return 1; }
}

@test "req4: on Claude Code that same path is returned untouched" {
    # Claude Code's model has a Bash tool and opens the POSIX path happily. Rewriting it there
    # would break the thing that already works.
    run env -u MMRY_HOST HOME="$HOME" bash -c "source '$LIB'; mmry_host_path_for_model /tmp/mmry-memories.md"
    assert_success
    assert_output "/tmp/mmry-memories.md"
}

# ---------------------------------------------------------------------------------------------
# WHICH SESSION AM I (#31245, 2026-09-21).
#
# Twelve formation handlers resolved the session id from the two Claude Code variables only, and
# neither exists in the model's shell on Codex, so every one of them refused with "No session id is
# available, so there is nothing to enrol." A customer's assistant could not join a formation
# through the plugin at all. Codex provides CODEX_SESSION_ID, measured by printing the environment
# from inside a live session's own shell.
# ---------------------------------------------------------------------------------------------

@test "req4: CLAUDE_SESSION_ID still wins, so Claude Code resolution is unchanged" {
    run env CLAUDE_SESSION_ID="claude-one" CLAUDE_CODE_SESSION_ID="claude-two" CODEX_SESSION_ID="codex-three" \
        bash -c "source '$LIB'; mmry_session_id"
    assert_success
    assert_output "claude-one"
}

@test "req4: and the Bash-tool variable is still second in line" {
    run env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="claude-two" CODEX_SESSION_ID="codex-three" \
        bash -c "source '$LIB'; mmry_session_id"
    assert_success
    assert_output "claude-two"
}

@test "codex: the session resolves from CODEX_SESSION_ID when the others are absent" {
    run env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID="codex-three" \
        bash -c "source '$LIB'; mmry_session_id"
    assert_success
    assert_output "codex-three"
}

@test "nosession: with nothing at all it returns empty rather than failing the caller" {
    # A non-zero return here would abort every handler under set -e, which is the failure mode
    # this whole area keeps producing.
    run env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID \
        bash -c "set -euo pipefail; source '$LIB'; mmry_session_id; echo SURVIVED"
    assert_success
    assert_output --partial "SURVIVED"
}

@test "codex: a model-invoked formation handler enrols instead of refusing" {
    # The observable symptom, not just the helper: before this, every formation handler run by the
    # model on Codex printed "No session id is available".
    local hh="$PLUGIN_ROOT/hooks-handlers"
    run env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID="bats-probe-session" \
        MMRY_HOST=codex HOME="$HOME" bash "$hh/formation-state.sh" get "bats-probe-session"
    [[ "$output" != *"No session id is available"* ]] || { echo "still refusing: $output"; return 1; }
}

@test "codex: an inherited Claude session id does NOT override the platform's own" {
    # FOUND BY THE DELIVERY TEST ITSELF, within an hour of shipping the first version of
    # mmry_session_id (#31245, 2026-09-21).
    #
    # A Codex session launched from a shell that already had CLAUDE_CODE_SESSION_ID exported
    # INHERITED it. The resolver checked the Claude variables first, so the handler answered with
    # the LAUNCHING session's identity and refused with "This session already belongs to an active
    # formation" - true of the other session, not of itself. Two sessions silently sharing one
    # identity is worse than a handler that refuses outright, and any Codex session started from
    # inside another assistant's shell would have done it.
    run env MMRY_HOST=codex CLAUDE_CODE_SESSION_ID="inherited-from-parent" CODEX_SESSION_ID="my-own-id" \
        bash -c "source '$LIB'; mmry_session_id"
    assert_success
    assert_output "my-own-id"
}

@test "codex: and an inherited CLAUDE_SESSION_ID loses to it as well" {
    run env MMRY_HOST=codex CLAUDE_SESSION_ID="inherited-outer" CODEX_SESSION_ID="my-own-id" \
        bash -c "source '$LIB'; mmry_session_id"
    assert_success
    assert_output "my-own-id"
}

@test "req4: a stray CODEX_SESSION_ID never displaces the Claude Code answer" {
    # The mirror image. On Claude Code the Claude variables remain authoritative even if a Codex
    # variable is lying around in the environment.
    run env -u MMRY_HOST CLAUDE_CODE_SESSION_ID="claude-id" CODEX_SESSION_ID="stray-codex-id" \
        bash -c "source '$LIB'; mmry_session_id"
    assert_success
    assert_output "claude-id"
}
