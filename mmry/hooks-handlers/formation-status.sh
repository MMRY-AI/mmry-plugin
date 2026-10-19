#!/usr/bin/env bash
# formation-status.sh - which formation this session is in, who it is in it, and who else is (#31410).
#
# WHY THIS EXISTS. The status command used to print the local state line and nothing else: a
# formation id and the time of the last message surfaced. A person overseeing several assistants
# asked for names, and the status view is the first thing they run. So it now shows, beside the
# formation id, this session's own member id and name, and every member with its name beside its
# member id, the same line the roster prints (mmry_member_line in mmry-client.sh). A member with no
# name is shown by role and member id.
#
# The local state comes first and is printed even when the service cannot be reached, because it
# is the part that answers "is this session listening at all". The roster is read from the service.
#
# Usage: formation-status.sh
# Exits 0 whenever it has told the truth, including "not in a formation" and "could not read the
# members", because there is no failure here a caller acts on differently.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

session_id="$(mmry_session_id)"  # #31143: the command runtime provides CLAUDE_CODE_SESSION_ID
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is no formation state to show. This needs to run inside a session."
    exit 0
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation. Run $(mmry_host_formation_ref list) to see what is active, then $(mmry_host_formation_ref join "<id>")."
    exit 0
fi

formation_id="${state%% *}"
last_seen="${state#* }"
[[ "$last_seen" == "$state" ]] && last_seen=""
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run $(mmry_host_formation_ref leave) and join again."
    exit 0
fi

echo "This session is in formation ${formation_id}."
if [[ -n "$last_seen" ]]; then
    echo "Last message shown here: ${last_seen}"
else
    echo "Last message shown here: none yet"
fi

mmry_load_config || true
if ! command -v curl >/dev/null 2>&1 || ! mmry_get_formation "$formation_id" || [[ -z "${MMRY_JQ:-}" ]]; then
    echo "The members could not be read from the service (HTTP ${MMRY_HTTP_CODE:-0}). Run $(mmry_host_formation_ref roster) to try again."
    exit 0
fi

lines="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r --arg sid "$session_id" "${MMRY_JQ_NAME_DEFS}"'
    ([(.members // [])[] | select(.sessionId == $sid and .leftDate == null)] | last) as $me
    | (if (.formation.objective // "") != "" then "Objective: " + (.formation.objective | mmry_name_clean) else empty end),
      (if $me == null then "This session has no current place on the roster."
       elif (($me.displayName // "") | mmry_name_clean) != ""
       then "You are member \($me.id), shown to the others as \"\($me.displayName | mmry_name_label)\"."
       else "You are member \($me.id), shown to the others as \($me.role // "Member") \($me.id), because this session has no name." end),
      "Members:",
      ((.members // []) | sort_by(.leftDate != null, .id) | .[]
       | mmry_member_line + (if .leftDate == null then "" else "   (has left)" end))
' 2>/dev/null || true)"

if [[ -z "$lines" ]]; then
    echo "The service answered, but the members could not be read from its answer. Run $(mmry_host_formation_ref roster) to see them."
    exit 0
fi
printf '%s\n' "${lines//$'\r'/}"
exit 0
