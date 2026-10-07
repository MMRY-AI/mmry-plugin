#!/usr/bin/env bash
# formation-state.sh - remember which formation this session belongs to (#31012).
#
# WHY THIS EXISTS. Nothing in the transmissions contract tells a session which formation it is in:
# the endpoint takes a formation id from the caller. Inferring it would mean listing the account's
# active formations and guessing, which is wrong the moment two are running. So the session records
# its own formation when it joins, and the delivery hook reads that record.
#
# State is per session and lives in the plugin's temp directory alongside the other hook state. It
# is deliberately not in the config file: a formation is a property of one working session, not of
# the installation, and leaving it in config would have a later session believe it is still in a
# formation that ended days ago.
#
# USAGE
#   formation-state.sh set <formationId> [sessionId]   record the formation for this session
#   formation-state.sh get [sessionId]                 print "formationId lastSeenIso" or nothing
#   formation-state.sh seen <iso8601> [sessionId]      record the newest message already surfaced
#   formation-state.sh clear [sessionId]               forget it (on leaving or standing down)
#
# Every path exits 0 except a genuinely malformed request. This is called from a hook, and a state
# helper that fails loudly would take a working session down with it.
# -e with explicit exits on every path. Every write is guarded with || true, because a state
# helper that fails loudly would take a working session down with it.
set -euo pipefail

MMRY_TMPDIR="${TMPDIR:-/tmp}"

# RESOLVE THE SESSION ID THROUGH THE HOST, NOT THROUGH A HAND-ROLLED CHAIN (#31245 QA round 7).
#
# This file used to fall back to CLAUDE_SESSION_ID, then CLAUDE_CODE_SESSION_ID, then
# CODEX_SESSION_ID, in that order, because it did not source lib-host.sh. On a Codex session
# launched from a shell that already exports a Claude session id, the Claude id won, and this
# session then read and wrote ANOTHER session's formation state: it could consume directed
# messages addressed to that session. lib-host.sh's mmry_session_id already gets the precedence
# right per host, and was fixed for exactly this in b3cefd0. There is no reason for a second,
# divergent copy of that decision to exist here.
#
# Sourcing is best-effort: this is a state helper called from a hook, and it must not take a
# working session down if the library is missing from a partial install. The old chain stays as
# the fallback for that case only.
#
# NO FORK TO FIND ITS OWN DIRECTORY (#31746). This was `$(cd "$(dirname ...)" && pwd)`, two
# processes, and formation-check.sh now sources this file on the per-prompt and per-tool-call path,
# where every process is paid for out of a hook budget. The path only has to be good enough to
# source a sibling, which is the rule hook-guard.sh already follows.
_MMRY_STATE_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_MMRY_STATE_DIR" == "${BASH_SOURCE[0]}" ]] && _MMRY_STATE_DIR="."
# shellcheck source=/dev/null
# [[ -f ]] first (#31245 QA round 9): bash 3.2, the macOS bash, aborts under set -e when a sourced
# file is missing, even inside an if, so the fallback below was unreachable exactly where it mattered.
[[ -f "${_MMRY_STATE_DIR}/lib-host.sh" ]] && { source "${_MMRY_STATE_DIR}/lib-host.sh" 2>/dev/null || true; }

# ---------------------------------------------------------------------------------------------
# THE SAME OPERATIONS, IN-PROCESS (#31746).
#
# formation-check.sh used to run this file as `bash formation-state.sh get|seen` three times per
# firing. Each of those is a fresh bash that parses lib-host.sh and forks for dirname, tr and sed:
# measured at 230 to 625 ms apiece on an idle Windows machine and several times that under load,
# inside a 10 second UserPromptSubmit budget the check was regularly losing. So the operations are
# functions, the file can be SOURCED, and the hook calls them without a process. The command line
# below is unchanged for every other caller and is implemented with these same functions, so there
# is still exactly one place that knows the file's name and layout.
#
# Results come back through globals, not stdout, because `$(f)` is itself a fork:
#   MMRY_FS_SAFE       the session id made safe for a file name
#   MMRY_FS_PATH       the state file for a session
#   MMRY_FS_FORMATION  line 1 of the state file, the formation id
#   MMRY_FS_LAST_SEEN  line 2, the newest message already surfaced (may be empty)
# ---------------------------------------------------------------------------------------------

# The session id with every byte outside A-Za-z0-9._- replaced by "_", exactly as
# `tr -c 'A-Za-z0-9._-' '_'` does it. An id that is already safe - every UUID Claude Code and Codex
# issue - is used as it is without a process. Anything else goes through tr itself, because tr
# works per BYTE and a bash pattern works per CHARACTER in a UTF-8 locale, so a multibyte id would
# map to a different file name and "set" and "get" would stop agreeing. The letters are spelled out
# rather than written as ranges because a range in a bracket expression is locale-dependent too.
mmry_formation_safe_sid() {
    local sid="${1:-}"
    if [[ -z "${sid//[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]/}" ]]; then
        MMRY_FS_SAFE="$sid"
    else
        MMRY_FS_SAFE="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"
    fi
}

mmry_formation_state_path() {
    local sid="${1:-}"
    if [[ -z "$sid" ]] && command -v mmry_session_id >/dev/null 2>&1; then
        sid="$(mmry_session_id)"
    fi
    sid="${sid:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID:-unknown}}}}"
    mmry_formation_safe_sid "$sid"
    MMRY_FS_PATH="${MMRY_TMPDIR}/.mmry-formation-${MMRY_FS_SAFE}"
}

# Returns 0 and sets MMRY_FS_FORMATION and MMRY_FS_LAST_SEEN when the session is in a formation;
# returns 1 with both empty when it is not. `read` returns non-zero on a last line with no newline
# even when it assigned it, hence the || true on each.
mmry_formation_state_read() {
    MMRY_FS_FORMATION=""
    MMRY_FS_LAST_SEEN=""
    mmry_formation_state_path "${1:-}"
    [[ -f "$MMRY_FS_PATH" ]] || return 1
    { IFS= read -r MMRY_FS_FORMATION || true; IFS= read -r MMRY_FS_LAST_SEEN || true; } \
        < "$MMRY_FS_PATH" 2>/dev/null || true
    [[ -n "$MMRY_FS_FORMATION" ]] || { MMRY_FS_LAST_SEEN=""; return 1; }
    return 0
}

# Record the newest message already surfaced. A session in no formation records nothing.
mmry_formation_state_seen() {
    local iso="${1:-}" fid=""
    mmry_formation_state_path "${2:-}"
    [[ -f "$MMRY_FS_PATH" ]] || return 0
    { IFS= read -r fid || true; } < "$MMRY_FS_PATH" 2>/dev/null || true
    [[ -n "$fid" ]] || return 0
    { printf '%s\n' "$fid"; printf '%s\n' "$iso"; } > "$MMRY_FS_PATH" 2>/dev/null || true
    return 0
}

# Sourced as a library: the functions above are all the caller wants. Run as a command: carry on.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

cmd="${1:-}"

case "$cmd" in
    set)
        formation_id="${2:-}"
        if [[ -z "$formation_id" ]]; then
            echo "usage: formation-state.sh set <formationId> [sessionId]" >&2
            exit 1
        fi
        # Numeric only. A formation id is a database identity, and anything else here would end up
        # interpolated into a URL by the delivery hook.
        if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
            echo "formation id must be numeric, got: $formation_id" >&2
            exit 1
        fi
        mmry_formation_state_path "${3:-}"
        printf '%s\n' "$formation_id" > "$MMRY_FS_PATH" 2>/dev/null || true
        exit 0
        ;;
    seen)
        mmry_formation_state_seen "${2:-}" "${3:-}"
        exit 0
        ;;
    get)
        mmry_formation_state_read "${2:-}" || exit 0
        printf '%s %s\n' "$MMRY_FS_FORMATION" "$MMRY_FS_LAST_SEEN"
        exit 0
        ;;
    clear)
        mmry_formation_state_path "${2:-}"
        rm -f "$MMRY_FS_PATH" 2>/dev/null || true
        exit 0
        ;;
    *)
        echo "usage: formation-state.sh {set|get|seen|clear} ..." >&2
        exit 1
        ;;
esac
