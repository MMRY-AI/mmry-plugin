#!/usr/bin/env bash
# uninstall.sh — Uninstall MMRY AI plugin for Claude Code (macOS/Linux)
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_PATH="${CLAUDE_DIR}/settings.json"
CONFIG_PATH="${CLAUDE_DIR}/mmry-config.json"

# ---------------------------------------------------------------------------------------------
# THIS UNINSTALLER IS CLAUDE CODE'S, AND IT REFUSES TO RUN AS ANY OTHER (#31245 QA round 3).
#
# Round 2 made Step 1 and Step 2 host-aware and stopped, which was worse than the defect it fixed.
# Steps 3 and 4 and the closing message still named ~/.claude, so the Codex copy - which
# session-init.sh puts at ${CODEX_HOME:-~/.codex}/mmry/setup/uninstall.sh on EVERY Codex install -
# deleted ~/.claude/mmry/, cleared the Claude plugin cache, left the Codex install exactly where it
# was, and closed by telling the customer to restart the wrong product. Reproduced on 2026-09-16.
#
# A partial fix that half succeeds is the worst of the three options. uninstall.bat already refuses
# outright; this file now does the same thing, for the same reason: everything below this block
# names ~/.claude - the credential, the settings file, the state directory, the plugin cache and
# the closing line - and there is no reading of it that is correct for another product.
#
# ON CLAUDE CODE NOTHING CHANGES. mmry_host() answers "claude" for every Claude Code install, the
# branch is not taken, and the script proceeds into the same steps it always ran.
# ---------------------------------------------------------------------------------------------
_mmry_uninstall_libs="$(cd "$(dirname "$0")/../hooks-handlers" && pwd 2>/dev/null)" || _mmry_uninstall_libs=""
MMRY_UNINSTALL_HOST="claude"
if [[ -n "$_mmry_uninstall_libs" && -f "${_mmry_uninstall_libs}/lib-host.sh" ]]; then
    # No MMRY_ALLOW_NO_CREDENTIAL here. lib-host.sh only RESOLVES the host when sourced; the
    # refusal that needs the opt-out lives in lib-jq.sh, which this script no longer sources on the
    # Codex path because it no longer has a Codex path. Exporting an opt-out that then survives for
    # the lifetime of the process - and is inherited by everything this script spawns - was itself a
    # QA finding (#31245 QA round 2).
    # shellcheck source=/dev/null
    if source "${_mmry_uninstall_libs}/lib-host.sh" 2>/dev/null; then
        MMRY_UNINSTALL_HOST="$(mmry_host)"
    fi
fi

if [[ "$MMRY_UNINSTALL_HOST" != "claude" ]]; then
    _mmry_codex_home="${CODEX_HOME:-${HOME}/.codex}"
    echo ""
    echo "MMRY AI: this script uninstalls the CLAUDE CODE installation, and you are running the"
    echo "copy that was placed in your Codex directory. It has changed nothing."
    echo ""
    echo "To remove MMRY from Codex: remove the plugin through Codex, then delete these two:"
    echo "  ${_mmry_codex_home}/mmry-config.json"
    echo "  ${_mmry_codex_home}/mmry"
    echo ""
    exit 1
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
# Claude Code's file, and only ever Claude Code's. Nothing here needs a host test any more: the
# refusal at the top of this file is the host test, and it is the only one, so there is no second
# place for the two answers to disagree (#31245 QA round 3).
if [[ ! -f "$SETTINGS_PATH" ]]; then
    echo "  No settings.json found."
else
    # Prefer the resolved jq (system or bundled). #30624. The Python block below
    # remains as a teardown safety net so uninstall can always clean settings.
    #
    # No MMRY_ALLOW_NO_CREDENTIAL opt-out is needed or set. lib-jq.sh's refusal only fires when the
    # host is Codex, and this line is unreachable on Codex - the script exited at the top. Setting
    # it here exported a credential-check override into every child process for the rest of the
    # run, which was a QA finding in its own right (#31245 QA round 3).
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
