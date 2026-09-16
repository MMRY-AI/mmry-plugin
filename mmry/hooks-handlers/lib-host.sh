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
# HOST DETECTION IS EXPLICIT, NEVER SNIFFED. MMRY_HOST is set by the Codex entry point
# (codex-hook.sh) and by nothing else. It is deliberately NOT inferred from the presence of
# CODEX_HOME or a codex binary on PATH: a developer who has Codex installed still runs Claude Code
# sessions, and a resolver that guessed from the machine would silently relocate that developer's
# Claude config the day they installed the other product. An unset or unrecognised MMRY_HOST means
# Claude Code, which is the behaviour every existing install already has.

# Guard against double-sourcing. Handlers source this both directly and transitively.
[[ -n "${_MMRY_LIB_HOST_SOURCED:-}" ]] && return 0
_MMRY_LIB_HOST_SOURCED=1

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
