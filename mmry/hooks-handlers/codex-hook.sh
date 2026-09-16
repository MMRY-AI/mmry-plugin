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

set -uo pipefail

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

# The credential. mmry-client.sh's discovery order is ${MMRY_CONFIG_FILE}, then the plugin root,
# then ${HOME}/.claude/mmry-config.json. Setting the first means the client reads the Codex
# credential without the client having to know Codex exists - which is why mmry-client.sh is
# untouched by this task.
#
# An already-set MMRY_CONFIG_FILE is left alone: it is the documented override and a customer or a
# test that set it deliberately outranks this default.
export MMRY_CONFIG_FILE="${MMRY_CONFIG_FILE:-$(mmry_host_config_file)}"

TARGET="${HANDLER_DIR}/${HANDLER_NAME}.sh"
[[ -f "$TARGET" ]] || exit 0

exec bash "$TARGET" "$@"
