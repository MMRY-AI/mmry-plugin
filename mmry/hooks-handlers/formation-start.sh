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

objective="${1:-}"
task_id="${2:-}"

if [[ -z "$objective" ]]; then
    echo "What is the job? Usage: /mmry:formation start \"what the formation is for\""
    exit 1
fi
if [[ "${#objective}" -lt 10 ]]; then
    echo "That objective is too short for anyone joining to know what the job is. Say what the formation is for."
    exit 1
fi

session_id="${CLAUDE_SESSION_ID:-}"
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nothing to enrol as the lead. This needs to run inside a session."
    exit 1
fi

existing="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
    echo "This session is already in formation ${existing%% *}. Run /mmry:formation leave first, or use that one."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so a formation cannot be started."
    exit 1
fi

# The server refuses a session it has never seen, which would otherwise read as a permission
# problem. Same ordering as formation-join.sh.
mmry_register_session "$session_id" "claude-code" "$PWD" 2>/dev/null || true

if ! mmry_create_formation "$objective" "$session_id" "$task_id"; then
    code="${MMRY_HTTP_CODE:-0}"
    case "$code" in
        400) echo "The server refused the objective. ${MMRY_RESPONSE:-}" ;;
        409) echo "This session already belongs to an active formation. Run /mmry:formation leave first." ;;
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
    echo "The formation was created but the server did not return an id this client could read, so this session has not been put in it. Run /mmry:formation list and join it by id."
    exit 1
fi

bash "${HANDLER_DIR}/formation-state.sh" set "$formation_id" "$session_id"

echo "Started formation ${formation_id}: ${objective}"
echo "You are the lead. Tell the others to run /mmry:formation join ${formation_id}, then use /mmry:formation say to keep them posted."
exit 0
