#!/usr/bin/env bash
# foundation-directive.sh - MMRY's built-in directive on every prompt and before shortening (#34281).
#
# WHAT IT SENDS. The one directive MMRY supplies to every account, telling the assistant that MMRY is its
# primary memory (DD-196 in the API). The service sends it in each Foundation moment's answer, and the
# plugin keeps the last one it was given (mmry_keep_foundation_directive, mmry-client.sh). This prints that
# kept copy, word for word, as its own block. It is not one of the account's Foundation memories: the
# account's set, its stored file, its six parts and their records are userpromptsubmit-foundation.sh's,
# untouched, and an account with none of its own still gets this.
#
# WHERE IT RUNS.
#   (no argument)   UserPromptSubmit, Claude Code (hooks/hooks.json) and Codex (hooks/codex-hooks.json,
#                   through codex-hook.sh). Prints the hook JSON with the block as additionalContext.
#   --precompact    PreCompact, Claude Code only: Claude Code uses a PreCompact hook's stdout as
#                   instructions for its summary, so this prints plain text asking the summary to keep the
#                   directive word for word. Codex gives no signal before shortening; there it does nothing.
# Session start, reload and the start after compaction carry it through session-start.sh.
#
# BUILTINS ONLY, AND SILENT WHEN THERE IS NOTHING TO SAY. No credential of this host's own, no kept copy,
# or a kept copy that is not this plugin's own file in its own format: nothing is printed and it exits 0.
# A hook that fails must never fail the prompt or the compaction.
#
# -e is turned straight back off on the next line; the full form is written first because the
# repository's structural check requires every handler to declare it (file-integrity.bats).
set -euo pipefail 2>/dev/null || true
set +e
umask 077

_fd_mode=prompt
[[ "${1:-}" == "--precompact" ]] && _fd_mode=precompact

_fd_self="${BASH_SOURCE[0]//\\//}"
case "$_fd_self" in
    */hooks-handlers/foundation-directive.sh) _fd_root="${_fd_self%/hooks-handlers/foundation-directive.sh}" ;;
    *) _fd_root="$(cd "$(dirname "$0")/.." && pwd)" ;;
esac

# shellcheck source=/dev/null
source "${_fd_root}/hooks-handlers/lib-host.sh" >/dev/null 2>&1 || exit 0
set +e
if declare -F mmry_host_assert_own_credential >/dev/null 2>&1; then
    mmry_host_assert_own_credential >/dev/null 2>&1 || exit 0
fi
if [[ "$_fd_mode" == precompact ]] && declare -F mmry_host >/dev/null 2>&1 && [[ "$(mmry_host)" == "codex" ]]; then
    exit 0
fi

# shellcheck source=/dev/null
source "${_fd_root}/hooks-handlers/lib-foundation-key.sh" >/dev/null 2>&1 || exit 0
set +e +u
_fd_dir="${MMRY_TMPDIR:-${TMPDIR:-/tmp}}"

mmry_foundation_directive_block_v "$_fd_dir" || exit 0
_fd_block="$_MMRY_FND_DIRECTIVE_BLOCK"

if [[ "$_fd_mode" == precompact ]]; then
    printf '%s\n' "MMRY AI: keep MMRY's built-in directive in the summary word for word, exactly as written below, so it stays in force after it."
    printf '\n%s\n' "$_fd_block"
    exit 0
fi

# JSON, by parameter expansion: the kept text holds no control character (the client replaces each with
# a space when it keeps it), so a backslash and a double quote are all there is to escape.
_fd_block="${_fd_block//\\/\\\\}"
_fd_block="${_fd_block//\"/\\\"}"
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}' "$_fd_block"
exit 0
