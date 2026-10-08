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
# THE RULE. Another session's record is removed at a session start only when ALL of these hold:
#   1. nobody has written it for MMRY_FORMATION_STALE_SECONDS (three days);
#   2. that session's idle watch is not running (its poll lock holds no live pid);
#   3. THE SERVICE SAYS, in so many words, that the session is not a member of the formation the
#      record names (#31844 QA round 2).
# A live member keeps its record fresh without trying: every check it makes refreshes it (see
# mmry_formation_state_refresh above), and its idle watch refreshes it at every pause. But age alone
# cannot tell an ended session from a member that has simply been quiet, and QA found three genuine
# members whose records go stale: a Codex member (Codex has no idle watch) idle for three days; a
# Claude Code member whose watch stopped after two unreachable-service results, then sat idle; and a
# Claude Code member closed on Friday and resumed on Tuesday after another window had started first.
# Nothing re-creates a removed record, so for each of those the gate closed and directed messages
# silently stopped. Rule 3 is what makes removal safe: only the service knows who is in a formation.
#
# Any answer that is not a clean "member": false keeps the record - the service unreachable, a
# server fault, a refused credential, a 404 from a service too old for the route, a body that is not
# the expected object. A record kept today is asked about again at the next session start.
#
# BOUNDED (#31844 QA round 2). The questions are asked at session start, which has a 30 s budget the
# memory load also needs, so at most MMRY_FORMATION_SWEEP_MAX_ASKS of them, each limited to a few
# seconds, and none is started once MMRY_FORMATION_SWEEP_BUDGET seconds would be exceeded. The first
# answer that says the service cannot be asked (no connection, a 5xx, 401, 403, 429) stops the
# questions for this start: forty stale records against a service that is down cost one timeout, not
# forty. Records not reached are kept and asked about at a later start.
#
# NO SWEEP WITHOUT THE HOST'S OWN SESSION ID (#31844 QA round 2, D1). The starting session's own
# record is never swept, however old: a resumed session keeps its id. That protection is only as good
# as the id, so the caller passes the id from the hook payload - never an environment variable that
# may be empty or inherited from another session - and a call with no id sweeps nothing at all.
#
# A record whose name is not the session id as written (an id with bytes that had to be replaced to
# make a file name; a "_" is the sign of it) is never asked about: the service would be asked about a
# session that does not exist, would truthfully say "not a member", and a member would be removed.
#
# The numbers are not customer settings. The variables exist so the suite can name them, as with the
# idle watch's window in formation-check.sh.
# ---------------------------------------------------------------------------------------------
MMRY_FORMATION_STALE_SECONDS="${MMRY_FORMATION_STALE_SECONDS:-259200}"
MMRY_FORMATION_SWEEP_MAX_ASKS="${MMRY_FORMATION_SWEEP_MAX_ASKS:-8}"
MMRY_FORMATION_SWEEP_BUDGET="${MMRY_FORMATION_SWEEP_BUDGET:-8}"

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

# Ask the service whether session $2 is a member of formation $1, within $3 seconds. Sets
# MMRY_FS_ANSWER to "member", "not-member", "unknown" (keep this record, ask about the next) or
# "stop" (keep this record and ask nothing more this time). Needs mmry-client.sh and MMRY_JQ.
_mmry_formation_sweep_ask() {
    local fid="$1" sid="$2" member=""
    local MMRY_HTTP_MAX_TIME="$3" MMRY_HTTP_CONNECT_TIMEOUT="$3"
    (( MMRY_HTTP_CONNECT_TIMEOUT > 3 )) && MMRY_HTTP_CONNECT_TIMEOUT=3
    MMRY_FS_ANSWER="unknown"
    MMRY_HTTP_CODE=""
    MMRY_RESPONSE=""
    mmry_get_formation_sent "$fid" "$sid" 2>/dev/null || true
    case "${MMRY_HTTP_CODE:-000}" in
        2[0-9][0-9]) ;;
        000|5[0-9][0-9]|401|403|429) MMRY_FS_ANSWER="stop"; return 0 ;;
        *) return 0 ;;
    esac
    member="$("$MMRY_JQ" -r 'if type == "object" and (.member | type) == "boolean" then (.member | tostring) else "unknown" end' \
        <<< "${MMRY_RESPONSE:-}" 2>/dev/null || true)"
    member="${member%$'\r'}"
    if [[ "$member" == "false" ]]; then
        MMRY_FS_ANSWER="not-member"
    elif [[ "$member" == "true" ]]; then
        MMRY_FS_ANSWER="member"
    fi
    return 0
}

# Remove other sessions' stale records. $1 = the calling session's id FROM THE HOOK PAYLOAD; its
# record is never touched, and without it nothing is swept. Best-effort on every path and silent:
# this runs at session start, and a session that fails to start because a temp file could not be
# read is a far worse fault than a temp file left in place.
# Costs nothing when there is no other record to look at. Otherwise one `stat` for all of them (two
# on BSD, whose stat spells it differently), and only for a record that is stale and has no live
# watch, one bounded question to the service each, then one `rm` if anything is to go.
mmry_formation_sweep() {
    local own_name="" max="${MMRY_FORMATION_STALE_SECONDS:-}" f name
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    (( max > 0 )) || return 0
    [[ -n "${1:-}" ]] || return 0
    mmry_formation_safe_sid "$1"
    own_name=".mmry-formation-${MMRY_FS_SAFE}"
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

    local -a stale=()
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
        stale+=("$path")
    done <<< "$stats"
    (( ${#stale[@]} > 0 )) || return 0

    # Old and unwatched is not enough: only the service can say the session has left (rule 3).
    # Without the client there is nobody to ask, and every record is kept.
    declare -F mmry_get_formation_sent >/dev/null 2>&1 || return 0
    [[ -n "${MMRY_JQ:-}" ]] || return 0
    local asks_max="${MMRY_FORMATION_SWEEP_MAX_ASKS:-}" budget="${MMRY_FORMATION_SWEEP_BUDGET:-}"
    [[ "$asks_max" =~ ^[0-9]+$ ]] || asks_max=8
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=8
    local per=4 asks=0 started="$SECONDS" fid=""
    (( per > budget )) && per="$budget"
    local -a doomed=()
    for path in "${stale[@]}"; do
        name="${path##*/}"
        sid="${name#.mmry-formation-}"
        fid=""
        { IFS= read -r fid || true; } < "$path" 2>/dev/null || true
        fid="${fid%$'\r'}"
        # A record that names no formation is not a membership: set refuses a non-numeric id, and
        # the delivery hook ignores such a record. Nobody can be in it, so there is nothing to ask.
        if ! [[ "$fid" =~ ^[0-9]+$ ]]; then
            doomed+=("$path")
            continue
        fi
        [[ "$sid" == *_* ]] && continue
        (( asks < asks_max && per > 0 )) || break
        (( SECONDS - started + per <= budget )) || break
        asks=$(( asks + 1 ))
        _mmry_formation_sweep_ask "$fid" "$sid" "$per" || true
        [[ "$MMRY_FS_ANSWER" == "stop" ]] && break
        [[ "$MMRY_FS_ANSWER" == "not-member" ]] && doomed+=("$path")
    done
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
