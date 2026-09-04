#!/usr/bin/env bash
# formation-roster.sh - who is in this session's formation, and the id to address each of them by.
#
# WHY THIS EXISTS (#31045). A message can now be directed at ONE member, and the address is that
# member's roster entry id. Without a way to see the roster, a sender has no way to learn the id,
# and a feature nobody can invoke is a feature that shipped inert - which is exactly what happened
# to formation transmissions in v1.21, when the whole receiving half was delivered with no way to
# speak into it.
#
# THE ROSTER ENTRY, NOT THE SESSION STRING. A session id is secret-adjacent and a sender has no
# legitimate way to learn somebody else's, so it could never be the address. The roster entry is
# the formation's own identifier for one participation and is already visible to its members.
#
# LEAVING IS SHOWN, NOT HIDDEN. Since #31194 a session releases its place when it moves on, and a
# message cannot be directed at a member who has gone: the server refuses it. Showing who has left,
# rather than silently omitting them, is what makes that refusal legible instead of baffling.
#
# THIS DOES NOT FAIL OPEN. It runs because somebody asked and is waiting for an answer, so a
# failure is reported with the status that caused it, the same rule formation-list.sh follows.
#
# Usage: formation-roster.sh [formationId]
#        With no argument it reads this session's own formation from local state.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

formation_id="${1:-}"

if [[ -z "$formation_id" ]]; then
    session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # #31143: the command runtime provides CLAUDE_CODE_SESSION_ID
    if [[ -z "$session_id" ]]; then
        echo "No session id is available and no formation id was given, so there is no roster to show."
        exit 1
    fi
    state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
    if [[ -z "$state" ]]; then
        echo "This session is not in a formation. Run /mmry:formation list to see what is active, then /mmry:formation join <id>."
        exit 1
    fi
    formation_id="${state%% *}"
fi

if ! [[ "$formation_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "A formation id is a positive whole number. Run /mmry:formation list to see what is active."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so the roster cannot be read."
    exit 1
fi

if ! mmry_get_formation "$formation_id"; then
    # #31195: a status is evidence about the server's answer, not about the state of the world.
    # HTTP 000 is the only status that proves nothing was reached, and mmry-client puts its
    # explanation in MMRY_RESPONSE, so that one is passed through as the unreachable case.
    if [[ "${MMRY_HTTP_CODE:-0}" == "000" ]]; then
        echo "Could not reach the service. ${MMRY_RESPONSE:-}"
    elif [[ "${MMRY_HTTP_CODE:-0}" == "404" ]]; then
        echo "Formation ${formation_id} does not exist, or it belongs to another account."
    else
        echo "Could not read the roster for formation ${formation_id} (HTTP ${MMRY_HTTP_CODE:-0}). ${MMRY_RESPONSE:-}"
    fi
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    # No safe way to read it, so hand over what came back rather than half-parsing it.
    echo "$MMRY_RESPONSE"
    exit 0
fi

printf 'Formation %s: %s\n\n' "$formation_id" \
    "$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.formation.objective // "(no objective)"' 2>/dev/null || printf '?')"

# The id first, because it is the thing the sender is here to get. Members who have left are listed
# last and marked, so "left" reads as a fact about the formation rather than as a missing row.
printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
    (.members // [])
    | sort_by(.leftDate != null, .id)
    | .[]
    | "  " + (.id | tostring)
      + "  " + (.role // "member")
      + "  " + (.email // "?")
      + (if .assignment then "  - " + .assignment else "" end)
      + (if .leftDate != null then "   (has left; cannot be addressed)" else "" end)
' 2>/dev/null || { echo "$MMRY_RESPONSE"; exit 0; }

printf '\nDirect a message at one of them with /mmry:formation say "..." --to <id>. Leave the id off\n'
printf 'and the message goes to the whole formation.\n'
exit 0
