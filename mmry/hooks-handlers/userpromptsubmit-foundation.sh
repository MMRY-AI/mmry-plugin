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
#   - COMPLETE. The set is delivered in full, every time. There is no size at which this
#     withholds part of what the customer wrote (#31411).
#   - VERIFIED. The cache is checked against a manifest the writer recorded, so a damaged
#     or substituted file is refused and reported rather than passed off as the
#     account's guidance (#31583).
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
#      (8, 10, 10, 10, 10, 15, 30, 300) and still under the default Claude Code would apply
#      if we declared no timeout at all. That default was an unverified assertion when first
#      written here; it is now checked against the hooks reference, which states that Claude
#      Code lowers the `command`, `http` and `mcp_tool` default to 30 seconds specifically on
#      UserPromptSubmit (the general default for those types is 600). The 30 does NOT apply to
#      `prompt` or `agent` hooks, which this plugin does not register.
#      https://code.claude.com/docs/en/hooks.md
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

# Lowercase an ASCII string using nothing but parameter expansion (#31434 QA).
#
# This replaces `printf '%s' "$x" | tr '[:upper:]' '[:lower:]'`, which cost a subshell AND a
# `tr` process on EVERY firing of a hook that runs on every prompt. On Windows Git Bash a
# process spawn measured ~300 ms, so that one idiom was ~10% of the handler's whole cost.
# bash 3.2 (what macOS ships) has no `${x,,}`, so this does the mapping by hand: the index of
# the character within the uppercase alphabet is the length of the prefix before it, and a
# character that is absent leaves the alphabet unchanged at length 26.
_mmry_tolower() {
    local s="$1" out="" c pre
    local up="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lo="abcdefghijklmnopqrstuvwxyz"
    local i=0
    while (( i < ${#s} )); do
        c="${s:i:1}"
        pre="${up%%"$c"*}"
        if (( ${#pre} < 26 )); then
            out="${out}${lo:${#pre}:1}"
        else
            out="${out}${c}"
        fi
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

# Is Foundation re-injection switched OFF by this value? Same vocabulary the worker has always
# honoured, now in one place because the SUPERVISOR has to answer the question too (#31434 QA).
_mmry_reinject_off() {
    case "$(_mmry_tolower "$1")" in
        false|off|0|no|disabled) return 0 ;;
    esac
    return 1
}

# Is Foundation re-injection switched off, answered WITHOUT spawning a single process?
# Environment override first, then the config file the client would have used (#31434 QA).
#
# Discovery order is kept identical to mmry_load_config in mmry-client.sh. If the two ever
# disagree, the customer's setting is honoured on one path and ignored on the other, which
# is the whole bug this closes.
#
# HOW THE CONFIG IS READ, and what that is and is not worth. This is a TEXT SCAN, not a JSON
# parse: `$(<file)` costs a subshell and no exec, where jq would cost a process on every
# prompt and would fail in exactly the circumstances this check matters most. The scan is
# therefore deliberately CONSERVATIVE - it acts only on a confident match of the key in key
# position followed by a bare or quoted scalar, and anything it cannot read that way is
# treated as "not switched off".
#
# That asymmetry is the safe one in both directions. A false "off" would silently disable a
# feature the customer wants, so the scan refuses to guess; a false "on" costs at worst a
# notice the customer did not want, and the WORKER still holds the authoritative jq-parsed
# answer, so a healthy firing that this scan could not read is decided correctly downstream.
# The only thing that changes here is whether the SUPERVISOR can answer when the worker cannot.
_mmry_reinject_is_off_here() {
    local v="" cfg="" txt=""

    # 1. Environment override. Free, and it wins, matching mmry-client.sh precedence.
    if [[ -n "${MMRY_FOUNDATION_REINJECT:-}" ]]; then
        _mmry_reinject_off "${MMRY_FOUNDATION_REINJECT}"
        return $?
    fi

    # 2. The config file, same discovery order as mmry_load_config.
    if [[ -n "${MMRY_CONFIG_FILE:-}" && -f "${MMRY_CONFIG_FILE}" ]]; then
        cfg="$MMRY_CONFIG_FILE"
    elif [[ -n "${PLUGIN_ROOT:-}" && -f "${PLUGIN_ROOT}/mmry-config.json" ]]; then
        cfg="${PLUGIN_ROOT}/mmry-config.json"
    elif [[ -f "${HOME:-}/.claude/mmry-config.json" ]]; then
        cfg="${HOME}/.claude/mmry-config.json"
    fi
    [[ -n "$cfg" && -r "$cfg" ]] || return 1

    txt="$(<"$cfg")" 2>/dev/null || return 1
    [[ -n "$txt" ]] || return 1

    # Key in key position, then a JSON scalar: `false`, `"false"`, `0`, `"off"`. A value that
    # is not a bare word (an object, an array, a spaced-out string) simply does not match, and
    # an unmatched scan returns "not off".
    [[ "$txt" =~ \"foundationReinject\"[[:space:]]*:[[:space:]]*\"?([A-Za-z0-9]+)\"? ]] || return 1
    v="${BASH_REMATCH[1]}"
    _mmry_reinject_off "$v"
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
    #
    # But this feature exists because of three customer reports nobody could reproduce, and
    # shipping it with stderr hard-wired to /dev/null would guarantee the next one is just as
    # unreproducible. MMRY_DEBUG=1 REDIRECTS that stderr to a file instead of discarding it.
    # The customer-facing contract is identical either way: stderr never reaches the terminal,
    # so a debug session cannot turn the handler into a source of noise.
    _FOUND_ERR=/dev/null
    [[ -n "${MMRY_DEBUG:-}" ]] && _FOUND_ERR="${_FOUND_TMPDIR}/mmry-foundation-debug.log"
    exec 2>>"$_FOUND_ERR"

    # Every abnormal exit below appends here regardless of MMRY_DEBUG. A failure that tells the
    # customer their directives were dropped and leaves no trace of WHY is the reason this
    # ticket needed three reports before anyone could act on it.
    _FOUND_LOG="${_FOUND_TMPDIR}/mmry-foundation.log"

    # THE OFF SWITCH, honoured HERE and not only in the worker (#31434 QA).
    #
    # The crash notice below tells the customer to set foundationReinject false. That advice
    # was inert on the very path that gave it: the toggle was read only by the worker, by way
    # of mmry_load_config, and the crash branch runs precisely when the worker could not run.
    # A customer who followed the instruction - in the config, in the environment, or both -
    # saw the same banner on every prompt with no way to stop it. A remedy printed in a
    # customer-facing string has to work.
    #
    # Checked UP FRONT, so the opt-out also skips the worker and the watchdog entirely: an
    # opted-out customer pays one subshell instead of the ~3 s of process spawns a firing
    # costs on Windows Git Bash.
    #
    # NOT by way of jq, deliberately. jq is a process, and this runs on every prompt; worse,
    # the most likely reason the worker failed is a jq that is slow or broken, so deciding
    # whether to REPORT a jq failure by invoking jq is how the check inherits the fault it is
    # reporting on. An earlier cut of this fix did exactly that and measured 33 s against a
    # 20 s budget with a 20 s-slow jq - it reintroduced the ticket's own defect inside the
    # remedy for it. This reads the file with no process at all.
    if _mmry_reinject_is_off_here; then
        exit 0
    fi

    # 10, not the 15 this shipped to QA with (#31434 QA). The deadline is not the whole
    # story: the supervisor still has to start, reap the worker, decide WHY it failed and
    # write the JSON afterwards, and on Windows Git Bash every one of those steps is a
    # ~300 ms process spawn. Measured enforced wall clock against the 20 s registered budget,
    # three runs each, this machine: a 15 s deadline finished in 17-18 s, inside the budget
    # but with under 2 s to spare on an IDLE box; a 10 s deadline finished in 12-13 s. The
    # margin is the point - a guard that only wins the race against the harness on a quiet
    # machine is not a guard. The enforced figure is asserted, not assumed: see
    # "the ENFORCED wall clock" test in tests/structural/hook-budgets.bats.
    DEADLINE="${MMRY_FOUNDATION_DEADLINE_SECS:-10}"
    [[ "$DEADLINE" =~ ^[0-9]+$ ]] && (( DEADLINE > 0 )) || DEADLINE=10

    # A marker left behind by a previous firing means that firing never reached its own
    # exit — the harness killed the whole handler — so that turn ran without directives
    # and nobody was told. Report it now.
    MISSED_PREVIOUS=0
    [[ -f "$_INFLIGHT" ]] && MISSED_PREVIOUS=1

    # Sweep per-firing files whose supervisor no longer exists. When the harness SIGKILLs us
    # the worker survives briefly and keeps writing, so its out-file is orphaned. `kill -0` is
    # a bash builtin, so this costs no process spawn.
    #
    # Both file families end in the supervisor's PID deliberately, so one loop reaps both and
    # neither can accumulate in the customer's temp directory across a long session.
    for _stale in "${_FOUND_TMPDIR}"/.mmry-foundation-out.* \
                  "${_FOUND_TMPDIR}"/.mmry-foundation-deadline.*; do
        [[ -e "$_stale" ]] || continue
        _stale_pid="${_stale##*.}"
        [[ "$_stale_pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$_stale_pid" 2>/dev/null || rm -f "$_stale" 2>/dev/null || true
    done

    OUTFILE="${_FOUND_TMPDIR}/.mmry-foundation-out.$$"
    # The watchdog touches this immediately BEFORE it kills the worker, and nothing else ever
    # creates it. It is therefore the only evidence that distinguishes "we stopped it at the
    # deadline" from "it died on its own", which the supervisor previously could not tell
    # apart: it branched on a non-zero exit alone, so a worker that exited 127 in 414 ms on a
    # broken install produced "loading took over the deadline" - a false cause, a false duration and a
    # remedy that could not possibly help.
    DEADLINE_MARK="${_FOUND_TMPDIR}/.mmry-foundation-deadline.$$"
    rm -f "$DEADLINE_MARK" 2>/dev/null || true
    : > "$OUTFILE" 2>/dev/null || true
    : > "$_INFLIGHT" 2>/dev/null || true

    MMRY_FOUNDATION_WORKER=1 bash "${PLUGIN_ROOT}/hooks-handlers/userpromptsubmit-foundation.sh" \
        > "$OUTFILE" 2>>"$_FOUND_ERR" &
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
    #
    # It measures ELAPSED TIME, not iterations (#31434 QA). Counting `sleep 1` rounds made the
    # effective deadline DEADLINE x (1 s + the cost of spawning `sleep`), and on Windows Git
    # Bash that spawn measured ~300 ms - so the shipped 15 s deadline really fired at 15 x 1.3
    # plus the supervisor's own overhead, and the whole handler measured 23-29 s against a 20 s
    # registered budget. The harness won the race it exists to lose, and discarded the output:
    # the exact silent loss this ticket closes. `SECONDS` is a bash builtin, so the drift and
    # the per-iteration spawn cost go together. Reset inside the subshell so it counts from
    # the watchdog's own start.
    (
        SECONDS=0
        while (( SECONDS < DEADLINE )); do
            kill -0 "$WORKER_PID" 2>/dev/null || exit 0
            sleep 1
        done
        # Record the REASON before causing it. Written first so that by the time `wait` can
        # possibly return, the marker the supervisor reads is already on disk.
        : > "$DEADLINE_MARK" 2>/dev/null || true
        kill -TERM "$WORKER_PID" 2>/dev/null
    ) >/dev/null 2>&1 <&- 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
    WATCHDOG_PID=$!

    wait "$WORKER_PID" 2>/dev/null
    WORKER_RC=$?
    kill "$WATCHDOG_PID" >/dev/null 2>&1 || true

    # Read the marker BEFORE deleting anything, then clean up whatever this firing created.
    HIT_DEADLINE=0
    [[ -f "$DEADLINE_MARK" ]] && HIT_DEADLINE=1

    BODY=""
    # `$(<file)`, not `$(cat file)` - one fewer process on every prompt (#31434 QA).
    [[ -s "$OUTFILE" ]] && BODY="$(<"$OUTFILE")"
    rm -f "$OUTFILE" 2>/dev/null || true
    rm -f "$DEADLINE_MARK" 2>/dev/null || true
    # THE IN-FLIGHT MARKER IS NOT CLEARED HERE. It is cleared immediately before each exit,
    # after the emit (#31411 QA).
    #
    # It used to be cleared at this point, which left the rest of this path unreported: the
    # emit and its JSON escape run after it, the watchdog only ever kills the WORKER, and the
    # escape is pure parameter expansion whose cost grows faster than its input. Measured on
    # this host with worst-case content, every line short so the newline replacement does the
    # most work: 8 KB 57 ms, 64 KB 120 ms, 128 KB 428 ms, 256 KB 1,435 ms, 360 KB 2,720 ms.
    #
    # That is superlinear and it is nowhere near the 10 s deadline or the 20 s budget at any
    # size a customer has: the largest Foundation set ever measured on the platform is 34,338
    # characters. Extrapolating the curve, it would take roughly 700 KB to reach 10 s. So the
    # speed is not the defect and I have NOT put a jq process on this path to fix it; #31434
    # deliberately took the processes out of here.
    #
    # The defect was that if it ever did run long, the turn would be silent about it, because
    # the marker saying "a turn was cut short" had already been removed. Clearing it after the
    # emit instead costs nothing and restores the guarantee: a firing killed anywhere, in the
    # worker or in the emit, leaves the marker, and the next turn says so.

    # THE CACHE WAS THERE AND COULD NOT BE TRUSTED (#31583).
    #
    # Distinct from both a crash and a deadline, and it needs its own words: nothing was
    # slow and nothing was broken about the install. Something replaced or damaged the file
    # this account's directives are read from, and the whole point of the ticket is that the
    # customer hears about it instead of being handed a stub described as authoritative.
    # The worker puts the specific reason on stdout; it is repeated verbatim to both
    # audiences so the assistant and the customer are told the same thing.
    if (( WORKER_RC == 3 )); then
        REASON="${BODY:-the cached directives could not be verified}"
        NOTICE="MMRY AI could not verify this account's FOUNDATION directives for this turn: ${REASON}. This turn is running WITHOUT the account's standing directives. Do not act on any partial or leftover directive text, and do not claim to be following them. Tell the user plainly that Foundation directives were not applied to this turn."
        USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn - ${REASON}. Nothing was truncated and nothing was guessed at; the local copy did not match the record MMRY wrote when it fetched them, so it was refused rather than used. Run /mmry:load-memories to rebuild it, then /mmry:foundation-status to confirm."
        printf '%s foundation reinjection REFUSED: %s
'             "$(date +%FT%T 2>/dev/null || echo now)" "$REASON" >> "$_FOUND_LOG" 2>/dev/null || true
        _mmry_emit "$NOTICE" "$USERMSG"
        rm -f "$_INFLIGHT" 2>/dev/null || true
        exit 0
    fi

    if (( WORKER_RC != 0 )); then
        # The turn proceeds either way; what matters is that the customer is told, in terms
        # they can act on, that this turn is running WITHOUT their standing directives — and
        # told the RIGHT thing. A crash and a deadline need different remedies, so they are
        # reported as different events rather than both as "it was slow".
        if (( HIT_DEADLINE == 1 )); then
            NOTICE="MMRY AI could not load this account's FOUNDATION directives for this turn: loading exceeded ${DEADLINE}s and was stopped so the prompt would not stall. This turn is running WITHOUT the account's standing directives. Do not claim to be following them. Tell the user plainly that Foundation directives were not applied to this turn."
            USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn (loading took over ${DEADLINE}s and was stopped). Re-send the prompt to try again. If it keeps happening, run /mmry:load-memories to rebuild the local cache, or set foundationReinject to false in ~/.claude/mmry-config.json to turn re-injection off."
            _FOUND_EVENT="deadline exceeded (${DEADLINE}s), worker killed"
        else
            # NOT a timeout. Saying "it took too long" here would be three lies at once: a
            # false cause, an invented duration, and a remedy (re-send the prompt) that cannot
            # work, because whatever made the worker exit non-zero will do it again.
            NOTICE="MMRY AI could not load this account's FOUNDATION directives for this turn: the loader failed with exit code ${WORKER_RC}. This was a failure, not a slow turn. This turn is running WITHOUT the account's standing directives. Do not claim to be following them. Tell the user plainly that Foundation directives were not applied to this turn."
            USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn — the loader exited with code ${WORKER_RC}. This is a failure rather than a slow load, so re-sending the prompt will not help; the usual cause is an incomplete plugin install. Run /mmry:load-memories to rebuild the local cache, reinstall the plugin if that fails, or set foundationReinject to false in ~/.claude/mmry-config.json to turn re-injection off."
            _FOUND_EVENT="worker exited ${WORKER_RC} without hitting the ${DEADLINE}s deadline"
        fi
        printf '%s foundation reinjection FAILED: %s\n' \
            "$(date +%FT%T 2>/dev/null || echo now)" "$_FOUND_EVENT" >> "$_FOUND_LOG" 2>/dev/null || true
        _mmry_emit "$NOTICE" "$USERMSG"
        rm -f "$_INFLIGHT" 2>/dev/null || true
        exit 0
    fi

    # Worker finished inside the deadline with nothing to inject (toggle off, no cache,
    # empty cache). Nothing was lost, so say nothing — including about a previous miss,
    # which would be a false alarm when there are no directives to apply.
    if [[ -z "${BODY//[[:space:]]/}" ]]; then
        rm -f "$_INFLIGHT" 2>/dev/null || true
        exit 0
    fi

    USERMSG=""
    if (( MISSED_PREVIOUS == 1 )); then
        BODY="NOTE: on the PREVIOUS turn these directives were not applied - loading them was cut short and its output discarded. Treat that turn's response as having been produced without them.

${BODY}"
        USERMSG="MMRY AI: your Foundation directives were not applied to the previous turn (the hook was cut short). They are applied again now."
    fi

    _mmry_emit "$BODY" "$USERMSG"
    rm -f "$_INFLIGHT" 2>/dev/null || true
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
REFRESH_SECS="${MMRY_FOUNDATION_REFRESH_SECONDS:-86400}"
CACHE="${MMRY_TMPDIR}/mmry-foundation.md"
# Kept for the supervisor's failure log only. Nothing on the happy path writes here any
# more: the line that did recorded a truncation that no longer happens, and recorded it
# wrongly - it printed the length AFTER the cut, so every one of the 1,457 entries on the
# affected machine read "had 6000 chars" (#31411).
LOG="${MMRY_TMPDIR}/mmry-foundation.log"

# Toggle off -> no-op. NOTE the supervisor checks this too, before it ever spawns this
# worker, so that the remedy the crash notice recommends actually works (#31434 QA).
_mmry_reinject_off "$REINJECT" && exit 0

# TTL-gated BACKGROUND refresh (#30579): if the cache is older than the refresh window,
# re-fetch Foundation memories in the background so an admin-added memory propagates without
# a Claude restart. This is non-blocking - the CURRENT prompt still uses the existing cache;
# the refreshed cache is picked up on the next prompt. A lock file (touched on each attempt)
# bounds this to one refresh per window per session even when a fetch fails. Default daily;
# users can force an immediate refresh with /mmry:load-memories or by restarting.
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

# UPGRADE RECOVERY (#31583 QA r3, found while verifying TC4 rather than reported).
#
# A cache written by a plugin older than this one has NO manifest beside it, because the
# manifest is what this ticket introduced. The verifier below is right to refuse it: an
# unmanifested file cannot be shown to be the account's own directives, and writing a manifest
# for whatever happens to be on disk would bless the four-byte stub this ticket exists to catch.
#
# But nothing rebuilt it, so the customer was warned on EVERY prompt for the rest of the
# session and the warning never cleared. Measured on a manifest-less cache over three prompts:
# refused each time, 922 characters of notice each time, no manifest ever appearing. That is
# the warn-all-the-time failure test case 4 exists to forbid, arriving by upgrade instead of by
# a bug, and it would have met every customer whose session did not happen to re-fetch. The
# live cache on the machine this was found on is exactly this shape: 15 entries, 6,279
# characters, no manifest.
#
# The age-gated refresh above cannot cover it. That gate asks how OLD the cache is, and an
# unmanifested cache is usually brand new, so its age is zero and it never fires; its lock is
# shared with the daily window besides. This gets its own short window, so recovery takes one
# prompt rather than a day, without hammering the API when the rebuild keeps failing.
#
# The turn still refuses. Recovery lands on the NEXT prompt, which is the honest order: this
# prompt genuinely has nothing it can verify.
if [[ -e "$CACHE" && ! -e "${CACHE}.manifest" && -n "${MMRY_API_KEY:-}" ]]; then
    _rebuild_lock="${MMRY_TMPDIR}/.mmry-foundation-rebuild"
    _rb_now="$(date +%s 2>/dev/null || echo 0)"
    if (( _rb_now - $(_mmry_mtime "$_rebuild_lock") >= 60 )); then
        touch "$_rebuild_lock" 2>/dev/null || true
        ( mmry_refresh_foundation_cache "$PWD" "$CACHE" >/dev/null 2>&1 & ) 2>/dev/null || true
    fi
fi

# ============================================================================
# VERIFY THE CACHE BEFORE BELIEVING IT (#31583).
#
# The old precondition was `[[ -s "$CACHE" ]]` - "the file is not empty" - and that is the
# whole defect. On 2026-09-18 this file held four bytes, the literal "- x", while the account
# held twelve directives totalling ~5.9 KB, and the product forwarded those four bytes to the
# assistant framed as the account's authoritative guidance. A single stray character passes
# a non-empty check exactly as well as the complete set does.
#
# The cache is a fixed name in a shared temp directory, so ANYTHING on the machine can write
# it. This does not try to prevent that - it makes it detectable. The writer records what it
# wrote (see mmry_write_foundation_cache); this refuses to inject anything that is not
# byte-for-byte that, and REPORTS rather than going quiet.
#
# Exit codes are the channel to the supervisor, which owns everything the customer sees:
#   0 - either injected in full, or a verified-empty set with nothing to inject
#   3 - the cache could not be verified; stdout carries the one-line reason
# ============================================================================

MANIFEST="${CACHE}.manifest"
# Written on every verified injection so /mmry:foundation-status can answer "are my
# directives reaching my assistants right now" without anyone reading a cache file
# (#31583 requirement 4). Costs one redirect and no process; its mtime is the timestamp.
STATUS="${MMRY_TMPDIR}/mmry-foundation.status"

# THROUGH THE SHARED VERIFIER (#31583 QA). This block used to carry its own copy of the
# manifest regex, the entries=0 check, the checksum comparison and the whitespace check, and
# foundation-status.sh carried another. They drifted twice in two rounds and each time the
# customer asking "are my directives reaching my assistant" was told the opposite of what was
# happening. One routine now; this file owns only the wording and the exit codes.
_reason="$(mmry_verify_foundation_cache "$CACHE")"
_verdict=$?

if (( _verdict == 1 )); then
    # ABSENT IS TWO DIFFERENT SITUATIONS AND ONLY ONE OF THEM IS A LOSS (#31583 R3/TC3).
    #
    # Nothing on disk at all can mean the set has never been built for this session -
    # SessionStart may not have run yet, or the account may hold no directives - and
    # warning on every prompt of a fresh session would make the notice worthless, which
    # TC4 explicitly forbids. It can also mean a set WAS verified and delivered this
    # session and the files have since gone. That is a disappearance, and TC3 requires it
    # to be reported exactly like damage, because the customer cannot tell those apart
    # and should not have to.
    #
    # The status record is what separates them. It is written on every verified delivery
    # and on a verified-empty set, so its presence means "this session has had a good
    # answer at least once". QA round 3 measured the gap: a valid cache delivered 294
    # characters, both files were then deleted, and the next firing emitted nothing at
    # all - no notice to the customer and no note to the assistant.
    if [[ "$_reason" == "absent" ]]; then
        if [[ -e "$STATUS" ]]; then
            printf '%s' 'the local copy of your Foundation directives has disappeared since it was last delivered in this session'
            exit 3
        fi
        exit 0
    fi
    # Verified and genuinely empty. Not damage, not worth a word, but it IS an answer,
    # so it goes on the record the status command reads.
    printf 'ok entries=0 bytes=0
' > "$STATUS" 2>/dev/null || true
    exit 0
fi

if (( _verdict != 0 )); then
    # The state token is for the status command's label; this channel is prose only.
    printf '%s' "${_reason#*|}"
    exit 3
fi

read -r _ok_word _exp_entries _act_bytes <<<"$_reason"
content="$(<"$CACHE")"

# ============================================================================
# DELIVER THE SET IN FULL (#31411).
#
# There is no size at which this withholds part of what the customer wrote. The cut that
# used to live here kept the first CAP_TOKENS*4 characters and discarded the rest, as a raw
# substring, so it landed wherever character 6000 happened to fall. On the account that
# surfaced it that was mid-sentence inside a list of corporate values, and four of the eight
# values had never reached any assistant. The log line recording the loss was itself broken:
# it printed the length AFTER the cut, so all 1,457 entries on that machine read
# "had 6000 chars" and the log could never show how much had been lost.
#
# Raising the ceiling was considered and rejected in #31411. Any ceiling, however high,
# keeps a size at which the product silently overrules the customer, and the product's
# standing claim is that these directives are in force on every response. The tokens are
# spent in the customer's own session, so the cost of a large set is theirs to judge; the
# account page tells them how large their set is and what it costs (#31411, website half).
#
# MMRY_FOUNDATION_TOKEN_CAP / foundationReinjectTokenCap is still PARSED by the client - the
# config-loading tests use it as a canary for key/value shear - but it is deliberately no
# longer honoured here. See the assertion "an explicitly configured token cap does NOT cut
# the set" in tests/handlers/userpromptsubmit-foundation.bats.
# ============================================================================

printf 'ok entries=%s bytes=%s
' "$_exp_entries" "$_act_bytes" > "$STATUS" 2>/dev/null || true

printf '%s' "The following are the account's FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive.

${content}"
exit 0
