#!/usr/bin/env bash
# uninstall.sh — Uninstall MMRY AI plugin for Claude Code (macOS/Linux)
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_PATH="${CLAUDE_DIR}/settings.json"

# #31245 QA round 2: THE CREDENTIAL THIS REMOVES BELONGS TO WHICHEVER HOST THIS COPY IS INSTALLED
# UNDER. Spelled as ~/.claude/mmry-config.json, a Codex uninstall deleted the OTHER product's
# credential - signing the customer out of Claude Code - and left the Codex one exactly where it
# was. The resolver answers "${HOME}/.claude/mmry-config.json" for every Claude Code install, which
# is the literal this line used to carry, so nothing changes there.
export MMRY_ALLOW_NO_CREDENTIAL=1
_mmry_uninstall_libs="$(cd "$(dirname "$0")/../hooks-handlers" && pwd)"
if [[ -f "${_mmry_uninstall_libs}/lib-host.sh" ]] && source "${_mmry_uninstall_libs}/lib-host.sh" 2>/dev/null; then
    CONFIG_PATH="$(mmry_host_config_file)"
    MMRY_UNINSTALL_HOST="$(mmry_host)"
else
    CONFIG_PATH="${CLAUDE_DIR}/mmry-config.json"
    MMRY_UNINSTALL_HOST="claude"
fi

# Handle both marketplace and local install key names
PLUGIN_NAMES=("mmry@mmry-plugin" "mmry@internal-plugins")
MARKETPLACE_NAMES=("mmry-plugin" "internal-plugins")
MMRY_PERMISSIONS=(
    "Bash(*save-memory.sh*)"
    "Bash(*reinforce-memory.sh*)"
    "Bash(*deactivate-memory.sh*)"
    "Bash(*link-memories.sh*)"
    "Bash(*search-memories.sh*)"
    "Bash(*submit-feedback.sh*)"
    "Bash(*mmry-client.sh*)"
)

echo ""
echo "=== MMRY AI Uninstall ==="
echo ""

# Step 1: Remove config file
if [[ -f "$CONFIG_PATH" ]]; then
    rm -f "$CONFIG_PATH"
    echo "  Removed mmry-config.json"
else
    echo "  No config file found (already removed)."
fi

# Step 2: Clean settings.json (plugin, marketplace, permissions)
#
# Claude Code's file, and only ever Claude Code's. A Codex uninstall that edited it would silently
# change an unrelated product's permissions and plugin list - the same trespass the installer is
# already guarded against (#31245).
if [[ "$MMRY_UNINSTALL_HOST" != "claude" ]]; then
    echo "  Codex install: leaving Claude Code's settings.json untouched."
elif [[ ! -f "$SETTINGS_PATH" ]]; then
    echo "  No settings.json found."
else
    # Prefer the resolved jq (system or bundled). #30624. The Python block below
    # remains as a teardown safety net so uninstall can always clean settings.
    # Uninstall runs when the credential is being removed, so it must not be gated on one
    # existing. See the refusal in lib-jq.sh (#31245 QA round 2).
    export MMRY_ALLOW_NO_CREDENTIAL=1
    source "$(cd "$(dirname "$0")/../hooks-handlers" && pwd)/lib-jq.sh" 2>/dev/null || true

    if command -v mmry_resolve_jq &>/dev/null && mmry_resolve_jq; then
        settings="$(cat "$SETTINGS_PATH")"

        # Remove plugin entries
        for name in "${PLUGIN_NAMES[@]}"; do
            settings="$(echo "$settings" | "$MMRY_JQ" --arg name "$name" '
                if .enabledPlugins then del(.enabledPlugins[$name]) else . end
            ')"
        done
        settings="$(echo "$settings" | "$MMRY_JQ" '
            if .enabledPlugins and (.enabledPlugins | length) == 0 then del(.enabledPlugins) else . end
        ')"

        # Remove marketplace entries
        for name in "${MARKETPLACE_NAMES[@]}"; do
            settings="$(echo "$settings" | "$MMRY_JQ" --arg name "$name" '
                if .extraKnownMarketplaces then del(.extraKnownMarketplaces[$name]) else . end
            ')"
        done
        settings="$(echo "$settings" | "$MMRY_JQ" '
            if .extraKnownMarketplaces and (.extraKnownMarketplaces | length) == 0 then del(.extraKnownMarketplaces) else . end
        ')"

        # Re-enable built-in auto memory
        settings="$(echo "$settings" | "$MMRY_JQ" 'del(.autoMemoryEnabled)')"

        # Remove MMRY AI permissions
        for perm in "${MMRY_PERMISSIONS[@]}"; do
            settings="$(echo "$settings" | "$MMRY_JQ" --arg p "$perm" '
                if .permissions.allow then .permissions.allow -= [$p] else . end
            ')"
        done
        settings="$(echo "$settings" | "$MMRY_JQ" '
            if .permissions.allow and (.permissions.allow | length) == 0 then del(.permissions.allow) else . end |
            if .permissions and (.permissions | length) == 0 then del(.permissions) else . end
        ')"

        echo "$settings" | "$MMRY_JQ" '.' > "$SETTINGS_PATH"
        echo "  Cleaned settings.json (plugin, marketplace, permissions)"
    else
        # Try Python fallback
        PY_CMD=""
        if command -v python3 &>/dev/null; then
            PY_CMD="python3"
        elif command -v python &>/dev/null; then
            PY_CMD="python"
        fi

        if [[ -n "$PY_CMD" ]]; then
            "$PY_CMD" - "$SETTINGS_PATH" << 'PYEOF'
import json, sys
sf = sys.argv[1]
plugin_names = ["mmry@mmry-plugin", "mmry@internal-plugins"]
marketplace_names = ["mmry-plugin", "internal-plugins"]
mmry_perms = [
    "Bash(*save-memory.sh*)",
    "Bash(*reinforce-memory.sh*)",
    "Bash(*deactivate-memory.sh*)",
    "Bash(*link-memories.sh*)",
    "Bash(*search-memories.sh*)",
    "Bash(*submit-feedback.sh*)",
    "Bash(*mmry-client.sh*)"
]
with open(sf) as f:
    data = json.load(f)
if "enabledPlugins" in data:
    for name in plugin_names:
        data["enabledPlugins"].pop(name, None)
    if not data["enabledPlugins"]:
        del data["enabledPlugins"]
if "extraKnownMarketplaces" in data:
    for name in marketplace_names:
        data["extraKnownMarketplaces"].pop(name, None)
    if not data["extraKnownMarketplaces"]:
        del data["extraKnownMarketplaces"]
data.pop("autoMemoryEnabled", None)
if "permissions" in data and "allow" in data["permissions"]:
    data["permissions"]["allow"] = [p for p in data["permissions"]["allow"] if p not in mmry_perms]
    if not data["permissions"]["allow"]:
        del data["permissions"]["allow"]
    if not data["permissions"]:
        del data["permissions"]
with open(sf, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
            echo "  Cleaned settings.json (plugin, marketplace, permissions)"
        else
            echo "  Warning: jq and python not found. Manually edit ${SETTINGS_PATH}:"
            echo "    - Remove mmry entries from enabledPlugins"
            echo "    - Remove mmry entries from extraKnownMarketplaces"
            echo "    - Remove MMRY AI permissions from permissions.allow"
        fi
    fi
fi

# Step 3: Remove stable hooks directory
if [[ -d "${HOME}/.claude/mmry" ]]; then
    rm -rf "${HOME}/.claude/mmry"
    echo "  Removed ~/.claude/mmry/"
fi

# Step 4: Clear plugin cache
for cache_name in "mmry-plugin" "internal-plugins"; do
    CACHE_DIR="${CLAUDE_DIR}/plugins/cache/${cache_name}/mmry"
    if [[ -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        echo "  Cleared plugin cache (${cache_name})"
    fi
done

echo ""
echo "MMRY AI uninstalled."
echo "Restart Claude Code to take effect."
echo ""
