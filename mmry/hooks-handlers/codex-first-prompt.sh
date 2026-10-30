#!/usr/bin/env bash
# codex-first-prompt.sh - hands a Codex conversation the startup memories its session start could
# not deliver in time, with its first prompt (#33062 fix round 1). Codex only: registered as a
# UserPromptSubmit hook in hooks/codex-hooks.json and run through codex-hook.sh. Claude Code has no
# session-start limit and never runs this.
#
# WHY. Codex cuts the SessionStart hook off at 30 s. codex-hook.sh gives up waiting at its budget and
# prints a notice instead, and on a heavily loaded Windows machine (76 to 88 bash processes) that
# happened in 4 live runs of 5. The memories were not lost: the work carries on after the hook returns
# and writes its finished answer to a hand-off file. Codex runs UserPromptSubmit hooks before the
# model answers the prompt, so this delivers them before the first answer.
#
# EXACTLY ONCE. codex-hook.sh writes .mmry-codex-late.<session> (holding its pid) only when it gave
# the notice INSTEAD of the memories. Without that marker for this conversation this says nothing. With
# it, this waits for the hand-off the same start wrote (.mmry-codex-start.<session>.<pid>.ready), up to
# its budget, hands it over, and removes the marker, so a later prompt does not hand it over again.
#
# AND IF THEY STILL HAVE NOT ARRIVED, IT SAYS SO. The start's notice told the assistant they were on
# their way; at the budget this tells it they were not loaded, and how the person can load them now.
#
# THE BUDGET is 30 s from this shell's start (MMRY_CODEX_FIRST_PROMPT_BUDGET, whole seconds 1 to 35,
# shortens it for a test), under the 45 s codex-hooks.json declares, leaving 15 s for cmd.exe and
# Git's bash to start on a loaded Windows machine and for this to answer.
#
# It runs only when a late marker exists: both the sh line in codex-hooks.json and codex-hook.cmd look
# for one with no process started, so every other prompt of every conversation pays a file lookup.
set -uo pipefail

_T="${TMPDIR:-/tmp}"

_sid=""
if [[ ! -t 0 ]]; then
    _payload=""
    IFS= read -r -d '' -t 5 _payload || true
    # The same id rule as codex-hook.sh and the per-prompt Foundation hook: no dot, no separator.
    _re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
    [[ "$_payload" =~ $_re ]] && _sid="${BASH_REMATCH[1]}"
fi

_sweep() {
    # A marker or hand-off no conversation collected (it ended before its first prompt) would keep
    # the gate open for every prompt on this machine. Half a day on, it is nobody's.
    find "$_T" -maxdepth 1 -type f \( -name '.mmry-codex-late.*' -o -name '.mmry-codex-start.*' \) -mmin +720 -delete 2>/dev/null || true
}

[[ -n "$_sid" ]] || { _sweep; exit 0; }
_late="${_T}/.mmry-codex-late.${_sid}"
[[ -f "$_late" ]] || { _sweep; exit 0; }

_pid=""
IFS= read -r _pid < "$_late" 2>/dev/null || true
if ! [[ "$_pid" =~ ^[0-9]{1,10}$ ]]; then
    rm -f "$_late" 2>/dev/null
    exit 0
fi
_hand="${_T}/.mmry-codex-start.${_sid}.${_pid}"

_budget="${MMRY_CODEX_FIRST_PROMPT_BUDGET:-30}"
if ! [[ "$_budget" =~ ^[0-9]+$ ]] || (( _budget < 1 || _budget > 35 )); then
    _budget=30
fi
while [[ ! -f "${_hand}.ready" ]] && (( SECONDS < _budget )); do
    sleep 1
done

if [[ -f "${_hand}.ready" ]]; then
    _ans=""
    IFS= read -r -d '' _ans < "${_hand}.out" 2>/dev/null || true
    # The session start's own answer, word for word, as this event's: Codex reads hookSpecificOutput
    # by its hookEventName. An answer with no JSON (no account set up says so in plain text) is
    # context as it stands on this event too.
    printf '%s' "${_ans/\"hookEventName\":\"SessionStart\"/\"hookEventName\":\"UserPromptSubmit\"}"
else
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"MMRY AI: the memories that were still loading at the start of this conversation did not arrive in time, so they were not loaded. Tell the user, before anything else, that their MMRY memories were not loaded this time because loading them took too long, and offer to load them now with the mmry_plugin memory_load tool."}}'
fi

rm -f "$_late" "${_hand}.out" "${_hand}.ready" 2>/dev/null
exit 0
