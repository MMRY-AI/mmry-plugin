#!/usr/bin/env bash
# formation-debrief.sh - close out this session's formation with the lead's summary (#31104).
#
# WHY THIS EXISTS. Eric's review of 2.8.0 caught the gap in one line: a lead could start a
# formation, speak to it and leave it, and could not close it out without calling the API by hand.
# The close-out is not an administrative afterthought, it is the point of the exercise: the summary
# is consolidated into lasting memories readable by someone who was never in the formation, and the
# running chatter stops being served. Leaving THAT as the one manual step meant most formations
# would simply never be closed out.
#
# The server enforces who may do this (lead, creator or admin), so this does not pre-check the
# role; it translates the refusal into words instead. And per DD-70, the server refuses to record
# the transition when the consolidation stored nothing, returning 502 with the formation left
# Active, so a failure here is safe to retry and is reported as exactly that.
#
# #31046: THE SUMMARY IS NO LONGER THE WHOLE RECORD. The server returns the close-out account with
# the transition - every member, the work it was given, and the state it ended in - and this prints
# it, because a lead that never sees the account cannot notice that a member it thought was
# finished never reported anything. The summary is one part of the record now, and the printing
# order says so: the account first, the confirmation after.
#
# Usage: formation-debrief.sh "summary of what was accomplished, decided, and learned"
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

summary="${1:-}"
if [[ -z "$summary" ]]; then
    echo "A debrief needs a summary. Usage: /mmry:formation debrief \"what was accomplished, what was decided, what went wrong\""
    exit 1
fi
# The server refuses under 20 characters with its own message; catching the obvious case here saves
# a round trip without duplicating the real rule.
if [[ "${#summary}" -lt 20 ]]; then
    echo "That summary is too short to be worth keeping. Say what was accomplished, what was decided, and what went wrong."
    exit 1
fi

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nothing to close out. Run /mmry:formation list to see what is active."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run /mmry:formation leave and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be closed out."
    exit 1
fi

if ! mmry_debrief_formation "$formation_id" "$summary"; then
    code="${MMRY_HTTP_CODE:-0}"
    case "$code" in
        502) echo "The debrief could not be consolidated, so the formation has been left active and nothing was recorded. Try again shortly." ;;
        403) echo "Refused. Only the formation's lead, its creator, or an administrator can close it out." ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        400) echo "The server refused the summary. ${MMRY_RESPONSE:-}" ;;
        409) echo "Formation ${formation_id} is not active, so there is nothing to close out." ;;
        *)   echo "Could not close out formation ${formation_id} (HTTP ${code}). It has not been changed." ;;
    esac
    exit 1
fi

# The formation is closed out server-side. Clear the local state so the delivery hook stops polling
# a channel that will never serve anything again; the membership record itself is the server's.
bash "${HANDLER_DIR}/formation-state.sh" clear "$session_id" 2>/dev/null || true

# THE ACCOUNT, AS THE SERVER RENDERED IT (#31046). Printed rather than rebuilt here: it is
# assembled in one place on purpose, and a second version written in bash would be a second answer
# that can disagree with what every other reader sees. A body that cannot be read is not faked into
# one - the close-out is still readable with /mmry:formation report.
record=""
if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
    record="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.closeOut.record // empty' 2>/dev/null || true)"
fi

if [[ -n "$record" ]]; then
    printf '%s\n\n' "$record"
fi

echo "Formation ${formation_id} closed out. The summary and the account above have been recorded as lasting memories, and the formation's chatter has stopped."
if [[ -z "$record" ]]; then
    echo "The account itself could not be read from the reply. Run /mmry:formation report ${formation_id} to see it."
fi
exit 0
