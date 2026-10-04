#!/usr/bin/env bash
# save-memory.sh — Send context to MMRY AI API for server-side processing.
# Thin client: the server decides tier, category, scope, and formatting.
# Usage: bash save-memory.sh --context "..." [--working-dir DIR] [--session-id ID]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# Parse arguments ��� accept both new and legacy formats
CONTEXT="" WORKING_DIR="" SESSION_ID="" PROJECT_ID="" TASK_ID=""

# Legacy arguments (ignored — server classifies now)
TIER="" CATEGORY="" SCOPE="" TOPIC="" CONTENT="" SOURCE=""
VISIBILITY="" PERMISSION_GROUP_ID="" SUPERSEDES=""
# Whether each id flag was GIVEN, which is not the same as non-empty (#31740 QA round 1): an empty
# --supersedes used to be silently ignored, so a replacement was saved as an unrelated memory.
SUPERSEDES_GIVEN="" PERMISSION_GROUP_ID_GIVEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --context)      CONTEXT="$2"; shift 2 ;;
        --working-dir)  WORKING_DIR="$2"; shift 2 ;;
        --session-id)   SESSION_ID="$2"; shift 2 ;;
        --project-id)   PROJECT_ID="$2"; shift 2 ;;
        --task-id)      TASK_ID="$2"; shift 2 ;;
        # Legacy arguments — build context from them for backward compatibility
        --tier)         TIER="$2"; shift 2 ;;
        --category)     CATEGORY="$2"; shift 2 ;;
        --scope)        SCOPE="$2"; shift 2 ;;
        --topic)        TOPIC="$2"; shift 2 ;;
        --content)      CONTENT="$2"; shift 2 ;;
        --source)       SOURCE="$2"; shift 2 ;;
        --visibility)   VISIBILITY="$2"; shift 2 ;;
        --permission-group-id)
            [[ $# -ge 2 ]] || { echo "Error: --permission-group-id needs a group id." >&2; exit 1; }
            PERMISSION_GROUP_ID="$2"; PERMISSION_GROUP_ID_GIVEN=1; shift 2 ;;
        --supersedes)
            [[ $# -ge 2 ]] || { echo "Error: --supersedes needs the id of the memory being replaced." >&2; exit 1; }
            SUPERSEDES="$2"; SUPERSEDES_GIVEN=1; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Default session_id from env when not passed explicitly. The API resolves
# WorkingDirectory server-side from the registered session record when a
# session_id is sent.
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="${CLAUDE_SESSION_ID:-}"
fi

# Default working directory.
# Bug #9 (Intervals #29949): /tmp/mmry-session-dir lookups removed — those
# files collided across concurrent Claude Code sessions. Working directory is
# now persisted on dbo.Session at SessionStart and resolved by the API when a
# save request supplies session_id but no working_dir. $PWD remains the
# client-side fallback for invocations outside a registered session.
if [[ -z "$WORKING_DIR" && -z "$SESSION_ID" ]]; then
    WORKING_DIR="$PWD"
fi

# If legacy arguments were used, build context from them
if [[ -z "$CONTEXT" && -n "$TOPIC" && -n "$CONTENT" ]]; then
    CONTEXT="Memory to save — Topic: ${TOPIC}. Content: ${CONTENT}."
    [[ -n "$TIER" ]] && CONTEXT="${CONTEXT} Suggested tier: ${TIER}."
    [[ -n "$CATEGORY" ]] && CONTEXT="${CONTEXT} Suggested category: ${CATEGORY}."
    [[ -n "$SCOPE" ]] && CONTEXT="${CONTEXT} Scope: ${SCOPE}."
fi

if [[ -z "$CONTEXT" ]]; then
    echo "Error: --context is required (or legacy --topic and --content)" >&2
    exit 1
fi

# --supersedes: the id of the memory this save REPLACES (#31740). It was parsed above and then
# never sent, so a correction was saved beside the memory it corrected and both stayed live. It is
# checked here, so a typo is refused rather than reaching the API as a different memory's id.
if [[ -n "$SUPERSEDES_GIVEN" ]]; then
    if [[ ! "$SUPERSEDES" =~ ^[1-9][0-9]{0,9}$ ]] || (( 10#$SUPERSEDES > 2147483647 )); then
        echo "Error: --supersedes takes the id of the memory being replaced, a positive whole number (got: ${SUPERSEDES})." >&2
        exit 1
    fi
fi

# --permission-group-id: checked the same way (#31740 QA round 1), so a typo is refused here
# rather than sent as somebody else's group. Group ids are numeric(18,0).
if [[ -n "$PERMISSION_GROUP_ID_GIVEN" && ! "$PERMISSION_GROUP_ID" =~ ^[1-9][0-9]{0,17}$ ]]; then
    echo "Error: --permission-group-id takes a group id, a positive whole number (got: ${PERMISSION_GROUP_ID})." >&2
    exit 1
fi

# Exit status: 0 saved (and, with --supersedes, the old memory retired); 1 nothing saved;
# 3 saved, but the memory named by --supersedes may still be active.
if mmry_process_context "$CONTEXT" "manual" "$WORKING_DIR" "$SESSION_ID" "$PROJECT_ID" "$TASK_ID" "$VISIBILITY" "$PERMISSION_GROUP_ID" "$SUPERSEDES"; then
    # Bug #8 (#29950): print the server's short ack when available, otherwise fall back.
    echo "${MMRY_PROCESS_MESSAGE:-Memory sent to MMRY AI for processing.}"
    if [[ -n "$SUPERSEDES" && "${MMRY_SUPERSEDE_APPLIED:-}" != "true" && "${MMRY_PROCESS_STORED:-}" == "0" ]]; then
        # Nothing was stored (#31740 QA round 1): the AI could not classify it, was unavailable,
        # or found nothing to save. The correction is lost, not saved beside the old memory, and
        # the assistant must not tell the customer otherwise.
        echo "Nothing was saved, so memory ${SUPERSEDES} was not replaced. Try the save again." >&2
        exit 1
    fi
    if [[ -n "$SUPERSEDES" && "${MMRY_SUPERSEDE_APPLIED:-}" != "true" ]]; then
        if [[ -z "${MMRY_SUPERSEDE_APPLIED:-}" ]]; then
            echo "MMRY AI did not report replacing memory ${SUPERSEDES}, so treat it as still active." >&2
        elif [[ "${MMRY_SUPERSEDE_REASON:-}" == "unverified" ]]; then
            # #31740 QA round 2: the save stood and the read-back failed, so nobody knows. Saying
            # "was NOT replaced" here contradicted the server's own "may still be active".
            echo "Whether memory ${SUPERSEDES} was replaced could not be confirmed, so it may still be active." >&2
        else
            echo "Memory ${SUPERSEDES} was NOT replaced and is still active." >&2
        fi
        exit 3
    fi
else
    if [[ -n "$SUPERSEDES" && "${MMRY_HTTP_CODE:-}" =~ ^4[0-9][0-9]$ && "${MMRY_HTTP_CODE}" != "401" \
          && "${MMRY_HTTP_CODE}" != "402" && -n "${MMRY_PROCESS_MESSAGE:-}" ]]; then
        # The API refused the replacement and saved nothing; its message says why and what to do.
        echo "MMRY AI: ${MMRY_PROCESS_MESSAGE}" >&2
    else
        _mmry_format_error "save"
    fi
    exit 1
fi
