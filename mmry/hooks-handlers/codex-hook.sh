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

exec bash "$TARGET" "$@"
