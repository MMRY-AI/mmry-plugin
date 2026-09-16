#!/usr/bin/env bash
# lib-host.sh - resolve which assistant this plugin is running inside, and where its files live.
#
# WHY THIS EXISTS (#31245). Twenty-eight handler scripts and the installer were written when there
# was exactly one host, so "the config directory" and "~/.claude" were the same sentence. Adding
# OpenAI Codex as a second host means every one of those places has to answer a question it never
# had to ask. This file is the single place that answers it.
#
# THE GOVERNING RULE: THE CLAUDE CODE ANSWER MUST NOT CHANGE. Requirement 4 of #31245 is that the
# existing Claude Code experience is preserved unchanged while these scripts are reworked. Every
# function below returns, for the default host, exactly the literal string the caller used to have
# hard-coded. That is not a convention, it is the acceptance criterion, and tests/unit/lib-host.bats
# asserts it string by string so a future edit that drifts the Claude path fails rather than ships.
#
# HOST DETECTION IS DECLARED FIRST, AND OTHERWISE READ OFF THIS FILE'S OWN LOCATION. MMRY_HOST is
# set by the Codex entry point (codex-hook.sh); when it is absent the block below asks whether this
# copy of the plugin is installed inside a Codex home, which is a fact about the install rather
# than a guess about the machine.
#
# It is deliberately NOT inferred from the presence of CODEX_HOME in the environment or a codex
# binary on PATH. A developer who has Codex installed still runs Claude Code sessions, and a
# resolver that guessed from the machine would relocate that developer's Claude config the day they
# installed the other product. Anything that is neither declared nor installed under a Codex home
# is Claude Code, which is the behaviour every existing install already has.

# set -euo pipefail is the repository convention for every script in this directory
# (structural/file-integrity.bats enforces it). It is safe in a sourced library here because
# every conditional below is written as an `if` or as a `&&` list, both of which bash exempts
# from -e, so a false test can never terminate the shell that sourced this file.
set -euo pipefail

# Guard against double-sourcing. Handlers source this both directly and transitively.
[[ -n "${_MMRY_LIB_HOST_SOURCED:-}" ]] && return 0
_MMRY_LIB_HOST_SOURCED=1

# ---------------------------------------------------------------------------------------------
# WHEN NOBODY DECLARED A HOST, THIS FILE'S OWN LOCATION IS THE ANSWER.
#
# The scripts a customer's assistant runs are NOT run through codex-hook.sh. session-init.sh copies
# every handler into the host's MMRY directory, and the model then invokes, say,
# ~/.codex/mmry/hooks-handlers/save-memory.sh in a shell of its own where MMRY_HOST is not set and
# never will be.
#
# Before this block that was a silent defect, reproduced on 2026-09-15: sourcing mmry-client.sh
# from the Codex copy with no MMRY_CONFIG_FILE resolved the credential at
# ${HOME}/.claude/mmry-config.json - the OTHER product's. On a machine with both installed a Codex
# save went out under whatever account the Claude file named; on a Codex-only machine there is no
# such file, so every model-invoked save failed with "No API key configured. Run /mmry:setup",
# naming a command Codex customers cannot type.
#
# THIS IS A LOCATION TEST, NOT MACHINE SNIFFING. It asks where this copy of the file is installed,
# which is a fact about the install, not a guess about the machine. A Claude Code install lives
# under ${HOME}/.claude or the Claude plugin cache and is unaffected; the check below can only ever
# answer "codex" for a file sitting inside a Codex home.
if [[ -z "${MMRY_HOST:-}" ]]; then
    _mmry_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _mmry_self_dir=""
    if [[ -n "$_mmry_self_dir" ]]; then
        # Normalise to forward slashes so the comparison works from Git Bash on Windows.
        _mmry_self_dir="${_mmry_self_dir//\\//}"
        if [[ -n "${CODEX_HOME:-}" ]]; then
            _mmry_codex_home="${CODEX_HOME//\\//}"
            [[ "$_mmry_self_dir" == "${_mmry_codex_home}"/* ]] && MMRY_HOST="codex"
        fi
        # The default Codex home, and any path segment that is literally ".codex".
        [[ -z "${MMRY_HOST:-}" && "$_mmry_self_dir" == */.codex/* ]] && MMRY_HOST="codex"
    fi
    unset _mmry_self_dir _mmry_codex_home 2>/dev/null || true
fi

# The host this process is serving. "claude" or "codex"; anything else is treated as "claude".
mmry_host() {
    case "${MMRY_HOST:-}" in
        codex) printf 'codex' ;;
        *)     printf 'claude' ;;
    esac
}

# The host's own configuration directory - the one the host itself owns, not one MMRY invents.
#
# Claude Code: ${HOME}/.claude, which is what every caller hard-coded before this file existed.
# Codex:       ${CODEX_HOME} when the host set it, else ${HOME}/.codex. CODEX_HOME is Codex's own
#              documented override (codex exec --ignore-user-config: "auth still uses CODEX_HOME"),
#              so honouring it is how a customer who relocated their Codex home gets MMRY in the
#              place they put it rather than in the place we assumed.
mmry_host_config_dir() {
    if [[ "$(mmry_host)" == "codex" ]]; then
        printf '%s' "${CODEX_HOME:-${HOME}/.codex}"
    else
        printf '%s' "${HOME}/.claude"
    fi
}

# Where session-init.sh copies the handler scripts to, and where hook-guard.sh looks for them.
# This is MMRY's own subdirectory of the host config directory.
mmry_host_state_dir() {
    printf '%s/mmry' "$(mmry_host_config_dir)"
}

# The credential file. mmry-client.sh already discovers ${MMRY_CONFIG_FILE} ahead of any hard-coded
# path, which is why the client needs no edit to serve a second host: the Codex entry point exports
# this value and the client finds it first.
mmry_host_config_file() {
    printf '%s/mmry-config.json' "$(mmry_host_config_dir)"
}

# What this host calls itself when a session is registered with the API. This shows up in the
# customer's own session list, so it has to be the truth rather than a default: a Codex session
# listed as "claude-code" is a session the customer cannot find.
mmry_host_client_name() {
    if [[ "$(mmry_host)" == "codex" ]]; then
        printf 'codex'
    else
        printf 'claude-code'
    fi
}

# The product name as a customer reads it, for messages the model relays to them.
mmry_host_label() {
    if [[ "$(mmry_host)" == "codex" ]]; then
        printf 'Codex'
    else
        printf 'Claude Code'
    fi
}

# The setup command to tell a customer to run, as a literal string they can copy.
# Home is spelled "~" rather than expanded because this is display text, not a path to execute.
mmry_host_setup_hint() {
    if [[ "$(mmry_host)" == "codex" ]]; then
        printf 'bash ~/.codex/mmry/setup/mmry-setup.sh'
    else
        printf 'bash ~/.claude/mmry/setup/mmry-setup.sh'
    fi
}

# How the model should refer to MMRY's own scripts in text it is asked to act on.
#
# This one is not cosmetic. stop-check.sh tells the model to run
# "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh", relying on the model expanding a variable
# that exists in ITS environment. Codex does export CLAUDE_PLUGIN_ROOT to hook processes for
# compatibility (codex-rs/hooks/src/engine/discovery.rs line 267), but that is the HOOK's
# environment, not the shell the model runs its own commands in. On Codex the directive therefore
# names an absolute path resolved at hook time, which works in any shell the model reaches for.
mmry_host_script_ref() {
    # Usage: mmry_host_script_ref <script-name.sh>
    local script="$1"
    if [[ "$(mmry_host)" == "codex" ]]; then
        printf '%s/hooks-handlers/%s' "$(mmry_host_state_dir)" "$script"
    else
        printf '${CLAUDE_PLUGIN_ROOT}/hooks-handlers/%s' "$script"
    fi
}

# ---------------------------------------------------------------------------------------------
# POINT THE CLIENT AT THE RIGHT CREDENTIAL, ONCE, AT SOURCE TIME.
#
# mmry-client.sh discovers its config as ${MMRY_CONFIG_FILE}, then ${CLAUDE_PLUGIN_ROOT}, then
# ${HOME}/.claude/mmry-config.json. Only the first of those can be right on a second host, and
# mmry-client.sh is not ours to change in this task. Setting it here means every consumer of the
# client - which is nearly every handler, through lib-jq.sh - resolves the correct credential
# without a single edit to the client.
#
# ON CLAUDE CODE THIS DOES NOTHING. mmry_host() is "claude", the branch is not taken, and the
# client's existing discovery order runs exactly as it always has.
if [[ -z "${MMRY_CONFIG_FILE:-}" ]] && [[ "$(mmry_host)" == "codex" ]]; then
    export MMRY_CONFIG_FILE="$(mmry_host_config_file)"
fi
