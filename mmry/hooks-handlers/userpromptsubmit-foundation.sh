#!/usr/bin/env bash
# userpromptsubmit-foundation.sh — UserPromptSubmit hook (#30579).
#
# Re-injects the account's Foundation-tier memories inline on EVERY prompt, framed as
# authoritative directives, from a session-local cache written at SessionStart
# (mmry-foundation.md). This is what turns Foundation memories from "loaded once" into
# a continuous guiding light: they are restated right before the model composes each
# response, and they survive context compaction because the next prompt re-adds them.
#
# Design guarantees:
#   - NEVER blocks a prompt. Any problem (no cache, toggle off, parse error) -> emit
#     nothing and exit 0.
#   - No network call. Reads only the local cache, so it adds no per-prompt latency and
#     cannot be rate-limited.
#   - Bounded cost. A configurable token cap (default 1500) truncates oversized sets and
#     logs the drop rather than silently ballooning every turn's context.
#   - Opt-out. foundationReinject=false (config or env) makes this a no-op.

# NOTE: deliberately NOT `set -e` — a failure here must never fail the user's prompt.
set -uo pipefail 2>/dev/null || true

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Source the client for MMRY_TMPDIR + config parsing. It runs `set -euo pipefail` at the
# top, so relax those options again immediately after — we must not fail the prompt.
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh" 2>/dev/null || exit 0
set +e +u

mmry_load_config 2>/dev/null || true

REINJECT="${MMRY_FOUNDATION_REINJECT:-true}"
CAP_TOKENS="${MMRY_FOUNDATION_TOKEN_CAP:-1500}"
REFRESH_SECS="${MMRY_FOUNDATION_REFRESH_SECONDS:-86400}"
CACHE="${MMRY_TMPDIR}/mmry-foundation.md"
LOG="${MMRY_TMPDIR}/mmry-foundation.log"

# Toggle off -> no-op.
case "$(printf '%s' "$REINJECT" | tr '[:upper:]' '[:lower:]')" in
    false|off|0|no|disabled) exit 0 ;;
esac

# TTL-gated BACKGROUND refresh (#30579): if the cache is older than the refresh window,
# re-fetch Foundation memories in the background so an admin-added memory propagates without
# a Claude restart. This is non-blocking - the CURRENT prompt still uses the existing cache;
# the refreshed cache is picked up on the next prompt. A lock file (touched on each attempt)
# bounds this to one refresh per window per session even when a fetch fails. Default daily;
# users can force an immediate refresh with /mmry:reload-memories or by restarting.
if [[ "$REFRESH_SECS" =~ ^[0-9]+$ ]] && (( REFRESH_SECS > 0 )) && [[ -n "${MMRY_API_KEY:-}" ]]; then
    _now="$(date +%s 2>/dev/null || echo 0)"
    _lock="${MMRY_TMPDIR}/.mmry-foundation-refresh"
    _cache_age=$(( _now - $(_mmry_mtime "$CACHE") ))
    _lock_age=$(( _now - $(_mmry_mtime "$_lock") ))
    if (( _cache_age >= REFRESH_SECS )) && (( _lock_age >= REFRESH_SECS )); then
        touch "$_lock" 2>/dev/null || true
        ( mmry_refresh_foundation_cache "$PWD" "$CACHE" >/dev/null 2>&1 & ) 2>/dev/null || true
    fi
fi

# No cache, or cache is empty/whitespace -> no-op.
[[ -s "$CACHE" ]] || exit 0
content="$(cat "$CACHE" 2>/dev/null)"
[[ -n "${content//[[:space:]]/}" ]] || exit 0

# Guard against a non-numeric cap.
[[ "$CAP_TOKENS" =~ ^[0-9]+$ ]] || CAP_TOKENS=1500

# Token cap (~4 chars/token). Truncate + log if over — never silently balloon context.
cap_chars=$(( CAP_TOKENS * 4 ))
truncated_note=""
if (( ${#content} > cap_chars )); then
    content="${content:0:cap_chars}"
    truncated_note=" (Foundation set truncated to the ${CAP_TOKENS}-token cap - trim Foundation memories in the portal to restore the full set.)"
    printf '%s truncated Foundation reinjection to %s tokens (had %s chars)\n' \
        "$(date +%FT%T 2>/dev/null || echo now)" "$CAP_TOKENS" "${#content}" >> "$LOG" 2>/dev/null || true
fi

# Authoritative framing. These lead every turn, so they are stated as directives that
# take precedence, distinct from transient memories.
framed="The following are the account's FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive.${truncated_note}

${content}"

# JSON-escape (backslash, quote, then newlines) and emit as additionalContext.
escaped="$(printf '%s' "$framed" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}' "$escaped"
exit 0
