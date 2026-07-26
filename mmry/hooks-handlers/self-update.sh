#!/usr/bin/env bash
# self-update.sh — Check for plugin updates and apply them automatically.
# Called from session-start.sh before loading memories.
# Returns 0 if no update needed or update succeeded, 1 on error.
#
# Local version resolution (#29966):
#   1. ${PLUGIN_ROOT}/.claude-plugin/plugin.json .version  (marketplace install)
#   2. ${PLUGIN_ROOT}/.last-self-update                    (legacy install with prior update)
#   3. None of the above                                   (fresh legacy install, bootstrap)
#
# Why the fallback: pre-marketplace installs at ~/.claude/mmry/ have no
# .claude-plugin/ subdirectory. Without a fallback, self-update.sh silently
# bailed on every run for those users. The v1.8 release shipped fixes that
# never reached them. The sentinel file gives legacy installs a version
# anchor going forward.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_VERSION_FILE="${PLUGIN_ROOT}/.claude-plugin/plugin.json"
LAST_UPDATE_SENTINEL="${PLUGIN_ROOT}/.last-self-update"
MARKETPLACE_URL="https://raw.githubusercontent.com/MMRY-AI/mmry-plugin/master/.claude-plugin/marketplace.json"
REPO_ARCHIVE_URL="https://github.com/MMRY-AI/mmry-plugin/archive/refs/heads/master.tar.gz"

# Resolve jq (system or bundled) for version parsing. #30624. Tolerate a missing
# resolver on a partial install rather than crash this best-effort background check.
if ! source "$(cd "$(dirname "$0")" && pwd)/lib-jq.sh" 2>/dev/null; then
    echo "mmry self-update: jq resolver unavailable; skipping update check" >&2
    exit 0
fi

TMPDIR="${TMPDIR:-/tmp}"
UPDATE_MARKER="${TMPDIR}/.mmry-update-checked"

# Logger — one-line stderr messages so silent bail conditions become discoverable.
log() {
    echo "mmry self-update: $*" >&2
}

# Debounce — only check once per hour
if [[ -f "$UPDATE_MARKER" ]]; then
    now=$(date +%s)
    if stat --version &>/dev/null 2>&1; then
        mtime=$(stat -c %Y "$UPDATE_MARKER" 2>/dev/null || echo 0)
    else
        mtime=$(stat -f %m "$UPDATE_MARKER" 2>/dev/null || echo 0)
    fi
    age=$(( now - mtime ))
    if (( age < 3600 )); then
        exit 0
    fi
fi

touch "$UPDATE_MARKER"

# jq is required to parse versions; it is bundled by setup. If somehow
# unavailable, skip this cycle rather than misparse (self-update is best-effort).
if ! mmry_resolve_jq; then
    log "no usable jq; skipping update check this cycle"
    exit 0
fi

# Get local version — fallback chain.
local_version=""
local_version_source=""

if [[ -f "$LOCAL_VERSION_FILE" ]]; then
    local_version="$("$MMRY_JQ" -r '.version // empty' "$LOCAL_VERSION_FILE" 2>/dev/null)"
    [[ -n "$local_version" ]] && local_version_source="plugin.json"
fi

if [[ -z "$local_version" && -f "$LAST_UPDATE_SENTINEL" ]]; then
    local_version="$(head -1 "$LAST_UPDATE_SENTINEL" | tr -d '[:space:]')"
    [[ -n "$local_version" ]] && local_version_source="sentinel"
fi

if [[ -z "$local_version" ]]; then
    # Fresh legacy install with neither plugin.json nor sentinel — bootstrap by
    # forcing the comparison to "0.0.0" so any real remote version triggers an update.
    log "no local version anchor found; treating as fresh legacy install (bootstrap)"
    local_version="0.0.0"
    local_version_source="legacy-bootstrap"
fi

# Get remote version (with short timeout — don't block session start)
remote_json="$(curl -s --connect-timeout 5 --max-time 10 "$MARKETPLACE_URL" 2>/dev/null)" || {
    log "failed to fetch marketplace.json; will retry on next debounce cycle"
    exit 0
}

remote_version="$(printf '%s' "$remote_json" | "$MMRY_JQ" -r '.plugins[0].version // empty' 2>/dev/null)"

if [[ -z "$remote_version" ]]; then
    log "could not parse remote version from marketplace.json"
    exit 0
fi

# Compare versions — if same, no update needed.
if [[ "$local_version" == "$remote_version" ]]; then
    exit 0
fi

# Version mismatch — download and apply update.
tmp_archive="$(mktemp "${TMPDIR}/mmry-update-XXXXXX.tar.gz")"
tmp_extract="$(mktemp -d "${TMPDIR}/mmry-update-XXXXXX")"

cleanup() {
    rm -rf "$tmp_archive" "$tmp_extract"
}
trap cleanup EXIT

# Download the archive
if ! curl -sL --connect-timeout 10 --max-time 30 -o "$tmp_archive" "$REPO_ARCHIVE_URL" 2>/dev/null; then
    log "failed to download update archive"
    exit 0
fi

# Extract
if ! tar -xzf "$tmp_archive" -C "$tmp_extract" 2>/dev/null; then
    log "failed to extract update archive"
    exit 0
fi

# Find the extracted directory (GitHub archives as repo-name-branch/)
extracted_dir="$(find "$tmp_extract" -maxdepth 1 -type d -name 'mmry-plugin-*' | head -1)"
if [[ -z "$extracted_dir" || ! -d "${extracted_dir}/mmry" ]]; then
    log "extracted archive missing expected mmry/ directory"
    exit 0
fi

# Copy updated files to the plugin root, including dotfiles like .claude-plugin/.
# Without dotglob the .claude-plugin/ subdirectory is skipped, which means legacy
# installs never receive the plugin.json that bootstraps version detection on the
# next run. Enable dotglob locally so the migration happens automatically.
shopt -s dotglob
cp -r "${extracted_dir}/mmry/"* "${PLUGIN_ROOT}/" 2>/dev/null || {
    shopt -u dotglob
    log "failed to copy update into plugin root"
    exit 0
}
shopt -u dotglob

# Also update the installed copy if it exists at ~/.claude/mmry/.
INSTALLED_DIR="${HOME}/.claude/mmry"
if [[ -d "$INSTALLED_DIR" && "$PLUGIN_ROOT" != "$INSTALLED_DIR" ]]; then
    shopt -s dotglob
    cp -r "${extracted_dir}/mmry/"* "${INSTALLED_DIR}/" 2>/dev/null || true
    shopt -u dotglob
fi

# Write/refresh the sentinel anchor so future runs have a version reference even
# if .claude-plugin/plugin.json is somehow missing on a future install.
echo "$remote_version" > "$LAST_UPDATE_SENTINEL" 2>/dev/null || true
if [[ -d "$INSTALLED_DIR" && "$PLUGIN_ROOT" != "$INSTALLED_DIR" ]]; then
    echo "$remote_version" > "${INSTALLED_DIR}/.last-self-update" 2>/dev/null || true
fi

echo "MMRY AI plugin updated: ${local_version} -> ${remote_version} (source: ${local_version_source})" >&2
exit 0
