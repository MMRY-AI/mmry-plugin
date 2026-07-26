#!/usr/bin/env bash
# install.sh — Install MMRY AI plugin for Claude Code (macOS/Linux)
set -euo pipefail

SETTINGS_PATH="${HOME}/.claude/settings.json"
MARKETPLACE_NAME="internal-plugins"
PLUGIN_NAME="mmry@internal-plugins"
MARKETPLACE_PATH="$(cd "$(dirname "$0")/../.." && pwd)"

# Ensure .claude directory exists
mkdir -p "${HOME}/.claude"

# Resolve jq (system or bundled). jq ships with the plugin (#30624), so this
# succeeds on every supported platform; only a truly unsupported OS/arch fails.
source "$(cd "$(dirname "$0")/../hooks-handlers" && pwd)/lib-jq.sh"
if ! mmry_resolve_jq; then
    mmry_jq_unavailable_message
    exit 1
fi

# Warn if bash version is below 4 (macOS ships bash 3.2)
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Warning: bash ${BASH_VERSION} detected. Bash 4+ is recommended."
    echo "  macOS: brew install bash"
fi

# Load or create settings
if [[ -f "$SETTINGS_PATH" ]]; then
    settings="$(cat "$SETTINGS_PATH")"
else
    settings='{}'
fi

# Add marketplace and enable plugin using the resolved jq
settings="$(echo "$settings" | "$MMRY_JQ" --arg name "$MARKETPLACE_NAME" --arg path "$MARKETPLACE_PATH" '
    .extraKnownMarketplaces //= {} |
    .extraKnownMarketplaces[$name] //= {"source": {"source": "directory", "path": $path}}
')"

settings="$(echo "$settings" | "$MMRY_JQ" --arg name "$PLUGIN_NAME" '
    .enabledPlugins //= {} |
    .enabledPlugins[$name] //= true
')"

# Disable built-in auto memory (MMRY AI replaces it)
settings="$(echo "$settings" | "$MMRY_JQ" '.autoMemoryEnabled = false')"

echo "$settings" | "$MMRY_JQ" '.' > "$SETTINGS_PATH"

echo "MMRY AI memory plugin installed!"
echo ""
echo "Restart Claude Code to activate."
