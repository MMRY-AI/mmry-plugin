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
#   MMRY_FS_SHOWN      line 3, comma-separated ids of DIRECTED messages already printed and not yet
#                      reported to the service as read (#31721). Usually absent. The next poll
#                      carries them, and they are cleared once the service has answered it.
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
    MMRY_FS_SHOWN=""
    mmry_formation_state_path "${1:-}"
    [[ -f "$MMRY_FS_PATH" ]] || return 1
    { IFS= read -r MMRY_FS_FORMATION || true; IFS= read -r MMRY_FS_LAST_SEEN || true
      IFS= read -r MMRY_FS_SHOWN || true; } \
        < "$MMRY_FS_PATH" 2>/dev/null || true
    # Only digits and commas are ids; a stray CR from a file written across a line-ending boundary
    # is not part of one.
    MMRY_FS_SHOWN="${MMRY_FS_SHOWN//[!0-9,]/}"
    [[ -n "$MMRY_FS_FORMATION" ]] || { MMRY_FS_LAST_SEEN=""; MMRY_FS_SHOWN=""; return 1; }
    return 0
}

# Record the newest message already surfaced. A session in no formation records nothing.
#
# The optional third argument (#31721) REPLACES the list of directed ids printed and not yet
# reported to the service. When it is not passed at all, the list already on file is kept, so a
# caller that only knows about "seen" - the `seen` command below - cannot erase reports still owed.
mmry_formation_state_seen() {
    local iso="${1:-}" fid="" seen_line="" shown="" keep_shown=1
    if (( $# >= 3 )); then keep_shown=0; shown="${3:-}"; fi
    mmry_formation_state_path "${2:-}"
    [[ -f "$MMRY_FS_PATH" ]] || return 0
    { IFS= read -r fid || true; IFS= read -r seen_line || true
      if (( keep_shown )); then IFS= read -r shown || true; fi; } < "$MMRY_FS_PATH" 2>/dev/null || true
    [[ -n "$fid" ]] || return 0
    shown="${shown//[!0-9,]/}"
    if [[ -n "${shown//,/}" ]]; then
        { printf '%s\n' "$fid"; printf '%s\n' "$iso"; printf '%s\n' "$shown"; } > "$MMRY_FS_PATH" 2>/dev/null || true
    else
        { printf '%s\n' "$fid"; printf '%s\n' "$iso"; } > "$MMRY_FS_PATH" 2>/dev/null || true
    fi
    return 0
}

# REFRESH WITHOUT A PROCESS (#31844). Rewrites the record exactly as it stands, which is the cheapest
# way to bring its mtime up to date: a `touch` would be one more process on every member's check.
# The mtime is how the sweep below tells a live member from a session that ended without leaving,
# so every check a member makes calls this. The callers hold the delivery mutex while they do, the
# same mutex every "seen" write is made under, so a refresh cannot write back a last-seen value
# another reader has just advanced. A record that is not there is not created.
mmry_formation_state_refresh() {
    mmry_formation_state_read "${1:-}" || return 0
    mmry_formation_state_seen "$MMRY_FS_LAST_SEEN" "${1:-}" || true
    return 0
}

# ---------------------------------------------------------------------------------------------
# LEFTOVER MEMBERSHIPS (#31844).
#
# A session that ends without leaving its formation - the window closed, the machine restarted, the
# client crashed - leaves its record here for ever. Nothing else removes it, and until #31844 the
# hooks' membership gate opened for any file in this folder, so one ended session made every later
# session on the machine pay for the full formation check. Measured on one Windows machine on
# 2026-10-08: 41 entries, the oldest five weeks old.
#
# THE RULE. Another session's record that has not been written for MMRY_FORMATION_STALE_SECONDS is
# removed when a session starts, unless that session's idle watch is still running (its poll lock
# holds a pid that is alive). A member that is alive keeps its record fresh without trying:
#   - every check it makes (prompt, tool call, session start) refreshes it - see
#     mmry_formation_state_refresh above, called from formation-check.sh;
#   - its idle watch refreshes it at every pause, at most a minute apart, for as long as the
#     service confirms the membership, renewing itself every 28 minutes.
# So a record this old belongs to a session that has done nothing at all for three days, and has no
# watch. The period is three days, not one, for the members that have no watch to keep them fresh: a
# Codex session (Codex has no background hook), or a Claude Code session whose watch stopped because
# the service could not be reached when it asked, then sat idle over a weekend. Those must not come
# back on Monday to find they have silently left.
#
# The starting session's own record is never swept, however old: a resumed session keeps its id.
#
# The number is not a customer setting. The variable exists so the suite can name it, as with the
# idle watch's window in formation-check.sh.
# ---------------------------------------------------------------------------------------------
MMRY_FORMATION_STALE_SECONDS="${MMRY_FORMATION_STALE_SECONDS:-259200}"

# True when a name in this folder is a membership record and not one of the locks and markers that
# share its prefix. Those belong to formation-check.sh and are judged by their own rules there.
# hooks/hooks.json, hooks/codex-hooks.json and codex-hook.cmd carry this same list in their gates.
mmry_formation_is_membership_name() {
    case "$1" in
        .mmry-formation-cs-*|.mmry-formation-poll-*|.mmry-formation-handover-*|.mmry-formation-renewed-*) return 1 ;;
        .mmry-formation-?*) return 0 ;;
    esac
    return 1
}

# Remove other sessions' stale records. $1 = the calling session's id, whose record is never touched.
# Best-effort on every path and silent: this runs at session start, and a session that fails to start
# because a temp file could not be read is a far worse fault than a temp file left in place.
# Costs nothing when there is no other record to look at. Otherwise one `stat` for all of them (two
# on BSD, whose stat spells it differently), and one `rm` if anything is to go.
mmry_formation_sweep() {
    local own_name="" max="${MMRY_FORMATION_STALE_SECONDS:-}" f name
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    (( max > 0 )) || return 0
    if [[ -n "${1:-}" ]]; then
        mmry_formation_safe_sid "$1"
        own_name=".mmry-formation-${MMRY_FS_SAFE}"
    fi
    local -a cands=()
    for f in "${MMRY_TMPDIR}"/.mmry-formation-*; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        mmry_formation_is_membership_name "$name" || continue
        [[ "$name" == "$own_name" ]] && continue
        cands+=("$f")
    done
    (( ${#cands[@]} > 0 )) || return 0

    local now=""
    now="$(date +%s 2>/dev/null)" || now=""
    [[ "$now" =~ ^[0-9]+$ ]] || return 0
    local stats=""
    stats="$(stat -c '%Y %n' -- "${cands[@]}" 2>/dev/null)" || true
    [[ -n "$stats" ]] || { stats="$(stat -f '%m %N' -- "${cands[@]}" 2>/dev/null)" || true; }
    [[ -n "$stats" ]] || return 0

    local -a doomed=()
    local line mtime path sid pid
    while IFS= read -r line; do
        mtime="${line%% *}"
        path="${line#* }"
        [[ "$mtime" =~ ^[0-9]+$ && "$path" != "$line" ]] || continue
        (( now - mtime > max )) || continue
        name="${path##*/}"
        sid="${name#.mmry-formation-}"
        # A watch that is still running is a live member, whatever the record's age says.
        pid=""
        if [[ -f "${MMRY_TMPDIR}/.mmry-formation-poll-${sid}/pid" ]]; then
            { IFS= read -r pid || true; } < "${MMRY_TMPDIR}/.mmry-formation-poll-${sid}/pid" 2>/dev/null || true
        fi
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        doomed+=("$path")
    done <<< "$stats"
    (( ${#doomed[@]} > 0 )) || return 0
    rm -f -- "${doomed[@]}" 2>/dev/null || true
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
    sweep)
        mmry_formation_sweep "${2:-}" || true
        exit 0
        ;;
    *)
        echo "usage: formation-state.sh {set|get|seen|clear|sweep} ..." >&2
        exit 1
        ;;
esac
