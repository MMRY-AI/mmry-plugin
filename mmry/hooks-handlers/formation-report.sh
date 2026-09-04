#!/usr/bin/env bash
# formation-report.sh - the close-out record: who was asked to do what, and how it ended (#31046).
#
# WHY THIS EXISTS. The closing record used to be whatever the lead wrote, drawn from the messages
# the lead happened to read. Nothing said whether each member actually did what it took on, so a
# member that went quiet or gave up left no trace and the summary read as though everything went to
# plan. This prints the other half: one section per member, the work it was given, and the state it
# ended in.
#
# EVERY MEMBER IS IN IT, including one that reported nothing, which reads as unstarted rather than
# being left out. Omission is the failure that would make the whole thing dishonest, so if a member
# is missing from this output that is a defect and not tidiness.
#
# IT CONTAINS NO MESSAGES. Anything said to one recipient was said to that recipient, and this
# record is readable by people who were never in the formation. If the user asks why something
# somebody transmitted is not in the report, that is the answer.
#
# READABLE BEFORE THE FORMATION IS CLOSED OUT, deliberately, so the lead can check the record
# before writing the summary that goes with it.
#
# THIS DOES NOT FAIL OPEN. It runs because somebody asked for the record and is waiting for it, the
# same rule formation-roster.sh follows.
#
# Usage: formation-report.sh [formationId]
#        With no argument it reads this session's own formation from local state.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

formation_id="${1:-}"

if [[ -z "$formation_id" ]]; then
    session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # #31143
    if [[ -z "$session_id" ]]; then
        echo "No session id is available and no formation id was given, so there is no record to show."
        exit 1
    fi
    state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
    if [[ -z "$state" ]]; then
        echo "This session is not in a formation. Give the id instead: /mmry:formation report <formationId>. The record is readable by anybody on the account, including somebody who was never a member."
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
    echo "curl is not available, so the record cannot be read."
    exit 1
fi

if ! mmry_get_formation_close_out "$formation_id"; then
    # #31195: a status is evidence about the server's answer, not about the state of the world.
    # HTTP 000 is the only status that proves nothing was reached.
    if [[ "${MMRY_HTTP_CODE:-0}" == "000" ]]; then
        echo "Could not reach the service. ${MMRY_RESPONSE:-}"
    elif [[ "${MMRY_HTTP_CODE:-0}" == "404" ]]; then
        echo "Formation ${formation_id} does not exist, or it belongs to another account."
    else
        echo "Could not read the record for formation ${formation_id} (HTTP ${MMRY_HTTP_CODE:-0}). ${MMRY_RESPONSE:-}"
    fi
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    # No safe way to read it, so hand over what came back rather than half-parsing it.
    echo "$MMRY_RESPONSE"
    exit 0
fi

# THE SERVER'S OWN RENDERING IS PRINTED, not one built here. The record is assembled in one place
# on purpose: a second version of it in bash would be a second answer that can disagree with the
# one every other reader gets, and the member who reported nothing is exactly the section a
# reimplementation would drop.
record="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.record // empty' 2>/dev/null || true)"

if [[ -z "$record" ]]; then
    echo "$MMRY_RESPONSE"
    exit 0
fi

printf '%s\n' "$record"
exit 0
