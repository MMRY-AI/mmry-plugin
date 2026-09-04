#!/usr/bin/env bash
# formation-leave.sh - release this session's place in a formation, on the service and here (#31194).
#
# WHAT THIS USED TO BE, AND WHY IT CHANGED. Leaving was local to this session: it cleared the
# delivery state and told the service nothing. That was honest and it was still a defect. The
# roster kept counting the session, and because the service allows one live membership per session,
# the next join was refused with a conflict. A session that had finished one job could not be moved
# to the next one without standing the whole formation down on everybody else in it.
#
# THE ONE RULE HERE: never report a release the service did not perform. Somebody told they left,
# who then cannot join anything, is worse off than somebody told plainly that the release was
# refused, because the first has nothing on screen to suggest anything is wrong.
#
# Delivery is stopped locally on EVERY path, including the failures. That is the part this session
# can always do and it is what the person asked for; what changes between paths is what they are
# told about the service.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nothing to release. This needs to run inside a session."
    exit 1
fi

# What this session THINKS it is in. Used only to name the formation if the service does not, and
# never to decide whether to call: a session whose local record is gone is precisely the one that
# is stuck on the service, and returning early here would leave it stuck for good.
state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
known_id="${state%% *}"

mmry_load_config || true

leave_rc=0
mmry_leave_formation "$session_id" || leave_rc=$?

# Stop delivery here regardless of what the service said. Leaving the state behind would keep the
# hook polling a formation the person has finished with, on top of whatever else went wrong.
bash "${HANDLER_DIR}/formation-state.sh" clear "$session_id"

if [[ "$leave_rc" -eq 0 ]]; then
    formation_id="$known_id"
    if [[ -n "${MMRY_JQ:-}" && -n "${MMRY_RESPONSE:-}" ]]; then
        # The service's own answer is preferred over the local record, because it is the only one
        # that can be right when there is no local record at all.
        from_service="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.formationId // empty' 2>/dev/null || true)"
        [[ -n "$from_service" ]] && formation_id="$from_service"
    fi

    if [[ -n "$formation_id" ]]; then
        echo "Left formation ${formation_id}. The service has released this session, so it can join another formation now."
    else
        echo "Left the formation. The service has released this session, so it can join another formation now."
    fi
    echo "No further messages from it will be surfaced here. Everyone else in it is unaffected."
    exit 0
fi

code="${MMRY_HTTP_CODE:-0}"

# 404 is not a failure worth alarming anybody about: the service holds no live membership for this
# session, which is the state the person was asking for. It must still not be dressed up as a
# release that happened.
if [[ "$code" == "404" ]]; then
    echo "The service has no record of this session being in a formation, so there was nothing to release."
    echo "Messages will not be surfaced here either way."
    exit 0
fi

# HTTP 000 is the only status that proves nothing was reached, and mmry-client puts its explanation
# in MMRY_RESPONSE. Every other code is the service answering, and calling that a network problem
# sends somebody to the one place the fault is not (#31195).
if [[ "$code" == "000" ]]; then
    echo "Could not reach the service. ${MMRY_RESPONSE:-}"
    echo "Messages will no longer be surfaced here, but this session may still be listed as a member,"
    echo "and it may be refused if it tries to join another formation. Try again when the service is back."
    exit 1
fi

echo "The service refused to release this session (HTTP ${code}). ${MMRY_RESPONSE:-}"
echo "Messages will no longer be surfaced here, but this session is still a member as far as the"
echo "service is concerned, and joining another formation will be refused until that is resolved."
exit 1
