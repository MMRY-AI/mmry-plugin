#!/usr/bin/env bash
# stop-check.sh — Stop hook: nags the assistant to save incremental session memories.
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
#        Stop DOES work on Codex, and identically: events/stop.rs line 343 takes exit 2 with
#        non-empty stderr and makes it the continuation prompt. The requirement is that a Codex
#        session ending produces the same save prompt a Claude Code session produces, and it does,
#        with one added sentence.

set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-host.sh"

TMPDIR="${TMPDIR:-/tmp}"
MARKER="${TMPDIR}/.mmry-stop-checked"
LAST_SAVE="${TMPDIR}/.mmry-last-save"
STOP_COUNT_FILE="${TMPDIR}/.mmry-stop-count"

DEBOUNCE_SECONDS=900           # 15 minutes between visible firings
ESCALATION_THRESHOLD=3         # consecutive firings without a save before nagging

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
    now=$(date +%s)
    mtime=$(_mmry_mtime "$MARKER")
    age=$(( now - mtime ))
    if (( age < DEBOUNCE_SECONDS )); then
        exit 0
    fi
fi

touch "$MARKER"

# Increment the "firings since last save" counter. Resets when mmry-client.sh
# calls _mmry_mark_save_success (which deletes the counter file).
firings=0
if [[ -f "$STOP_COUNT_FILE" ]]; then
    firings=$(head -1 "$STOP_COUNT_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ "$firings" =~ ^[0-9]+$ ]] || firings=0
fi
firings=$(( firings + 1 ))
echo "$firings" > "$STOP_COUNT_FILE" 2>/dev/null || true

# Last-save anchor for incremental phrasing.
last_save_clause=""
if [[ -f "$LAST_SAVE" ]]; then
    last_save_ts=$(head -1 "$LAST_SAVE" 2>/dev/null | tr -d '[:space:]')
    if [[ "$last_save_ts" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
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
if [[ "$(mmry_host)" == "codex" ]]; then
    compaction_clause=" This is also your last prompt before this conversation may be trimmed: $(mmry_host_label) gives MMRY no moment at compaction, so anything not saved now can be lost without warning."
fi

# Build the directive — one imperative line, explicit skip clause, anchored by last-save info
# when available. Plain double quotes around the path (the model sees them literally on stderr).
#
# On Claude Code the ${CLAUDE_PLUGIN_ROOT} reference is intentionally literal so the model expands
# it when it runs save-memory.sh. On Codex that variable is exported to HOOK processes only
# (codex-rs/hooks/src/engine/discovery.rs line 267), not to the shell the model runs its own
# commands in, so mmry_host_script_ref resolves an absolute path there instead. Getting this wrong
# is silent: the model would run a command against an empty prefix and report a missing file.
DIRECTIVE="Save what is new since the last memory: identify decisions, findings, and corrections from this segment of the session, then call \"$(mmry_host_script_ref save-memory.sh)\" with --context for each. If nothing new is worth keeping, skip and proceed.${last_save_clause}${escalation_clause}${compaction_clause}"

# #30642: deliver the directive on stderr and keep exit 2. On exit 2 (which blocks the stop)
# Claude Code discards stdout entirely and feeds the hook's STDERR to the model, so we emit
# ONLY to stderr - no JSON. Emitting the directive as JSON would force backslash escaping that
# leaks into the model-visible text; stderr-only keeps it clean. exit 2 preserves the block;
# moving to exit 0 would risk changing it. The user-only systemMessage is dropped.
printf '%s\n' "$DIRECTIVE" >&2
exit 2
