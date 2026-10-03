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

# CAPTURED BEFORE THE CLIENT IS SOURCED (#31583 QA round 4, finding 4a).
#
# The shared off-switch honours a genuine environment override first, exactly as the hook
# does. But mmry_load_config POPULATES that same variable from the config file, defaulting it
# to true, so by the time this script could ask, an inherited value and a derived one are
# indistinguishable and the derived default would win every time. That is what kept this
# command reporting ON while the hook was silent, even after both were pointed at one routine:
# the routine was right and the input to it was already contaminated.
#
# The real environment is only knowable here, before anything is sourced.
_MMRY_ENV_REINJECT="${MMRY_FOUNDATION_REINJECT-}"
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
# THROUGH THE SAME ROUTINE THE HOOK OBEYS (#31583 QA round 4, finding 4a).
#
# This used to read MMRY_FOUNDATION_REINJECT, which mmry_load_config only populates when jq
# parses the config file and otherwise leaves at its default of true. The hook decides with a
# jq-free text scan instead, on purpose, because a broken jq is what it was hardened against.
# So any config jq could not read split the two: this command printed "Re-injection: ON -
# directives are re-sent on every prompt" while the hook sent nothing. One trailing comma was
# enough, and this command's own advice tells the customer to hand-edit that file.
#
# The question a customer is asking here is what the HOOK will do, so the hook's routine is
# the one that has to answer it.
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/lib-foundation-switch.sh"
if MMRY_FOUNDATION_REINJECT="$_MMRY_ENV_REINJECT" _mmry_reinject_is_off_here; then
    echo "Re-injection is TURNED OFF (foundationReinject=${MMRY_REINJECT_MATCHED_VALUE:-false})."
    echo "Your Foundation directives are NOT being sent to your assistant on each prompt."
    echo "Set foundationReinject to true in ~/.claude/mmry-config.json to turn it back on."
    exit 0
fi
echo "Re-injection: ON - directives are re-sent on every prompt."

# 2. What does the stored copy claim to be, and is it actually that?
#
# THROUGH THE SHARED VERIFIER (#31583 QA). This block used to re-implement the manifest
# regex, the entries=0 check and the checksum comparison, and it drifted from the hook twice
# in two rounds: it reported "VALID and EMPTY, nothing is being withheld" for a manifest
# claiming zero beside a full cache, and "VERIFIED, N directives, Delivered: IN FULL" for a
# cache holding only whitespace. In both cases the hook was refusing the turn and the customer
# asking the question was told the opposite. There is one routine now, so the two cannot
# disagree about what is verified; only the wording is this command's own.
_reason="$(mmry_verify_foundation_cache "$CACHE")"
_verdict=$?

if (( _verdict == 1 )); then
    if [[ "$_reason" == "absent" ]]; then
        # TWO STATES LOOK IDENTICAL HERE AND MEAN OPPOSITE THINGS (#31583 QA round 4, 4b).
        #
        # This branch used to return before it ever read the delivery record further down, so
        # a set that had vanished after being delivered was described as one that had never
        # loaded. That is not a wording quibble: the hook's own refusal ends by telling the
        # customer to run this command to confirm, and reviewers followed that instruction and
        # got the opposite story from the two surfaces in the same second.
        if mmry_foundation_delivered_this_session "$MMRY_TMPDIR"; then
            echo "Stored copy:  DISAPPEARED - it was delivered in this session and is now gone."
            echo "              It is being REFUSED, not used."
            echo "Action:       run /mmry:load-memories to rebuild it."
        else
            echo "Stored copy:  NOT LOADED YET in this session."
            echo "Action:       run /mmry:load-memories, or start a new session."
        fi
    else
        echo "Stored copy:  VALID and EMPTY - this account has no Foundation memories."
        echo "              Nothing is being withheld; there is nothing to send."
    fi
    exit 0
fi

if (( _verdict != 0 )); then
    # The state token, not the prose, chooses the label. Matching a one-word state out of a
    # sentence would break the moment the sentence was reworded, and these labels are what a
    # customer scans for. The bytes case and the checksum case are separate states now, so
    # this no longer prints that 28 bytes does not match 28 bytes (#31583 QA).
    _state="${_reason%%|*}"
    _prose="${_reason#*|}"
    case "$_state" in
        no-manifest|bad-manifest) _label="PRESENT BUT UNVERIFIABLE" ;;
        inconsistent)             _label="INCONSISTENT" ;;
        missing)                  _label="MISSING" ;;
        size|contents|unreadable) _label="DAMAGED" ;;
        blank)                    _label="EMPTY OF TEXT" ;;
        *)                        _label="REFUSED" ;;
    esac
    echo "Stored copy:  ${_label} - ${_prose}."
    echo "              It is being REFUSED, not used."
    echo "Action:       run /mmry:load-memories to rebuild it."
    exit 0
fi

# Verified. The verdict carries the numbers so they cannot be recomputed differently here.
read -r _ok_word _exp_entries _act_bytes <<<"$_reason"
echo "Stored copy:  VERIFIED - ${_exp_entries} directives, ${_act_bytes} bytes, matching what was stored."

# 3. WAS THE MOST RECENT PROMPT ACTUALLY DELIVERED? (#31583 QA round 5, 4e)
#
# "The copy verifies" and "the copy reached the assistant" are different claims, and this used to
# print "Delivered: IN FULL" on the first alone. Straight after a prompt the hook's own log
# recorded as FAILED - deadline exceeded, worker killed - a customer who asked was told IN FULL
# and could not learn that their latest prompt went out with no directives at all.
#
# The hook leaves three pieces of evidence and this now reads all of them before it speaks:
#   - the delivery record, written only after a successful emit and stamped with the session;
#   - the in-flight marker, which survives only if a firing was killed before it finished;
#   - the failure log, one line per refused or failed firing.
# Evidence counts only if it is newer than this session's start (the token SessionStart wrote)
# and, for a failure, newer than the last successful delivery. Older lines belong to a turn the
# customer has already moved past, or to an earlier session in the same temp directory.
_session_file="${MMRY_TMPDIR}/mmry-foundation.session"
_inflight="${MMRY_TMPDIR}/.mmry-foundation-inflight"
_log="${MMRY_TMPDIR}/mmry-foundation.log"

_delivered=0
mmry_foundation_delivered_this_session "$MMRY_TMPDIR" && _delivered=1

_failed_why=""
if [[ -f "$_inflight" ]] && { [[ ! -f "$_session_file" ]] || [[ "$_inflight" -nt "$_session_file" ]]; }; then
    _failed_why="the last prompt was stopped before it finished loading them"
fi
if [[ -z "$_failed_why" && -f "$_log" ]]    && { [[ ! -f "$_session_file" ]] || [[ "$_log" -nt "$_session_file" ]]; }    && { (( _delivered == 0 )) || [[ "$_log" -nt "$STATUS" ]]; }; then
    _last_line="$(tail -n 1 "$_log" 2>/dev/null)"
    case "$_last_line" in
        *"reinjection FAILED: deadline exceeded ("*)
            # The log line is for whoever investigates; the customer gets plain words.
            _secs="${_last_line#*deadline exceeded (}"; _secs="${_secs%%)*}"
            _failed_why="loading them took longer than the ${_secs} limit and was stopped" ;;
        *"reinjection FAILED: worker exited "*)
            _failed_why="the loader failed before it finished" ;;
        *"reinjection FAILED: "*)  _failed_why="${_last_line#*reinjection FAILED: }" ;;
        *"reinjection REFUSED: "*) _failed_why="the stored copy was refused: ${_last_line#*reinjection REFUSED: }" ;;
    esac
fi

if [[ -n "$_failed_why" ]]; then
    echo "Delivered:    NOT on the most recent prompt - ${_failed_why}."
    echo "              That prompt ran without your Foundation directives."
    echo "Action:       re-send the prompt. If it keeps happening, run /mmry:load-memories."
elif (( _delivered )); then
    echo "Delivered:    IN FULL on the most recent prompt. There is no size limit; nothing is trimmed or cut."
else
    echo "Delivered:    nothing yet in this session."
fi

# Last successful delivery, from THIS session's record only, parsed rather than echoed. The raw
# record used to be printed verbatim, so anything written after the token reached the customer.
if (( _delivered )); then
    _st="$(mmry_foundation_delivery_detail "$MMRY_TMPDIR")"
    _when="$(_mmry_mtime "$STATUS" 2>/dev/null)"
    _now="$(date +%s 2>/dev/null || echo 0)"
    _what=""
    if [[ "$_st" =~ ^ok[[:space:]]+entries=([0-9]+)[[:space:]]+bytes=([0-9]+)$ ]]; then
        _what=" (${BASH_REMATCH[1]} directives, ${BASH_REMATCH[2]} bytes)"
    fi
    if [[ "$_when" =~ ^[0-9]+$ ]] && [[ "$_now" =~ ^[0-9]+$ ]] && (( _now >= _when )); then
        _ago=$(( _now - _when ))
        if (( _ago == 1 )); then
            echo "Last sent:    1 second ago${_what}."
        else
            echo "Last sent:    ${_ago} seconds ago${_what}."
        fi
    else
        echo "Last sent:    earlier in this session${_what}."
    fi
else
    echo "Last sent:    nothing yet in this session."
fi
exit 0
