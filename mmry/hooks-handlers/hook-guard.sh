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
_mmry_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if source "${_mmry_guard_dir}/lib-host.sh" 2>/dev/null; then
    TARGET="$(mmry_host_state_dir)/hooks-handlers/${SCRIPT_NAME}.sh"
else
    TARGET="${HOME}/.claude/mmry/hooks-handlers/${SCRIPT_NAME}.sh"
fi

if [[ -f "$TARGET" ]]; then
    exec bash "$TARGET"
fi

exit 0
