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

_state_file() {
    local sid="${1:-${CLAUDE_SESSION_ID:-unknown}}"
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
