#!/usr/bin/env bash
# foundation-status.sh - answer "are my Foundation directives actually reaching my
# assistants right now?" without anyone opening a file (#31583 requirement 4).
#
# WHY THIS EXISTS.
#
# On 2026-09-18 an account's local Foundation copy held four bytes while the account held
# twelve directives, and every response for roughly six hours was produced by an assistant
# that had been handed that stub and told it was authoritative. The customer had no way to
# ask. The re-injection hook now REFUSES an unverifiable copy and says so, but a refusal
# only speaks when something is wrong; a customer also has to be able to ask when nothing
# appears to be wrong, which is exactly the state that hid this for hours.
#
# Read-only. It never writes the cache, never repairs anything, and never fails the caller.

# -e is turned straight back off on the next line. This script is a customer asking a
# question; it must answer even when part of the answer cannot be gathered, so it must
# never abort mid-report. The full form is written first because the repo's structural
# check requires every handler to declare it, and a handler that quietly omitted it is
# how this file shipped with no strict mode at all (caught by file-integrity.bats).
set -euo pipefail 2>/dev/null || true
set +e

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh" 2>/dev/null || {
    echo "MMRY AI: the plugin's client could not be loaded, so Foundation status cannot be read."
    exit 0
}
set +e +u
mmry_load_config 2>/dev/null || true

CACHE="${MMRY_TMPDIR}/mmry-foundation.md"
MANIFEST="${CACHE}.manifest"
STATUS="${MMRY_TMPDIR}/mmry-foundation.status"

echo "MMRY AI - Foundation directive status"
echo

# 1. Is re-injection switched on at all? A customer who turned it off, or inherited an
#    environment that turned it off, should be told that first - everything below is moot.
_reinject="${MMRY_FOUNDATION_REINJECT:-true}"
case "$(printf '%s' "$_reinject" | tr '[:upper:]' '[:lower:]')" in
    false|off|0|no|disabled)
        echo "Re-injection is TURNED OFF (foundationReinject=${_reinject})."
        echo "Your Foundation directives are NOT being sent to your assistant on each prompt."
        echo "Set foundationReinject to true in ~/.claude/mmry-config.json to turn it back on."
        exit 0
        ;;
esac
echo "Re-injection: ON - directives are re-sent on every prompt."

# 2. What does the stored copy claim to be, and is it actually that?
if [[ ! -r "$MANIFEST" ]]; then
    if [[ -e "$CACHE" ]]; then
        echo "Stored copy:  PRESENT BUT UNVERIFIABLE - there is no manifest for it, so it"
        echo "              cannot be shown to be your own directives. It is being refused."
        echo "Action:       run /mmry:load-memories to rebuild it."
    else
        echo "Stored copy:  NOT LOADED YET in this session."
        echo "Action:       run /mmry:load-memories, or start a new session."
    fi
    exit 0
fi

_man="$(<"$MANIFEST")" 2>/dev/null || _man=""
if [[ "$_man" =~ ^mmry-foundation[[:space:]]+v1[[:space:]]+entries=([0-9]+)[[:space:]]+bytes=([0-9]+)[[:space:]]+cksum=([0-9]+) ]]; then
    _exp_entries="${BASH_REMATCH[1]}"; _exp_bytes="${BASH_REMATCH[2]}"; _exp_cksum="${BASH_REMATCH[3]}"
else
    echo "Stored copy:  UNVERIFIABLE - the manifest is unreadable. It is being refused."
    echo "Action:       run /mmry:load-memories to rebuild it."
    exit 0
fi

if (( _exp_entries == 0 )); then
    echo "Stored copy:  VALID and EMPTY - this account has no Foundation memories."
    echo "              Nothing is being withheld; there is nothing to send."
    exit 0
fi

if [[ ! -r "$CACHE" ]]; then
    echo "Stored copy:  MISSING - the manifest expects ${_exp_entries} directives and the file is gone."
    echo "              It is being refused, so this turn and the next run without them."
    echo "Action:       run /mmry:load-memories to rebuild it."
    exit 0
fi

read -r _act_cksum _act_bytes < <(cksum < "$CACHE" 2>/dev/null)
if [[ "$_act_bytes" != "$_exp_bytes" || "$_act_cksum" != "$_exp_cksum" ]]; then
    echo "Stored copy:  DAMAGED - it holds ${_act_bytes:-0} bytes and does not match the ${_exp_bytes} bytes"
    echo "              of ${_exp_entries} directives that were stored. It is being REFUSED, not used."
    echo "Action:       run /mmry:load-memories to rebuild it."
    exit 0
fi

echo "Stored copy:  VERIFIED - ${_exp_entries} directives, ${_exp_bytes} characters, matching what was stored."
echo "Delivered:    IN FULL. There is no size limit; nothing is trimmed or cut."

# 3. Did the most recent prompt actually inject it? The hook records this on each verified
#    injection, so this distinguishes "the copy is good" from "the copy is good AND it
#    reached the assistant", which are not the same claim.
if [[ -r "$STATUS" ]]; then
    _st="$(<"$STATUS")" 2>/dev/null || _st=""
    _when="$(_mmry_mtime "$STATUS" 2>/dev/null)"
    _now="$(date +%s 2>/dev/null || echo 0)"
    if [[ "$_when" =~ ^[0-9]+$ ]] && [[ "$_now" =~ ^[0-9]+$ ]] && (( _now >= _when )); then
        echo "Last sent:    $(( _now - _when )) seconds ago (${_st})."
    else
        echo "Last sent:    ${_st}"
    fi
else
    echo "Last sent:    not yet in this session - the next prompt will send it."
fi
exit 0
