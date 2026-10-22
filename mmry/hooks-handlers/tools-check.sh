#!/usr/bin/env bash
# tools-check.sh - why the MMRY tools are missing from a Codex conversation, in one step, and how to
# get them back without changing the conversation's place in a Formation (#32602).
#
# Usage:
#   bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/tools-check.sh"            say why
#   bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/tools-check.sh" --recover  and repair
#   ... [--session <conversation id>]
#
# WHY IT EXISTS. On Codex the MMRY tools come from a local server Codex starts itself
# (hooks-handlers/mcp-server.sh, through mcp/mmry-mcp). When Codex does not start it, or it stops,
# the conversation simply has no MMRY tools and nothing says why (MMRY feedback item 36). The server
# now records its starts, failures and the conversations it serves (lib-tool-server.sh); this script
# reads those records and the plugin's own files and names the first thing that is wrong.
#
# READ ONLY, AND NO NETWORK. The assistant may run this inside Codex's sandbox, which has no network
# and cannot write under the Codex home, so the diagnosis only reads. --recover is meant for a
# terminal; the one thing it changes is the launcher's execute permission, and only when that is
# what is wrong.
#
# THE FORMATION MEMBERSHIP IS NEVER TOUCHED. A conversation's place in a Formation is its Codex
# conversation id: the membership file in TMPDIR is named by it, and MMRY AI keeps the member id
# against it. Nothing here reads the network, leaves, joins, or edits a .mmry-formation-* file. The
# recovery gets the tools back by reopening the SAME conversation, which keeps the same id. A new
# conversation, a leave and rejoin, or the mmry_formation connector tools would each join as someone
# else, so the recovery says not to.

set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-host.sh finds the Codex home from the .mmry-host marker beside this copy when MMRY_HOST is not
# set, which is how a relocated Codex home is found from the assistant's shell. This check is for
# Codex only, so whatever lib-host.sh concludes about the host, the answer is Codex.
# shellcheck source=/dev/null
source "${HANDLER_DIR}/lib-host.sh"
export MMRY_HOST="codex"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/lib-tool-server.sh"

recover=0
sid=""
while (( $# > 0 )); do
    case "$1" in
        --recover) recover=1 ;;
        --session) sid="${2:-}"; if (( $# > 1 )); then shift; fi ;;
        *) ;;
    esac
    shift
done
if [[ -z "$sid" ]]; then
    sid="${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}"
fi

CODEX_DIR="$(mmry_host_config_dir)"
TMP_DIR="${TMPDIR:-/tmp}"
is_windows=0
case "${OSTYPE:-}" in msys*|cygwin*|win32*) is_windows=1 ;; esac

_ago() {
    local then="${1:-0}" now
    now="$(date +%s 2>/dev/null)" || now=0
    if [[ ! "$then" =~ ^[0-9]+$ || ! "$now" =~ ^[0-9]+$ ]] || (( then == 0 || now < then )); then
        printf 'at an unknown time'
        return 0
    fi
    local s=$(( now - then ))
    if (( s < 120 )); then printf '%s seconds ago' "$s"
    elif (( s < 7200 )); then printf '%s minutes ago' "$(( s / 60 ))"
    elif (( s < 172800 )); then printf '%s hours ago' "$(( s / 3600 ))"
    else printf '%s days ago' "$(( s / 86400 ))"; fi
}

# ---- Where is the plugin Codex starts the server from? ----
plugin_root=""
mmry_ts_dir
if _mmry_ts_read2 "${MMRY_TS_DIR}/launched"; then
    _launched_root=""
    { IFS= read -r _ || true; IFS= read -r _ || true; IFS= read -r _launched_root || true; } < "${MMRY_TS_DIR}/launched" 2>/dev/null || true
    _launched_root="${_launched_root%$'\r'}"
    [[ -n "$_launched_root" && -f "${_launched_root}/codex-mcp.json" ]] && plugin_root="$_launched_root"
fi
if [[ -z "$plugin_root" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/codex-mcp.json" ]]; then
    plugin_root="$CLAUDE_PLUGIN_ROOT"
fi
if [[ -z "$plugin_root" && -d "${CODEX_DIR}/plugins" ]]; then
    plugin_root="$(find "${CODEX_DIR}/plugins" -path '*/mmry/*' -name codex-mcp.json -type f 2>/dev/null | head -1 || true)"
    plugin_root="${plugin_root%/codex-mcp.json}"
fi

# ---- Is MMRY switched off in Codex's settings? ----
plugin_disabled=0
if [[ -f "${CODEX_DIR}/config.toml" ]]; then
    if awk '
        /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[plugins\."mmry@mmry-plugin"\][[:space:]]*$/) ; next }
        insec && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false/ { found = 1 }
        END { exit found ? 0 : 1 }' "${CODEX_DIR}/config.toml" 2>/dev/null; then
        plugin_disabled=1
    fi
fi

launcher=""
launcher_problem=""
if [[ -n "$plugin_root" ]]; then
    launcher="${plugin_root}/mcp/mmry-mcp"
    if [[ ! -f "$launcher" || ! -f "${plugin_root}/hooks-handlers/mcp-server.sh" ]]; then
        launcher_problem="missing"
    elif (( is_windows == 0 )) && [[ ! -x "$launcher" ]]; then
        launcher_problem="not-executable"
    fi
fi

mmry_ts_status "$sid"
state="$MMRY_TS_STATE"
detail="$MMRY_TS_DETAIL"

# ---- --recover: the one repair that is safe to make, and nothing that touches identity ----
repaired=""
if (( recover == 1 )) && [[ "$launcher_problem" == "not-executable" ]]; then
    if chmod +x "$launcher" 2>/dev/null && [[ -x "$launcher" ]]; then
        repaired="the launcher Codex starts, ${launcher}, is now marked executable"
        launcher_problem=""
    fi
fi

# ---- Say it. First line is the answer. ----
if [[ "$state" == "running" && "$plugin_disabled" == 0 && -z "$launcher_problem" ]]; then
    echo "MMRY tools: running"
    if [[ "$detail" == "this-conversation" ]]; then
        echo "MMRY's tool server is running for this conversation."
    else
        echo "MMRY's tool server is running on this machine."
    fi
    echo "If this conversation still does not list the mmry_plugin tools, quit Codex completely and reopen this same conversation, which starts its tool server again and keeps its place in any Formation."
else
    echo "MMRY tools: not started"
    printf 'Why: '
    if (( plugin_disabled == 1 )); then
        echo "MMRY is switched off in Codex's settings (${CODEX_DIR}/config.toml has enabled = false for mmry@mmry-plugin), so Codex does not start its tool server."
    elif [[ -z "$plugin_root" ]]; then
        echo "MMRY's plugin files were not found in Codex's plugin folder (${CODEX_DIR}/plugins), so Codex has nothing to start."
    elif [[ "$launcher_problem" == "missing" ]]; then
        echo "MMRY's plugin files are incomplete: ${launcher} or the server it starts is missing."
    elif [[ "$launcher_problem" == "not-executable" ]]; then
        echo "the launcher Codex starts, ${launcher}, is not marked executable, so Codex cannot start it."
    else
        case "$detail" in
            failed)
                _mmry_ts_read2 "${MMRY_TS_DIR}/failed" || true
                echo "MMRY's tool server last tried to start $(_ago "$MMRY_TS_L1") and stopped: ${MMRY_TS_L2:-no reason was recorded}." ;;
            stopped)
                _mmry_ts_read2 "${MMRY_TS_DIR}/session-${MMRY_TS_SAFE}" || true
                echo "the tool server that served this conversation is no longer running, and none has started since (it last served this conversation $(_ago "$MMRY_TS_L2")). Codex stops it when Codex closes or when MMRY is reinstalled or updated, and does not start it again for a conversation that is already open." ;;
            exited)
                _mmry_ts_read2 "${MMRY_TS_DIR}/launched" || true
                echo "MMRY's tool server last started $(_ago "$MMRY_TS_L1") and is no longer running." ;;
            *)
                echo "Codex has not started MMRY's tool server on this machine since this version of MMRY was installed." ;;
        esac
    fi
    if [[ -f "${CODEX_DIR}/log/codex-tui.log" ]]; then
        _log="$(grep -i 'mmry_plugin' "${CODEX_DIR}/log/codex-tui.log" 2>/dev/null | tail -3 || true)"
        if [[ -n "$_log" ]]; then
            echo "Codex's own log mentions the server:"
            printf '  %s\n' "${_log//$'\n'/$'\n'  }"
        fi
    fi
fi

if [[ -n "$repaired" ]]; then
    echo "Repaired: ${repaired}."
fi

if [[ "$state" != "running" || "$plugin_disabled" == 1 || -n "$launcher_problem" ]]; then
    echo ""
    echo "To get the MMRY tools back and keep this conversation's place in the Formation:"
    n=1
    if (( plugin_disabled == 1 )) || [[ -z "$plugin_root" || "$launcher_problem" == "missing" ]]; then
        echo "  ${n}. Quit Codex completely, then in a terminal run: $(mmry_host_plugin_recovery_ref)"; n=$(( n + 1 ))
    elif [[ "$launcher_problem" == "not-executable" ]]; then
        echo "  ${n}. In a terminal run: bash \"\${CODEX_HOME:-\$HOME/.codex}/mmry/hooks-handlers/tools-check.sh\" --recover"; n=$(( n + 1 ))
        echo "  ${n}. Quit Codex completely."; n=$(( n + 1 ))
    else
        echo "  ${n}. Quit Codex completely."; n=$(( n + 1 ))
    fi
    if [[ -n "$sid" ]]; then
        echo "  ${n}. Reopen this same conversation: in the desktop app, choose it from the conversation list; in a terminal, run: codex resume ${sid}"
    else
        echo "  ${n}. Reopen the same conversation: in the desktop app, choose it from the conversation list; in a terminal, run: codex resume, and pick it."
    fi
    echo "Do not start a new conversation for it, do not leave and rejoin the Formation, and do not use the mmry_formation connector tools: each of those joins as someone else. Reopening the same conversation keeps its member id."
fi

# ---- The memberships on this machine, so the customer can see which conversation to reopen ----
_memberships=""
for _f in "${TMP_DIR}"/.mmry-formation-*; do
    [[ -f "$_f" ]] || continue
    _name="${_f##*/}"
    case "$_name" in
        .mmry-formation-cs-*|.mmry-formation-poll-*|.mmry-formation-handover-*|.mmry-formation-renewed-*) continue ;;
    esac
    _fid=""
    { IFS= read -r _fid || true; } < "$_f" 2>/dev/null || true
    _fid="${_fid%$'\r'}"
    [[ "$_fid" =~ ^[0-9]+$ ]] || continue
    _memberships="${_memberships}  Formation ${_fid}: conversation ${_name#.mmry-formation-} (reopen with: codex resume ${_name#.mmry-formation-})"$'\n'
done
if [[ -n "$_memberships" ]]; then
    echo ""
    echo "Formation memberships on this machine (this check changed none of them):"
    printf '%s' "$_memberships"
fi
exit 0
