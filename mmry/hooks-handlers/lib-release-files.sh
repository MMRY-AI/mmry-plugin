#!/usr/bin/env bash
# lib-release-files.sh - read a release's file list, remove what it does not ship, and compare
# release versions (#32957 fix rounds 4 and 4b).
#
# Shared by self-update.sh, which installs a downloaded release, and session-init.sh, which copies
# the running session's release into the installed copy (~/.claude/mmry, or ~/.codex/mmry on
# Codex). Both decide removals from the same release-files.txt by the same rules; the rules are
# described at the top of self-update.sh and exercised by tests/handlers/self-update-cleanup.bats
# and tests/handlers/session-init-no-downgrade.bats.
#
# Defines functions only. The caller must define log(), which takes one message, and must run with
# its own error handling: every function here reports failure by its return status.
#
# set -euo pipefail is the repository convention for every script in this directory
# (structural/file-integrity.bats). Both callers already run under it, so sourcing this changes
# nothing for them.
set -euo pipefail

# Scratch space for the removal step, made only when it is needed.
_su_scratch=""
_su_scratch_dir() {
    if [[ -z "$_su_scratch" ]]; then
        _su_scratch="$(mktemp -d "${TMPDIR:-/tmp}/mmry-prune-XXXXXX")" || return 1
    fi
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
            [[ "$line" == "release-files.txt" ]] && has_list=1
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

# A release version without any pre-release or build suffix (-rc1, +sha), or failure when it is not
# dotted digits. Taken from the unmerged #31245 fix (mmry-plugin 8aa3e1a).
_su_version_core() {
    local v="${1%%[-+]*}"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    printf '%s' "$v"
}

# Returns 0 when version $1 is strictly newer than $2, 1 when it is not, 2 when either cannot be
# read as a version. Numeric, field by field, so 2.10.0 ranks above 2.9.1, which a string
# comparison gets wrong; a missing field counts as 0, so 2.15 equals 2.15.0. Also from 8aa3e1a.
_su_version_newer() {
    local a b ai bi i n
    a="$(_su_version_core "$1")" || return 2
    b="$(_su_version_core "$2")" || return 2
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
