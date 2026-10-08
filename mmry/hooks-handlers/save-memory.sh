#!/usr/bin/env bash
# save-memory.sh — Send context to MMRY AI API for server-side processing.
# Thin client: the server decides tier, category, scope, and formatting.
# Usage: bash save-memory.sh --context "..." [--working-dir DIR] [--session-id ID] [--agent-name NAME]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# Parse arguments ��� accept both new and legacy formats
CONTEXT="" WORKING_DIR="" SESSION_ID="" PROJECT_ID="" TASK_ID="" AGENT_NAME=""

# Legacy arguments (ignored — server classifies now)
TIER="" CATEGORY="" SCOPE="" TOPIC="" CONTENT="" SOURCE=""
VISIBILITY="" PERMISSION_GROUP_ID="" SUPERSEDES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --context)      CONTEXT="$2"; shift 2 ;;
        --working-dir)  WORKING_DIR="$2"; shift 2 ;;
        --session-id)   SESSION_ID="$2"; shift 2 ;;
        --project-id)   PROJECT_ID="$2"; shift 2 ;;
        --task-id)      TASK_ID="$2"; shift 2 ;;
        # #30320: the creating agent's name. Optional; see mmry_resolve_agent_name for the fallbacks.
        --agent-name)   AGENT_NAME="$2"; shift 2 ;;
        # Legacy arguments — build context from them for backward compatibility
        --tier)         TIER="$2"; shift 2 ;;
        --category)     CATEGORY="$2"; shift 2 ;;
        --scope)        SCOPE="$2"; shift 2 ;;
        --topic)        TOPIC="$2"; shift 2 ;;
        --content)      CONTENT="$2"; shift 2 ;;
        --source)       SOURCE="$2"; shift 2 ;;
        --visibility)   VISIBILITY="$2"; shift 2 ;;
        --permission-group-id) PERMISSION_GROUP_ID="$2"; shift 2 ;;
        --supersedes)   SUPERSEDES="$2"; shift 2 ;;
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

# #30320: the flag, else a configured name, else the one Claude Code reported for this session.
AGENT_NAME="$(mmry_resolve_agent_name "$AGENT_NAME")"

if mmry_process_context "$CONTEXT" "manual" "$WORKING_DIR" "$SESSION_ID" "$PROJECT_ID" "$TASK_ID" "$VISIBILITY" "$PERMISSION_GROUP_ID" "$AGENT_NAME"; then
    # Bug #8 (#29950): print the server's short ack when available, otherwise fall back.
    echo "${MMRY_PROCESS_MESSAGE:-Memory sent to MMRY AI for processing.}"
else
    _mmry_format_error "save"
    exit 1
fi
