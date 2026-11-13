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
# EXACTLY ONCE. codex-hook.sh writes .mmry-codex-late.<key>.<session> (holding its pid) as the session
# start begins, and rewrites it "delivered" when it gave the memories in time (fix round 2; it used to
# write it only when it gave the notice INSTEAD of the memories). Without that marker for this
# conversation, or with it saying "delivered" or "none", this says nothing. Otherwise it waits for the
# hand-off the same start writes (.mmry-codex-start.<key>.<session>.<pid>.ready), hands it over, and
# removes the marker, so a later prompt does not hand it over again.
#
# AND ONLY TO ITS OWN ACCOUNT (#33617, DD-179). <key> is the account key every Foundation file carries
# (#33363), computed before anything else is loaded by lib-codex-key.sh, the same helper codex-hook.sh
# names the files with. Two accounts on one machine can share a session id, and the independent QA of
# #33363 (S1) saw account B's first prompt handed account A's memories through a hand-off named by the id
# alone. The name keeps the hand-offs apart; a second guard below refuses an answer whose memories file
# is not this account's, whatever name it came under. The bare names an older plugin left are never
# read again, by any account: nothing in them proves whose they are. They go with the sweep below.
#
# AND IF THEY STILL HAVE NOT ARRIVED, IT SAYS SO. The start's notice told the assistant they were on
# their way; at the budget this tells it they were not loaded, to load them with the memory_load tool
# before it answers, and to tell the person.
#
# HOW LONG IT WAITS (fix round 2, see the ceiling below): while the start's work is still running, up
# to 200 s from codex-hook.cmd's start, under the 300 s codex-hooks.json declares; not at all once that
# work has stopped without an answer; and, only when there is no work it can see, the fixed budget of
# 90 s (MMRY_CODEX_FIRST_PROMPT_BUDGET, whole seconds 1 to 100, shortens it for a test). The
# person waits only when the memories really are still on their way; every other prompt is gated off.
# Measured on a real Codex run at 98 to 148 bash processes: the late answer was finished a few
# seconds after a 45 s budget gave up, because session-start.sh, after writing the memories, still
# stores the Foundation set before it answers. The memories are worth that wait on the first prompt.
#
# It runs only when a late marker exists: both the sh line in codex-hooks.json and codex-hook.cmd look
# for one with no process started, so every other prompt of every conversation pays a file lookup.
set -euo pipefail
# EVERYTHING THIS WRITES IS OWNER-ONLY (#33231, DD-182): its claim and its log. A builtin.
umask 077

# The shared temp folder is named here for one thing only: the sweep of the names a previous plugin
# wrote there, which nothing reads any more (#33231).
_T="${TMPDIR:-/tmp}"

# THE PER-USER FOLDER FIRST, AND NOTHING WITHOUT IT (#33231, DD-182). The marker and the hand-off live
# in <CODEX_HOME, else $HOME/.codex>/mmry-handoff (lib-codex-key.sh, builtins only), and are read only
# when that is this user's own directory and not a link. A folder that is a link, another user's, or
# absent is refused: nothing is read, nothing is delivered and nothing is said. Not even logged, because
# the log lives in the folder. Forward slashes first and only when there is a backslash, as
# codex-hook.sh does: this file is found from a Windows path when codex-hook.cmd started it.
_self="${BASH_SOURCE[0]}"
case "$_self" in *\\*) _self="${_self//\\//}" ;; esac
[[ "$_self" == */* ]] || _self="./${_self}"
_D=""
if [[ -f "${_self%/*}/lib-codex-key.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_self%/*}/lib-codex-key.sh" 2>/dev/null || true
    if declare -F mmry_codex_private_dir_ok >/dev/null 2>&1; then
        mmry_codex_private_dir_v 2>/dev/null && mmry_codex_private_dir_ok 2>/dev/null && _D="$_MMRY_CODEX_DIR"
    fi
fi
[[ -n "$_D" ]] || exit 0

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
# In the per-user folder (#33231): it names the session and what was delivered.
_log() {
    local f="${_D}/mmry-codex-first-prompt.log" n=0 l
    [[ -f "$f" ]] && while IFS= read -r l; do n=$((n + 1)); done < "$f"
    (( n > 200 )) && : > "$f"
    # bash 3.2 (macOS) has no %(...)T: the line goes without its time there.
    printf '%(%Y-%m-%dT%H:%M:%S)T session=%s %s\n' -1 "${_sid:-none}" "$1" >> "$f" 2>/dev/null \
        || printf 'session=%s %s\n' "${_sid:-none}" "$1" >> "$f" 2>/dev/null || true
}

_sweep() {
    # A marker or hand-off no conversation collected (it ended before its first prompt) would keep
    # the gate open for every prompt on this machine. Half a day on, it is nobody's. The old names in
    # the temp folder, which a previous plugin wrote and nothing reads now, go the same way.
    find "$_D" -maxdepth 1 -type f \( -name '.mmry-codex-late.*' -o -name '.mmry-codex-start.*' \) -mmin +720 -delete 2>/dev/null || true
    find "$_T" -maxdepth 1 -type f \( -name '.mmry-codex-late.*' -o -name '.mmry-codex-start.*' \) -mmin +720 -delete 2>/dev/null || true
}

[[ -n "$_sid" ]] || { _log "no session id in the payload"; _sweep; exit 0; }
# The account key, from lib-codex-key.sh above, builtins only (#33617). Without a key nothing is read: a
# bare name is never looked for.
_part="" _key=""
declare -F mmry_codex_session_part_v >/dev/null 2>&1 \
    && mmry_codex_session_part_v "$_sid" 2>/dev/null && _part="$_MMRY_CODEX_SESSION_PART" _key="$_MMRY_CODEX_KEY"
[[ -n "$_part" && -n "$_key" ]] || { _log "no account key could be computed: nothing is read"; exit 0; }
_late="${_D}/.mmry-codex-late.${_part}"
# The marker must be this user's own regular file, not a link (#33231): anything else is not read.
mmry_codex_own_file "$_late" || { _log "nothing late for this session"; _sweep; exit 0; }

_pid="" _state=""
{ IFS= read -r _pid; IFS= read -r _state; } < "$_late" 2>/dev/null || true
# The pattern from a variable and the length tested apart: bash 3.2, the macOS sh, refused the
# inline ^[0-9]{1,10}$ (CI macOS: the marker was dropped here with nothing said).
_re_pid='^[0-9]+$'
if ! [[ "$_pid" =~ $_re_pid ]] || (( ${#_pid} > 10 )); then
    _log "the late marker held no process id: ${_pid:0:20}"
    rm -f "$_late" 2>/dev/null
    exit 0
fi
_hand="${_D}/.mmry-codex-start.${_part}.${_pid}"
# The session start arms the marker as it begins (fix round 2) and settles it: "delivered" when the
# memories went out in time, "none" when it started no work. Either way there is nothing to hand over.
if [[ "$_state" == delivered || "$_state" == none ]]; then
    _log "the start ${_pid} said ${_state}: nothing to hand over"
    rm -f "$_late" "${_hand}.out" "${_hand}.ready" "${_hand}.pid" "${_hand}.claim" 2>/dev/null
    exit 0
fi

# THE HAND-OFF IS CLAIMED BEFORE IT IS WAITED FOR (#33062 fix round 3). This prompt running while the
# start has not said "delivered" means Codex stopped listening to the start, so an answer the start
# gives from now on, however much inside its own budget, reaches nobody: the hand-off is this
# prompt's. It used to be taken away anyway: the start that answered in time marked "delivered" and
# its cleanup removed the hand-off, and on a fast Linux runner (CI ubuntu) that happened between two
# of this loop's looks, which then found the work gone and no answer and said the memories were not
# loaded. Whichever of the two creates .claim first owns the delivery: noclobber creates it only if it
# is not there (O_EXCL), a builtin, no process started. The start marks "delivered", and its cleanup
# removes the hand-off, only when it got the claim. printf, not `:`: under sh (bash in POSIX mode, the
# Windows and macOS sh) a redirection that fails on a special builtin such as `:` ends the shell, and
# a claim that is already taken is exactly that failure.
_claimed=0
set -C
{ printf '%s\n' "$$" > "${_hand}.claim"; } 2>/dev/null && _claimed=1
set +C
_state=gone
# A pending marker is one line, so the second read ends at the end of the file: not a failure.
[[ -f "$_late" ]] && { _state=""; { IFS= read -r _; IFS= read -r _state; } < "$_late" 2>/dev/null || true; }
if (( _claimed == 0 )) || [[ "$_state" == delivered || "$_state" == gone ]]; then
    # The start claimed first: it answered while Codex was still listening, before this prompt ran.
    _log "the start ${_pid} answered in time: nothing to hand over"
    (( _claimed == 1 )) && rm -f "${_hand}.claim" 2>/dev/null
    exit 0
fi

_budget="${MMRY_CODEX_FIRST_PROMPT_BUDGET:-90}"
if ! [[ "$_budget" =~ ^[0-9]+$ ]] || (( _budget < 1 || _budget > 100 )); then
    _budget=90
fi
# WAIT FOR THE WORK, NOT FOR A FIXED TIME (#33062 fix round 2). Measured with a real Codex at 157 to 177
# bash processes, the memories were ready 142 to 163 s after this hook started, and the fixed 90 s
# above gave up on work that was still running. So while the start's drain (its pid in .pid, written by
# codex-hook.sh) is alive, this waits for it, up to the ceiling; when it is gone with no answer, this
# says so at once. Only when there is no drain to watch does the fixed wait above still decide.
#
# THE CEILING IS 200 s FROM codex-hook.cmd's START, AND codex-hooks.json DECLARES 300. Codex counts its
# limit from when it spawns the hook, before cmd.exe has run a line: it spawns the prompt's eight hooks
# together, and under that load this one's cmd.exe began 19 s after Codex's clock had started. A wait
# that ended near the declared limit by this hook's own clock ran past Codex's, and Codex dropped the
# answer, so the conversation got no MMRY message at all. A test may shorten the ceiling with
# MMRY_CODEX_FIRST_PROMPT_CEILING (whole seconds, 1 to 200).
_ceiling="${MMRY_CODEX_FIRST_PROMPT_CEILING:-200}"
if ! [[ "$_ceiling" =~ ^[0-9]+$ ]] || (( _ceiling < 1 || _ceiling > 200 )); then
    _ceiling=200
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
        # Within the 300 s codex-hooks.json declares: a stamp further away is not this hook's.
        (( _since > SECONDS && _since <= 300 )) && _spent0=$(( _since - SECONDS ))
    fi
fi
# kill -0 is a builtin: it asks whether the process is still there and starts none.
_wpid="" _gone=0
while [[ ! -f "${_hand}.ready" ]] && (( SECONDS + _spent0 < _ceiling )); do
    if [[ -z "$_wpid" && -f "${_hand}.pid" ]]; then
        IFS= read -r _wpid < "${_hand}.pid" 2>/dev/null || true
        [[ "$_wpid" =~ $_re_pid ]] && (( ${#_wpid} <= 10 )) || _wpid=""
    fi
    if [[ -n "$_wpid" ]]; then
        if ! kill -0 "$_wpid" 2>/dev/null; then
            [[ -f "${_hand}.ready" ]] || _gone=1
            break
        fi
    elif (( SECONDS + _spent0 >= _budget )); then
        break
    fi
    sleep 1
done

_ans="" _refused=0
if [[ -f "${_hand}.ready" ]]; then
    # THE FIRST GUARD (#33231, DD-182): the hand-off is read only when .ready and .out are this user's
    # own regular files, not links. Anything else at those names is refused, cleared below with the
    # marker, and the person is told as for memories that never arrived.
    if mmry_codex_own_file "${_hand}.ready" && mmry_codex_own_file "${_hand}.out"; then
        IFS= read -r -d '' _ans < "${_hand}.out" 2>/dev/null || true
    else
        _refused=1
        _log "refused the late start ${_pid}: its hand-off is not this user's own regular file"
    fi
    # THE SECOND GUARD (#33617, DD-179): an answer that names a memories file names THIS account's, or it
    # is refused. The file is mmry-memories.<key>.<session>.md (lib-foundation-key.sh), so a path under
    # another key is another account's memories, whatever name the hand-off came under. Cheap, and it
    # holds even if a writer forgets the key. A refused hand-off is cleared below with the marker, and the
    # person is told as for memories that never arrived, which for this account they did not.
    _mark='Read them now: '
    if (( _refused == 0 )) && [[ "$_ans" == *"$_mark"* && "$_ans" != *"mmry-memories.${_key}."* ]]; then
        _refused=1
        _log "refused the late start ${_pid}: its memories file is not this account's"
    fi
fi

if [[ -f "${_hand}.ready" ]] && (( _refused == 0 )); then
    # The session start's own answer, word for word, as this event's: Codex reads hookSpecificOutput
    # by its hookEventName. An answer with no JSON (no account set up says so in plain text) is
    # context as it stands on this event too.
    # Pattern and replacement from variables, unquoted inside the expansion: bash 3.2 keeps escaped
    # quotes there literally. Neither holds a glob character.
    _from='"hookEventName":"SessionStart"' _to='"hookEventName":"UserPromptSubmit"'
    _out="${_ans/$_from/$_to}"
    # AND THE PERSON IS TOLD, IN MMRY AI'S NAME, THAT THEY WERE LATE (#33062 fix round 7). Eric, watched
    # check 2: "I saw the notice but didn't know what the source was". The start's own late notice says
    # so too, but Codex drops it when the start is cut off at its limit, so the memories handed over here
    # carry the sentence themselves, after the "Read them now: <path>" line, so that line and its path
    # are unchanged for whatever reads them. Only for an answer that loaded memories; any other answer
    # (no account, credits, a fault) is passed on as it stands. The sentence is Eric's approved copy
    # (2026-11-03 03:14 UTC), already escaped for JSON. Patterns from variables, unquoted inside the
    # expansion, as above, for bash 3.2.
    _late_note='\n\nThese memories were late: they could not be loaded in time for the start of this conversation. Tell the user this sentence, word for word, before anything else: \"MMRY AI: your saved memories were late to load at the start of this conversation. They are loaded now.\"'
    _mark='Read them now: ' _q='"' _bs='\'
    if [[ "$_out" == *"$_mark"* ]]; then
        _rest="${_out#*${_mark}}"
        _path="${_rest%%${_q}*}"
        if [[ "$_path" != "$_rest" && "${_path: -1}" != "$_bs" ]]; then
            _out="${_out%%${_mark}*}${_mark}${_path}${_late_note}${_q}${_rest#*${_q}}"
        fi
    fi
    printf '%s' "$_out"
    _log "delivered the late start ${_pid} (${#_ans} bytes) after ${SECONDS}s"
else
    if (( _refused == 1 )); then
        :
    elif (( _gone == 1 )); then
        _log "the late start ${_pid} stopped without an answer after ${SECONDS}s; said they were not loaded"
    else
        _log "the late start ${_pid} had not finished after ${SECONDS}s; said they were not loaded"
    fi
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"MMRY AI: the memories that were still loading at the start of this conversation did not arrive in time, so they were not loaded. Load them now with the mmry_plugin memory_load tool before you answer. If that loads them, tell the user this sentence, word for word, before anything else: \"MMRY AI: your saved memories were late to load at the start of this conversation. They are loaded now.\" If it does not, tell the user this sentence instead, word for word: \"MMRY AI: your saved memories could not be loaded for this conversation.\""}}'
fi

rm -f "$_late" "${_hand}.out" "${_hand}.ready" "${_hand}.pid" "${_hand}.claim" 2>/dev/null
exit 0
