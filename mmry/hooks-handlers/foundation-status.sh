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

# THE REMEDIES THIS COMMAND OFFERS ARE THE HOST'S OWN (#31245 merged onto #31411). On Codex there
# is no slash command to type, no ~/.claude, and the product is not Claude Code; the session-init
# copy of this script sits beside the others, so the model runs it by path like every Codex
# command. The literals are the fallback for a copy with no lib-host.sh and are exactly what
# Claude Code customers have always seen (requirement 4).
_FS_RELOAD='/mmry:load-memories'
_FS_CONFIG='~/.claude/mmry-config.json'
_FS_HOST='Claude Code'
if declare -F mmry_host_command_ref >/dev/null 2>&1; then
    _fs_x="$(mmry_host_command_ref load-memories)" && [[ -n "$_fs_x" ]] && _FS_RELOAD="$_fs_x"
fi
if declare -F mmry_host_config_file_ref >/dev/null 2>&1; then
    _fs_x="$(mmry_host_config_file_ref)" && [[ -n "$_fs_x" ]] && _FS_CONFIG="$_fs_x"
fi
if declare -F mmry_host_label >/dev/null 2>&1; then
    _fs_x="$(mmry_host_label)" && [[ -n "$_fs_x" ]] && _FS_HOST="$_fs_x"
fi

CACHE="${MMRY_TMPDIR}/mmry-foundation.md"
# THIS SESSION, by its own id (#31583 QA round 6, R4(c)). The command runtime provides
# CLAUDE_CODE_SESSION_ID; the per-prompt hook reads the same id from its payload, so both file this
# session's records under one name and another session's are never read here. With no id, the old
# token-named records are read, exactly as before.
_sid="$(mmry_foundation_sid "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}")"
STATUS="$(mmry_foundation_record_path "$MMRY_TMPDIR" "$_sid")"

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
    echo "Set foundationReinject to true in ${_FS_CONFIG} to turn it back on."
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
        if mmry_foundation_delivered_this_session "$MMRY_TMPDIR" "$_sid"; then
            echo "Stored copy:  DISAPPEARED - it was delivered in this session and is now gone."
            echo "              It is being REFUSED, not used."
            echo "Action:       run ${_FS_RELOAD} to rebuild it."
        else
            echo "Stored copy:  NOT LOADED YET in this session."
            echo "Action:       run ${_FS_RELOAD}, or start a new session."
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
    # THE UPGRADE STATE SAYS WHAT THE HOOK SAYS (#31583 QA round 5). A copy stored by an earlier
    # plugin version carries no record to check it against. The hook tells the customer that is
    # an update and needs no action; this command used to tell them to rebuild it. One answer.
    if [[ "$_state" == "no-manifest" ]]; then
        echo "Stored copy:  FROM AN EARLIER PLUGIN VERSION - it has no record to check it against,"
        echo "              so it is not used. It is fetched again in the new format automatically,"
        echo "              normally by the next prompt."
        echo "Action:       none needed. If this persists after a few prompts, run ${_FS_RELOAD}."
        exit 0
    fi
    echo "Stored copy:  ${_label} - ${_prose}."
    echo "              It is being REFUSED, not used."
    echo "Action:       run ${_FS_RELOAD} to rebuild it."
    exit 0
fi

# Verified. The verdict carries the numbers so they cannot be recomputed differently here.
read -r _ok_word _exp_entries _act_bytes _ <<<"$_reason"
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
_tok="$(mmry_foundation_session_key "$MMRY_TMPDIR" "$_sid")"
_parts_max="${MMRY_FOUNDATION_PARTS_MAX:-6}"
[[ "$_parts_max" =~ ^[1-9][0-9]*$ ]] || _parts_max=6

# READ WHAT EACH PART REPORTED, NOT WHAT FILE TIMES IMPLY (#31583 QA round 6, #31411 split).
#
# This used to infer "was the latest prompt delivered" by comparing the modification times of the
# delivery record and the failure log with -nt, which counts whole seconds here, so a failure in the
# same second as a delivery read as IN FULL. Each hook firing now writes its own outcome line,
# stamped with the session, replaced atomically, last write wins: "ok part k of n",
# "ok by-reference n", "failed <why>" or "none". Part 1's file has no suffix, part k's ends ".k".
# An outcome stamped with another session's token is not this session's and is not read.
_outcome() {
    local f="${MMRY_TMPDIR}/mmry-foundation.outcome${_sid:+.$_sid}$1" l=""
    # Something at the path that is not a regular file is not a record of anything, and is said so
    # rather than read (#31583 QA round 2). A directory cannot be read and a FIFO would block.
    if [[ -e "$f" && ! -f "$f" ]]; then printf '%s' unreadable; return 0; fi
    [[ -f "$f" && -r "$f" ]] && { l="$(<"$f")" 2>/dev/null || l=""; }
    [[ -n "$_tok" && "${l%% *}" == "$_tok" ]] || return 1
    printf '%s' "${l#* }"
}
# A firing killed before it finished leaves its in-flight marker behind. Markers older than this
# session's start belong to an earlier session in the same temp directory and are not read.
_cut_short() {
    local f="${MMRY_TMPDIR}/.mmry-foundation-inflight${_sid:+.$_sid}$1"
    [[ -e "$f" ]] || return 1
    # A marker that is not a regular file is still a marker: fail closed (#31583 QA round 2).
    [[ -f "$f" ]] || return 0
    # A marker named by this session is this session's. Only the token-named fallback can belong
    # to an earlier session in the same temp directory, and only it needs the age check.
    [[ -n "$_sid" ]] && return 0
    [[ ! -f "$_session_file" ]] || [[ "$f" -nt "$_session_file" ]]
}
_sfx() { (( $1 > 1 )) && printf '.%s' "$1"; }

# FIXED SENTENCES FROM A CAUSE CODE (#31583 QA round 6). The outcome record lives in a shared temp
# directory, so nothing in it is printed: only a code and a number are read, and anything else reads
# as "unrecorded". The advice follows the cause, because the hook gives cause-specific advice on the
# same turn and the two must not contradict each other: after a loader crash the hook says re-sending
# will not help, so this must not tell the customer to re-send.
_why_and_action() {
    local code="$1"
    _WHY="" _ACTION=""
    if [[ "$code" =~ ^deadline\ ([0-9]{1,4})$ ]]; then
        _WHY="loading them took longer than the ${BASH_REMATCH[1]}s limit and was stopped"
        _ACTION="re-send the prompt. If it keeps happening, run ${_FS_RELOAD}."
    elif [[ "$code" == "crash" ]]; then
        _WHY="the loader failed before it finished"
        _ACTION="re-sending will not help. Run ${_FS_RELOAD}, and reinstall the plugin if that fails."
    elif [[ "$code" == "upgrade" ]]; then
        _WHY="they were stored by an earlier plugin version and are being fetched again"
        _ACTION="none needed. If this persists after a few prompts, run ${_FS_RELOAD}."
    elif [[ "$code" == "refused changed" ]]; then
        _WHY="your directives were being replaced as the prompt arrived, so nothing was sent rather than a mix of two versions"
        _ACTION="re-send the prompt."
    elif [[ "$code" =~ ^refused($|\ [a-z-]{1,20}$) ]]; then
        _WHY="the stored copy could not be verified, so it was refused rather than used"
        _ACTION="run ${_FS_RELOAD} to rebuild it."
    else
        _WHY="the reason was not recorded"
        _ACTION="re-send the prompt. If it keeps happening, run ${_FS_RELOAD}."
    fi
}

_delivered=0
mmry_foundation_delivered_this_session "$MMRY_TMPDIR" "$_sid" && _delivered=1

_failed_why=""
_partly=""
_partly_action=""
_byref=""
_unknown=""
_n=""
# FAIL CLOSED (#31583 QA round 2). Only a record in one of the forms the hook writes counts for
# anything. Anything else - a torn line, a file that is not a regular file, words a third party put
# there - cannot be shown to describe the most recent prompt, so it is reported as unknown, never
# as delivered. Part counts above six are refused the same way: the hook is registered six times,
# so no prompt can have had more.
_o1="$(_outcome "")"
if _cut_short ""; then
    _failed_why="the last prompt was stopped before it finished loading them"
elif [[ "$_o1" == failed* ]]; then
    _why_and_action "${_o1#failed }"
    _failed_why="$_WHY"
    _failed_action="$_ACTION"
elif [[ "$_o1" =~ ^ok\ by-reference\ [0-9]{1,4}$ ]]; then
    _byref=1
elif [[ "$_o1" =~ ^ok\ part\ 1\ of\ ([1-9])(\ set\ ([0-9]{1,10}))?$ ]] && (( BASH_REMATCH[1] <= 6 && BASH_REMATCH[1] <= _parts_max )); then
    _n="${BASH_REMATCH[1]}"
    # EVERY PART MUST BE PART OF THE SAME SET (#31583 QA round 2, R4). Each part names the version
    # it was cut from. A replacement landing between part firings - the daily refresh, another
    # session starting - can leave parts from two versions, or a part that found the new set smaller
    # and sent nothing; neither may read as IN FULL. A part from another version, a part that sent
    # nothing, and a part with no record all count as not arrived.
    _set1="${BASH_REMATCH[3]}"
    _got=1
    _missing=""
    for (( _k = 2; _k <= _n; _k++ )); do
        _ok="$(_outcome "$(_sfx "$_k")")"
        if _cut_short "$(_sfx "$_k")"; then
            _missing="${_missing}; part ${_k} was stopped before it finished"
            [[ -n "$_partly_action" ]] || _partly_action="re-send the prompt. If it keeps happening, run ${_FS_RELOAD}."
        elif [[ -n "$_set1" && "$_ok" == "ok part ${_k} of ${_n} set ${_set1}" ]]; then
            _got=$(( _got + 1 ))
        elif [[ "$_ok" =~ ^ok\ part\ ${_k}\ of\ [1-9]\ set\ [0-9]{1,10}$ ]]; then
            _missing="${_missing}; part ${_k} came from a different version of the set, which was replaced while it was being sent"
            [[ -n "$_partly_action" ]] || _partly_action="re-send the prompt."
        elif [[ "$_ok" == failed* ]]; then
            _why_and_action "${_ok#failed }"
            _missing="${_missing}; part ${_k}: ${_WHY}"
            # The advice follows the cause of the first part that did not arrive (#31583 QA round 2):
            # after a crash re-sending does not help, and the hook has already said so.
            [[ -n "$_partly_action" ]] || _partly_action="$_ACTION"
        else
            _missing="${_missing}; part ${_k} has no record of arriving"
            [[ -n "$_partly_action" ]] || _partly_action="re-send the prompt. If it keeps happening, run ${_FS_RELOAD}."
        fi
    done
    (( _got < _n )) && _partly="${_got} of ${_n} parts arrived${_missing}"
elif [[ -n "$_o1" ]]; then
    _unknown=1
fi

if [[ -n "$_failed_why" ]]; then
    echo "Delivered:    NOT on the most recent prompt - ${_failed_why}."
    echo "              That prompt ran without your Foundation directives."
    echo "Action:       ${_failed_action:-re-send the prompt. If it keeps happening, run ${_FS_RELOAD}.}"
elif [[ -n "$_partly" ]]; then
    echo "Delivered:    PARTLY on the most recent prompt - ${_partly}."
    echo "              That prompt ran without part of your Foundation directives."
    echo "Action:       ${_partly_action}"
elif [[ -n "$_byref" ]]; then
    echo "Delivered:    BY REFERENCE on the most recent prompt. Your set is larger than ${_FS_HOST} lets"
    echo "              a plugin show on each prompt (${_parts_max} parts of under 10,000 characters), so"
    echo "              your assistant was pointed to the full copy and asked to read it. That relies on"
    echo "              the assistant opening the file, and it may need your permission to read it."
elif [[ -n "$_unknown" ]]; then
    echo "Delivered:    UNKNOWN for the most recent prompt - its record could not be read, so it cannot"
    echo "              be shown that your Foundation directives reached your assistant."
    echo "Action:       re-send the prompt, then run /mmry:foundation-status again."
elif [[ -n "$_n" ]] && (( _n > 1 )); then
    echo "Delivered:    IN FULL on the most recent prompt, in ${_n} parts. Nothing is trimmed or cut."
elif [[ -n "$_n" ]]; then
    echo "Delivered:    IN FULL on the most recent prompt. Nothing is trimmed or cut."
else
    echo "Delivered:    nothing yet in this session."
fi

# Last successful delivery, from THIS session's record only, parsed rather than echoed. The raw
# record used to be printed verbatim, so anything written after the token reached the customer.
if (( _delivered )); then
    _st="$(mmry_foundation_delivery_detail "$MMRY_TMPDIR" "$_sid")"
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
