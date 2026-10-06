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

# NEVER SELF-UPDATE A CHECKOUT (#31411 QA).
#
# This pulls master over PLUGIN_ROOT. When PLUGIN_ROOT is a git working tree that is
# destruction, not an update: it replaces the branch under development with the released
# plugin, and because HEAD does not move, git reports the result as ordinary uncommitted
# edits rather than as the branch having been rolled back.
#
# It happened twice on 2026-09-20, both times reverting 13 files on
# 31411/foundation-integrity, including plugin.json from 2.9.2 to 2.9.1. The second time came
# through the committed test suite: handlers/session-start.bats runs session-start.sh with
# PLUGIN_ROOT pointing at the worktree, and session-start.sh line 11 calls this script. So the
# plugin's own tests could swap the code under test for the released code, which makes any
# result from them evidence of nothing. Nothing was lost only because the branch was pushed.
#
# A .git entry is the signal: present means somebody is working on this tree, and the way it
# gets a new version is git, not a tarball.
#
# Opt-out kept separately for harnesses that copy the plugin somewhere without .git.
if [[ -e "${PLUGIN_ROOT}/../.git" || -e "${PLUGIN_ROOT}/.git" ]]; then
    echo "mmry self-update: plugin root is a git checkout; refusing to overwrite it" >&2
    exit 0
fi
if [[ -n "${MMRY_NO_SELF_UPDATE:-}" ]]; then
    echo "mmry self-update: disabled by MMRY_NO_SELF_UPDATE" >&2
    exit 0
fi

# Resolve jq (system or bundled) for version parsing. #30624. Tolerate a missing
# resolver on a partial install rather than crash this best-effort background check.
#
# MMRY_ALLOW_NO_CREDENTIAL, set here and unset immediately afterwards (#31245 QA round 3).
# lib-jq.sh refuses - by exiting 1 - when a Codex install has no credential of its own, so that
# the client cannot walk on to the other product's account. This program never asks for an
# account: it fetches a public marketplace.json and a public archive, and an update check has no
# business failing because the customer has not signed in yet. It is a plain shell variable, not
# an export, so nothing this script spawns inherits a credential-check override for the rest of
# its life - which was a QA finding in its own right.
MMRY_ALLOW_NO_CREDENTIAL=1
if ! source "$(cd "$(dirname "$0")" && pwd)/lib-jq.sh" 2>/dev/null; then
    echo "mmry self-update: jq resolver unavailable; skipping update check" >&2
    exit 0
fi
unset MMRY_ALLOW_NO_CREDENTIAL

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

# Compare versions: update ONLY when the published version is strictly newer (#31245 UAT).
#
# This used to be `local == remote`, so any difference meant "update", in either direction. A Mac
# Codex install of the 2.10.0 branch build was replaced on its first signed-in session with
# master's 2.9.1, which brought back the 2.9.1 macOS hook defect on every prompt. Anyone whose
# installed copy is ahead of master's marketplace.json is in the same position, including the
# minutes after a release while a CDN still serves the old file.
#
# Numeric, field by field, so 2.10.0 ranks above 2.9.1 (a string comparison gets that wrong).
# A pre-release or build suffix (-rc1, +sha) is ignored. A version that is not dotted digits is
# not guessed at: this is a best-effort background check, and leaving the install alone is the
# outcome that cannot do harm.
_mmry_version_core() {
    local v="${1%%[-+]*}"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    printf '%s' "$v"
}

# Returns 0 when $1 is strictly newer than $2, 1 when it is not, 2 when either is unparseable.
_mmry_version_newer() {
    local a b ai bi i n
    a="$(_mmry_version_core "$1")" || return 2
    b="$(_mmry_version_core "$2")" || return 2
    local IFS=.
    local -a av=($a) bv=($b)
    n=${#av[@]}; (( ${#bv[@]} > n )) && n=${#bv[@]}
    for (( i = 0; i < n; i++ )); do
        ai=$(( 10#${av[i]:-0} )); bi=$(( 10#${bv[i]:-0} ))
        (( ai > bi )) && return 0
        (( ai < bi )) && return 1
    done
    return 1
}

newer_rc=0
_mmry_version_newer "$remote_version" "$local_version" || newer_rc=$?
if (( newer_rc == 2 )); then
    log "cannot compare versions '${local_version}' and '${remote_version}'; leaving the install alone"
    exit 0
fi
if (( newer_rc != 0 )); then
    if [[ "$local_version" != "$remote_version" ]]; then
        log "installed ${local_version} is newer than published ${remote_version}; not downgrading"
    fi
    exit 0
fi

# Published version is newer — download and apply update.
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

# Also update the installed copy, IN THE STATE DIRECTORY OF THE HOST THIS SESSION BELONGS TO.
#
# #31245 QA round 3: this was spelled ${HOME}/.claude/mmry, and self-update.sh runs from
# session-start.sh on EVERY host. On a Codex session it therefore reached across and overwrote the
# OTHER product's installed handlers - a reviewer watched it rewrite a plugin root mid-run - while
# the Codex copy under ~/.codex/mmry was never updated at all, so Codex customers would have sat
# on whatever version they first installed.
#
# mmry_host_state_dir() answers "${HOME}/.claude/mmry" for every Claude Code install, which is the
# literal this line used to carry, so nothing changes there. The fallback covers a partial install
# where lib-host.sh could not be sourced: same literal again, and no worse than before.
if declare -F mmry_host_state_dir >/dev/null 2>&1; then
    INSTALLED_DIR="$(mmry_host_state_dir)"
else
    INSTALLED_DIR="${HOME}/.claude/mmry"
fi
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
