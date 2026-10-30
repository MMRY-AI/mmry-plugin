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
# their way; at the budget this tells it they were not loaded, to load them with the memory_load tool
# before it answers, and to tell the person.
#
# THE BUDGET is 90 s from codex-hook.cmd's start, or this shell's (MMRY_CODEX_FIRST_PROMPT_BUDGET,
# whole seconds 1 to 100, shortens it for a test), under the 120 s codex-hooks.json declares. The
# person waits only when the memories really are still on their way; every other prompt is gated off.
# Measured on a real Codex run at 98 to 148 bash processes: the late answer was finished a few
# seconds after a 45 s budget gave up, because session-start.sh, after writing the memories, still
# stores the Foundation set before it answers. The memories are worth that wait on the first prompt.
#
# It runs only when a late marker exists: both the sh line in codex-hooks.json and codex-hook.cmd look
# for one with no process started, so every other prompt of every conversation pays a file lookup.
set -euo pipefail

_T="${TMPDIR:-/tmp}"

_sid=""
if [[ ! -t 0 ]]; then
    _payload=""
    IFS= read -r -d '' -t 5 _payload || true
    # The same id rule as codex-hook.sh and the per-prompt Foundation hook: no dot, no separator.
    _re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
    [[ "$_payload" =~ $_re ]] && _sid="${BASH_REMATCH[1]}"
fi

# ONE LINE PER RUN THAT GOT PAST THE GATE, for support: what it found and what it did. The bash clock
# where there is one (4.2+), so no process is started for it; the file is overwritten past 200 lines.
_log() {
    local f="${_T}/mmry-codex-first-prompt.log" n=0 l
    [[ -f "$f" ]] && while IFS= read -r l; do n=$((n + 1)); done < "$f"
    (( n > 200 )) && : > "$f"
    printf '%(%Y-%m-%dT%H:%M:%S)T session=%s %s
' -1 "${_sid:-none}" "$1" >> "$f" 2>/dev/null || true
}

_sweep() {
    # A marker or hand-off no conversation collected (it ended before its first prompt) would keep
    # the gate open for every prompt on this machine. Half a day on, it is nobody's.
    find "$_T" -maxdepth 1 -type f \( -name '.mmry-codex-late.*' -o -name '.mmry-codex-start.*' \) -mmin +720 -delete 2>/dev/null || true
}

[[ -n "$_sid" ]] || { _log "no session id in the payload"; _sweep; exit 0; }
_late="${_T}/.mmry-codex-late.${_sid}"
[[ -f "$_late" ]] || { _log "nothing late for this session"; _sweep; exit 0; }

_pid=""
IFS= read -r _pid < "$_late" 2>/dev/null || true
if ! [[ "$_pid" =~ ^[0-9]{1,10}$ ]]; then
    rm -f "$_late" 2>/dev/null
    exit 0
fi
_hand="${_T}/.mmry-codex-start.${_sid}.${_pid}"

_budget="${MMRY_CODEX_FIRST_PROMPT_BUDGET:-90}"
if ! [[ "$_budget" =~ ^[0-9]+$ ]] || (( _budget < 1 || _budget > 100 )); then
    _budget=90
fi
# Counted from codex-hook.cmd's start where it stamped one, as codex-hook.sh counts the session
# start's: on a loaded Windows machine cmd.exe and Git's bash took several seconds before this shell
# existed. printf's clock is bash 4.2+ and starts no process; a stamp that does not read as H:MM:SS,
# or is more than two minutes away, is ignored.
_spent0=0
_t0="${MMRY_CODEX_HOOK_STARTED:-}"; _t0="${_t0// /}"; _t0="${_t0%%[.,]*}"
_re_t='^([0-9]{1,2}):([0-9]{2}):([0-9]{2})$'
if [[ "$_t0" =~ $_re_t ]]; then
    _t0s=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
    _now=""
    printf -v _now '%(%H:%M:%S)T' -1 2>/dev/null || _now=""
    if [[ "$_now" =~ $_re_t ]]; then
        _since=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} - _t0s ))
        (( _since >= 0 )) || _since=$(( _since + 86400 ))
        (( _since > SECONDS && _since <= 120 )) && _spent0=$(( _since - SECONDS ))
    fi
fi
while [[ ! -f "${_hand}.ready" ]] && (( SECONDS + _spent0 < _budget )); do
    sleep 1
done

if [[ -f "${_hand}.ready" ]]; then
    _ans=""
    IFS= read -r -d '' _ans < "${_hand}.out" 2>/dev/null || true
    # The session start's own answer, word for word, as this event's: Codex reads hookSpecificOutput
    # by its hookEventName. An answer with no JSON (no account set up says so in plain text) is
    # context as it stands on this event too.
    # Pattern and replacement from variables, unquoted inside the expansion: bash 3.2 keeps escaped
    # quotes there literally. Neither holds a glob character.
    _from='"hookEventName":"SessionStart"' _to='"hookEventName":"UserPromptSubmit"'
    printf '%s' "${_ans/$_from/$_to}"
    _log "delivered the late start ${_pid} (${#_ans} bytes) after ${SECONDS}s"
else
    _log "the late start ${_pid} had not finished after ${SECONDS}s; said they were not loaded"
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"MMRY AI: the memories that were still loading at the start of this conversation did not arrive in time, so they were not loaded. Load them now with the mmry_plugin memory_load tool before you answer, and tell the user that their MMRY memories were not loaded automatically this time because loading them took too long."}}'
fi

rm -f "$_late" "${_hand}.out" "${_hand}.ready" 2>/dev/null
exit 0
