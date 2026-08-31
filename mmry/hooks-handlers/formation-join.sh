#!/usr/bin/env bash
# formation-join.sh - join a formation and make delivery reachable (#31012 QA).
#
# WHY THIS EXISTS. The delivery hook reads which formation a session belongs to from local state,
# and nothing in the shipped plugin ever wrote that state. The mechanism worked when the state was
# populated by hand and was therefore unreachable in practice, which is what QA found. This is the
# missing half: it enrols the session server-side AND records it locally, in that order, so local
# state can never claim a membership the server did not grant.
#
# Usage: formation-join.sh <formationId>
# Exits 0 on success. On failure it exits non-zero and explains itself on stdout, because the
# calling command passes that explanation straight to the user.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

formation_id="${1:-}"
if [[ -z "$formation_id" ]]; then
    echo "Which formation? Usage: /mmry:formation join <formationId>"
    exit 1
fi
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "A formation id is a number. Got: $formation_id"
    exit 1
fi

session_id="${CLAUDE_SESSION_ID:-}"
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nothing to enrol. This needs to run inside a session."
    exit 1
fi

mmry_load_config || true

# Register the session first. A formation is joined by a session, and the server refuses a session
# it has never seen, which would otherwise read as a permission problem.
mmry_register_session "$session_id" "claude-code" "$PWD" 2>/dev/null || true

if ! mmry_join_formation "$formation_id" "$session_id"; then
    code="${MMRY_HTTP_CODE:-0}"
    case "$code" in
        403) echo "Refused. Either you share no access group with whoever created formation ${formation_id}, or your account is not active. An administrator can add you to the group." ;;
        404) echo "Formation ${formation_id} does not exist, or it belongs to another account." ;;
        409) echo "This session already belongs to an active formation. Run /mmry:formation leave first." ;;
        *)   echo "Could not join formation ${formation_id} (HTTP ${code}). Nothing has been changed locally." ;;
    esac
    exit 1
fi

# Only now record it locally. Writing state first would leave a session believing it was in a
# formation the server had refused, and the hook would poll it after every tool call forever.
bash "${HANDLER_DIR}/formation-state.sh" set "$formation_id" "$session_id"

objective=""
if [[ -n "${MMRY_JQ:-}" && -n "${MMRY_RESPONSE:-}" ]]; then
    objective="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.formation.objective // empty' 2>/dev/null || true)"
fi

if [[ -n "$objective" ]]; then
    echo "Joined formation ${formation_id}: ${objective}. Messages from the other members will now be surfaced automatically."
else
    echo "Joined formation ${formation_id}. Messages from the other members will now be surfaced automatically."
fi
exit 0
