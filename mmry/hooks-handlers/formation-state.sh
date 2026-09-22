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
_MMRY_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_MMRY_STATE_DIR}/lib-host.sh" 2>/dev/null || true

_state_file() {
    local sid="${1:-}"
    if [[ -z "$sid" ]] && command -v mmry_session_id >/dev/null 2>&1; then
        sid="$(mmry_session_id)"
    fi
    sid="${sid:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID:-unknown}}}}"
    # Session ids come from the client and can carry characters that are awkward in a filename.
    local safe
    safe="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/.mmry-formation-%s' "$MMRY_TMPDIR" "$safe"
}

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
        printf '%s\n' "$formation_id" > "$(_state_file "${3:-}")" 2>/dev/null || true
        exit 0
        ;;
    seen)
        iso="${2:-}"
        f="$(_state_file "${3:-}")"
        [[ -f "$f" ]] || exit 0
        fid="$(head -n 1 "$f" 2>/dev/null || true)"
        [[ -n "$fid" ]] || exit 0
        { printf '%s\n' "$fid"; printf '%s\n' "$iso"; } > "$f" 2>/dev/null || true
        exit 0
        ;;
    get)
        f="$(_state_file "${2:-}")"
        [[ -f "$f" ]] || exit 0
        fid="$(sed -n '1p' "$f" 2>/dev/null || true)"
        last="$(sed -n '2p' "$f" 2>/dev/null || true)"
        [[ -n "$fid" ]] || exit 0
        printf '%s %s\n' "$fid" "$last"
        exit 0
        ;;
    clear)
        rm -f "$(_state_file "${2:-}")" 2>/dev/null || true
        exit 0
        ;;
    *)
        echo "usage: formation-state.sh {set|get|seen|clear} ..." >&2
        exit 1
        ;;
esac
