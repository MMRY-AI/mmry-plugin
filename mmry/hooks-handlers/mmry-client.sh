#!/usr/bin/env bash
# mmry-client.sh — MMRY AI REST API client library (bash+curl)
# Source this file to access all MMRY AI API functions.
# Version: 2.2.0

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
