#!/usr/bin/env bash
# codex-hook.sh - the single entry point every MMRY hook uses on OpenAI Codex (#31245).
#
# WHY AN ENTRY POINT RATHER THAN EDITING TWENTY-EIGHT HANDLERS. The handlers already locate
# themselves from ${BASH_SOURCE[0]} and already prefer environment variables over hard-coded paths
# where it matters - mmry-client.sh checks ${MMRY_CONFIG_FILE} before anything else. What they do
# not do is decide which host they are serving. This script decides once, exports the answer, and
# hands over. The alternative, teaching every handler to detect its own host, puts the same
# decision in twenty-eight places where it can be made twenty-eight different ways.
#
# It also keeps the Codex registration honest about what it is doing: hooks/codex-hooks.json names
# this file and a handler, so the whole Codex surface is readable in one place instead of being
# spread across command strings.
#
# Usage: bash codex-hook.sh <handler-name> [args...]
#   e.g. bash codex-hook.sh session-init
#        bash codex-hook.sh formation-check
#
# FAIL OPEN. A hook that cannot run must not break the customer's session. Every failure path here
# exits 0 with nothing on stdout, which Codex treats as "this hook had nothing to say"
# (codex-rs/hooks/src/events/post_tool_use.rs: Some(0) with empty stdout is a no-op). The one
# exception is the exit code of the handler itself, which is passed through untouched, because
# exit 2 is how Stop and PostToolUse handlers deliver text to the model and swallowing it would
# silently disable delivery.

# set -e is the repository convention (structural/file-integrity.bats enforces it) and is safe here
# only because every step below is explicitly guarded with `|| exit 0`. The fail-open promise is
# carried by those guards, not by the absence of -e.
# STARTED BY sh, NOT BY bash, AND THAT IS DELIBERATE (#31245, 2026-09-21).
#
# The hook command used to begin with a bare `bash`. On Windows Codex runs it through cmd, cmd
# takes the first `bash` on PATH, and Windows ships one in System32: the Linux subsystem's. On a
# machine where that wins, it cannot translate a Windows working directory and exits 1 with no
# output before any of this file runs. Measured on Eric's machine, where `where.exe bash` inside a
# live session returns C:\Windows\System32\bash.exe ahead of Git's, and the hook failed on every
# turn. commandWindows was the mitigation for exactly this and is unusable, because declaring it
# stops Codex consuming the hook's output at all.
#
# `sh` is immune to that trap: Windows ships bash.exe in System32 but NO sh.exe, so `sh` can only
# resolve to Git's, which is bash 5.2 wearing a different name and sets BASH_VERSION.
#
# On Linux `sh` is often dash, which has no [[ ]] and no pipefail, so the two lines below re-exec
# under a real bash before anything bash-specific is parsed. They are deliberately POSIX: this is
# the one part of the file that may be read by a shell that is not bash. Everything after the
# re-exec is guaranteed bash.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

HANDLER_NAME="${1:-}"
[[ -n "$HANDLER_NAME" ]] || exit 0
shift

# Reject anything that is not a bare handler name. This runs with whatever the hook declaration
# says, and a declaration is editable by anyone who can write the customer's config, so a name
# carrying a path separator or "." is refused rather than resolved.
case "$HANDLER_NAME" in
    *[/\\]*|.*|"") exit 0 ;;
esac

# THE FIRST PROMPT'S LATE MEMORIES RUN HERE, IN THIS SHELL, BEFORE ANYTHING BELOW (#33062 fix round 1).
# codex-first-prompt.sh needs no host, no library and no credential, only the temp folder, and it runs
# exactly when a start was already too slow, so it is sourced before the lines below start their
# subshells and their library, and without a second bash. Measured on a heavily loaded Windows machine
# (110 to 158 bash processes), the path through them took it past its limit.
if [[ "$HANDLER_NAME" == "codex-first-prompt" ]]; then
    # Forward slashes first: codex-hook.cmd starts this file by its Windows path, C:\...\codex-hook.sh
    # (measured: without this the late memories were never delivered on Windows).
    # Only when there is a backslash: bash 3.2 (macOS sh) does not read that expansion the same way.
    _mmry_self="${BASH_SOURCE[0]}"
    case "$_mmry_self" in *\\*) _mmry_self="${_mmry_self//\\//}" ;; esac
    [[ "$_mmry_self" == */* ]] || _mmry_self="./${_mmry_self}"
    # Not found that way: carry on to the ordinary dispatch below, which also runs it, only slower.
    if [[ -f "${_mmry_self%/*}/codex-first-prompt.sh" ]]; then
        set +e
        # shellcheck source=/dev/null
        source "${_mmry_self%/*}/codex-first-prompt.sh"
        exit 0
    fi
fi

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
PLUGIN_ROOT="$(cd "${HANDLER_DIR}/.." && pwd)" || exit 0

# ---- Declare the host, before anything reads a path. ----
export MMRY_HOST="codex"

# shellcheck source=/dev/null
# [[ -f ]] first (#31245 QA round 9): bash 3.2, the macOS bash, aborts under set -e when a sourced
# file is missing, even inside an if, so the fallback below was unreachable exactly where it mattered.
[[ -f "${HANDLER_DIR}/lib-host.sh" ]] || exit 0
source "${HANDLER_DIR}/lib-host.sh" 2>/dev/null || exit 0

# NO RESOLVABLE HOME MEANS NOTHING BELOW CAN WORK, SO STOP QUIETLY (#31245, 2026-09-20).
#
# Every path from here reads or writes under the customer's home: the credential, the state
# directory, the memories file. With none of HOME, USERPROFILE or HOMEDRIVE/HOMEPATH set, those
# become paths rooted at "/" and the handlers spend their time failing to create directories they
# were never going to be able to use. Exiting here keeps the session clean instead.
[[ -n "$(mmry_home)" ]] || exit 0

# CLAUDE_PLUGIN_ROOT is exported by Codex itself for plugin-sourced hooks
# (codex-rs/hooks/src/engine/discovery.rs line 267, commented "For OOTB compat with existing
# plugins that use this env var"). It is re-derived here rather than trusted, because this script
# is also reachable from a hooks.json a customer wrote by hand, from config.toml, and from the test
# suite, none of which set it. Deriving it from our own location is correct in all four cases.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# THE CREDENTIAL IS SET BY lib-host.sh, SOURCED ABOVE, AND DELIBERATELY NOT AGAIN HERE.
#
# mmry-client.sh's discovery order is ${MMRY_CONFIG_FILE}, then the plugin root, then
# ${HOME}/.claude/mmry-config.json, so setting the first is what lets the client serve a second
# host without being edited. That has to happen for the handlers the MODEL runs directly as well,
# and those never come through this file, so it belongs in lib-host.sh where every consumer of the
# client reaches it.
#
# This file used to repeat it. The repetition was removed after the mutation harness showed the
# line could be deleted without a single test failing - lib-host.sh was already doing the work, so
# the second copy was unreachable code that looked load-bearing. An already-set MMRY_CONFIG_FILE is
# still left alone, by lib-host.sh, because it is the documented override.

TARGET="${HANDLER_DIR}/${HANDLER_NAME}.sh"
[[ -f "$TARGET" ]] || exit 0

# THE SESSION START HAS A DEADLINE, AND MISSING IT MUST BE SAID (#33062).
#
# Codex gives the SessionStart hook the seconds hooks/codex-hooks.json declares (30) and then cuts
# it off, and a hook that is cut off delivers nothing: the conversation starts without memories and
# without a word about it. Measured on a busy Windows machine, a start took 34 s to 75 s, and in
# one run 142 s, almost all of it starting processes, while the service answered in well under one.
#
# Two things keep that from reaching the person.
#
# THE MEMORIES FIRST, THE HOUSEKEEPING AFTER. _mmry_codex_start, below, runs session-start.sh before
# anything else, lets go of the output it hands to this hook, and only then runs session-init.sh
# (with --after-delivery, so it does not run session-start.sh a second time) for the handler
# install, the version check, the mirror and the update check. session-start.sh itself registers
# the session after it has printed and closed its output. So the output this hook waits for closes
# as soon as the memories are out, and the housekeeping carries on while the conversation starts.
# stdin is passed on explicitly, because a command started with & in a script otherwise reads
# /dev/null, and the SessionStart payload, with the session id, is on stdin.
#
# AND THE WAIT HAS A BUDGET: if the output is not complete within it, this prints a notice instead,
# so the person is told the memories were not loaded rather than told nothing.
#
# THE BUDGET IS BELOW THE LIMIT, NOT AT IT, AND IT IS COUNTED FROM THIS SHELL'S START. The limit runs
# from when Codex starts the hook. On Windows a few seconds of it are spent before this shell exists
# (cmd.exe, finding Git's bash, starting it: 3.3 s measured on the machine above), and under load
# the lines above this one, which source a library and start a few processes, took several seconds
# more. So the wait is what is left of 20 s since this shell started (bash's SECONDS, which bash 3.2
# has too), or, on Windows, since codex-hook.cmd started, whichever is longer ago: the .cmd records
# its %TIME% in MMRY_CODEX_HOOK_STARTED, read here with printf's clock (bash 4.2+, no process
# started). A value that does not read as H:MM:SS, or that is more than two minutes away, is ignored.
# Never less than 1. A test may shorten the 20 with MMRY_CODEX_START_BUDGET (whole seconds, 1 to 25);
# anything else means 20.
#
# THE HANDLER'S STDERR GOES TO A FILE, NOT TO CODEX. Its housekeeping runs on after this hook exits,
# and a process still holding the hook's stderr would keep Codex waiting for it exactly as one
# holding stdout would. The file is the previous start's diagnostics, overwritten each start.
#
# WHAT IS READ IS PASSED ON BYTE FOR BYTE. The read stops at end of input or at the budget; with
# IFS empty, -r, and a NUL delimiter the handler never writes, nothing is trimmed or unescaped.
#
# AND A START THAT RUNS OUT OF TIME STILL GETS ITS MEMORIES, WITH THE FIRST PROMPT (#33062 fix round 1).
# Under heavy load (76 to 88 bash processes on the machine above) the start took 23 to 32 s, so the
# notice came instead of the memories in 4 live runs of 5. The memories were not lost: the work goes
# on after this hook returns. So when the reader below gives up, it hands what is still coming to the
# conversation's first prompt, which Codex runs before the model answers it (codex-first-prompt.sh,
# registered as a UserPromptSubmit hook in hooks/codex-hooks.json).
#
# THE HAND-OFF, AND WHY IT IS EXACTLY ONCE. This hook reads the SessionStart payload itself, with
# builtins, for the session id, and gives session-start.sh the same bytes from a file written with a
# plain redirection. Only when the reader gives the out-of-time notice INSTEAD of the answer does it
# write this hook's pid to .mmry-codex-late.<session>, and start, in the background and holding
# nothing of this hook's, a drain that collects the rest of the answer into
# .mmry-codex-start.<session>.<pid>.out and then writes .ready. The first prompt delivers only when
# that marker exists. So the memories are delivered at the start or with the first prompt, never
# both, and never neither unless they never arrive at all, which the first prompt then says. A start
# that finishes in time starts no process for any of this.
_mmry_codex_start() {
    local start_pid
    if [[ -n "$_mmry_in" ]]; then
        bash "${HANDLER_DIR}/session-start.sh" < "$_mmry_in" &
    else
        bash "${HANDLER_DIR}/session-start.sh" <&0 &
    fi
    start_pid=$!
    exec >/dev/null
    wait "$start_pid" || true
    [[ -n "$_mmry_in" ]] && rm -f "$_mmry_in" 2>/dev/null
    bash "$TARGET" --after-delivery "$@" </dev/null || true
    # Hand-offs and markers no conversation collected (it ended before its first prompt), half a day on.
    find "${TMPDIR:-/tmp}" -maxdepth 1 -type f \( -name '.mmry-codex-start.*' -o -name '.mmry-codex-late.*' \) -mmin +720 -delete 2>/dev/null || true
}

if [[ "$HANDLER_NAME" == "session-init" ]]; then
    _mmry_budget="${MMRY_CODEX_START_BUDGET:-20}"
    if ! [[ "$_mmry_budget" =~ ^[0-9]+$ ]] || (( _mmry_budget < 1 || _mmry_budget > 25 )); then
        _mmry_budget=20
    fi
    _mmry_spent=$SECONDS
    _mmry_t0="${MMRY_CODEX_HOOK_STARTED:-}"
    _mmry_t0="${_mmry_t0// /}"
    _mmry_t0="${_mmry_t0%%[.,]*}"
    _mmry_re_t0='^([0-9]{1,2}):([0-9]{2}):([0-9]{2})$'
    if [[ "$_mmry_t0" =~ $_mmry_re_t0 ]]; then
        _mmry_t0s=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
        _mmry_now=""
        printf -v _mmry_now '%(%H:%M:%S)T' -1 2>/dev/null || _mmry_now=""
        if [[ "$_mmry_now" =~ $_mmry_re_t0 ]]; then
            _mmry_since=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} - _mmry_t0s ))
            (( _mmry_since >= 0 )) || _mmry_since=$(( _mmry_since + 86400 ))
            if (( _mmry_since > _mmry_spent && _mmry_since <= 120 )); then
                _mmry_spent=$_mmry_since
            fi
        fi
    fi
    _mmry_left=$(( _mmry_budget - _mmry_spent ))
    (( _mmry_left >= 1 )) || _mmry_left=1
    _mmry_errlog="${TMPDIR:-/tmp}/mmry-codex-session-start.log"
    # The payload, read here with builtins (Codex writes it and closes stdin), and passed on from a
    # file (a here-string would not parse under dash). If the file cannot be written, session-start.sh
    # reads what is left of stdin, as before. The session id names the hand-off: the same characters
    # the per-prompt hook accepts, and no dot, so an id cannot reach outside the temp directory or name
    # another conversation's file.
    _mmry_payload="" _mmry_in="" _mmry_hand="" _mmry_late_file=""
    if [[ ! -t 0 ]]; then
        IFS= read -r -d '' -t 5 _mmry_payload || true
        _mmry_in="${TMPDIR:-/tmp}/.mmry-codex-start.payload.$$"
        printf '%s' "$_mmry_payload" > "$_mmry_in" 2>/dev/null || _mmry_in=""
        _mmry_re_sid='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
        if [[ "$_mmry_payload" =~ $_mmry_re_sid ]]; then
            _mmry_hand="${TMPDIR:-/tmp}/.mmry-codex-start.${BASH_REMATCH[1]}.$$"
            _mmry_late_file="${TMPDIR:-/tmp}/.mmry-codex-late.${BASH_REMATCH[1]}"
        fi
    fi
    # A PIPELINE WHOSE WRITING SIDE ONLY STARTS THE WORK. `{ ... & }` returns at once, so the pipeline
    # ends when the reading side does: at the end of the output, or at the budget. The work carries on
    # in the background, holding nothing of this hook's but the pipe, which it closes once the memories
    # are out. Not process substitution: on macOS `sh` is bash 3.2 in POSIX mode, which has none, and
    # this file must also parse under dash. stdin goes through fd 3 because a command started with &
    # in a script otherwise reads /dev/null.
    exec 3<&0
    set +e
    { _mmry_codex_start "$@" <&3 3<&- 2>"$_mmry_errlog" & } | {
        _mmry_out=""
        _mmry_read_at=$SECONDS
        IFS= read -r -d '' -t "$_mmry_left" _mmry_out
        _mmry_rc=$?
        # Out of time is status > 128 from bash 4. bash 3.2, the stock macOS bash, returns 1 for a
        # timeout exactly as for the end of the output, so there a read that returned at the budget
        # with an output that is not finished counts as out of time too. Every answer session-start.sh
        # gives is one JSON object, so a finished output ends with "}".
        _mmry_late=0
        if (( _mmry_rc > 128 )); then
            _mmry_late=1
        elif [[ "$_mmry_out" != *"}" ]] && (( SECONDS - _mmry_read_at >= _mmry_left - 1 )); then
            _mmry_late=1
        fi
        if (( _mmry_late == 1 )); then
            # Out of time. Fixed text, and NO PROCESS STARTED to build it: this runs after the
            # budget, when every second is the margin left before Codex's limit, and on a loaded
            # Windows machine each process cost 1 to 2 s. The reference is the one
            # mmry_host_command_ref load-memories gives on Codex, which is all this file serves:
            # mmry_host_tool_ref memory_load, "the mmry_plugin memory_load tool".
            # With a session id, the marker that sends the memories on with the first prompt, and the
            # notice that says so. Without one there is nothing to send them on by: the old notice.
            # The pid ends with a newline, so every bash reads it back as a whole line.
            if [[ -n "$_mmry_late_file" ]] && printf '%s\n' "$$" > "$_mmry_late_file" 2>/dev/null; then
                # The drain: what was read so far, then the rest of the answer as it arrives. Its
                # output goes to the hand-off and /dev/null, never to this hook's, so Codex is not
                # kept waiting for it; it ends when session-start.sh closes its output.
                ( { printf '%s' "$_mmry_out"; cat; } > "${_mmry_hand}.out" 2>/dev/null                     && : > "${_mmry_hand}.ready" ) >/dev/null 2>&1 &
                printf '%s' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI could not load your memories in time for the start of this conversation. They are still loading and will be delivered with the user'"'"'s first message. If they have not arrived when you answer it, load them with the mmry_plugin memory_load tool before you answer, and tell the user that their MMRY memories were late to load this time."}}'
            else
                printf '%s' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI could not load your memories in time for the start of this conversation, so this conversation started without them. Tell the user, before anything else, that their MMRY memories were not loaded this time because loading them took too long, and offer to load them now with the mmry_plugin memory_load tool."}}'
            fi
        else
            printf '%s' "$_mmry_out"
        fi
    }
    set -e
    exit 0
fi

# FAIL OPEN, FOR REAL THIS TIME (#31245, 2026-09-20).
#
# This file's header has always promised that a hook which cannot run must not break the
# customer's session. It did not keep that promise: `exec` handed the handler's exit code straight
# to Codex, and Codex renders ANY non-zero as "hook exited with code 1" to the customer, on every
# turn, with no way to dismiss it. A single unset HOME was enough to produce that on a real
# machine, silently, before any of our code ran.
#
# AND EXIT 2 IS NOT A CHANNEL HERE, WHICH IS WHY IT IS NO LONGER PASSED THROUGH. The header used
# to argue that exit 2 had to reach Codex because it is how Stop and PostToolUse deliver text to
# the model. That was read from the platform's source and never run. Measured: an emitter exiting
# 2 is reported Failed on EVERY event, including SessionStart and Stop, and delivers nothing at
# all; the same emitter exiting 0 is reported Completed. So passing 2 through buys a visible
# failure and no delivery. Codex handlers deliver with additionalContext on stdout and exit 0,
# which formation-check.sh already does.
#
# The handler's own exit code is therefore deliberately discarded. If a handler needs to tell the
# model something, it prints it; there is no other channel, and pretending otherwise is what put
# "Hook failed" in front of a customer every turn.
set +e
bash "$TARGET" "$@"
set -e
exit 0
