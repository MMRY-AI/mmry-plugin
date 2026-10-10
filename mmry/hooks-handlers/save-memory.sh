#!/usr/bin/env bash
# save-memory.sh — Send context to MMRY AI API for server-side processing.
# Thin client: the server decides tier, category, scope, and formatting.
# Usage: bash save-memory.sh --context "..." [--working-dir DIR] [--session-id ID] [--agent-name NAME]
#
# A SAVE THAT NAMES A STRUCTURED RECORD TYPE TAKES A DIFFERENT ROUTE, and it has to (#31460).
# The ordinary path hands the words to the server's AI layer, which decides tier, category and
# scope and may extract SEVERAL memories from one context - there is no single memory for a set
# of fields to belong to, and /api/memories/process carries no structured block. So when
# --record-type, --record-fields or --record-name is given, this writes ONE memory directly
# through POST /api/memories with the structure attached, and the classification has to come
# from the caller: --tier, --category, --scope, --topic and --content are then all required.
#
# Usage: bash save-memory.sh --tier T --category C --scope S --topic T --content C \
#            --record-type "Migraine log" --record-fields '{"severity":7}' [--record-name NAME]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# Parse arguments ��� accept both new and legacy formats
CONTEXT="" WORKING_DIR="" SESSION_ID="" PROJECT_ID="" TASK_ID="" AGENT_NAME=""

# Legacy arguments (ignored — server classifies now)
TIER="" CATEGORY="" SCOPE="" TOPIC="" CONTENT="" SOURCE=""
VISIBILITY="" PERMISSION_GROUP_ID="" SUPERSEDES=""
# Whether each id flag was GIVEN, which is not the same as non-empty (#31740 QA round 1): an empty
# --supersedes used to be silently ignored, so a replacement was saved as an unrelated memory.
SUPERSEDES_GIVEN="" PERMISSION_GROUP_ID_GIVEN=""

# The structured block (#31460). All three optional, and none of them can cost the save.
RECORD_TYPE="" RECORD_FIELDS="" RECORD_NAME=""

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
        --permission-group-id)
            [[ $# -ge 2 ]] || { echo "Error: --permission-group-id needs a group id." >&2; exit 1; }
            PERMISSION_GROUP_ID="$2"; PERMISSION_GROUP_ID_GIVEN=1; shift 2 ;;
        --supersedes)
            [[ $# -ge 2 ]] || { echo "Error: --supersedes needs the id of the memory being replaced." >&2; exit 1; }
            SUPERSEDES="$2"; SUPERSEDES_GIVEN=1; shift 2 ;;
        # The name of one of the user's structured record types, from list-formats.sh, when this
        # save is an example of it. Naming one that does not exist costs the structure, never
        # the words.
        --record-type)   RECORD_TYPE="$2"; shift 2 ;;
        # The field values read out of the user's own words, as a JSON object keyed by that
        # type's field keys: {"severity":7,"triggers":["red wine","poor sleep"]}
        --record-fields) RECORD_FIELDS="$2"; shift 2 ;;
        # What names this record within its type, for a type whose records are named things that
        # each change on their own. Saving the same name twice UPDATES that record.
        --record-name)   RECORD_NAME="$2"; shift 2 ;;
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

# Checked before either route (#31827), so a structured save is held to the same refusals.
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

# #30320: the flag, else a configured name, else the one Claude Code reported for this session.
AGENT_NAME="$(mmry_resolve_agent_name "$AGENT_NAME")"

# ---------------------------------------------------------------------------
# THE STRUCTURED ROUTE (#31460)
# ---------------------------------------------------------------------------
if [[ -n "$RECORD_TYPE" || -n "$RECORD_FIELDS" || -n "$RECORD_NAME" ]]; then
    missing=""
    [[ -z "$TIER" ]] && missing+=" --tier"
    [[ -z "$CATEGORY" ]] && missing+=" --category"
    [[ -z "$SCOPE" ]] && missing+=" --scope"
    [[ -z "$TOPIC" ]] && missing+=" --topic"
    [[ -z "$CONTENT" ]] && missing+=" --content"
    if [[ -n "$missing" ]]; then
        echo "Error: a save that names a record type is written directly rather than classified" >&2
        echo "       by the server, so it needs:${missing}" >&2
        exit 1
    fi

    if mmry_create_memory "$TIER" "$CATEGORY" "$SCOPE" "$TOPIC" "$CONTENT" \
        "$SOURCE" "$TASK_ID" "$WORKING_DIR" "$PROJECT_ID" "$SESSION_ID" \
        "$VISIBILITY" "$PERMISSION_GROUP_ID" "$SUPERSEDES" "$AGENT_NAME" \
        "$RECORD_TYPE" "$RECORD_FIELDS" "$RECORD_NAME"; then

        if [[ -n "${MMRY_JQ:-}" ]]; then
            new_id="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.id // empty')"
        else
            new_id="$(printf '%s' "$MMRY_RESPONSE" | { grep -o '"id":[0-9]*' || true; } | head -1 | sed 's/"id"://')"
        fi
        echo "NewMemoryID: ${new_id}"

        # WHAT ACTUALLY HAPPENED, REPORTED RATHER THAN ASSUMED. A save that named a record type
        # may still have been stored as ordinary text - an unknown type, a field the type does
        # not declare, a value too wide for its column - and the caller has to be able to tell,
        # because telling the user "recorded in your migraine log" when it was not is worse than
        # saying nothing. The response carries the format block only when the structure was
        # really stored.
        if [[ -n "${MMRY_JQ:-}" ]]; then
            recorded="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.format.name // empty')"
        else
            # Scoped to the format block. Grepping the whole body for "name" would read the
            # customer's own content (#31460 QA round three, also-fix 5).
            recorded="$(_mmry_format_name "$MMRY_RESPONSE")"
        fi

        if [[ -n "$recorded" ]]; then
            echo "RecordedAs: ${recorded}"
        else
            echo "RecordedAs: (none - saved as ordinary text, the structure was not stored)"
        fi
        exit 0
    else
        _mmry_format_error "save"
        # A REFUSED RECORD SAVE STORES NOTHING (#32002). Said here, beside the server's own words,
        # so the assistant does not report a save that did not happen. The SKILL describes it too.
        if [[ "$MMRY_HTTP_CODE" == "400" ]]; then
            echo "Nothing was saved. Check that --record-fields is one valid JSON object, then run the save again." >&2
        fi
        exit 1
    fi
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

# Exit status: 0 saved (and, with --supersedes, the old memory retired); 1 nothing saved;
# 3 saved, but the memory named by --supersedes may still be active.
if mmry_process_context "$CONTEXT" "manual" "$WORKING_DIR" "$SESSION_ID" "$PROJECT_ID" "$TASK_ID" "$VISIBILITY" "$PERMISSION_GROUP_ID" "$AGENT_NAME" "$SUPERSEDES"; then
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
