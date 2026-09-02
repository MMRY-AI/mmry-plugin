#!/usr/bin/env bash
# formation-say.sh - send a message to the other members of this session's formation (#31104).
#
# WHY THIS EXISTS. v1.21 shipped the whole receiving half of formation coordination and no way to
# speak. A session could start a formation, others could join, and every one of them would listen
# faithfully to a channel nobody could put anything into. UAT against production found it: the
# feature was deployed and inert. #31012's two-party proof looked like it covered this, but the
# lead's message in that proof was written straight to the stored procedure, which is not a route
# any customer has.
#
# EXPLICIT RATHER THAN AUTOMATIC. Transmitting is a deliberate act, not a side effect of saving a
# memory. The delivery hook already tells the model not to reply to the formation unless it has
# something worth transmitting, so sending on every save would contradict the instruction the model
# is given, and it would turn ordinary memories into chatter.
#
# THIS DOES NOT FAIL OPEN. That is the opposite of formation-check.sh, deliberately. The hook runs
# after every tool call and must never disturb a session, so it swallows everything. This runs
# because somebody asked for it and is waiting to know whether it worked, so a failure is reported.
# Reporting success for a message nobody received is the failure this whole task exists to fix.
#
# Usage: formation-say.sh "message"
# Exits 0 only when the server confirms it stored the transmission.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

message="${1:-}"
if [[ -z "$message" ]]; then
    echo "Say what? Usage: /mmry:formation say \"what you want the others to know\""
    exit 1
fi

# Long enough to be worth someone else's attention. A one-word transmission interrupts every other
# session in the formation to say nothing.
if [[ "${#message}" -lt 10 ]]; then
    echo "That is too short to be worth interrupting the others with. Say what you are doing or what is blocked."
    exit 1
fi

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nobody to send this as. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nobody to tell. Run /mmry:formation list to see what is active, then /mmry:formation join <id>."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run /mmry:formation leave and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be sent."
    exit 1
fi

if ! mmry_send_formation_transmission "$formation_id" "$session_id" "$message" "$PWD"; then
    code="${MMRY_HTTP_CODE:-0}"
    case "$code" in
        502) echo "Nothing was recorded, so nobody will see this. The formation may have been closed out, or you may no longer be a member of it. Nothing was sent." ;;
        403) echo "Refused. Your account may no longer be active, or you are no longer a member of formation ${formation_id}." ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        400) echo "The server refused the message. ${MMRY_RESPONSE:-}" ;;
        *)   echo "Could not send to formation ${formation_id} (HTTP ${code}). Nothing was recorded." ;;
    esac
    exit 1
fi

# A 2xx is not enough on its own. The processing path swallows an AI failure and returns a result
# rather than throwing, so the only honest signal that anyone will receive this is the count of what
# was stored. This is the #31012 lesson applied at the client: never report delivery on faith.
stored="${MMRY_TRANSMISSION_STORED:-}"
if [[ -z "$stored" || ! "$stored" =~ ^[0-9]+$ || "$stored" -eq 0 ]]; then
    echo "The server accepted the request but recorded nothing, so nobody will see this. Try again shortly."
    exit 1
fi

echo "Sent to formation ${formation_id}. The other members will see it after their next tool call."
exit 0
