#!/usr/bin/env bash
# session-init.sh — SessionStart hook entry point.
# Discovers the plugin root, copies handler scripts into the host's MMRY directory
# (~/.claude/mmry/ on Claude Code, ~/.codex/mmry/ on Codex), then delegates to
# session-start.sh for memory loading.
#
# Extracted from hooks.json inline command to avoid bash -c quoting issues
# on Windows where cmd.exe misinterprets && and || inside single quotes.
#
# #31245: every destination below comes from lib-host.sh instead of being spelled here. With
# MMRY_HOST unset, which is every existing Claude Code install, mmry_host_state_dir returns
# "${HOME}/.claude/mmry" - the same literal these lines used to carry - so the Claude Code
# behaviour is unchanged rather than merely intended to be.

set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-host.sh"

MMRY_STATE_DIR="$(mmry_host_state_dir)"
MMRY_CONFIG_DIR="$(mmry_host_config_dir)"

# Discover plugin root: prefer CLAUDE_PLUGIN_ROOT, fall back to filesystem search.
# Codex exports CLAUDE_PLUGIN_ROOT to plugin hook processes itself
# (codex-rs/hooks/src/engine/discovery.rs), so the preferred path works on both hosts and the
# fallback search is host-scoped rather than always looking in the Claude plugin cache.
P="${CLAUDE_PLUGIN_ROOT:-}"
P="${P//\\//}"  # Normalize backslashes to forward slashes (Windows)

if [[ -z "$P" ]] || [[ ! -d "$P/hooks-handlers" ]]; then
    # `|| true` is load-bearing under `set -euo pipefail` (#31245 QA round 2). When the plugins
    # directory does not exist, find exits non-zero, pipefail promotes that to the pipeline, and
    # set -e killed this script THERE - before the message below could be printed. The customer
    # got a SessionStart hook that exited 1 and said nothing at all, which is the failure this
    # whole ticket exists to stop. It is likelier on Codex than on Claude Code, where
    # ~/.claude/plugins nearly always exists.
    P="$(find "${MMRY_CONFIG_DIR}/plugins" -path "*/mmry/hooks-handlers" -type d 2>/dev/null | head -1 | sed 's|/hooks-handlers$||' || true)"
fi

if [[ -z "$P" ]]; then
    echo "MMRY AI: Could not locate plugin root. Run $(mmry_host_plugin_recovery_ref)"
    exit 0
fi

# Clean old hooks dir, create target directories
# `|| true` (#31844): under set -e a failing rm ended the session start here, before memories loaded.
rm -rf "${MMRY_STATE_DIR}/hooks" 2>/dev/null || true
mkdir -p "${MMRY_STATE_DIR}/hooks-handlers" "${MMRY_STATE_DIR}/setup"

# WRITE DOWN WHICH HOST THIS INSTALL BELONGS TO, BESIDE THE FILES (#31245 QA round 3).
#
# This is the one moment in the product where the host is known for certain and the files are in
# front of us: this script runs as a Codex hook, with MMRY_HOST exported by codex-hook.sh, and it
# is what puts the handlers in the state directory in the first place.
#
# Every later reader is worse placed. The model invokes
# ${CODEX_HOME:-~/.codex}/mmry/hooks-handlers/save-memory.sh in a shell of its own where MMRY_HOST
# is not set and CODEX_HOME may not be either, and lib-host.sh then has nothing but the path to go
# on. A Codex home relocated somewhere without a ".codex" segment defeated that, and the handler
# loaded the OTHER product's credential (reproduced 2026-09-16). The marker is what it reads first.
#
# It is written for BOTH hosts, and on Claude Code it says "claude" - which lib-host.sh ignores,
# because only "codex" changes any answer. Writing it unconditionally means the file is a statement
# of fact rather than a flag whose absence has to be interpreted.
#
# IT IS WRITTEN BEFORE THE HANDLERS ARE COPIED, NOT AFTER. The marker is the only thing that tells
# a model-invoked handler which product it belongs to when the home was relocated, so a state
# directory must never hold handlers without one. Ordering it first means the only way to get that
# combination is a run that failed before it copied anything.
# AND THE WRITE IS CHECKED, BECAUSE THE COMMENT ABOVE WAS NOT TRUE (#31245 QA round 4).
#
# It said the only way to get handlers without a marker is a run that failed before copying
# anything. It was written with `|| true` and followed by an unconditional `cp`, so a write that
# failed - a read-only state dir, a full disk, a permissions problem, an antivirus lock - exited
# 0, wrote no marker, and copied the handlers anyway. Forced by a reviewer, and confirmed: exit
# 0, no marker, handlers present. That combination is the precondition for the credential defect
# the marker exists to prevent, so the invariant is now enforced rather than asserted in prose.
#
# THE CHECK IS A READ-BACK, not the write's exit status. It is the FILE that later readers
# depend on, not the syscall, and the two can disagree.
_mmry_marker_ok=0
if printf '%s
' "$(mmry_host)" > "${MMRY_STATE_DIR}/.mmry-host" 2>/dev/null; then
    _mmry_marker_readback=""
    read -r _mmry_marker_readback < "${MMRY_STATE_DIR}/.mmry-host" 2>/dev/null || _mmry_marker_readback=""
    _mmry_marker_readback="${_mmry_marker_readback//[[:space:]]/}"
    [[ "$_mmry_marker_readback" == "$(mmry_host)" ]] && _mmry_marker_ok=1
fi

# WHAT FAILURE MEANS DIFFERS BY HOST, so the response does too.
#
# On CODEX the marker is the only signal that survives a relocated home in the shell the model
# actually runs handlers in. Handlers installed without it can resolve the host as Claude and
# reach for the other product's credential, so installing them is worse than not installing
# them. This stops - loudly enough to act on, and with exit 0 so the session still starts.
#
# On CLAUDE CODE the marker changes nothing: lib-host.sh acts only on a marker reading "codex",
# so its absence gives exactly the answer every existing install already has. Refusing to
# install there would break working setups to guard against a risk that does not exist on it.
if (( _mmry_marker_ok == 0 )) && [[ "$(mmry_host)" == "codex" ]]; then
    echo "MMRY AI: could not write the host marker at ${MMRY_STATE_DIR}/.mmry-host." >&2
    echo "  Handlers were NOT installed. Without that file a handler cannot tell which" >&2
    echo "  assistant it belongs to, and may read the wrong account's credential." >&2
    echo "  Check that ${MMRY_STATE_DIR} is writable, then start a new session." >&2
    exit 0
fi

# THE PLUGIN ROOT CARRIES THE MARKER TOO (#31245 QA, Security). lib-host.sh looks for the marker
# beside whichever copy of a handler is running. A handler run from Codex's plugin cache, with
# CODEX_HOME unset and a relocated home, found none and resolved as Claude. The plugin-root marker
# names the home on its second line, because two levels above the plugin root is not the home.
# Codex only, and only when the plugin root is inside this Codex home, so a plugin root that Claude
# Code reads is never marked. Best effort: the state-directory marker above is the one that gates.
if [[ "$(mmry_host)" == "codex" ]]; then
    _mmry_norm_path "$(mmry_host_config_dir)"; _mmry_ci_home="$_MMRY_NP"
    _mmry_norm_path "$P"; _mmry_ci_root="$_MMRY_NP"
    if [[ -n "$_mmry_ci_home" && -n "$_mmry_ci_root" ]] && _mmry_path_is_within "$_mmry_ci_root" "$_mmry_ci_home"; then
        printf 'codex\n%s\n' "$(mmry_host_config_dir)" > "$P/.mmry-host" 2>/dev/null || true
    fi
fi

# NEVER PUT AN OLDER RELEASE OVER A NEWER ONE, AND REMOVE WHAT THIS RELEASE DOES NOT SHIP
# (#32957 fix round 4b).
#
# The copy below used to run on every session start with no version check and no deletion. Claude
# Code keeps a session on the plugin cache folder it started from, so a session still running an
# older release, starting or clearing after an update, copied its old handlers over the newer
# installed copy. Measured on a real machine on 2026-10-28: an older mmry-client.sh, without
# mmry_get_entries, beside the newer query-entries.sh, which then failed with "command not found".
#
# So the copy now happens only when this session's release (its .claude-plugin/plugin.json) is the
# same as or newer than the installed copy's. Versions are compared numerically, field by field,
# with any -suffix or +suffix ignored (lib-release-files.sh, taken from the unmerged #31245 fix).
# The installed copy's version is its own .claude-plugin/plugin.json, which self-update.sh and this
# script write, or failing that the .last-self-update self-update.sh writes beside it. When either
# version cannot be read the copy goes ahead as it always did, and that is said on stderr.
#
# An equal version copies on purpose: it is what repairs an installed copy that an older session,
# running a session-init.sh from before this check, has already overwritten.
#
# When it copies, it also removes from the installed copy every file in a folder the release ships
# that this release's release-files.txt does not list, by self-update.sh's rules and code
# (lib-release-files.sh): the credential, dot files, logs, run-time state and anything outside the
# shipped folders are kept, and with no readable list nothing is removed. A git checkout is never
# used to remove anything, because a developer's new handler is in no list yet.
log() {
    echo "mmry session-init: $*" >&2
}
_mmry_install=1
_mmry_root_ver=""
_mmry_inst_ver=""
_mmry_inst_json_ver=""
_mmry_have_lib=0
_su_scratch=""
# shellcheck source=/dev/null
# Checked for first: stock macOS bash 3.2 ends the script on a source of a missing file.
_mmry_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-release-files.sh"
if [[ -f "$_mmry_lib" && -r "$_mmry_lib" ]] && source "$_mmry_lib" 2>/dev/null \
        && declare -F _su_version_newer >/dev/null 2>&1; then
    _mmry_have_lib=1
    _mmry_root_ver="$(_su_json_version "$P/.claude-plugin/plugin.json" || true)"
    _mmry_inst_json_ver="$(_su_json_version "${MMRY_STATE_DIR}/.claude-plugin/plugin.json" || true)"
    _mmry_inst_ver="$_mmry_inst_json_ver"
    if [[ -z "$_mmry_inst_ver" && -f "${MMRY_STATE_DIR}/.last-self-update" ]]; then
        IFS= read -r _mmry_inst_ver < "${MMRY_STATE_DIR}/.last-self-update" 2>/dev/null || true
        _mmry_inst_ver="${_mmry_inst_ver//[[:space:]]/}"
    fi
    if [[ -z "$_mmry_root_ver" ]]; then
        log "this session's release at ${P} has no readable version; installing it as before"
    elif [[ -z "$_mmry_inst_ver" ]]; then
        for _mmry_f in "${MMRY_STATE_DIR}"/hooks-handlers/*.sh; do
            if [[ -f "$_mmry_f" ]]; then
                log "the installed copy at ${MMRY_STATE_DIR} has no readable version; installing ${_mmry_root_ver} over it as before"
                break
            fi
        done
    else
        _mmry_cmp=0
        _su_version_newer "$_mmry_inst_ver" "$_mmry_root_ver" || _mmry_cmp=$?
        if (( _mmry_cmp == 0 )); then
            _mmry_install=0
            log "the installed copy at ${MMRY_STATE_DIR} is ${_mmry_inst_ver}, newer than this session's ${_mmry_root_ver}; leaving it as it is"
        elif (( _mmry_cmp == 2 )); then
            log "cannot compare the installed version '${_mmry_inst_ver}' with this session's '${_mmry_root_ver}'; installing as before"
        fi
    fi
else
    log "lib-release-files.sh could not be loaded; installing without the version check, removing nothing"
fi

# IS THIS A VERIFIED RELEASE (#33033)? Its release-files.txt reads as a release file list, names
# its own core files and is for the version its plugin.json states. Only then does this session
# record its version in the installed copy or remove anything from it. A root whose plugin.json
# overstates its version (a hand-edited or half-copied folder) used to have that version written
# into the installed copy before any check, which then pinned it: every real release below it was
# refused as older. Checked once, when first needed, because most sessions need neither.
_mmry_list_state=""    # "", "ok" or "bad"
_mmry_list_problem=""
_mmry_verified_release() {
    case "$_mmry_list_state" in ok) return 0 ;; bad) return 1 ;; esac
    _mmry_list_state="bad"
    if (( _mmry_have_lib != 1 )) || [[ -z "$_mmry_root_ver" ]]; then
        _mmry_list_problem="this session's release has no readable version"
        return 1
    fi
    if ! { _su_scratch_dir && _su_load_list "$P/release-files.txt" "${_su_scratch}/list"; }; then
        _mmry_list_problem="could not read this release's file list (${_SU_LIST_PROBLEM:-no scratch space})"
        return 1
    fi
    if [[ "$_SU_LIST_VERSION" != "$_mmry_root_ver" ]]; then
        _mmry_list_problem="this release's file list is for '${_SU_LIST_VERSION}' but its plugin.json says '${_mmry_root_ver}'"
        return 1
    fi
    _mmry_list_state="ok"
}

# Remove from the installed copy what this release does not ship. Cheap when there is nothing to
# do: once a version has been mirrored (.last-release-mirror), the full comparison runs again only
# when a file appears, in any folder this release ships, that this release does not have, which is
# what an older session's copy leaves. Every shipped folder is watched (#33033), not only
# hooks-handlers/ and setup/: a stale command or skill left there used to stay until the next
# version. Dot-named folders are not watched, because the removal rules keep everything in them.
_mmry_mirror() {
    local marker="${MMRY_STATE_DIR}/.last-release-mirror"
    local done_ver="" d="" f="" rel="" stale=0
    (( _mmry_have_lib == 1 )) && [[ -n "$_mmry_root_ver" ]] || return 0
    if [[ -e "$P/.git" || -e "$P/../.git" ]]; then
        return 0
    fi
    if [[ -f "$marker" ]]; then
        IFS= read -r done_ver < "$marker" 2>/dev/null || true
        done_ver="${done_ver%$'\r'}"
    fi
    if [[ -n "$done_ver" && "$done_ver" == "$_mmry_root_ver" ]]; then
        # The installed copy's counterpart of each folder this release ships, searched by ONE find.
        set --
        for d in "$P"/*/; do
            d="${d%/}"; d="${d##*/}"
            [[ -d "${MMRY_STATE_DIR}/$d" && ! -L "${MMRY_STATE_DIR}/$d" ]] && set -- "$@" "${MMRY_STATE_DIR}/$d"
        done
        (( $# > 0 )) || return 0
        while IFS= read -r -d '' f; do
            case "${f##*/}" in mmry-config*.json|*.log) continue ;; esac
            rel="${f#"${MMRY_STATE_DIR}"/}"
            if [[ ! -e "$P/$rel" ]]; then
                stale=1
                break
            fi
        done < <(find "$@" -name '.*' -prune -o -type f -print0 2>/dev/null)
        (( stale == 1 )) || return 0
    fi
    if ! _mmry_verified_release; then
        log "${_mmry_list_problem}; removing nothing from ${MMRY_STATE_DIR}"
        return 0
    fi
    if _su_prune "${_su_scratch}/list" "${MMRY_STATE_DIR}" "$_mmry_root_ver"; then
        printf '%s\n' "$_mmry_root_ver" > "$marker" 2>/dev/null || true
    fi
    return 0
}

if (( _mmry_install == 1 )); then
    # Copy current handler and setup scripts (all platforms)
    cp "$P"/hooks-handlers/*.sh "${MMRY_STATE_DIR}/hooks-handlers/"
    # No .cmd is staged here, and none needs to be. The Windows launcher, codex-hook.cmd, is back since
    # #31245 QA round 8 and is named by every commandWindows entry in hooks/codex-hooks.json, but it is
    # run from the PLUGIN ROOT, beside the codex-hook.sh it starts, exactly as the Unix registrations
    # run codex-hook.sh from there. Nothing reaches it through this state directory.
    # NOT THE CLAUDE CODE INSTALLERS (#31245 QA). install.sh, install.ps1 and install.bat install MMRY
    # for Claude Code: they create ~/.claude and rewrite its settings, and none refuses on Codex the way
    # the uninstallers do. Nothing tells a Codex customer to run them, so they are not put in the Codex
    # home at all, and copies an earlier version put there are removed. Claude Code is unchanged.
    for _mmry_setup_file in "$P"/setup/*.sh "$P"/setup/*.bat "$P"/setup/*.ps1; do
        [[ -f "$_mmry_setup_file" ]] || continue
        case "$(basename "$_mmry_setup_file")" in
            install.sh|install.ps1|install.bat)
                [[ "$(mmry_host)" == "codex" ]] && continue ;;
        esac
        cp "$_mmry_setup_file" "${MMRY_STATE_DIR}/setup/" 2>/dev/null || true
    done
    if [[ "$(mmry_host)" == "codex" ]]; then
        rm -f "${MMRY_STATE_DIR}/setup/install.sh" "${MMRY_STATE_DIR}/setup/install.ps1" \
              "${MMRY_STATE_DIR}/setup/install.bat" 2>/dev/null || true
    fi

    # THE BUNDLED jq, BESIDE THE INSTALLED HANDLERS, ON CODEX (#31245 QA round 8).
    #
    # The skill sends the model to run handlers from this state directory (join, save, search), and
    # lib-jq.sh looks for the bundled jq at ../vendor/jq beside whichever copy is running, or at
    # ${CLAUDE_PLUGIN_ROOT}/vendor/jq. Codex exports that variable to hook processes only, not to the
    # commands the model runs, so on Codex the lookup landed on a vendor directory nobody had copied.
    # On a machine with a jq on PATH nobody noticed. On a stock Windows machine there is none, so
    # every handler the model ran failed to read the credential: measured live, a Codex session asked
    # to join a formation got "Could not join formation 35 (HTTP 000)" while its own hooks, which run
    # from the plugin root where vendor/jq does exist, loaded memories normally.
    #
    # Copied only when the checksum list differs, so once per plugin version rather than per session.
    # Codex only: on Claude Code the model's commands carry CLAUDE_PLUGIN_ROOT and resolve the plugin's
    # own copy, and test case 4 forbids changing what this file does there.
    if [[ "$(mmry_host)" == "codex" && -f "$P/vendor/jq/CHECKSUMS.txt" ]]; then
        if ! cmp -s "$P/vendor/jq/CHECKSUMS.txt" "${MMRY_STATE_DIR}/vendor/jq/CHECKSUMS.txt" 2>/dev/null; then
            mkdir -p "${MMRY_STATE_DIR}/vendor/jq" 2>/dev/null \
                && cp "$P"/vendor/jq/* "${MMRY_STATE_DIR}/vendor/jq/" 2>/dev/null \
                && chmod +x "${MMRY_STATE_DIR}"/vendor/jq/jq-* 2>/dev/null || true
        fi
    fi

    # Record the version now installed, so a later older session can tell it is older. Only for a
    # verified release (#33033): an unverified plugin.json is not evidence of a version.
    if [[ -n "$_mmry_root_ver" && "$_mmry_root_ver" != "$_mmry_inst_json_ver" ]]; then
        if _mmry_verified_release; then
            { mkdir -p "${MMRY_STATE_DIR}/.claude-plugin" \
                && cp "$P/.claude-plugin/plugin.json" "${MMRY_STATE_DIR}/.claude-plugin/plugin.json"; } 2>/dev/null || true
        else
            log "${_mmry_list_problem}; not recording ${_mmry_root_ver} as the installed version"
        fi
    fi

    _mmry_mirror || true
    if [[ -n "$_su_scratch" ]]; then
        rm -rf "$_su_scratch" 2>/dev/null || true
    fi
fi

# LEFTOVER FORMATION MEMBERSHIPS (#31844) are cleared by session-start.sh, not here. The sweep must
# know this session's own id for certain, and only the hook payload says that: this file does not
# read stdin, and the environment variable it used to consult can be empty or inherited from another
# session (#31844 QA round 2, D1). session-start.sh also has the client the sweep now needs, to ask
# the service before it removes anything.

# Delegate to the main session-start logic.
#
# EXCEPT WHEN codex-hook.sh HAS ALREADY RUN IT, FIRST (#33062). Codex cuts the SessionStart hook off
# at 30 s, and on a slow Windows machine this file's install, version check and mirror, with the
# update check session-start.sh used to make first, took most of that before a single memory was
# handed over. So codex-hook.sh runs session-start.sh before this file, hands its output to Codex,
# and then runs this file with --after-delivery and its output already closed. Only codex-hook.sh
# passes that, and it counts only on Codex. On Claude Code this is the same single line it always was.
#
# ON CODEX THE UPDATE CHECK IS MADE HERE, AFTER THE INSTALL, rather than by session-start.sh before
# the memories, and only where session-start.sh made it: when this host has a credential of its own.
#
# The exit status is still session-start.sh's, as it was when that call was this file's last line.
_mmry_host_resolve
_mmry_start_rc=0
if [[ "${1:-}" != "--after-delivery" || "$_MMRY_HOST_V" != "codex" ]]; then
    bash "$P/hooks-handlers/session-start.sh" || _mmry_start_rc=$?
fi
if [[ "$_MMRY_HOST_V" == "codex" ]] && mmry_host_assert_own_credential 2>/dev/null; then
    bash "$P/hooks-handlers/self-update.sh" 2>/dev/null || true
fi
exit "$_mmry_start_rc"
