#!/usr/bin/env bash
# formation-leave.sh - stop delivery to this session (#31012 QA).
#
# LEAVING IS LOCAL ONLY, and this says so rather than implying otherwise. There is no leave endpoint:
# #31010 shipped create, list, get, update, join and stand-down, and a member is removed by the lead
# or by the formation being stood down. So this stops delivery here and leaves the roster alone.
#
# That is the honest half of the operation and it is the half that matters to the person running it:
# they stop receiving. The roster still listing the session is visible to the lead, who can remove
# it, whereas a session that keeps polling a formation it thinks it is in is invisible to everyone.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"

if [[ -z "$state" ]]; then
    echo "This session is not in a formation."
    exit 0
fi

formation_id="${state%% *}"
bash "${HANDLER_DIR}/formation-state.sh" clear "$session_id"

echo "Left formation ${formation_id}. No further messages will be surfaced here."
echo "The formation's roster still lists this session: leaving is local to this session, and only"
echo "the flight lead or standing the formation down removes a member. Tell the lead if it matters."
exit 0
