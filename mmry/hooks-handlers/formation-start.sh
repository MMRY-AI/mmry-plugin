#!/usr/bin/env bash
# formation-start.sh - start a formation and put this session in it as the lead (#31104).
#
# WHY THIS EXISTS, and it is the same reason as formation-say.sh one level up. v1.21 shipped join,
# leave, list and the delivery hook. It shipped no way to speak, and no way to start a formation
# either. So a plugin user could only ever join something that had been created elsewhere, by
# calling the API by hand. #31104 asks for a message to reach another session with no manual step,
# and creating the formation by hand is a manual step.
#
# The server enrols the creator as Lead as part of creating, so this records local state directly
# rather than calling the join handler, which would be refused: one live membership per session is
# enforced by a unique filtered index in the database and the creator already holds it.
#
# Usage: formation-start.sh "objective" [taskId]
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/lib-formation-roles.sh"

objective="${1:-}"
task_id=""
explicit_name=""
[[ $# -gt 0 ]] && shift
# The task id is the second positional argument; --name "<name>" may come anywhere after the
# objective (#31410). Without it the session's own name is used, as on join.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) explicit_name="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
        *) [[ -z "$task_id" ]] && task_id="$1"; shift ;;
    esac
done

if [[ -z "$objective" ]]; then
    echo "What is the job? Usage: $(mmry_host_formation_ref start '"what the formation is for"')"
    exit 1
fi
if [[ "${#objective}" -lt 10 ]]; then
    echo "That objective is too short for anyone joining to know what the job is. Say what the formation is for."
    exit 1
fi

session_id="$(mmry_session_id)"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nothing to enrol as the lead. This needs to run inside a session."
    exit 1
fi

existing="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
    echo "This session is already in formation ${existing%% *}. Run $(mmry_host_formation_ref leave) first, or use that one."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so a formation cannot be started."
    exit 1
fi

# The server refuses a session it has never seen, which would otherwise read as a permission
# problem. Same ordering as formation-join.sh.
# #31245 QA round 3: the client name is the HOST's, not the constant "claude-code". A Codex session
# registered as claude-code is a session the customer cannot find in their own session list - and
# docs/codex.md tells them, in as many words, that Codex sessions are listed as `codex`. The
# resolver is reached through mmry-client.sh; the fallback keeps the old literal if it is not.
if declare -F mmry_host_client_name >/dev/null 2>&1; then
    _mmry_client_name="$(mmry_host_client_name)"
else
    _mmry_client_name="claude-code"
fi
mmry_register_session "$session_id" "$_mmry_client_name" "$PWD" 2>/dev/null || true

# The lead's name (#31410): the one given, else the session's own, else none.
display_name="$explicit_name"
name_was_captured=""
if [[ -z "$display_name" ]]; then
    display_name="$(mmry_session_display_name "$session_id" 2>/dev/null || true)"
    [[ -n "$display_name" ]] && name_was_captured=1
fi
started=""
if mmry_create_formation "$objective" "$session_id" "$task_id" "$display_name"; then
    started=1
elif [[ "${MMRY_HTTP_CODE:-0}" == "400" && -n "$name_was_captured" ]]; then
    # A captured name must never cost the formation; a refusal writes nothing, so try once without.
    display_name=""
    mmry_create_formation "$objective" "$session_id" "$task_id" "" && started=1
fi
if [[ -z "$started" ]]; then
    code="${MMRY_HTTP_CODE:-0}"
    case "$code" in
        400) echo "The server refused the objective. ${MMRY_RESPONSE:-}" ;;
        409) mmry_formation_held_refusal; echo ;;   # names the formation that holds the session (#32401)
        *)   echo "Could not start a formation (HTTP ${code}). Nothing has been changed locally." ;;
    esac
    exit 1
fi

formation_id=""
if [[ -n "${MMRY_JQ:-}" && -n "${MMRY_RESPONSE:-}" ]]; then
    formation_id="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.id // empty' 2>/dev/null || true)"
fi

# Without an id there is nothing to record, and a formation the session cannot address is worse than
# a clean failure: the hook would never poll it and the lead would believe they were coordinating.
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The formation was created but the server did not return an id this client could read, so this session has not been put in it. Run $(mmry_host_formation_ref list) and join it by id."
    exit 1
fi

bash "${HANDLER_DIR}/formation-state.sh" set "$formation_id" "$session_id"

echo "Started formation ${formation_id}: ${objective}"
if [[ -n "$display_name" ]]; then
    echo "The others see you as \"${display_name}\"."
fi
echo "You are the lead. Tell the others to run $(mmry_host_formation_ref join "${formation_id}"), then use $(mmry_host_formation_ref say) to keep them posted."
# #32683: the lead's own rule, held in lib-formation-roles.sh. The same text the service sends a
# member promoted to lead.
echo "${MMRY_FORMATION_LEAD_RULE}"
# #31789: on Codex the lead is told it hears its members only on its next action, what to do
# instead, and that a Claude Code session should lead. Prints nothing on Claude Code.
if declare -F mmry_host_lead_notice >/dev/null 2>&1; then
    mmry_host_lead_notice start || true
fi
exit 0
