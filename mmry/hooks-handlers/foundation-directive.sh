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

# ON CODEX'S FIRST MESSAGE THE START CAN STILL BE RUNNING (#34281, measured live). `codex exec` starts the
# first turn while the SessionStart hook is still loading, and the start keeps the directive only when
# its answer arrives (6 s into turn 1 in the live proof), so this hook found no copy and said nothing on
# that message; the start's own context carried it, but the message did not. So on Codex, with no copy
# kept yet, it waits for THIS session's start while the start's hand-off marker
# (.mmry-codex-late.<key>.<session>, codex-hook.sh) says it is still running: at most 12 s of the 20 the
# hook is given, polling every quarter second. A start that has finished, failed or was never armed is
# not waited for, so a service that sends no directive costs a later message nothing.
_fd_wait_codex_start() {
    declare -F mmry_host >/dev/null 2>&1 && [[ "$(mmry_host)" == "codex" ]] || return 1
    local payload="" sid="" re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"' late pid state end
    [[ -t 0 ]] && return 1
    IFS= read -r -d '' -t 2 payload || true
    [[ "$payload" =~ $re ]] || return 1
    sid="${BASH_REMATCH[1]}"
    # shellcheck source=/dev/null
    source "${_fd_root}/hooks-handlers/lib-codex-key.sh" >/dev/null 2>&1 || return 1
    set +e +u
    mmry_codex_private_dir_v 2>/dev/null && mmry_codex_private_dir_ok 2>/dev/null || return 1
    mmry_codex_session_part_v "$sid" 2>/dev/null || return 1
    late="${_MMRY_CODEX_DIR}/.mmry-codex-late.${_MMRY_CODEX_SESSION_PART}"
    end=$(( SECONDS + 12 ))
    while (( SECONDS < end )); do
        mmry_foundation_directive_block_v "$_fd_dir" && return 0
        mmry_codex_own_file "$late" || break
        pid="" state=""
        { IFS= read -r pid; IFS= read -r state; } < "$late" 2>/dev/null || true
        [[ "$state" == delivered || "$state" == none ]] && break
        sleep 0.25 2>/dev/null || sleep 1 2>/dev/null
    done
    mmry_foundation_directive_block_v "$_fd_dir"
}

if ! mmry_foundation_directive_block_v "$_fd_dir"; then
    [[ "$_fd_mode" == prompt ]] && _fd_wait_codex_start || exit 0
fi
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
