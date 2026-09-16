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

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-host.sh"

TARGET="$(mmry_host_state_dir)/hooks-handlers/${SCRIPT_NAME}.sh"

if [[ -f "$TARGET" ]]; then
    exec bash "$TARGET"
fi

exit 0
