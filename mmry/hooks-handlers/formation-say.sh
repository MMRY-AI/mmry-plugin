#!/usr/bin/env bash
# formation-say.sh - send a message to the other members of this session's formation (#31104).
#
# #31122: this now posts to the formation's own endpoint, which records the message VERBATIM. It
# used to go through memory processing, so a short message was interpreted and often discarded,
# and the ones that survived turned up in the subscriber's own recall, search and export.
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

# #31122: the ten-character floor is GONE, and removing it is a fix rather than a relaxation. It
# was written on the assumption that a very short message was probably an accident, when the real
# reason short messages went nowhere was that the server ran them through AI extraction and
# discarded whatever it judged not worth keeping. "done", "stop" and "files locked" are among the
# most useful things one assistant can tell another. Blank is still refused above.

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
        # One answer covers not-a-member, closed-out and another account's formation, because the
        # server deliberately does not distinguish them: telling them apart would disclose whether
        # somebody else's formation exists.
        403) echo "Refused, and nothing was sent. This session is not a current member of formation ${formation_id}, or the formation has been closed out. Run /mmry:formation join ${formation_id} from this window, or /mmry:formation list to see what is active." ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        # An out-of-date plugin still posting to the old memory-processing path lands here, and the
        # server's message names the endpoint to use. Passing it through verbatim rather than
        # replacing it with a summary: the person reading this is working out why nothing arrived.
        400) echo "The server refused the message. ${MMRY_RESPONSE:-}" ;;
        *)   echo "Could not send to formation ${formation_id} (HTTP ${code}). Nothing was recorded." ;;
    esac
    exit 1
fi

# A 2xx is not enough on its own. The count of what was recorded is checked even now that the
# write is a plain insert, because the rule is about what this script is allowed to claim rather
# than about which failure is currently possible: never report delivery on faith (#31012, DD-70).
stored="${MMRY_TRANSMISSION_STORED:-}"
if [[ -z "$stored" || ! "$stored" =~ ^[0-9]+$ || "$stored" -eq 0 ]]; then
    echo "The server accepted the request but recorded nothing, so nobody will see this. Try again shortly."
    exit 1
fi

echo "Sent to formation ${formation_id}. The other members will see it after their next tool call."
exit 0
