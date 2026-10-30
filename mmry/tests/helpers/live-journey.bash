#!/usr/bin/env bash
# live-journey.bash - shared plumbing for the live session-start journey specs (#33030).
#
# integration/session-start-live.bats (J-011@claude-code) and integration/codex-session-live.bats
# (J-011@codex) prove one journey on two hosts: a new session on a real account is handed that
# account's startup memories, a planted Foundation memory among them, and nothing of another
# account's. This file holds what both need: the guard that keeps them off production, the calls
# to the service, the planted memories and the reading of what a session was given.
#
# WHAT A RUN NEEDS, AND WHAT HAPPENS WITHOUT IT. A missing key, a production URL or a missing host
# FAILS the spec with the reason. It is never skipped: a journey spec that skips reads as proven
# (the ticket forbids skip and todo outright).
#
#   MMRY_INTEGRATION_API_KEY        account A, the account the session is configured for (the name
#                                   the CI integration job already uses)
#   MMRY_INTEGRATION_OTHER_API_KEY  account B, a second throwaway account on the same service. Its key
#                                   is planted where a mistaken plugin would find it, so a plugin that
#                                   reads the wrong credential hands the session B's memories.
#   MMRY_LIVE_API_URL               optional; default https://integration.mmryai.com. Only Integration
#                                   and a loopback address (an offline stand-in) are accepted.
#
# NEVER A CREDENTIAL IN OUTPUT. No helper echoes a key, writes one anywhere but the private config
# files a session reads, or runs curl verbosely. Failure messages name memory ids and topics only.

LIVE_DEFAULT_URL="https://integration.mmryai.com"

# The jq the plugin bundles, when the machine has none (stock Windows, stock macOS before 15).
live_resolve_jq() {
    if command -v jq >/dev/null 2>&1; then LIVE_JQ="$(command -v jq)"; return 0; fi
    local os arch name
    case "$(uname -s 2>/dev/null)" in
        Linux) os=linux ;; Darwin) os=macos ;; MINGW*|MSYS*|CYGWIN*) os=windows ;; *) os=unknown ;;
    esac
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) arch=unknown ;;
    esac
    name="jq-${os}-${arch}"
    [[ "$os" == "windows" ]] && name="${name}.exe"
    if [[ -f "${PLUGIN_ROOT}/vendor/jq/${name}" ]]; then
        chmod +x "${PLUGIN_ROOT}/vendor/jq/${name}" 2>/dev/null || true
        LIVE_JQ="${PLUGIN_ROOT}/vendor/jq/${name}"
        return 0
    fi
    echo "no jq on PATH and no bundled ${name}" >&2
    return 1
}

# The service URL, refused unless it is Integration or loopback. Sets LIVE_URL.
live_service_url() {
    local url="${MMRY_LIVE_API_URL:-$LIVE_DEFAULT_URL}"
    url="${url%/}"
    case "$url" in
        https://integration.mmryai.com|https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net) ;;
        http://127.0.0.1:*|http://localhost:*) ;;
        *)
            echo "refusing to run a live journey spec against ${url}: only Integration (or a loopback stand-in) is allowed, never production" >&2
            return 1 ;;
    esac
    LIVE_URL="$url"
}

# Everything a run needs, checked once, failing with the reason.
live_require_accounts() {
    live_resolve_jq || return 1
    live_service_url || return 1
    if [[ -z "${MMRY_INTEGRATION_API_KEY:-}" ]]; then
        echo "MMRY_INTEGRATION_API_KEY is not set: the live journey spec needs the throwaway test account's key (never production)" >&2
        return 1
    fi
    if [[ -z "${MMRY_INTEGRATION_OTHER_API_KEY:-}" ]]; then
        echo "MMRY_INTEGRATION_OTHER_API_KEY is not set: the spec needs a second throwaway account, so that a session handed the wrong account's memories is caught" >&2
        return 1
    fi
    if [[ "$MMRY_INTEGRATION_API_KEY" == "$MMRY_INTEGRATION_OTHER_API_KEY" ]]; then
        echo "the two account keys are the same key; the second account must be a different account" >&2
        return 1
    fi
    return 0
}

# live_api METHOD PATH KEY [BODY] - prints the body, then the status code on its own last line.
live_api() {
    local method="$1" path="$2" key="$3" body="${4:-}"
    local args=(-s -w '\n%{http_code}' --connect-timeout 15 --max-time 60 -X "$method"
        -H "X-Api-Key: ${key}" -H "Content-Type: application/json")
    [[ -n "$body" ]] && args+=(-d "$body")
    curl "${args[@]}" "${LIVE_URL}${path}"
}

# live_plant KEY TOPIC CONTENT - stores one Foundation memory; prints its id.
live_plant() {
    local key="$1" topic="$2" content="$3" body resp code id
    body="$("$LIVE_JQ" -cn --arg t "$topic" --arg c "$content" \
        '{memoryTier:"Foundation",category:"Convention",scope:"global",topic:$t,content:$c,source:"bats-33030"}')"
    resp="$(live_api POST /api/memories "$key" "$body")"
    code="${resp##*$'\n'}"
    if [[ "$code" != "201" ]]; then
        echo "planting the Foundation memory '${topic}' returned HTTP ${code}" >&2
        return 1
    fi
    id="$(printf '%s' "${resp%$'\n'*}" | "$LIVE_JQ" -r '.id // empty')"
    [[ -n "$id" ]] || { echo "planting '${topic}' returned no id" >&2; return 1; }
    printf '%s' "$id"
}

# live_retire KEY ID - best effort; a planted memory left behind is harmless on a throwaway account.
live_retire() {
    [[ -n "${2:-}" ]] || return 0
    live_api DELETE "/api/memories/$2" "$1" >/dev/null 2>&1 || true
}

# live_startup_ids KEY WORKDIR - the ids the service itself returns as that account's startup
# memories for that working directory, one per line, sorted. This is what a session should get.
live_startup_ids() {
    local key="$1" dir="$2" resp code
    # MSYS2_ARG_CONV_EXCL: Git Bash would otherwise rewrite a /c/... or /tmp/... argument to C:/...,
    # and the service would be asked about a different directory from the one the hook named.
    resp="$(MSYS2_ARG_CONV_EXCL='*' curl -s -w '\n%{http_code}' --connect-timeout 15 --max-time 60 -G \
        -H "X-Api-Key: ${key}" --data-urlencode "workingDirectory=${dir}" \
        "${LIVE_URL}/api/memories/startup")"
    code="${resp##*$'\n'}"
    [[ "$code" == "200" ]] || { echo "GET /api/memories/startup returned HTTP ${code}" >&2; return 1; }
    printf '%s' "${resp%$'\n'*}" | "$LIVE_JQ" -r '.[].id' | tr -d '\r' | sort
}

# live_file_ids FILE - the ids in a memories file the session-start hook wrote, sorted.
live_file_ids() {
    sed -n 's/^id: *\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" | sort
}

# live_write_config FILE KEY - the config file a customer's setup writes, for this service.
live_write_config() {
    mkdir -p "$(dirname "$1")"
    "$LIVE_JQ" -cn --arg u "$LIVE_URL" --arg k "$2" '{apiUrl:$u,apiKey:$k,authMethod:"apikey"}' > "$1"
}

# live_unix_path PATH - a path the hook handed the model, in the form this shell can open.
live_unix_path() {
    local p="$1"
    if [[ "$p" == [A-Za-z]:[\\/]* ]] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
    else
        printf '%s' "$p"
    fi
}

# live_nonce - unique per run, so a memory from an earlier run can never satisfy this one.
live_nonce() {
    printf 'j011-%s-%s-%s' "$(date +%Y%m%d%H%M%S)" "$$" "${RANDOM}${RANDOM}"
}

# live_timeout SECONDS CMD... - timeout where the machine has one (stock macOS has neither).
live_timeout() {
    local s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
    else "$@"
    fi
}

# live_plant_both - plants one Foundation memory in each account; saves ids and nonces to the
# file's state directory. Account B's is the marker that must never reach the session.
live_plant_both() {
    local state="$1" na nb ia ib
    na="$(live_nonce)a"; nb="$(live_nonce)b"
    ia="$(live_plant "$MMRY_INTEGRATION_API_KEY" "J-011 live proof ${na}" \
        "Planted by ${LIVE_SPEC_NAME:-a live journey spec} (#33030). Marker ${na}.")" || return 1
    printf '%s' "$ia" > "$state/id-a"
    ib="$(live_plant "$MMRY_INTEGRATION_OTHER_API_KEY" "J-011 live proof ${nb}" \
        "Planted in the OTHER account (#33030). Marker ${nb}. A session for account A must never see this.")" || return 1
    printf '%s' "$ib" > "$state/id-b"
    printf '%s' "$na" > "$state/nonce-a"
    printf '%s' "$nb" > "$state/nonce-b"
}

live_retire_both() {
    local state="$1"
    [[ -f "$state/id-a" ]] && live_retire "$MMRY_INTEGRATION_API_KEY" "$(cat "$state/id-a")"
    [[ -f "$state/id-b" ]] && live_retire "$MMRY_INTEGRATION_OTHER_API_KEY" "$(cat "$state/id-b")"
    return 0
}
