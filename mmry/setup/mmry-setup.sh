#!/usr/bin/env bash
# mmry-setup.sh — Interactive MMRY AI plugin setup
# Uses browser-based device authorization by default.
# Credential fallback (--email + --password) for CI/automation.
#
# Usage:
#   bash mmry-setup.sh
#   bash mmry-setup.sh --email user@acme.com --password "Pass1234!"
#   bash mmry-setup.sh --api-url http://localhost:5291

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
API_URL="https://mmryai.com"
EMAIL=""
PASSWORD=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --join)        shift ;;  # accepted for backwards compatibility, no-op
        --email)       EMAIL="$2"; shift 2 ;;
        --password)    PASSWORD="$2"; shift 2 ;;
        --api-url)     API_URL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage:"
            echo "  Setup (browser):     bash mmry-setup.sh"
            echo "  Setup (CI/automation): bash mmry-setup.sh --email EMAIL --password PASS"
            echo "  Options:             [--api-url URL]"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Check dependencies
if ! command -v curl &>/dev/null; then
    echo "Error: curl is required. Install it and try again."
    exit 1
fi

# jq is required for setup; it ships bundled with the plugin (#30624). Resolve a
# usable one (system or bundled) and stop with a clear message if none works.
source "${PLUGIN_ROOT}/hooks-handlers/lib-jq.sh"
if ! mmry_resolve_jq; then
    mmry_jq_unavailable_message
    exit 1
fi

# Helper: extract a JSON string or numeric value with the resolved jq.
json_value() {
    local json="$1" key="$2"
    printf '%s' "$json" | "$MMRY_JQ" -r ".${key} // empty"
}

json_number() {
    local json="$1" key="$2"
    printf '%s' "$json" | "$MMRY_JQ" -r ".${key} // empty"
}

# Helper: escape a string for safe JSON embedding (handles \, ", newlines)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # \ → \\
    s="${s//\"/\\\"}"   # " → \"
    s="${s//$'\n'/\\n}"  # newline → \n
    s="${s//$'\r'/}"     # strip CR
    printf '%s' "$s"
}

# Helper: open a URL in the user's default browser.
#
# Layered approach (#29765) — tries multiple openers in priority order and stops
# on first success. Stdout and stderr from each attempt are suppressed so the
# setup output stays clean on success. The URL is always displayed in a visually
# distinct block by the caller regardless of whether auto-open succeeded.
open_browser() {
    local url="$1"

    # Test/CI escape hatch: never launch a real browser when MMRY_NO_BROWSER is set.
    # The device-auth e2e tests mock curl but previously still reached this function,
    # which opened real tabs against the live authorize page during a local test run.
    # Returning non-zero keeps the caller's "open the URL yourself" path, which is the
    # correct unattended behavior.
    if [[ -n "${MMRY_NO_BROWSER:-}" ]]; then
        return 1
    fi

    local kernel
    kernel="$(uname -s 2>/dev/null || echo unknown)"

    # WSL detection — /proc/version contains "Microsoft" or "WSL".
    local is_wsl=0
    if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        is_wsl=1
    fi

    _try() {
        # Run a candidate opener with stdout+stderr suppressed; return its exit code.
        "$@" >/dev/null 2>&1
    }

    if [[ "$is_wsl" -eq 1 ]]; then
        # WSL: prefer PowerShell, then wslview, then cmd.exe.
        _try powershell.exe -NoProfile -Command "Start-Process '$url'" && return 0
        _try wslview "$url" && return 0
        _try cmd.exe /c start "" "$url" && return 0
        return 1
    fi

    case "$kernel" in
        Darwin*)
            _try open "$url" && return 0
            return 1
            ;;
        Linux*)
            _try xdg-open "$url" && return 0
            _try gio open "$url" && return 0
            return 1
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Git Bash, MSYS2, Cygwin: prefer PowerShell, then explorer, then cmd, then rundll32.
            _try powershell.exe -NoProfile -Command "Start-Process '$url'" && return 0
            _try explorer.exe "$url" && return 0
            _try cmd.exe /c start "" "$url" && return 0
            _try rundll32.exe url.dll,FileProtocolHandler "$url" && return 0
            return 1
            ;;
    esac
    return 1
}

# Helper: print the authorization URL in a visually distinct block (#29765).
# Always called regardless of whether auto-open succeeded so users on hidden
# terminals or scrolled-past output can still find the URL.
print_url_block() {
    local url="$1"
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo "  Open this URL in your browser to authorize:"
    echo ""
    echo "    $url"
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo ""
}

echo ""
echo "=== MMRY AI Setup ==="
echo ""

if [[ -n "$EMAIL" && -n "$PASSWORD" ]]; then
    # --- Credential fallback (CI/automation) ---
    echo "Authenticating..."
    echo ""

    echo "Logging in..."
    LOGIN_BODY="{\"email\":\"$(json_escape "$EMAIL")\",\"password\":\"$(json_escape "$PASSWORD")\"}"

    LOGIN_TMP="$(mktemp)"
    LOGIN_CODE=$(curl -s -o "$LOGIN_TMP" -w '%{http_code}' \
        --connect-timeout 10 --max-time 25 \
        -X POST "${API_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "$LOGIN_BODY")

    LOGIN_RESP="$(cat "$LOGIN_TMP")"
    rm -f "$LOGIN_TMP"

    if [[ "$LOGIN_CODE" == "401" ]]; then
        echo "Error: Invalid email or password."
        exit 1
    elif [[ "$LOGIN_CODE" != "200" ]]; then
        echo "Error: Login failed (HTTP ${LOGIN_CODE})."
        echo "$LOGIN_RESP"
        exit 1
    fi

    echo "  Logged in successfully."
    TOKEN="$(json_value "$LOGIN_RESP" "token")"

    if [[ -z "$TOKEN" ]]; then
        echo "Error: No token in response."
        exit 1
    fi

    echo "Generating API key..."
    MACHINE_LABEL="$(hostname 2>/dev/null || echo "unknown")"
    KEY_BODY="{\"label\":\"${MACHINE_LABEL}\"}"

    KEY_TMP="$(mktemp)"
    KEY_CODE=$(curl -s -o "$KEY_TMP" -w '%{http_code}' \
        --connect-timeout 10 --max-time 25 \
        -X POST "${API_URL}/api/auth/apikey" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$KEY_BODY")

    KEY_RESP="$(cat "$KEY_TMP")"
    rm -f "$KEY_TMP"

    if [[ "$KEY_CODE" != "201" ]]; then
        echo "Error: API key generation failed (HTTP ${KEY_CODE})."
        echo "$KEY_RESP"
        exit 1
    fi

    API_KEY="$(json_value "$KEY_RESP" "apiKey")"
    if [[ -z "$API_KEY" ]]; then
        echo "Error: No API key in response."
        exit 1
    fi
    echo "  API key generated."

else
    # --- Device authorization flow (default) ---
    if [[ -n "$EMAIL" || -n "$PASSWORD" ]]; then
        echo "Note: Both --email and --password are required for credential mode. Using browser authorization."
        echo ""
    fi

    echo "Setting up MMRY AI..."
    echo ""

    # Step 1: Request device code
    echo "Requesting authorization..."
    DEVICE_TMP="$(mktemp)"
    DEVICE_CODE_HTTP=$(curl -s -o "$DEVICE_TMP" -w '%{http_code}' \
        --connect-timeout 10 --max-time 25 \
        -X POST "${API_URL}/api/auth/device")

    DEVICE_RESP="$(cat "$DEVICE_TMP")"
    rm -f "$DEVICE_TMP"

    if [[ "$DEVICE_CODE_HTTP" != "200" ]]; then
        echo "Error: Could not start device authorization (HTTP ${DEVICE_CODE_HTTP})."
        echo "$DEVICE_RESP"
        exit 1
    fi

    DEVICE_CODE="$(json_value "$DEVICE_RESP" "deviceCode")"
    VERIFICATION_URL="$(json_value "$DEVICE_RESP" "verificationUrl")"
    EXPIRES_IN="$(json_number "$DEVICE_RESP" "expiresIn")"
    POLL_INTERVAL="$(json_number "$DEVICE_RESP" "interval")"

    # Defaults if server doesn't return them
    EXPIRES_IN="${EXPIRES_IN:-600}"
    POLL_INTERVAL="${POLL_INTERVAL:-2}"

    if [[ -z "$DEVICE_CODE" || -z "$VERIFICATION_URL" ]]; then
        echo "Error: Invalid device authorization response."
        exit 1
    fi

    # Step 2: Open browser (#29765 — URL is always shown in a distinct block,
    # auto-open is best-effort, and the polling loop emits periodic status so
    # the script never looks hung).
    AUTHORIZE_URL="${VERIFICATION_URL}?code=${DEVICE_CODE}"
    print_url_block "$AUTHORIZE_URL"
    if open_browser "$AUTHORIZE_URL"; then
        echo "Your browser should open shortly. If it does not, paste the URL above."
    else
        echo "Could not auto-open your browser. Paste the URL above to continue."
    fi
    echo ""
    echo "Waiting for authorization (expires in $((EXPIRES_IN / 60)) minutes)..."

    # Step 3: Poll for authorization
    ELAPSED=0
    NEXT_STATUS_AT=30   # emit a 'still waiting' line every 30 elapsed seconds
    while (( ELAPSED < EXPIRES_IN )); do
        sleep "$POLL_INTERVAL"
        ELAPSED=$(( ELAPSED + POLL_INTERVAL ))

        # #29765 — periodic status so the script never appears hung.
        if (( ELAPSED >= NEXT_STATUS_AT )); then
            mins=$(( ELAPSED / 60 ))
            secs=$(( ELAPSED % 60 ))
            echo "  Still waiting for authorization... (${mins}m ${secs}s elapsed)"
            NEXT_STATUS_AT=$(( ELAPSED + 30 ))
        fi

        STATUS_TMP="$(mktemp)"
        STATUS_CODE=$(curl -s -o "$STATUS_TMP" -w '%{http_code}' \
            --connect-timeout 10 --max-time 15 \
            "${API_URL}/api/auth/device/${DEVICE_CODE}/status")

        STATUS_RESP="$(cat "$STATUS_TMP")"
        rm -f "$STATUS_TMP"

        if [[ "$STATUS_CODE" == "429" ]]; then
            # Rate limited - back off
            sleep "$POLL_INTERVAL"
            ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
            continue
        fi

        if [[ "$STATUS_CODE" != "200" ]]; then
            echo "Error: Status check failed (HTTP ${STATUS_CODE})."
            echo "$STATUS_RESP"
            exit 1
        fi

        DEVICE_STATUS="$(json_value "$STATUS_RESP" "status")"

        if [[ "$DEVICE_STATUS" == "authorized" ]]; then
            API_KEY="$(json_value "$STATUS_RESP" "apiKey")"
            if [[ -z "$API_KEY" ]]; then
                echo "Error: Authorization succeeded but no API key returned."
                exit 1
            fi
            echo "  Authorized!"
            break
        elif [[ "$DEVICE_STATUS" == "expired" ]]; then
            echo "Error: Device code expired. Please run setup again."
            exit 1
        fi
        # status == "pending" - keep polling
    done

    if (( ELAPSED >= EXPIRES_IN )) && [[ -z "${API_KEY:-}" ]]; then
        echo "Error: Authorization timed out. Please run setup again."
        exit 1
    fi
fi

# --- Write config and configure plugin ---

# Write config file
CONFIG_DIR="${HOME}/.claude"
CONFIG_FILE="${CONFIG_DIR}/mmry-config.json"

mkdir -p "$CONFIG_DIR"

"$MMRY_JQ" -n --arg url "$API_URL" --arg key "$API_KEY" '{
    apiUrl: $url,
    authMethod: "apikey",
    apiKey: $key
}' > "$CONFIG_FILE"

echo "  Config written to ${CONFIG_FILE}"

# Auto-approve MMRY AI scripts in Claude Code settings
SETTINGS_FILE="${HOME}/.claude/settings.json"
MMRY_PERMISSIONS=(
    "Bash(*save-memory.sh*)"
    "Bash(*reinforce-memory.sh*)"
    "Bash(*deactivate-memory.sh*)"
    "Bash(*link-memories.sh*)"
    "Bash(*search-memories.sh*)"
    "Bash(*list-groups.sh*)"
    "Bash(*submit-feedback.sh*)"
    "Bash(*mmry-client.sh*)"
)

# Create settings file if it doesn't exist
if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo '{}' > "$SETTINGS_FILE"
fi

# Build jq filter to add permissions
JQ_FILTER='.permissions //= {} | .permissions.allow //= []'
for perm in "${MMRY_PERMISSIONS[@]}"; do
    JQ_FILTER+=" | if (.permissions.allow | index(\"${perm}\")) then . else .permissions.allow += [\"${perm}\"] end"
done

"$MMRY_JQ" "$JQ_FILTER" "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
    && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
echo "  Script permissions configured."

# Install plugin (skip for marketplace/stable installs — already handled by Claude Code)
SCRIPT_DIR_RESOLVED="$(cd "$SCRIPT_DIR" && pwd)"
if [[ "$SCRIPT_DIR_RESOLVED" == *"/.claude/plugins/cache/"* || "$SCRIPT_DIR_RESOLVED" == *"/.claude/mmry/"* ]]; then
    echo "  Plugin already installed via marketplace."
else
    echo "Installing plugin..."
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            # Windows: delegate to PowerShell script (no bash dependency for install)
            if [[ -f "${SCRIPT_DIR}/install.ps1" ]]; then
                powershell.exe -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/install.ps1" 2>/dev/null
                echo "  Plugin installed."
            else
                echo "  Error: install.ps1 not found."
                exit 1
            fi
            ;;
        *)
            # macOS/Linux: use bash install script
            if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
                bash "${SCRIPT_DIR}/install.sh" 2>/dev/null
                echo "  Plugin installed."
            else
                echo "  Error: install.sh not found."
                exit 1
            fi
            ;;
    esac

    # Clear stale cache (local installs only)
    CACHE_DIR="${HOME}/.claude/plugins/cache/internal-plugins/mmry"
    if [[ -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        echo "  Plugin cache cleared."
    fi
fi

echo ""
echo "=== You're all set ==="
echo ""
echo "MMRY AI will remember your decisions, conventions, and context across every"
echo "session. You don't need to do anything special — it works in the background."
echo ""
echo "Restart Claude Code to get started."
echo ""
echo "Anytime you need help, type: /mmry:help"
