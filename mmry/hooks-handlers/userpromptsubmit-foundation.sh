#!/usr/bin/env bash
# userpromptsubmit-foundation.sh — UserPromptSubmit hook (#30579, #31434).
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
#   - No network call on the critical path. Reads only the local cache.
#   - Bounded cost. A configurable token cap (default 1500) truncates oversized sets.
#   - Opt-out. foundationReinject=false (config or env) makes this a no-op.
#   - BOUNDED WALL CLOCK, and it says so when it fails (#31434). See below.
#
# #31434 — why this file is split into a supervisor and a worker.
#
# When a hook exceeds its hooks.json timeout, Claude Code kills it and DISCARDS its
# output. For this hook that means the turn silently runs with none of the account's
# standing directives, and all the customer sees is a generic harness warning that reads
# like noise. Three customer reports (feedback 21, 22, 27) across plugin 2.4.0, 2.6.0 and
# 2.9.0 are all this.
#
# Raising the budget alone would only move the cliff. So:
#   1. The real cost was removed - see the mmry_load_config change in mmry-client.sh.
#   2. The hook budget went 5s -> 20s, in line with the other hooks this plugin registers
#      (8, 10, 10, 10, 10, 15, 30, 300) and still under Claude Code's own 30s default for
#      UserPromptSubmit.
#   3. This file now enforces its OWN deadline, below the hook budget, so the plugin - not
#      the harness - decides what happens on a slow turn. The supervisor runs the real work
#      as a background worker and kills it at the deadline, which is what makes the failure
#      REPORTABLE instead of silent. A trap cannot do this: bash does not run a trap while
#      a foreground external command (jq, cat) is still running.
#   4. If the harness kills the supervisor too, an in-flight marker left on disk is noticed
#      on the NEXT firing and reported then. Belt and braces, because a silent loss is the
#      whole defect.

# NOTE: deliberately NOT `set -e` — a failure here must never fail the user's prompt.
set -uo pipefail 2>/dev/null || true

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Resolved without sourcing the client, so the supervisor stays cheap. Must match
# MMRY_TMPDIR in mmry-client.sh.
_FOUND_TMPDIR="${MMRY_TMPDIR:-${TMPDIR:-/tmp}}"
# KNOWN LIMITATION, stated rather than hidden: this marker is per-TMPDIR, not per-session,
# exactly like the mmry-foundation.md cache it guards. Two Claude Code sessions sharing a
# TMPDIR can therefore have one session report the other's cut-short turn. The report is
# still true - directives were lost on some turn - but it may name the wrong one. Fixing it
# properly means session-scoping the whole Foundation cache, which is a bigger change than
# this ticket and would be smuggled in here.
_INFLIGHT="${_FOUND_TMPDIR}/.mmry-foundation-inflight"

# Emit one JSON object. $1 = additionalContext text (may be empty), $2 = systemMessage
# text (may be empty). additionalContext must be nested under hookSpecificOutput or
# Claude Code silently ignores it; systemMessage is the user-facing channel.
# JSON-escape a string using nothing but parameter expansion.
#
# This replaces `sed ':a;N;$!ba;s/\n/\\n/g'` (#31434). That label-and-branch form is a GNU
# extension; the BSD sed macOS ships rejects it, the error text landed in the handler's
# output, and the emitted "JSON" was not JSON at all on every Mac. The macOS CI leg has been
# failing "userpromptsubmit-foundation: emits valid JSON" on that since before this ticket.
#
# Pure expansion is also faster than two sed processes, which is the point of the ticket, and
# it now escapes tab and CR as well - previously those went into the string raw, which is
# invalid JSON. Other control characters below 0x20 are still passed through unescaped; that
# is unchanged behaviour and Foundation memories are prose, not binary.
_mmry_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"       # backslash FIRST or it re-escapes the escapes below
    s="${s//\"/\\\"}"
    s="${s//$'\015'/\\r}"
    s="${s//$'\011'/\\t}"
    s="${s//$'\012'/\\n}"
    printf '%s' "$s"
}

_mmry_emit() {
    local ctx="$1" msg="$2"
    [[ -z "$ctx" && -z "$msg" ]] && return 0
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}' \
        "$(_mmry_json_escape "$ctx")"
    # Omit systemMessage entirely when there is nothing to say, rather than emitting an
    # empty string that a client could render as a blank notice.
    if [[ -n "$msg" ]]; then
        printf ',"systemMessage":"%s"' "$(_mmry_json_escape "$msg")"
    fi
    printf '}'
}

# ============================================================================
# SUPERVISOR — bounds the wall clock and owns everything the customer sees.
# ============================================================================
if [[ "${MMRY_FOUNDATION_WORKER:-}" != "1" ]]; then
    # This handler's contract is "one JSON object on stdout, or nothing at all". It has no
    # business writing to stderr either, and it must not, because the supervisor deliberately
    # kills a background job: the shell announces that ("Terminated") on ITS stderr, at a
    # moment we do not control, and anything a hook prints is noise the customer has to
    # interpret. Silenced for the whole supervisor. Nothing here reports errors by printing;
    # every path exits 0 and says what it has to say inside the JSON.
    exec 2>/dev/null

    DEADLINE="${MMRY_FOUNDATION_DEADLINE_SECS:-15}"
    [[ "$DEADLINE" =~ ^[0-9]+$ ]] && (( DEADLINE > 0 )) || DEADLINE=15

    # A marker left behind by a previous firing means that firing never reached its own
    # exit — the harness killed the whole handler — so that turn ran without directives
    # and nobody was told. Report it now.
    MISSED_PREVIOUS=0
    [[ -f "$_INFLIGHT" ]] && MISSED_PREVIOUS=1

    # Sweep out-files whose supervisor no longer exists. When the harness SIGKILLs us the
    # worker survives briefly and keeps writing, so its out-file is orphaned. `kill -0` is a
    # bash builtin, so this costs no process spawn.
    for _stale in "${_FOUND_TMPDIR}"/.mmry-foundation-out.*; do
        [[ -e "$_stale" ]] || continue
        _stale_pid="${_stale##*.}"
        [[ "$_stale_pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$_stale_pid" 2>/dev/null || rm -f "$_stale" 2>/dev/null || true
    done

    OUTFILE="${_FOUND_TMPDIR}/.mmry-foundation-out.$$"
    : > "$OUTFILE" 2>/dev/null || true
    : > "$_INFLIGHT" 2>/dev/null || true

    MMRY_FOUNDATION_WORKER=1 bash "${PLUGIN_ROOT}/hooks-handlers/userpromptsubmit-foundation.sh" \
        > "$OUTFILE" 2>/dev/null &
    WORKER_PID=$!

    # The watchdog POLLS instead of sleeping out the whole deadline in one go, and it closes
    # every descriptor it could have inherited.
    #
    # This is not tidiness. The first cut was `( sleep "$DEADLINE"; kill ... ) &` killed after
    # the wait. Killing the subshell ORPHANS its sleep, and the orphan keeps every descriptor
    # it inherited. A reader waits for the LAST WRITER to close, not for the handler to exit,
    # so it sat there for the whole deadline after the answer had already been produced.
    #
    # Measured, same fixture, only the watchdog differing, with one extra descriptor attached
    # to the pipe being read: 15155/15170/15155 ms (n=3, 15 s deadline) against 494/515/604/
    # 567/572 ms (n=5). Plain stdout showed NOTHING - the old watchdog redirected its own
    # stdout to /dev/null, so `bash handler | cat` finished in about 500 ms either way, which
    # is how this survived both a hand measurement and a green fourteen-test suite.
    #
    # What a real Claude Code hook invocation inherits beyond stdout is not something I could
    # verify, so the size of the production impact is unknown. The defect is not.
    #
    # Polling also means the watchdog is GONE about a second after the worker finishes, so
    # nothing has to kill it and there is nothing left to orphan.
    (
        _waited=0
        while (( _waited < DEADLINE )); do
            kill -0 "$WORKER_PID" 2>/dev/null || exit 0
            sleep 1
            _waited=$(( _waited + 1 ))
        done
        kill -TERM "$WORKER_PID" 2>/dev/null
    ) >/dev/null 2>&1 <&- 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
    WATCHDOG_PID=$!

    wait "$WORKER_PID" 2>/dev/null
    WORKER_RC=$?
    kill "$WATCHDOG_PID" >/dev/null 2>&1 || true

    BODY=""
    [[ -s "$OUTFILE" ]] && BODY="$(cat "$OUTFILE" 2>/dev/null)"
    rm -f "$OUTFILE" 2>/dev/null || true
    rm -f "$_INFLIGHT" 2>/dev/null || true

    if (( WORKER_RC != 0 )); then
        # We stopped ourselves at the deadline. The turn proceeds either way; what matters
        # is that the customer is told, in terms they can act on, that this turn is running
        # WITHOUT their standing directives.
        NOTICE="MMRY AI could not load this account's FOUNDATION directives for this turn: loading exceeded ${DEADLINE}s and was stopped so the prompt would not stall. This turn is running WITHOUT the account's standing directives. Do not claim to be following them. Tell the user plainly that Foundation directives were not applied to this turn."
        USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn (loading took over ${DEADLINE}s). Re-send the prompt to try again. If it keeps happening, run /mmry:reload-memories to rebuild the local cache, or set foundationReinject to false in ~/.claude/mmry-config.json to turn re-injection off."
        _mmry_emit "$NOTICE" "$USERMSG"
        exit 0
    fi

    # Worker finished inside the deadline with nothing to inject (toggle off, no cache,
    # empty cache). Nothing was lost, so say nothing — including about a previous miss,
    # which would be a false alarm when there are no directives to apply.
    [[ -n "${BODY//[[:space:]]/}" ]] || exit 0

    USERMSG=""
    if (( MISSED_PREVIOUS == 1 )); then
        BODY="NOTE: on the PREVIOUS turn these directives were not applied - loading them was cut short and its output discarded. Treat that turn's response as having been produced without them.

${BODY}"
        USERMSG="MMRY AI: your Foundation directives were not applied to the previous turn (the hook was cut short). They are applied again now."
    fi

    _mmry_emit "$BODY" "$USERMSG"
    exit 0
fi

# ============================================================================
# WORKER — the real work. Writes PLAIN TEXT to stdout; the supervisor does the
# JSON. Anything that goes wrong here means "emit nothing", never "fail".
# ============================================================================

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
printf '%s' "The following are the account's FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive.${truncated_note}

${content}"
exit 0
