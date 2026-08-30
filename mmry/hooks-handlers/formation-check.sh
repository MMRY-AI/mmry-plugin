#!/usr/bin/env bash
# formation-check.sh - PostToolUse hook: surface a formation's new messages mid-session (#31012).
#
# THE GOVERNING RULE: FAIL OPEN AND SILENT. This runs after every tool call in every session, so a
# fault here is a fault in everybody's work. Any error, any missing tool, any unreachable service,
# any malformed response: exit 0 and say nothing. A coordination feature that breaks an ordinary
# session is worse than not having the feature at all.
#
# COST WHEN NOT IN A FORMATION: one file test. The overwhelming majority of sessions are not in a
# formation, and they must not pay a network round trip after every tool call to discover that. The
# state file is checked first and the hook returns immediately when it is absent.
#
# DELIVERY MECHANISM: stderr plus exit 2. On exit 2 Claude Code discards stdout and feeds stderr to
# the model, which is how plan-accepted-check.sh already delivers its directive (#30642). Exit 0
# means "nothing to say" and the session continues untouched.
#
# WHAT IT DOES NOT DO: it never reports an error to the model, and it never says "you are not a
# member". The server returns an empty list rather than a refusal for a non-member so that a caller
# cannot tell an empty formation from one it cannot see; turning that into a message here would leak
# exactly what the server withholds.
# set -e is here to satisfy the repository convention every other handler follows, and it is
# safe only because of the ERR trap below: with -e any unguarded failure would exit
# non-zero, and the trap converts that into the silent exit 0 this hook must always make.
set -euo pipefail

# Absolutely everything below is best-effort. A single unguarded failure would exit non-zero on a
# path Claude Code treats as "blocking", so the trap is the backstop for anything missed.
trap 'exit 0' ERR

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
MMRY_TMPDIR="${TMPDIR:-/tmp}"

# ---- 1. Are we in a formation at all? One file test, then out. ----
state="$(bash "${HANDLER_DIR}/formation-state.sh" get 2>/dev/null || true)"
[[ -n "$state" ]] || exit 0

formation_id="${state%% *}"
last_seen="${state#* }"
[[ "$formation_id" =~ ^[0-9]+$ ]] || exit 0

session_id="${CLAUDE_SESSION_ID:-}"
[[ -n "$session_id" ]] || exit 0

# ---- 2. Load the client. If it is not there, this feature simply does not run. ----
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh" 2>/dev/null || exit 0
command -v curl >/dev/null 2>&1 || exit 0
mmry_load_config 2>/dev/null || exit 0

# ---- 3. Poll. Any failure is silence, not a message. ----
if ! mmry_get_formation_transmissions "$formation_id" "$session_id" "$last_seen" 2>/dev/null; then
    exit 0
fi
[[ "${MMRY_HTTP_CODE:-}" =~ ^2[0-9][0-9]$ ]] || exit 0
[[ -n "${MMRY_RESPONSE:-}" ]] || exit 0

# ---- 4. Parse. Without jq there is no safe way to read this, so do nothing. ----
# Guarding rather than falling back to grep: a half-parsed transmission shown to the model is worse
# than no transmission, and the unguarded-pipeline lesson from #30622 applies here too.
[[ -n "${MMRY_JQ:-}" ]] || exit 0
command -v "$MMRY_JQ" >/dev/null 2>&1 || [[ -x "$MMRY_JQ" ]] || exit 0

count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r 'if type == "array" then length else 0 end' 2>/dev/null || printf '0')"
[[ "$count" =~ ^[0-9]+$ ]] || exit 0
[[ "$count" -gt 0 ]] || exit 0

lines="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
    if type == "array" then
        .[] | "  [" + ((.senderRole // "member")) + " " + ((.senderSessionID // "?") | tostring) + "] " + ((.content // .topic // "") | tostring)
    else empty end' 2>/dev/null || true)"
[[ -n "$lines" ]] || exit 0

newest="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
    if type == "array" then ([.[].sentDate // empty] | max // empty) else empty end' 2>/dev/null || true)"

# ---- 5. Record what was surfaced BEFORE surfacing it. ----
# If this ran afterwards and the hook were interrupted, the same messages would be delivered again
# on the next tool call, and a repeating transmission is worse than a late one.
if [[ -n "$newest" ]]; then
    bash "${HANDLER_DIR}/formation-state.sh" seen "$newest" 2>/dev/null || true
fi

# ---- 6. Surface. ----
{
    printf 'FORMATION TRANSMISSION (%s new, formation %s)\n\n' "$count" "$formation_id"
    printf '%s\n' "$lines"
    printf '\nThese are other assistants working the same job right now. Act on anything that\n'
    printf 'affects what you are doing, especially a Blocked or a Heads up naming something you\n'
    printf 'are about to touch. Do not reply to the formation unless you have something worth\n'
    printf 'transmitting.\n'
} >&2

exit 2
