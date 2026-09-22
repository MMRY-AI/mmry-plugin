#!/usr/bin/env bash
# lib-foundation-switch.sh - is Foundation re-injection switched off? ONE answer, two callers.
#
# #31583 QA round 4, finding 4a. This question was answered in two places that disagreed, and
# the disagreement was customer-visible in the worst way: /mmry:foundation-status reported
# "Re-injection: ON - directives are re-sent on every prompt" while the hook was sending
# nothing at all.
#
# The two derivations differed in their failure mode rather than their intent. The hook reads
# the config with a deliberately jq-free text scan, because a broken or unusable jq is exactly
# the circumstance it was hardened against. The status command took the value from
# mmry_load_config, which only populates it when jq PARSES the file and otherwise leaves the
# default of true. So any config jq cannot read split them: the hook saw false and went quiet,
# the command saw the default and said everything was fine. A single trailing comma does it,
# and the product itself tells the customer to hand-edit that file. Reviewers reproduced the
# same divergence three ways - malformed JSON, a duplicate key where jq takes last-wins and
# the scan takes first-match, and an unresolvable jq.
#
# It lives in its own small file rather than in mmry-client.sh because the hook's SUPERVISOR
# must be able to answer before it spawns anything, and sourcing the whole client on every
# prompt is the cost #31434 exists to have removed. This file defines functions only, spawns
# no process, and runs on the bash 3.2 that macOS ships.

# Matches the repository convention every other handler and library follows, and
# file-integrity.bats enforces it. But this file is sourced BY the one handler that must never
# kill a prompt: userpromptsubmit-foundation.sh deliberately runs without errexit, because a
# failure anywhere in Foundation re-injection has to cost the customer nothing. Imposing -e on
# it from here would quietly undo that guarantee, so errexit is put back the way the caller had
# it. The -u and pipefail options are already set by both call sites, so they are unchanged.
_mmry_fsw_had_errexit=0
case "$-" in *e*) _mmry_fsw_had_errexit=1 ;; esac
set -euo pipefail
(( _mmry_fsw_had_errexit )) || set +e
unset _mmry_fsw_had_errexit

# Lowercase an ASCII string using nothing but parameter expansion (#31434 QA).
#
# This replaces `printf '%s' "$x" | tr '[:upper:]' '[:lower:]'`, which cost a subshell AND a
# `tr` process on EVERY firing of a hook that runs on every prompt. On Windows Git Bash a
# process spawn measured ~300 ms, so that one idiom was ~10% of the handler's whole cost.
# bash 3.2 (what macOS ships) has no `${x,,}`, so this does the mapping by hand: the index of
# the character within the uppercase alphabet is the length of the prefix before it, and a
# character that is absent leaves the alphabet unchanged at length 26.
_mmry_tolower() {
    local s="$1" out="" c pre
    local up="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lo="abcdefghijklmnopqrstuvwxyz"
    local i=0
    while (( i < ${#s} )); do
        c="${s:i:1}"
        pre="${up%%"$c"*}"
        if (( ${#pre} < 26 )); then
            out="${out}${lo:${#pre}:1}"
        else
            out="${out}${c}"
        fi
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

# Is Foundation re-injection switched OFF by this value? Same vocabulary the worker has always
# honoured, now in one place because the SUPERVISOR has to answer the question too (#31434 QA).
_mmry_reinject_off() {
    case "$(_mmry_tolower "$1")" in
        false|off|0|no|disabled) return 0 ;;
    esac
    return 1
}

# Is Foundation re-injection switched off, answered WITHOUT spawning a single process?
# Environment override first, then the config file the client would have used (#31434 QA).
#
# Discovery order is kept identical to mmry_load_config in mmry-client.sh. If the two ever
# disagree, the customer's setting is honoured on one path and ignored on the other, which
# is the whole bug this closes.
#
# HOW THE CONFIG IS READ, and what that is and is not worth. This is a TEXT SCAN, not a JSON
# parse: `$(<file)` costs a subshell and no exec, where jq would cost a process on every
# prompt and would fail in exactly the circumstances this check matters most. The scan is
# therefore deliberately CONSERVATIVE - it acts only on a confident match of the key in key
# position followed by a bare or quoted scalar, and anything it cannot read that way is
# treated as "not switched off".
#
# That asymmetry is the safe one in both directions. A false "off" would silently disable a
# feature the customer wants, so the scan refuses to guess; a false "on" costs at worst a
# notice the customer did not want, and the WORKER still holds the authoritative jq-parsed
# answer, so a healthy firing that this scan could not read is decided correctly downstream.
# The only thing that changes here is whether the SUPERVISOR can answer when the worker cannot.
# Set to the value this routine actually read, environment or config, for callers that want
# to quote it. Empty when nothing could be read.
MMRY_REINJECT_MATCHED_VALUE=""

_mmry_reinject_is_off_here() {
    local v="" cfg="" txt=""
    MMRY_REINJECT_MATCHED_VALUE=""

    # 1. Environment override. Free, and it wins, matching mmry-client.sh precedence.
    if [[ -n "${MMRY_FOUNDATION_REINJECT:-}" ]]; then
        MMRY_REINJECT_MATCHED_VALUE="${MMRY_FOUNDATION_REINJECT}"
        _mmry_reinject_off "${MMRY_FOUNDATION_REINJECT}"
        return $?
    fi

    # 2. The config file, same discovery order as mmry_load_config.
    if [[ -n "${MMRY_CONFIG_FILE:-}" && -f "${MMRY_CONFIG_FILE}" ]]; then
        cfg="$MMRY_CONFIG_FILE"
    elif [[ -n "${PLUGIN_ROOT:-}" && -f "${PLUGIN_ROOT}/mmry-config.json" ]]; then
        cfg="${PLUGIN_ROOT}/mmry-config.json"
    elif [[ -f "${HOME:-}/.claude/mmry-config.json" ]]; then
        cfg="${HOME}/.claude/mmry-config.json"
    fi
    [[ -n "$cfg" && -r "$cfg" ]] || return 1

    txt="$(<"$cfg")" 2>/dev/null || return 1
    [[ -n "$txt" ]] || return 1

    # Key in key position, then a JSON scalar: `false`, `"false"`, `0`, `"off"`. A value that
    # is not a bare word (an object, an array, a spaced-out string) simply does not match, and
    # an unmatched scan returns "not off".
    [[ "$txt" =~ \"foundationReinject\"[[:space:]]*:[[:space:]]*\"?([A-Za-z0-9]+)\"? ]] || return 1
    v="${BASH_REMATCH[1]}"
    # WHAT IT ACTUALLY MATCHED, so a caller can quote the customer's own value back at them
    # rather than a default it never set (#31583 QA round 4). The status command printed
    # "foundationReinject=true" while reporting the switch as off, because the only value it
    # could see was the one mmry_load_config had defaulted.
    MMRY_REINJECT_MATCHED_VALUE="$v"
    _mmry_reinject_off "$v"
}
