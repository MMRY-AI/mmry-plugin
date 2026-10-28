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
#
# REMOVING WHAT A RELEASE NO LONGER SHIPS (#32957 fix round 4).
#
# This used to copy a new release over the install folder and delete nothing, so a file a release
# dropped stayed on every customer machine for good: after the AI database rename, the nine old
# database scripts (save-record.sh, query-records.sh and the rest) sat beside their replacements.
# Now, after copying, it removes from the plugin's own folders every file the release does not
# list in its release-files.txt (written by scripts/build-release-files.sh, checked against the
# tree by CI). The rules, all of which tests/handlers/self-update.bats exercises:
#
#   - The list decides. A file is removed only because the release's own list does not name it,
#     never because of what it is called.
#   - Only the folders the release ships are looked in (hooks-handlers, commands, skills, setup,
#     vendor and the rest, read off the list). Files at the top of the install folder are never
#     removed, and neither is any folder the release does not ship.
#   - Kept even when the list does not name them, because the plugin or the customer writes them at
#     run time: anything whose name, or a folder above it, starts with a dot (.mmry-host,
#     .last-self-update, .last-release-cleanup, Claude Code's .in_use, a .mmry-formation-* state
#     file), mmry-config*.json (the credential), *.log, symbolic links, and everything under a
#     listed folder that ends in "/" (the BATS submodules a marketplace clone carries).
#   - Never touched at all, because they are outside the folders above: ~/.claude/mmry-config.json
#     and ~/.codex/mmry-config.json, tool-server/ (lib-tool-server.sh's run-time state), and the
#     Formation state in ${TMPDIR}.
#   - If the list cannot be read, is not a release file list, names an unsafe path, or belongs to a
#     different version than the plugin.json beside it, NOTHING is removed and it says so.
#   - Every removal is printed.
#
# It runs at two moments: right after an update, against the list in the release just downloaded;
# and once per installed version against the installed list, so an install that received this
# release from an older self-update (which knew nothing of the list) is cleaned on its next run.
#
# THE BLOCK OF HASH LINES BELOW IS LOAD-BEARING. DO NOT SHORTEN IT, AND DO NOT PUT CODE ABOVE IT.
#
# bash reads a script as it runs it. An older self-update.sh copies this file over itself and then
# carries on reading at the byte where it stopped, in THIS file's text. Every self-update.sh mmry
# has shipped (702898c through c4aca93) stops between byte 5100 and byte 7345. Measured and pinned
# by tests/handlers/self-update.bats, which runs the 2.15.2 script against this one. So those bytes
# must be comment lines made of nothing but "#": a comment entered half way through is still a
# comment. Prose there would be executed as a command from wherever the old script landed. After
# the hash lines the old process reads the block below and runs it, which is how the update from
# an older version gets its removals done at once instead of on the next run.
#
# Everything after the hash lines is ONE brace group, so bash parses all of it before running any
# of it. A later release that overwrites this file mid-run therefore cannot change what this run
# executes, and the group ends in exit, so nothing after it is ever read.
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
{
set -euo pipefail
shopt -u dotglob

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_VERSION_FILE="${PLUGIN_ROOT}/.claude-plugin/plugin.json"
LAST_UPDATE_SENTINEL="${PLUGIN_ROOT}/.last-self-update"
CLEANUP_MARKER="${PLUGIN_ROOT}/.last-release-cleanup"
RELEASE_LIST_NAME="release-files.txt"
MARKETPLACE_URL="https://raw.githubusercontent.com/MMRY-AI/mmry-plugin/master/.claude-plugin/marketplace.json"
REPO_ARCHIVE_URL="https://github.com/MMRY-AI/mmry-plugin/archive/refs/heads/master.tar.gz"
TMPDIR="${TMPDIR:-/tmp}"
UPDATE_MARKER="${TMPDIR}/.mmry-update-checked"

# Logger — one-line stderr messages so silent bail conditions become discoverable.
log() {
    echo "mmry self-update: $*" >&2
}

# Scratch space for the removal step, made only when it is needed.
_su_scratch=""
_su_scratch_dir() {
    if [[ -z "$_su_scratch" ]]; then
        _su_scratch="$(mktemp -d "${TMPDIR}/mmry-prune-XXXXXX")" || return 1
    fi
}

cleanup() {
    local p
    for p in "${tmp_archive:-}" "${tmp_extract:-}" "$_su_scratch"; do
        [[ -n "$p" ]] && rm -rf "$p"
    done
    return 0
}

# The version in a plugin.json, without jq, so the removal step does not depend on resolving it.
_su_json_version() {
    local content=""
    [[ -f "$1" ]] || return 1
    content="$(<"$1")" 2>/dev/null || return 1
    [[ "$content" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# Read and check a release file list. On success writes its paths, sorted, to $2 and sets
# _SU_LIST_VERSION. On failure returns 1 with the reason in _SU_LIST_PROBLEM and writes nothing
# anyone acts on.
_SU_LIST_VERSION=""
_SU_LIST_PROBLEM=""
_su_load_list() {
    local list="$1" out="$2" header="" line="" first=1 has_list=0 has_self=0 has_manifest=0
    _SU_LIST_VERSION=""
    _SU_LIST_PROBLEM=""
    if [[ ! -f "$list" || ! -r "$list" ]]; then
        _SU_LIST_PROBLEM="there is no readable file list at ${list}"
        return 1
    fi
    IFS= read -r header < "$list" || true
    header="${header%$'\r'}"
    case "$header" in
        "# mmry release files "?*) _SU_LIST_VERSION="${header#\# mmry release files }" ;;
        *) _SU_LIST_PROBLEM="${list} is not a release file list (its first line is not '# mmry release files <version>')"
           return 1 ;;
    esac
    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ -n "$first" ]]; then first=""; continue; fi
            line="${line%$'\r'}"
            case "$line" in
                ""|/*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*)
                    _SU_LIST_PROBLEM="${list} names an unsafe or empty path: '${line}'"
                    return 1 ;;
            esac
            [[ "$line" == "$RELEASE_LIST_NAME" ]] && has_list=1
            [[ "$line" == "hooks-handlers/self-update.sh" ]] && has_self=1
            [[ "$line" == ".claude-plugin/plugin.json" ]] && has_manifest=1
            printf '%s\n' "$line"
        done < "$list"
    } > "$out" || { _SU_LIST_PROBLEM="${_SU_LIST_PROBLEM:-could not read ${list}}"; return 1; }
    if (( has_list == 0 || has_self == 0 || has_manifest == 0 )); then
        _SU_LIST_PROBLEM="${list} does not name the release's own core files, so it is not trusted"
        return 1
    fi
    LC_ALL=C sort -u -o "$out" "$out" || { _SU_LIST_PROBLEM="could not sort ${list}"; return 1; }
}

# Remove from install folder $2 every file, in a folder the release ships, that the checked list
# $1 (from _su_load_list) does not name. $3 is the release version, for the messages.
_su_prune() {
    local list="$1" target="$2" ver="$3"
    local tops="" top="" f="" rel="" base="" keep="" dir="" removed=0
    local found="" gone="" prefixes=""
    case "$target" in
        ""|/|"${HOME:-/}"|"${HOME:-/}/")
            log "refusing to remove anything from '${target}': not a plugin folder"; return 1 ;;
    esac
    if [[ ! -d "$target" || ! -d "$target/hooks-handlers" ]]; then
        log "refusing to remove anything from '${target}': it has no hooks-handlers folder, so it is not a plugin folder"
        return 1
    fi
    _su_scratch_dir || { log "no scratch space; removing nothing from ${target}"; return 1; }
    found="${_su_scratch}/found"
    gone="${_su_scratch}/gone"

    # The folders the release ships, and the folders it keeps whole (entries ending in "/").
    tops="$(awk -F/ 'NF>1 && $1!="" {print $1}' "$list" | LC_ALL=C sort -u)"
    prefixes="$(awk '/\/$/' "$list")"

    : > "$found"
    while IFS= read -r top; do
        [[ -n "$top" ]] || continue
        [[ -d "$target/$top" && ! -L "$target/$top" ]] || continue
        while IFS= read -r f; do
            rel="${f#"$target"/}"
            base="${rel##*/}"
            # Run-time and customer files, kept whatever the list says (see the header).
            case "/$rel" in */.*) continue ;; esac
            case "$base" in mmry-config*.json|*.log) continue ;; esac
            keep=""
            if [[ -n "$prefixes" ]]; then
                while IFS= read -r dir; do
                    [[ -n "$dir" && "$rel" == "$dir"* ]] && { keep=1; break; }
                done <<< "$prefixes"
            fi
            [[ -n "$keep" ]] && continue
            printf '%s\n' "$rel"
        done < <(find "$target/$top" -type f 2>/dev/null) >> "$found"
    done <<< "$tops"

    # Fail closed: comm on input that is not sorted reports shipped files as missing from the list.
    if ! LC_ALL=C sort -u -o "$found" "$found" || ! LC_ALL=C comm -23 "$found" "$list" > "$gone"; then
        log "could not compare ${target} with the release's file list; removing nothing"
        return 1
    fi

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        # Belt and braces: a path the list names is never removed, whatever comm said.
        if grep -Fxq -- "$rel" "$list"; then
            continue
        fi
        if rm -f -- "$target/$rel" 2>/dev/null && [[ ! -e "$target/$rel" ]]; then
            removed=$((removed + 1))
            log "removed ${rel} from ${target} (not in release ${ver})"
            # Take away folders this left empty, up to but not including the shipped folder.
            dir="${rel%/*}"
            while [[ "$dir" == */* ]]; do
                rmdir -- "$target/$dir" 2>/dev/null || break
                dir="${dir%/*}"
            done
        else
            log "could not remove ${rel} from ${target}"
        fi
    done < "$gone"
    if (( removed == 0 )); then
        log "nothing to remove from ${target}: every file in its plugin folders is in release ${ver}"
    fi
    return 0
}

# Where the second, installed copy lives, IN THE STATE DIRECTORY OF THE HOST THIS SESSION BELONGS TO.
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
_su_installed_dir() {
    if declare -F mmry_host_state_dir >/dev/null 2>&1; then
        mmry_host_state_dir
    else
        printf '%s' "${HOME}/.claude/mmry"
    fi
}

# Remove what release list $1 does not name from the plugin root and from the installed copy.
# Writes the once-per-version marker only when both folders were handled.
_su_prune_both() {
    local listfile="$1" ver="$2" sorted="" installed="" ok=1
    _su_scratch_dir || { log "no scratch space; removing nothing"; return 1; }
    sorted="${_su_scratch}/list"
    _su_prune "$sorted" "$PLUGIN_ROOT" "$ver" || ok=0
    installed="$(_su_installed_dir)"
    if [[ -d "$installed" && "$PLUGIN_ROOT" != "$installed" ]]; then
        _su_prune "$sorted" "$installed" "$ver" || ok=0
    fi
    if (( ok == 1 )); then
        printf '%s\n' "$ver" > "$CLEANUP_MARKER" 2>/dev/null || true
    fi
}

# Everything that follows copying a downloaded release into PLUGIN_ROOT. Uses extracted_dir,
# remote_version, local_version and local_version_source.
_su_finish_update() {
    local installed="" listfile="" release_version=""
    installed="$(_su_installed_dir)"
    if [[ -d "$installed" && "$PLUGIN_ROOT" != "$installed" ]]; then
        shopt -s dotglob
        cp -r "${extracted_dir}/mmry/"* "${installed}/" 2>/dev/null || true
        shopt -u dotglob
    fi

    # Removals, decided by the list in the release just downloaded.
    listfile="${extracted_dir}/mmry/${RELEASE_LIST_NAME}"
    if _su_scratch_dir && _su_load_list "$listfile" "${_su_scratch}/list"; then
        release_version="$(_su_json_version "${extracted_dir}/mmry/.claude-plugin/plugin.json" || true)"
        if [[ "$release_version" == "$_SU_LIST_VERSION" ]]; then
            _su_prune_both "$listfile" "$_SU_LIST_VERSION" || true
        else
            log "the release's file list is for '${_SU_LIST_VERSION}' but its plugin.json says '${release_version}'; removing nothing"
        fi
    else
        log "could not read the release's file list (${_SU_LIST_PROBLEM:-no scratch space}); removing nothing"
    fi

    # Write/refresh the sentinel anchor so future runs have a version reference even
    # if .claude-plugin/plugin.json is somehow missing on a future install.
    echo "$remote_version" > "$LAST_UPDATE_SENTINEL" 2>/dev/null || true
    if [[ -d "$installed" && "$PLUGIN_ROOT" != "$installed" ]]; then
        echo "$remote_version" > "${installed}/.last-self-update" 2>/dev/null || true
    fi

    echo "MMRY AI plugin updated: ${local_version} -> ${remote_version} (source: ${local_version_source})" >&2
}

# Once per installed version, remove what the INSTALLED release's list does not name. This is what
# cleans an install that received this release from an older self-update. The first check reads
# two one-line files and starts no process, because this runs on every session start.
_su_reconcile_installed() {
    local listfile="${PLUGIN_ROOT}/${RELEASE_LIST_NAME}" header="" done_ver="" installed_version=""
    if [[ ! -f "$listfile" ]]; then
        log "no release file list installed at ${listfile}; removing nothing"
        return 0
    fi
    IFS= read -r header < "$listfile" 2>/dev/null || true
    header="${header%$'\r'}"
    if [[ -f "$CLEANUP_MARKER" ]]; then
        IFS= read -r done_ver < "$CLEANUP_MARKER" 2>/dev/null || true
        done_ver="${done_ver%$'\r'}"
        [[ -n "$done_ver" && "$header" == "# mmry release files ${done_ver}" ]] && return 0
    fi
    if ! { _su_scratch_dir && _su_load_list "$listfile" "${_su_scratch}/list"; }; then
        log "could not read the installed release's file list (${_SU_LIST_PROBLEM:-no scratch space}); removing nothing"
        return 0
    fi
    installed_version="$(_su_json_version "$LOCAL_VERSION_FILE" || true)"
    if [[ "$installed_version" != "$_SU_LIST_VERSION" ]]; then
        log "the installed file list is for '${_SU_LIST_VERSION}' but plugin.json says '${installed_version}'; removing nothing"
        return 0
    fi
    _su_prune_both "$listfile" "$_SU_LIST_VERSION" || true
    return 0
}

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
# gets a new version is git, not a tarball. The same check keeps the removal step away from a
# checkout: a developer's untracked work is not in any release list.
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

# AN OLDER SELF-UPDATE IS STILL RUNNING, AND HAS JUST INSTALLED THIS RELEASE (see the header).
# It copied the release into PLUGIN_ROOT and then read on into this file. Its variables are still
# set, so finish its update with this release's code: the installed copy, the removals and the
# sentinel. Its EXIT trap calls cleanup, which is the one defined above.
if [[ -n "${extracted_dir:-}" && -n "${tmp_extract:-}" && -n "${remote_version:-}" \
      && "$extracted_dir" == "$tmp_extract"/mmry-plugin-* && -d "${extracted_dir}/mmry" ]]; then
    local_version="${local_version:-unknown}"
    local_version_source="${local_version_source:-unknown}"
    _su_finish_update
    exit 0
fi

trap cleanup EXIT

# Once per installed version: remove what the installed release does not ship.
_su_reconcile_installed

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

# The installed copy, the removals, the sentinel and the message.
_su_finish_update
exit 0
}
