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

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
PLUGIN_ROOT="$(cd "${HANDLER_DIR}/.." && pwd)" || exit 0

# ---- Declare the host, before anything reads a path. ----
export MMRY_HOST="codex"

# shellcheck source=/dev/null
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
