#!/usr/bin/env bash
# hook-guard.sh — Guard wrapper for Stop/PreCompact/PostToolUse hooks.
# Checks if the named handler script exists in the host's installed-handler directory
# (~/.claude/mmry/hooks-handlers/ on Claude Code) and runs it if found, otherwise exits 0 silently.
#
# Usage: bash hook-guard.sh <script-name>
#   e.g. bash hook-guard.sh stop-check
#        bash hook-guard.sh precompact-check
#        bash hook-guard.sh plan-accepted-check
#
# #31245: the target directory is resolved through lib-host.sh rather than spelled here, so one
# guard serves a second host. With MMRY_HOST unset - which is every existing Claude Code install -
# mmry_host_state_dir returns "${HOME}/.claude/mmry", the exact string this line used to contain.

set -euo pipefail

SCRIPT_NAME="${1:-}"

if [[ -z "$SCRIPT_NAME" ]]; then
    exit 0
fi

# THE RESOLVER IS OPTIONAL HERE, AND THE FALLBACK IS THE OLD LITERAL.
#
# This script runs from the COPIED handler directory, not from the plugin root, and that directory
# is assembled by whoever did the copying. session-init.sh copies hooks-handlers/*.sh so a real
# install always has lib-host.sh - but a curated copy may not, and one such copy exists in the test
# suite today. An unguarded source there kills the hook with "No such file or directory" on a line
# number, which is a sentence about nothing.
#
# So a missing resolver falls back to exactly the path this file carried before #31245. That is
# strictly no worse than the previous behaviour, which is the right bar for a guard whose whole job
# is to never break a session.
# DERIVED WITHOUT A PROCESS (#31245 QA round 4). This was
# `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` - two nested command substitutions, and a fork
# measured ~300 ms on Windows Git Bash, on a guard that fires after every tool call. The path only
# has to be good enough to source a sibling file. lib-host.sh resolves its OWN absolute location
# for the detection it does, so nothing downstream depends on this one being absolute.
_mmry_guard_dir="${BASH_SOURCE[0]%/*}"
[[ "$_mmry_guard_dir" == "${BASH_SOURCE[0]}" ]] && _mmry_guard_dir="."
# shellcheck source=/dev/null
if source "${_mmry_guard_dir}/lib-host.sh" 2>/dev/null; then
    # The resolved value is read from the variable rather than through $(mmry_host_state_dir),
    # because command substitution is a fork and this is the hottest path the plugin has
    # (#31245 QA round 4). _mmry_host_resolve is idempotent and costs no process; the accessor
    # function remains the public interface for everyone who is not on a per-tool-call path.
    _mmry_host_resolve
    TARGET="${_MMRY_HOST_DIR_V}/mmry/hooks-handlers/${SCRIPT_NAME}.sh"
else
    TARGET="${HOME}/.claude/mmry/hooks-handlers/${SCRIPT_NAME}.sh"
fi

if [[ -f "$TARGET" ]]; then
    exec bash "$TARGET"
fi

exit 0
