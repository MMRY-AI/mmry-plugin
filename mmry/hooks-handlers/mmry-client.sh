#!/usr/bin/env bash
# mmry-client.sh — MMRY AI REST API client library (bash+curl)
# Source this file to access all MMRY AI API functions.
# Version: tracked in .claude-plugin/plugin.json, not here. This line said 2.2.0 while the
# plugin shipped 2.8.0 (#31104 QA), which is what a hardcoded second copy of a version does.

set -euo pipefail

# Resolve a usable jq (system or bundled) before anything parses JSON. #30624.
# jq is guaranteed by setup; on an unsupported platform MMRY_JQ is empty and
# jq-dependent steps are skipped (entry-point handlers fail fast with a message).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-jq.sh"
mmry_resolve_jq || true

# ============================================================================
# 1. CONFIG LOADING
# ============================================================================

MMRY_API_URL="${MMRY_API_URL:-}"
MMRY_API_KEY="${MMRY_API_KEY:-}"
MMRY_AUTH_METHOD="${MMRY_AUTH_METHOD:-}"

# #30579 Foundation re-injection (UserPromptSubmit hook) settings.
# foundationReinject: "true"/"false" — restate Foundation memories every prompt (default true).
# foundationReinjectTokenCap: max approx tokens re-injected per prompt (default 1500).
MMRY_FOUNDATION_REINJECT="${MMRY_FOUNDATION_REINJECT:-}"
MMRY_FOUNDATION_TOKEN_CAP="${MMRY_FOUNDATION_TOKEN_CAP:-}"
# foundationRefreshSeconds: re-fetch the Foundation cache mid-session at most this often so
# admin-added Foundation memories propagate without a Claude restart. 0 = session-start only.
MMRY_FOUNDATION_REFRESH_SECONDS="${MMRY_FOUNDATION_REFRESH_SECONDS:-}"

# Temp directory — cross-platform
MMRY_TMPDIR="${TMPDIR:-/tmp}"

# HTTP response globals
MMRY_HTTP_CODE=""
MMRY_RESPONSE=""
# Set by mmry_process_context — the server's short ack message (Bug #8 / #29950)
MMRY_PROCESS_MESSAGE=""

# Default API URL
_MMRY_DEFAULT_URL="https://mmryai.com"

_mmry_urlencode() {
    # URL-encode a string using sed (cross-platform, no curl trick)
    local str="$1"
    printf '%s' "$str" | sed \
        -e 's|%|%25|g' \
        -e 's| |%20|g' \
        -e 's|:|%3A|g' \
        -e 's|\\|%5C|g' \
        -e 's|#|%23|g' \
        -e 's|?|%3F|g' \
        -e 's|&|%26|g' \
        -e 's|=|%3D|g' \
        -e 's|+|%2B|g' \
        -e 's|@|%40|g'
}

mmry_load_config() {
    # Discovery order: $MMRY_CONFIG_FILE → plugin root → ~/.claude/
    local config_file=""
    local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"

    if [[ -n "${MMRY_CONFIG_FILE:-}" && -f "${MMRY_CONFIG_FILE}" ]]; then
        config_file="$MMRY_CONFIG_FILE"
    elif [[ -n "$plugin_root" && -f "${plugin_root}/mmry-config.json" ]]; then
        config_file="${plugin_root}/mmry-config.json"
    elif [[ -f "${HOME}/.claude/mmry-config.json" ]]; then
        config_file="${HOME}/.claude/mmry-config.json"
    fi

    if [[ -n "$config_file" ]]; then
        local content
        content="$(cat "$config_file")"

        # Parse config with the resolved jq (system or bundled). No regex
        # fallback: the slow, brittle grep/sed path was the #30608 silent-save
        # bug site and is removed now that jq is guaranteed by setup (#30624).
        if [[ -n "${MMRY_JQ:-}" ]]; then
            local val
            val="$(printf '%s' "$content" | "$MMRY_JQ" -r '.apiUrl // empty')"
            [[ -z "$MMRY_API_URL" && -n "$val" ]] && MMRY_API_URL="$val" || true
            val="$(printf '%s' "$content" | "$MMRY_JQ" -r '.authMethod // empty')"
            [[ -z "$MMRY_AUTH_METHOD" && -n "$val" ]] && MMRY_AUTH_METHOD="$val" || true
            val="$(printf '%s' "$content" | "$MMRY_JQ" -r '.apiKey // empty')"
            [[ -z "$MMRY_API_KEY" && -n "$val" ]] && MMRY_API_KEY="$val" || true
            val="$(printf '%s' "$content" | "$MMRY_JQ" -r '.foundationReinject // empty')"
            [[ -z "${MMRY_FOUNDATION_REINJECT:-}" && -n "$val" ]] && MMRY_FOUNDATION_REINJECT="$val" || true
            val="$(printf '%s' "$content" | "$MMRY_JQ" -r '.foundationReinjectTokenCap // empty')"
            [[ -z "${MMRY_FOUNDATION_TOKEN_CAP:-}" && -n "$val" ]] && MMRY_FOUNDATION_TOKEN_CAP="$val" || true
            val="$(printf '%s' "$content" | "$MMRY_JQ" -r '.foundationRefreshSeconds // empty')"
            [[ -z "${MMRY_FOUNDATION_REFRESH_SECONDS:-}" && -n "$val" ]] && MMRY_FOUNDATION_REFRESH_SECONDS="$val" || true
        fi
    fi

    # Apply defaults
    MMRY_API_URL="${MMRY_API_URL:-$_MMRY_DEFAULT_URL}"
    MMRY_FOUNDATION_REINJECT="${MMRY_FOUNDATION_REINJECT:-true}"
    MMRY_FOUNDATION_TOKEN_CAP="${MMRY_FOUNDATION_TOKEN_CAP:-1500}"
    MMRY_FOUNDATION_REFRESH_SECONDS="${MMRY_FOUNDATION_REFRESH_SECONDS:-86400}"

    # Auto-detect auth method if not set
    if [[ -z "$MMRY_AUTH_METHOD" && -n "$MMRY_API_KEY" ]]; then
        MMRY_AUTH_METHOD="apikey"
    fi
}

# ============================================================================
# 3. FOUNDATION CACHE (#30579)
# ============================================================================

_mmry_mtime() {
    # Epoch mtime of a file, cross-platform. Echoes 0 if missing.
    if stat --version &>/dev/null 2>&1; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

mmry_write_foundation_cache() {
    # Usage: mmry_write_foundation_cache <response-json> <cache-file>
    # Writes Foundation-tier memories (topic + content) to the cache. Best-effort; the
    # UserPromptSubmit hook applies framing at inject time, so this holds just the data.
    local resp="$1" cache="$2"
    if [[ -n "${MMRY_JQ:-}" ]]; then
        printf '%s' "$resp" \
            | "$MMRY_JQ" -r '[.[] | select(.memoryTier == "Foundation")] | .[] | "- \(.topic): \(.content)"' \
            > "$cache" 2>/dev/null || true
    fi
}

mmry_refresh_foundation_cache() {
    # Usage: mmry_refresh_foundation_cache <working-dir> <cache-file>
    # Re-fetches startup memories and rewrites the Foundation cache ONLY on a successful
    # fetch, so an offline/failed refresh never clobbers a good cache. Returns 0 on refresh.
    local workdir="$1" cache="$2"
    if mmry_get_startup_memories "$workdir" >/dev/null 2>&1; then
        mmry_write_foundation_cache "$MMRY_RESPONSE" "$cache"
        return 0
    fi
    return 1
}

# ============================================================================
# 2. AUTHENTICATION
# ============================================================================

_mmry_get_auth_header() {
    if [[ "$MMRY_AUTH_METHOD" == "apikey" && -n "$MMRY_API_KEY" ]]; then
        echo "X-Api-Key: ${MMRY_API_KEY}"
        return 0
    fi

    MMRY_RESPONSE="No API key configured. Run /mmry:setup to configure your account."
    return 1
}

# ============================================================================
# 4. CORE HTTP
# ============================================================================

_mmry_request() {
    # Usage: _mmry_request METHOD PATH [BODY]
    # Sets MMRY_HTTP_CODE and MMRY_RESPONSE globals
    # Returns 0 for 2xx, 1 otherwise
    local method="$1"
    local path="$2"
    local body="${3:-}"

    local auth_header
    auth_header="$(_mmry_get_auth_header)" || {
        MMRY_HTTP_CODE="000"
        MMRY_RESPONSE="Authentication failed"
        return 1
    }

    local tmp_resp
    tmp_resp="$(mktemp "${MMRY_TMPDIR}/mmry-resp-XXXXXX")"

    local curl_args=(-s -o "$tmp_resp" -w '%{http_code}'
        --connect-timeout 10 --max-time 25
        -X "$method"
        -H "$auth_header"
        -H "Content-Type: application/json; charset=utf-8")

    local tmp_body=""
    if [[ -n "$body" ]]; then
        tmp_body="$(mktemp "${MMRY_TMPDIR}/mmry-body-XXXXXX")"
        printf '%s' "$body" > "$tmp_body"
        curl_args+=(--data-binary "@${tmp_body}")
    fi

    local http_code
    http_code=$(curl "${curl_args[@]}" "${MMRY_API_URL}${path}") || {
        rm -f "$tmp_resp" "$tmp_body"
        MMRY_HTTP_CODE="000"
        MMRY_RESPONSE="curl failed"
        return 1
    }

    MMRY_RESPONSE="$(cat "$tmp_resp")"
    rm -f "$tmp_resp" "$tmp_body"
    MMRY_HTTP_CODE="$http_code"

    # 2xx = success
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        return 1
    fi
}

_mmry_format_error() {
    # Format an API error for display. Handles 402 (credits exhausted) specially.
    # Usage: _mmry_format_error [context]
    #   context: optional label like "save" or "search"
    local context="${1:-request}"
    if [[ "$MMRY_HTTP_CODE" == "402" ]]; then
        echo "Credits exhausted. Your MMRY AI subscription has run out of API credits." >&2
        echo "Visit https://mmryai.com or contact your admin to add more credits." >&2
    elif [[ "$MMRY_HTTP_CODE" == "401" ]]; then
        # #30321: the stored credential is present but invalid or expired. Warn clearly and
        # point to setup rather than a bare "Error (HTTP 401)". Kept after the 402 case so
        # credit-exhaustion messaging is not swallowed. The empty-key case (HTTP 000, whose
        # MMRY_RESPONSE is "No API key configured. Run /mmry:setup ...") stays in the generic
        # branch below and keeps its own setup direction.
        echo "MMRY AI: your saved credential is invalid or expired. Memories may not be saved or loaded." >&2
        echo "Run /mmry:setup to re-authenticate." >&2
    else
        echo "Error (HTTP ${MMRY_HTTP_CODE}): ${MMRY_RESPONSE}" >&2
    fi
}

# ============================================================================
# 5. JSON HELPERS
# ============================================================================

_mmry_json_escape() {
    # Escape a string for JSON embedding
    local s="$1"
    s="${s//\\/\\\\}"       # backslash
    s="${s//\"/\\\"}"       # double quote
    s="${s//$'\n'/\\n}"     # newline
    s="${s//$'\r'/\\r}"     # carriage return
    s="${s//$'\t'/\\t}"     # tab
    s="${s//$'\x08'/\\b}"   # backspace
    s="${s//$'\x0c'/\\f}"   # form feed
    printf '%s' "$s"
}

_mmry_build_json() {
    # Build a JSON object from key-value pairs
    # Usage: _mmry_build_json key1 val1 key2 val2 ...
    # Prefix key with # for integer values (no quotes): #key val
    # Empty values are skipped
    local json="{"
    local first=true

    while [[ $# -ge 2 ]]; do
        local key="$1"
        local val="$2"
        shift 2

        # Skip empty values
        [[ -z "$val" ]] && continue || true

        if [[ "$first" == "true" ]]; then
            first=false
        else
            json+=","
        fi

        # Check for integer prefix
        if [[ "$key" == \#* ]]; then
            key="${key:1}"
            json+="\"${key}\":${val}"
        else
            local escaped
            escaped="$(_mmry_json_escape "$val")"
            json+="\"${key}\":\"${escaped}\""
        fi
    done

    json+="}"
    echo -n "$json"
}

# ============================================================================
# 6. API WRAPPERS
# ============================================================================

mmry_create_memory() {
    # Usage: mmry_create_memory TIER CATEGORY SCOPE TOPIC CONTENT [SOURCE] [TASK_ID] [WORKING_DIR] [PROJECT_ID] [SESSION_ID] [VISIBILITY] [PERMISSION_GROUP_ID] [SUPERSEDES_ID]
    local tier="$1" category="$2" scope="$3" topic="$4" content="$5"
    local source="${6:-}" task_id="${7:-}" working_dir="${8:-}"
    local project_id="${9:-}" session_id="${10:-}" visibility="${11:-}"
    local permission_group_id="${12:-}" supersedes_id="${13:-}"

    local body
    body="$(_mmry_build_json \
        "memoryTier" "$tier" \
        "category" "$category" \
        "scope" "$scope" \
        "topic" "$topic" \
        "content" "$content" \
        "source" "$source" \
        "taskDisplayID" "$task_id" \
        "workingDirectory" "$working_dir" \
        "#projectID" "$project_id" \
        "sessionID" "$session_id" \
        "visibility" "$visibility" \
        "#permissionGroupID" "$permission_group_id" \
        "#supersedesId" "$supersedes_id")"

    _mmry_request POST "/api/memories" "$body"
}

mmry_get_memories() {
    # Usage: mmry_get_memories [WORKING_DIR] [SCOPE] [PROJECT_ID] [TIER] [STARTUP_MODE]
    local working_dir="${1:-}" scope="${2:-}" project_id="${3:-}"
    local tier="${4:-}" startup_mode="${5:-}"

    local query=""
    [[ -n "$working_dir" ]] && query+="workingDirectory=$(_mmry_urlencode "$working_dir")&" || true
    [[ -n "$scope" ]] && query+="scope=${scope}&" || true
    [[ -n "$project_id" ]] && query+="projectId=${project_id}&" || true
    [[ -n "$tier" ]] && query+="tier=${tier}&" || true
    [[ -n "$startup_mode" ]] && query+="startupMode=${startup_mode}&" || true

    # Remove trailing &
    query="${query%&}"
    local path="/api/memories"
    [[ -n "$query" ]] && path+="?${query}" || true

    _mmry_request GET "$path"
}

mmry_get_startup_memories() {
    # Usage: mmry_get_startup_memories [WORKING_DIR] [SCOPE] [PROJECT_ID]
    local working_dir="${1:-}" scope="${2:-}" project_id="${3:-}"

    local query=""
    [[ -n "$working_dir" ]] && query+="workingDirectory=$(_mmry_urlencode "$working_dir")&" || true
    [[ -n "$scope" ]] && query+="scope=${scope}&" || true
    [[ -n "$project_id" ]] && query+="projectId=${project_id}&" || true
    query="${query%&}"

    local path="/api/memories/startup"
    [[ -n "$query" ]] && path+="?${query}" || true

    _mmry_request GET "$path"
}

mmry_get_memory_by_id() {
    # Usage: mmry_get_memory_by_id ID
    _mmry_request GET "/api/memories/$1"
}

mmry_search_memories() {
    # Usage: mmry_search_memories KEYWORDS [SCOPE] [PROJECT_ID]
    local keywords="$1" scope="${2:-}" project_id="${3:-}"

    # URL-encode keywords
    local encoded_q
    encoded_q="$(printf '%s' "$keywords" | sed 's/ /%20/g; s/&/%26/g; s/=/%3D/g; s/?/%3F/g; s/#/%23/g')"

    local query="q=${encoded_q}"
    [[ -n "$scope" ]] && query+="&scope=${scope}" || true
    [[ -n "$project_id" ]] && query+="&projectId=${project_id}" || true

    _mmry_request GET "/api/memories/search?${query}"
}

mmry_deactivate_memory() {
    # Usage: mmry_deactivate_memory ID
    _mmry_request DELETE "/api/memories/$1"
}

mmry_reinforce_memory() {
    # Usage: mmry_reinforce_memory ID
    _mmry_request POST "/api/memories/$1/reinforce"
}

mmry_create_link() {
    # Usage: mmry_create_link SOURCE_ID TARGET_ID LINK_TYPE
    local body
    body="$(_mmry_build_json \
        "#targetMemoryId" "$2" \
        "linkType" "$3")"
    _mmry_request POST "/api/memories/$1/links" "$body"
}

mmry_delete_link() {
    # Usage: mmry_delete_link SOURCE_ID TARGET_ID
    _mmry_request DELETE "/api/memories/$1/links/$2"
}

mmry_get_related() {
    # Usage: mmry_get_related MEMORY_ID
    _mmry_request GET "/api/memories/$1/related"
}

mmry_register_session() {
    # Usage: mmry_register_session SESSION_ID CLIENT_NAME [WORKING_DIR] [PROJECT_ID]
    local body
    body="$(_mmry_build_json \
        "sessionId" "$1" \
        "clientName" "$2" \
        "workingDirectory" "${3:-}" \
        "#projectId" "${4:-}")"
    _mmry_request POST "/api/sessions" "$body"
}

mmry_get_active_sessions() {
    _mmry_request GET "/api/sessions/active"
}

# Poll a formation's shared messages since a moment (#31012). The server decides whether this
# caller may hear anything: it returns an empty list rather than an error for a non-member, so that
# a caller cannot tell an empty formation from one it cannot see. Do not turn that silence into an
# error message here.
# Join a formation with this session, and list or leave one (#31012 QA). Delivery was unreachable
# without these: the hook reads the formation from local state and nothing wrote it.
mmry_get_active_formations() {
    _mmry_request GET "/api/formations/active"
}

# One formation and its roster (#31045). This is how a sender learns the roster entry id to
# address a message to: the roster is the formation's own public identifier for each participation,
# and the alternative - naming somebody's session string - is not available to a sender and should
# not be, because a session string is secret-adjacent.
#
# The roster includes members who have left, carrying a leftDate, which is deliberate: the history
# is the point. A caller wanting only the current crew filters on it, and formation-roster.sh does.
mmry_get_formation() {
    # Usage: mmry_get_formation FORMATION_ID
    local formation_id="$1"
    _mmry_request GET "/api/formations/${formation_id}"
}

mmry_join_formation() {
    # Usage: mmry_join_formation FORMATION_ID SESSION_ID
    local formation_id="$1" session_id="$2"
    local body
    body="$(_mmry_build_json "sessionId" "$session_id")"
    _mmry_request POST "/api/formations/${formation_id}/join" "$body"
}

# Release this session's own place in whatever formation it is in (#31194).
#
# There is no formation id, and that is the point rather than an omission. A session has at most
# one membership it has not left, so the service resolves it from the caller's token and the named
# session. That also rescues a session whose local record of the formation is gone, which is every
# session stranded by the leave that used to be local to the plugin: it could not name the
# formation it was stuck in, so an id-carrying route would have left it stuck for good.
#
# Callers must distinguish the outcomes rather than treating any non-zero return as one failure.
# MMRY_HTTP_CODE 404 means the service holds no live membership for this session, which is a
# different thing to say than a refusal, and 000 is the only status that proves nothing was
# reached (#31195).
mmry_leave_formation() {
    # Usage: mmry_leave_formation SESSION_ID
    local session_id="$1"
    local body
    body="$(_mmry_build_json "sessionId" "$session_id")"
    _mmry_request POST "/api/formations/leave" "$body"
}

# Start a formation (#31104). Added alongside the send path for the same reason: without it a
# plugin user could only ever join a formation that something else had created, and nothing they
# have could create one. Requirement 2 of #31104 asks for a message to reach another session with no
# manual step, and calling the API by hand to start the formation is a manual step.
mmry_create_formation() {
    # Usage: mmry_create_formation "objective" SESSION_ID [TASK_ID]
    local objective="$1" session_id="$2" task_id="${3:-}"
    local body
    body="$(_mmry_build_json \
        "objective" "$objective" \
        "sessionId" "$session_id" \
        "taskId"    "$task_id")"
    _mmry_request POST "/api/formations" "$body"
}

# Close out a formation with the lead's summary (#31104). The server consolidates the summary into
# lasting memories and only records the transition if that actually happened; a failed
# consolidation returns 502 with the formation left Active (DD-70), so retrying is safe.
mmry_debrief_formation() {
    # Usage: mmry_debrief_formation FORMATION_ID "summary"
    local formation_id="$1" summary="$2"
    local body
    body="$(_mmry_build_json "context" "$summary")"
    _mmry_request POST "/api/formations/${formation_id}/debrief" "$body"
}

# Send a transmission to a formation (#31104). Until this existed the plugin could join a formation
# and listen, and had no way to speak, so nothing was ever delivered to anybody and the feature
# shipped inert in v1.21.
#
# It goes through the processing endpoint rather than a create-memory call because that is the ONLY
# write path the server binds a formation on: #31011 QA deliberately made a formation id on the
# public create-memory body bind nothing, so a caller cannot forge a binding. The hook type must be
# 'formation' and the id must travel with it; the server ignores a formation id on any other type.
#
# That endpoint is synchronous for this hook type as of #31104 and reports how many memories it
# stored, so a refusal (not a current member, formation closed out) is a real failure here rather
# than the 202 that used to come back either way.
mmry_send_formation_transmission() {
    # Usage: mmry_send_formation_transmission FORMATION_ID SESSION_ID "message" [WORKING_DIR]
    #
    # #31122: this posts to the formation's own endpoint, not to memory processing. It used to go
    # to /api/memories/process with hookType "formation", which ran the message through AI
    # extraction on its way to the memory store. Verified against production on 2026-09-02: a
    # short message came back 502 with stored 0 and "No memories warranted saving from this
    # context", while a longer one from the same session stored fine. The server now refuses the
    # old path outright, so an un-updated plugin gets a 400 that names this route rather than
    # silently delivering nothing.
    #
    # #31045: an optional FIFTH argument names ONE roster entry to address the message to, and the
    # field is omitted entirely when it is empty. Omitting rather than sending null matters: an
    # absent recipient is what every message has been until now and is what the server reads as
    # "the whole formation", so an un-updated caller and an updated caller sending nothing produce
    # byte-identical requests.
    #
    # The roster entry, never a session string. A sender has no legitimate way to learn somebody
    # else's session id, and _mmry_build_json's "#" prefix sends this unquoted because it is a
    # number on the wire.
    local formation_id="$1" session_id="$2" message="$3" working_dir="${4:-}"
    local recipient_member_id="${5:-}"
    local body
    body="$(_mmry_build_json \
        "sessionId"          "$session_id" \
        "content"            "$message" \
        "workingDirectory"   "$working_dir" \
        "#recipientMemberId" "$recipient_member_id")"

    _mmry_request POST "/api/formations/${formation_id}/transmissions" "$body"
    local rc=$?

    # Whether the message was actually recorded. The server returns stored 1 on a 201 and stored 0
    # with its reason on a refusal, so this stays the single signal the caller checks: zero means
    # nobody will receive it, whatever the accompanying message says.
    MMRY_TRANSMISSION_STORED=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        MMRY_TRANSMISSION_STORED="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.stored // empty' 2>/dev/null || true)"
    fi

    return $rc
}

mmry_get_formation_transmissions() {
    # Usage: mmry_get_formation_transmissions FORMATION_ID SESSION_ID [SINCE_ISO8601]
    local formation_id="$1" session_id="$2" since="${3:-}"
    local path="/api/formations/${formation_id}/transmissions?sessionId=${session_id}"
    if [[ -n "$since" ]]; then
        path="${path}&since=${since}"
    fi
    _mmry_request GET "$path"
}

mmry_submit_feedback() {
    # Usage: mmry_submit_feedback TYPE TITLE DESCRIPTION [COMPONENT] [REPRO_STEPS] [ENVIRONMENT]
    local type="$1" title="$2" description="$3"
    local component="${4:-}" repro_steps="${5:-}" environment="${6:-}"

    local body
    body="$(_mmry_build_json \
        "type" "$type" \
        "title" "$title" \
        "description" "$description" \
        "component" "$component" \
        "reproSteps" "$repro_steps" \
        "environment" "$environment")"

    _mmry_request POST "/api/feedback" "$body"
}

mmry_get_my_groups() {
    _mmry_request GET "/api/groups/mine"
}

mmry_set_memory_visibility() {
    # Retarget one memory's visibility (#29901). Creator-only, enforced server-side.
    # Usage: mmry_set_memory_visibility MEMORY_ID VISIBILITY [PERMISSION_GROUP_ID]
    local id="$1" visibility="$2" group_id="${3:-}"

    local body
    body="$(_mmry_build_json         "visibility" "$visibility"         "#permissionGroupID" "$group_id")"

    _mmry_request PUT "/api/memories/${id}/visibility" "$body"
}

mmry_get_default_visibility() {
    # Current user's default memory visibility (#29901).
    _mmry_request GET "/api/users/me/default-visibility"
}

mmry_set_default_visibility() {
    # Usage: mmry_set_default_visibility VISIBILITY [PERMISSION_GROUP_ID]
    # VISIBILITY is Global, Private, or Group; a group id is required for Group.
    local visibility="$1" group_id="${2:-}"

    local body
    body="$(_mmry_build_json \
        "visibility" "$visibility" \
        "#permissionGroupID" "$group_id")"

    _mmry_request PUT "/api/users/me/default-visibility" "$body"
}

mmry_process_context() {
    # Send session context to the server-side AI layer for processing.
    # Usage: mmry_process_context "context" "hookType" \
    #            ["workingDir" "sessionId" "projectId" "taskId" \
    #             "visibility" "permissionGroupId"]
    #
    # Visibility/permissionGroupId are forwarded uniformly to every memory
    # the server extracts from this single context (Option A -- no per-memory
    # AI scope reclassification). Empty values are omitted from the body.
    local context="$1"
    local hook_type="$2"
    local working_dir="${3:-}"
    local session_id="${4:-}"
    local project_id="${5:-}"
    local task_id="${6:-}"
    local visibility="${7:-}"
    local permission_group_id="${8:-}"

    local body
    body=$(_mmry_build_json \
        "context"             "$context" \
        "hookType"            "$hook_type" \
        "workingDirectory"    "$working_dir" \
        "sessionId"           "$session_id" \
        "projectId"           "$project_id" \
        "taskId"              "$task_id" \
        "visibility"          "$visibility" \
        "#permissionGroupID"  "$permission_group_id")

    _mmry_request POST "/api/memories/process" "$body"
    local rc=$?

    # Bug #8 (Intervals #29950): server returns 202 with { "message": "..." }.
    # Surface the message for callers (save-memory.sh, process-context.sh) so
    # they can print the actual ack instead of a generic placeholder.
    MMRY_PROCESS_MESSAGE=""
    if [[ -n "$MMRY_RESPONSE" && -n "${MMRY_JQ:-}" ]]; then
        MMRY_PROCESS_MESSAGE="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.message // empty' 2>/dev/null || true)"
    fi

    # #29912 — record successful save so stop-check.sh can compute time-since-last-save
    # and reset the no-save-counter that drives compliance escalation.
    if [[ $rc -eq 0 ]]; then
        _mmry_mark_save_success || true
    fi

    return $rc
}

# Mark a successful save in the local state files. stop-check.sh reads these to
# (a) format the systemMessage with an incremental last-save anchor and
# (b) reset the per-firing counter that triggers compliance escalation.
# Errors here are non-fatal — the network call already succeeded.
_mmry_mark_save_success() {
    local d="${MMRY_TMPDIR:-${TMPDIR:-/tmp}}"
    date +%s > "${d}/.mmry-last-save" 2>/dev/null || true
    rm -f "${d}/.mmry-stop-count" 2>/dev/null || true
}

mmry_health() {
    # Health check — does not require auth
    local tmp_resp
    tmp_resp="$(mktemp "${MMRY_TMPDIR}/mmry-health-XXXXXX")"
    MMRY_HTTP_CODE=$(curl -s -o "$tmp_resp" -w '%{http_code}' \
        --connect-timeout 10 --max-time 25 \
        "${MMRY_API_URL}/api/health")
    MMRY_RESPONSE="$(cat "$tmp_resp")"
    rm -f "$tmp_resp"
    [[ "$MMRY_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]
}

# ============================================================================
# 7. AUTO-INIT
# ============================================================================

mmry_load_config
