#!/usr/bin/env bash
# stop-check.sh - the save prompt. Registered on Stop on Claude Code, and on UserPromptSubmit
# on Codex, because a Stop hook that exits 2 is reported there as a failure. See item 6 below.
#
# Design (#29912):
#   The Claude Code "Stop" event fires after every assistant turn, not at session end.
#   Earlier versions blocked with a visible passive-status reason field ("MMRY AI:
#   saving important memories..."), and assistants would reply "Acknowledged" without
#   ever calling save-memory.sh. Net effect: multi-hour sessions produced zero memories.
#
#   This version:
#     1. Delivers the directive on STDERR and keeps exit 2 (#30642). On exit 2 Claude Code
#        feeds the hook's stderr to the model and ignores stdout JSON, so the directive now
#        reaches the model instead of surfacing only as "Blocked by hook". Keeping exit 2
#        preserves the block (no exit-code change). systemMessage was user-only and never
#        reached the model.
#     2. The directive is a single imperative line with an explicit skip clause, so the model
#        acts rather than replying "Acknowledged".
#     3. Track last successful save via ${TMPDIR}/.mmry-last-save (written by
#        mmry-client.sh). The systemMessage surfaces minutes-since-last-save so
#        the assistant produces incremental memories, not duplicates.
#     4. Compliance escalation: a per-session counter at ${TMPDIR}/.mmry-stop-count
#        increments each firing and resets on successful save. After 3 consecutive
#        firings without a save the systemMessage demands a save-or-rationale.
#     5. Debounce extended from 120s to 900s (15 min). A 4-hour session goes from
#        ~120 firings to ~16, each covering enough new substance to warrant a save.

#     6. #31245, Codex. On Codex this hook carries TWO jobs, not one. Codex has no channel to the
#        model at the pre-compaction moment at all - pre-compact.command.output.schema.json has no
#        hookSpecificOutput and no decision/reason, and compact.rs has no case for exit 2 - so the
#        "save before your context is trimmed" directive has nowhere else to go and is folded in
#        here. That is a change of moment, not of meaning, and it is stated to the model rather
#        than left implicit: a customer who silently loses work they believed was kept is the one
#        failure this feature exists to prevent.
#
#        ON CODEX THIS IS NOT A STOP HOOK AT ALL. An earlier version of this comment said "Stop
#        DOES work on Codex, and identically", and that claim outlived the code: Codex reports a
#        Stop hook that exits 2 as a FAILED hook to the customer, so the prompt arrives as an
#        error rather than as a directive. The registration moved to UserPromptSubmit, where the
#        prompt is delivered as additionalContext with exit 0, and Eric's decision on 2026-09-20
#        was that it must stay silent when there is nothing to save. So on Codex it fires at the
#        START of the customer's next turn, gated on the save marker, and hooks/codex-hooks.json
#        registers no Stop hook whatsoever. On Claude Code the delivery is unchanged (stderr plus
#        exit 2, on Stop), and so is WHEN it fires: the "a save already landed" silence below is
#        gated to Codex, because on Claude Code it changed the master behaviour.

set -euo pipefail

# NO PROCESS ON ANY PATH CODEX TAKES (#33967). On Codex this runs on every message, beside the six
# Foundation parts, and Codex stops it at 10 s with a "hook timed out" line. In the 33452 TC5 proof it
# did: under Git Bash on a loaded Windows machine each process start took about a second, and this file
# started ten of them (dirname, stat, date, head, tr, touch, sed), even on the early way out. Every one
# is now a builtin: the directory by parameter expansion, the clock by printf, files by read and
# redirection, the escaping by parameter expansion. The marker's time is also recorded beside it, so
# its age needs no stat while the marker is not older than that record (see _mmry_sc_marker_at).
#
# AND A LAUNCH THAT ALREADY USED THE TIME DOES NOTHING (#33967). MMRY_HOOK_LAUNCH_SECS is what the
# launcher measured before handing over (codex-hook.sh on Codex; unset, so 0, elsewhere). From 6 s of
# a 10 s limit there is not time left to be sure of finishing, so this ends at once, quietly, and
# touches nothing: the next message prompts instead.
_mmry_sc_launch="${MMRY_HOOK_LAUNCH_SECS:-0}"
[[ "$_mmry_sc_launch" =~ ^[0-9]{1,3}$ ]] || _mmry_sc_launch=0
(( _mmry_sc_launch < 6 )) || exit 0

# The clock, as a builtin where bash has one (4.2 and later); the bash 3.2 a Mac ships pays for date.
_mmry_sc_now() {
    if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 ) )); then
        printf -v _MMRY_SC_NOW '%(%s)T' -1
    else
        _MMRY_SC_NOW="$(date +%s)"
    fi
}

# The first line of a file, whitespace removed, by read: no head, no tr.
_mmry_sc_first() {
    _MMRY_SC_LINE=""
    { IFS= read -r _MMRY_SC_LINE || true; } 2>/dev/null < "$1" || _MMRY_SC_LINE=""
    _MMRY_SC_LINE="${_MMRY_SC_LINE//[[:space:]]/}"
}

# Optional, with the pre-#31245 behaviour as the fallback. This handler is reached through
# hook-guard.sh from the COPIED handler directory, which is assembled by whoever did the copying
# and is not guaranteed complete. A missing resolver must produce the directive this file has
# always produced, not a dead hook.
_mmry_sc_dir="${BASH_SOURCE[0]//\\//}"
case "$_mmry_sc_dir" in */*) _mmry_sc_dir="${_mmry_sc_dir%/*}" ;; *) _mmry_sc_dir="." ;; esac
[[ -n "$_mmry_sc_dir" ]] || _mmry_sc_dir="/"
# shellcheck source=/dev/null
# [[ -f ]] first (#31245 QA round 9): bash 3.2, the macOS bash, aborts under set -e when a sourced
# file is missing, even inside an if, so the fallback below was unreachable exactly where it mattered.
if ! { [[ -f "${_mmry_sc_dir}/lib-host.sh" ]] && source "${_mmry_sc_dir}/lib-host.sh" 2>/dev/null; }; then
    mmry_host() { printf 'claude'; }
    mmry_host_label() { printf 'Claude Code'; }
    mmry_host_script_ref() { printf '${CLAUDE_PLUGIN_ROOT}/hooks-handlers/%s' "$1"; }
fi
# The host and its name, read once and without a subshell where lib-host.sh resolved them (#33967).
if declare -F _mmry_host_resolve >/dev/null 2>&1 && _mmry_host_resolve 2>/dev/null && [[ -n "${_MMRY_HOST_V:-}" ]]; then
    _mmry_sc_host="$_MMRY_HOST_V"
    _mmry_sc_label="${_MMRY_HOST_LABEL_V:-}"
else
    _mmry_sc_host="$(mmry_host)"
    _mmry_sc_label=""
fi
[[ -n "$_mmry_sc_label" || "$_mmry_sc_host" != "codex" ]] || _mmry_sc_label="$(mmry_host_label)"

TMPDIR="${TMPDIR:-/tmp}"
MARKER="${TMPDIR}/.mmry-stop-checked"
LAST_SAVE="${TMPDIR}/.mmry-last-save"
STOP_COUNT_FILE="${TMPDIR}/.mmry-stop-count"

DEBOUNCE_SECONDS=900           # 15 minutes between visible firings
ESCALATION_THRESHOLD=3         # consecutive firings without a save before nagging

# A FORMATION RENEWAL TURN IS NOT A SEGMENT OF WORK (#31850). formation-check.sh renews its idle watch
# by waking the session with a notice; the model replies "Still listening." and this Stop follows.
# The 15-minute debounce is shorter than the 28-minute window, so this prompt used to fire on every
# renewal, and its exit 2 made a second model turn asking for memories from a turn that did nothing.
# The renewal leaves .mmry-renewal-turn-<session> for exactly that turn; finding this session's, this
# hook spends it and says nothing, leaving its debounce and count as they were.
#
# The payload is read only when some renewal marker exists, so every other Stop costs one glob and
# nothing more. A marker older than 15 minutes is discarded rather than obeyed.
_mmry_sc_renewal_turn() {
    local f any="" payload="" sid="" re='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"' at=""
    for f in "${TMPDIR}"/.mmry-renewal-turn-*; do
        [[ -f "$f" ]] && { any=1; break; }
    done
    [[ -n "$any" ]] || return 1
    if [[ ! -t 0 ]]; then
        IFS= read -r -d '' -t 2 payload || true
    fi
    [[ "$payload" =~ $re ]] && sid="${BASH_REMATCH[1]}"
    if [[ -z "$sid" ]] && declare -F mmry_session_id >/dev/null 2>&1; then
        sid="$(mmry_session_id 2>/dev/null || true)"
    fi
    [[ -n "$sid" ]] || return 1
    f="${TMPDIR}/.mmry-renewal-turn-${sid//[^A-Za-z0-9._-]/_}"
    [[ -f "$f" ]] || return 1
    { IFS= read -r at || true; } 2>/dev/null < "$f" || true
    rm -f -- "$f" 2>/dev/null || true
    [[ "$at" =~ ^[0-9]+$ ]] || return 1
    _mmry_sc_now
    (( _MMRY_SC_NOW - at <= 900 ))
}
if _mmry_sc_renewal_turn; then
    exit 0
fi

# The marker's time: the one it carries (#33967), else its mtime by stat, as before.
# THE MARKER'S MTIME STAYS THE AUTHORITY. Its time is also written to a file beside it, written FIRST,
# and that record is believed only while the marker is not older than it: [[ -ot ]] is a builtin
# comparison of the two mtimes, so the ordinary prompt reads the time with no process. A marker whose
# mtime was moved back afterwards (touch -t, as the suites do), or one with no record beside it (an
# older version's), is older than the record or has none, and is aged by stat as it always was.
_MMRY_SC_AT_FILE="${MARKER}.at"
_mmry_sc_marker_at() {
    if [[ -f "$_MMRY_SC_AT_FILE" && -f "$MARKER" && ! "$MARKER" -ot "$_MMRY_SC_AT_FILE" ]]; then
        _mmry_sc_first "$_MMRY_SC_AT_FILE"
        if [[ "$_MMRY_SC_LINE" =~ ^[0-9]{1,12}$ ]]; then
            _MMRY_SC_AT="$_MMRY_SC_LINE"
            return 0
        fi
    fi
    _MMRY_SC_AT="$(_mmry_mtime "$MARKER")"
}
# Stamp the marker by redirection, no touch: the record first, then the marker, so the marker is never
# older than its record.
#
# AND A RECORD FOR THE WINDOWS LAUNCHER (#33967 round 4). codex-hook.cmd ends a quiet stop-check in cmd,
# before Git's bash starts, from .mmry-stop-checked.cmd: this launch's seconds of the day and cmd's own
# date, exactly as the launcher handed them over (MMRY_CODEX_HOOK_SECS, MMRY_CODEX_HOOK_DATE), so cmd
# compares its own values and no clock or date arithmetic is shared. Written after the marker. Where they
# were not handed over (Claude Code, the sh form, a %TIME% the launcher could not read) an old record is
# emptied, so the launcher never trusts a stamp it did not make. Builtins only.
_MMRY_SC_CMD_FILE="${MARKER}.cmd"
_mmry_sc_stamp() {
    _mmry_sc_now
    printf '%s\n' "$_MMRY_SC_NOW" > "$_MMRY_SC_AT_FILE" 2>/dev/null
    # The marker write keeps its old effect: if it fails, so does this function.
    : > "$MARKER" 2>/dev/null || return
    if [[ "${MMRY_CODEX_HOOK_SECS:-}" =~ ^[0-9]{1,5}$ && -n "${MMRY_CODEX_HOOK_DATE:-}" && "$MMRY_CODEX_HOOK_DATE" != *[$'\r\n']* ]] \
        && (( 10#$MMRY_CODEX_HOOK_SECS < 86400 )); then
        printf '%05d %s' "$(( 10#$MMRY_CODEX_HOOK_SECS ))" "$MMRY_CODEX_HOOK_DATE" > "$_MMRY_SC_CMD_FILE" 2>/dev/null
    elif [[ -e "$_MMRY_SC_CMD_FILE" ]]; then
        : > "$_MMRY_SC_CMD_FILE" 2>/dev/null
    fi
    return 0
}

# Cross-platform mtime helper
_mmry_mtime() {
    if stat --version &>/dev/null 2>&1; then
        stat -c %Y "$1" 2>/dev/null || echo 0
    else
        stat -f %m "$1" 2>/dev/null || echo 0
    fi
}

# Debounce check.
if [[ -f "$MARKER" ]]; then
    _mmry_sc_now; now="$_MMRY_SC_NOW"
    _mmry_sc_marker_at; mtime="$_MMRY_SC_AT"
    age=$(( now - mtime ))
    if (( age < DEBOUNCE_SECONDS )); then
        exit 0
    fi
fi

# NOTHING TO SAVE MEANS SAY NOTHING (Eric, 2026-09-20).
#
# The hook is a shell script: it cannot read the conversation, so it cannot judge whether anything
# is worth keeping. Only the model can, and the directive below already asks it to ("If nothing new
# is worth keeping, skip and proceed"). What the hook CAN know for certain is that a save has
# already landed since the last time it spoke, and in that case there is positive evidence nothing
# is outstanding and the cheapest correct behaviour is silence.
#
# Compares the save sentinel against this hook's own marker rather than against the clock, so a
# customer who saves once per hour is not nudged an hour later about work they already kept.
#
# CODEX ONLY (#31245 QA, 2026-09-22). The decision was taken for the Codex prompt, which arrives at
# the start of the customer's next turn and is visible to them. On Claude Code this block changed
# an existing behaviour: master exits 2 with the directive in this exact state (marker past the
# debounce, a save recorded after it), and the branch went silent. Test case 4 says any change to
# Claude Code behaviour is a defect in this task, so Claude Code keeps the master behaviour and
# stop-check.bats pins it with a control that sets marker and save together.
if [[ "$_mmry_sc_host" == "codex" && -f "$MARKER" && -f "$LAST_SAVE" ]]; then
    _mmry_sc_marker_at; _sc_marker_at="$_MMRY_SC_AT"
    _mmry_sc_first "$LAST_SAVE"; _sc_save_at="$_MMRY_SC_LINE"
    if [[ "$_sc_save_at" =~ ^[0-9]+$ ]] && (( _sc_save_at >= _sc_marker_at )); then
        _mmry_sc_stamp || true
        echo "0" > "$STOP_COUNT_FILE" 2>/dev/null || true
        exit 0
    fi
fi

_mmry_sc_stamp

# Increment the "firings since last save" counter. Resets when mmry-client.sh
# calls _mmry_mark_save_success (which deletes the counter file).
firings=0
if [[ -f "$STOP_COUNT_FILE" ]]; then
    _mmry_sc_first "$STOP_COUNT_FILE"; firings="$_MMRY_SC_LINE"
    [[ "$firings" =~ ^[0-9]+$ ]] || firings=0
fi
firings=$(( firings + 1 ))
echo "$firings" > "$STOP_COUNT_FILE" 2>/dev/null || true

# Last-save anchor for incremental phrasing.
last_save_clause=""
if [[ -f "$LAST_SAVE" ]]; then
    _mmry_sc_first "$LAST_SAVE"; last_save_ts="$_MMRY_SC_LINE"
    if [[ "$last_save_ts" =~ ^[0-9]+$ ]]; then
        _mmry_sc_now; now="$_MMRY_SC_NOW"
        mins_since=$(( (now - last_save_ts) / 60 ))
        if (( mins_since < 1 )); then
            last_save_clause=" Your last save was under a minute ago; save only what is genuinely new since then, or skip."
        else
            last_save_clause=" Your last save was ${mins_since} minute(s) ago; save only what is new since then."
        fi
    fi
fi

# Escalation when the assistant has skipped repeatedly.
escalation_clause=""
if (( firings >= ESCALATION_THRESHOLD )); then
    escalation_clause=" You have skipped ${firings} Stop firings without saving. Either save now or briefly state in your reply why this segment has nothing worth keeping."
fi

# The compaction clause exists only on a host that has no pre-compaction moment of its own
# (#31245). On Claude Code it is empty, so the directive below is byte-for-byte the string this
# file has always produced; precompact-check.sh still owns that job there.
compaction_clause=""
if [[ "$_mmry_sc_host" == "codex" ]]; then
    compaction_clause=" ${_mmry_sc_label} gives MMRY no moment at compaction and no channel at session end, so this periodic prompt is the only warning you get: anything not saved can be lost when the conversation is trimmed."
fi

# Build the directive — one imperative line, explicit skip clause, anchored by last-save info
# when available. Plain double quotes around the path (the model sees them literally on stderr).
#
# On Claude Code the ${CLAUDE_PLUGIN_ROOT} reference is intentionally literal so the model expands
# it when it runs save-memory.sh. On Codex that variable is exported to HOOK processes only
# (codex-rs/hooks/src/engine/discovery.rs line 267), not to the shell the model runs its own
# commands in, so mmry_host_script_ref resolves an absolute path there instead. Getting this wrong
# is silent: the model would run a command against an empty prefix and report a missing file.
#
# ON CODEX THE DIRECTIVE NAMES THE TOOL, NOT THE SCRIPT (#31743). MMRY's tool server saves with no
# Internet access approval; the script, run by the model in Codex's sandbox, gets HTTP 000 until
# the customer approves access for the conversation. The first live Mac CLI run showed the model
# running whichever script it had been pointed at before it found the tool, so this prompt, which
# arrives on every turn with unsaved work, points at the tool. The Claude Code string is built
# exactly as before.
if [[ "$_mmry_sc_host" == "codex" ]]; then
    _mmry_save_how="call the mmry_plugin memory_save tool for each, with the memory as its content"
else
    _mmry_save_how="call \"$(mmry_host_script_ref save-memory.sh)\" with --context for each"
fi
DIRECTIVE="Save what is new since the last memory: identify decisions, findings, and corrections from this segment of the session, then ${_mmry_save_how}. If nothing new is worth keeping, skip and proceed.${last_save_clause}${escalation_clause}${compaction_clause}"

# #30642: deliver the directive on stderr and keep exit 2. On exit 2 (which blocks the stop)
# Claude Code discards stdout entirely and feeds the hook's STDERR to the model, so we emit
# ONLY to stderr - no JSON. Emitting the directive as JSON would force backslash escaping that
# leaks into the model-visible text; stderr-only keeps it clean. exit 2 preserves the block;
# moving to exit 0 would risk changing it. The user-only systemMessage is dropped.
# HOW THIS REACHES THE MODEL, PER HOST (#31245, 2026-09-20).
#
# Claude Code: unchanged. stderr plus exit 2, the #30642 contract. On exit 2 Claude Code discards
# stdout and feeds stderr to the model, so we emit ONLY to stderr; emitting JSON there would force
# escaping that leaks into the model-visible text.
#
# Codex: additionalContext on stdout with exit 0, registered on UserPromptSubmit rather than Stop.
# Measured against real sessions: exit 2 is reported Failed on EVERY Codex event and delivers
# nothing, and Stop rejects an additionalContext payload outright, so Stop has no channel to the
# model at all. The research design recommended moving this prompt to Stop and said it would work;
# that was reasoned from source and never run.
#
# UserPromptSubmit is also the better moment on its own merits. Codex trims conversations
# mid-session (auto_compact), and a prompt delivered at session end cannot save anyone from a
# trim that happened fifty turns earlier. The debounce above keeps it periodic rather than
# per-turn.
if [[ "$_mmry_sc_host" == "codex" ]]; then
    # Escaped by parameter expansion (#33967), not jq or sed: both were processes on every prompt that
    # prompts. The directive is one line of fixed prose, numbers and the host's name, so backslashes and
    # quotes are the only characters that can break the payload.
    _sc_escaped="${DIRECTIVE//\\/\\\\}"
    _sc_escaped="${_sc_escaped//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}' "$_sc_escaped"
    exit 0
fi

printf '%s\n' "$DIRECTIVE" >&2
exit 2
