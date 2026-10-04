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
# TMPDIR can therefore have one session report the other's cut-short turn. CORRECTED (#31583 QA
# round 5): this used to say such a report is "still true". It is not: two healthy sessions
# started close together produced a false "not applied to the previous turn" in 5 of 6 pairs
# measured, telling the assistant to distrust a turn that went fine. Fixing it
# properly means session-scoping the whole Foundation cache, which is a bigger change than
# this ticket and would be smuggled in here.
# WHICH PART OF THE SET THIS FIRING DELIVERS (#31411 QA round 2, decided by the formation lead
# with Eric's approval).
#
# Claude Code caps a hook's additionalContext at 10,000 characters, with no setting to raise it,
# and over the cap it substitutes a 2,000-character preview and a file path the model is not told
# to read (code.claude.com/docs/en/hooks, and measured here: an 11,000-character hook arrived as
# characters 1 to 2,000 only). The cap is applied to each hook on its own, measured too: two hooks
# of 9,000 characters each arrived inline in full in the same prompt. It counts DECODED characters
# (9,900 characters containing 707 newlines, 10,607 once escaped, arrived whole).
#
# So hooks.json registers this script MMRY_FND_PARTS_MAX times, as --part 1 .. --part K. Every
# firing reads and verifies the same set, cuts it the same way, and sends only its own part,
# labelled "part k of n". Claude Code starts them together and they land in any order, so the
# labels, not the arrival order, carry the sequence. Part 1 alone owns everything said about the
# set as a whole: refusals, disappearance, rebuilds, and the by-reference fallback for a set too
# large for K parts. Parts 2..K only ever speak about their own part.
MMRY_FND_PART=1
if [[ "${1:-}" == "--part" && "${2:-}" =~ ^[1-9][0-9]*$ ]]; then MMRY_FND_PART="$2"; fi
MMRY_FND_PARTS_MAX="${MMRY_FOUNDATION_PARTS_MAX:-6}"
[[ "$MMRY_FND_PARTS_MAX" =~ ^[1-9][0-9]*$ ]] || MMRY_FND_PARTS_MAX=6
# Characters of the SET per part, counted as Claude Code counts them, in UTF-16 units (see
# _mmry_fnd_parts). With the heading, the part label and the cut-short note, the largest part there
# can be stays under the 10,000 cap; tests/handlers/foundation-parts.bats pins that.
MMRY_FND_PART_CAP=9500
_SFX=""
(( MMRY_FND_PART > 1 )) && _SFX=".${MMRY_FND_PART}"
_INFLIGHT="${_FOUND_TMPDIR}/.mmry-foundation-inflight${_SFX}"

# A PART THE SET CANNOT REACH LEAVES AT ONCE, HERE, BEFORE ANYTHING ELSE IS READ. Every part but
# the last is at least half a window long in bytes, and a window is never fewer bytes than the cap
# less the three a character can be stepped back by (see _mmry_fnd_parts), so a set of B bytes has
# fewer than k parts whenever B < (k-1) * (cap/2 - 8). The 8 is that step back, and margin. Decided
# from the manifest's own byte count with one read and no process, before anything else in the file
# runs. With no verifiable manifest at all, part 1 owns every report about it.
#
# What an unused part costs is the process start, not this script: moving this check up from inside
# the supervisor block was measured over 15 interleaved runs on Windows and made no difference
# (five unused parts 280 ms here, 273 ms there, against 210 ms for five bare bash starts). That cost
# is what sets K; see hooks.json and the latency notes in #31411.
if (( MMRY_FND_PART > 1 )); then
    _fnd_m="${_FOUND_TMPDIR}/mmry-foundation.md.manifest"
    _fnd_mb=""
    [[ -f "$_fnd_m" && -r "$_fnd_m" ]] && { _fnd_mb="$(<"$_fnd_m")" 2>/dev/null || _fnd_mb=""; }
    [[ "$_fnd_mb" =~ bytes=([0-9]+) ]] || exit 0
    (( BASH_REMATCH[1] < (MMRY_FND_PART - 1) * (MMRY_FND_PART_CAP / 2 - 8) )) && exit 0
fi

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
# NAMED FOR THIS FILE ALONE (#31411 QA). It was _mmry_json_escape, and mmry-client.sh defines a
# function of that same name. The supervisor never sources the client, so it got this one. The
# WORKER sources the client after this definition, so the client's silently replaced it there:
# moving the payload escape into the worker therefore ran a different, older escaper - one that
# leaves most control characters raw and is quadratic on newlines - while every test of this
# function passed against this copy. Found because a form feed came out escaped and a 0x01 did
# not. A unique name makes the override impossible rather than unlikely.
_mmry_fnd_json_escape() {
    # IN FIXED-SIZE CHUNKS (#31411 QA, performance, R6).
    #
    # Each replacement below is one character for one escape, so a match can never straddle a
    # chunk boundary, and escaping the set chunk by chunk gives exactly the same bytes as
    # escaping it whole. It matters because bash replacement is quadratic in the number of
    # matches: the newline pass alone took 24,097 ms on a 2 MB set of 21,500 lines, after the
    # worker's deadline had already released it, so the harness discarded the output and
    # nothing was said. Chunked, the whole escape took about 3 s at that size.
    #
    # Byte offsets, not characters, so a multibyte sequence is copied through a boundary intact;
    # every pattern here is ASCII and no UTF-8 continuation byte can match one. The locale is
    # local to this function and is restored on return.
    local LC_ALL=C
    local s="$1" out="" p i=0 n step=16384
    n=${#s}
    local _cc=$'[\001-\010\013\014\016-\037]' _need=0 _i _ch _hex
    # EVERY OTHER CONTROL CHARACTER, BUT ONLY WHEN ONE IS THERE (#31411 QA, R1). JSON forbids
    # raw characters below 0x20 in a string, and only tab, CR and LF used to be escaped, so a
    # form feed pasted from a PDF or a word processor broke the hook's JSON while the product
    # recorded the turn as delivered. One test decides; the extra passes run only if needed.
    [[ "$s" =~ $_cc ]] && _need=1
    while (( i < n )); do
        p="${s:i:step}"
        p="${p//\\/\\\\}"       # backslash FIRST or it re-escapes the escapes below
        p="${p//\"/\\\"}"
        p="${p//$'\015'/\\r}"
        p="${p//$'\011'/\\t}"
        p="${p//$'\012'/\\n}"
        if (( _need )); then
            for (( _i = 1; _i < 32; _i++ )); do
                case "$_i" in 9|10|13) continue ;; esac
                printf -v _hex '%02x' "$_i"
                printf -v _ch "\x${_hex}"
                p="${p//"$_ch"/\\u00${_hex}}"
            done
        fi
        out+="$p"
        i=$(( i + step ))
    done
    printf '%s' "$out"
}

# The same object, for a context the WORKER has already JSON-escaped (#31411 QA, R6).
#
# The success payload is the whole Foundation set, and escaping it is the one cost on this path
# that grows faster than the set does. It used to happen HERE, in the supervisor, after the
# watchdog had already released the worker, so on a large enough set it alone could carry the
# turn past the hook budget, where Claude Code discards the output and nothing is said on either
# channel. The worker now escapes its own payload inside its deadline, so a set too large to
# escape in time is killed at the deadline and REPORTED, and this side only copies bytes.
# R6 says there is no size at which the product silently withholds the set; this is what makes
# that true at any size rather than merely at every size anyone has measured.
_mmry_emit_escaped() {
    local ctx_escaped="$1" msg="$2"
    [[ -z "$ctx_escaped" && -z "$msg" ]] && return 0
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}' "$ctx_escaped"
    if [[ -n "$msg" ]]; then
        printf ',"systemMessage":"%s"' "$(_mmry_fnd_json_escape "$msg")"
    fi
    printf '}'
}

# THE OUTCOME OF THE MOST RECENT FIRING, one line, last write wins (#31583 QA round 6).
#
# /mmry:foundation-status used to decide "was the latest prompt delivered" by comparing the
# modification times of the delivery record and the failure log with -nt. Those are whole seconds
# on the bash and filesystems this runs on, so a failure logged in the same second as a delivery
# was reported as IN FULL, and QA proved it with a paired control. Ordering by file time cannot be
# fixed by being more careful with file times. So the supervisor now states the outcome of every
# firing it completes, in one file it replaces atomically, and the command reads that instead of
# inferring an order. The failure log stays, for whoever investigates.
#
# Stamped with the session token like the delivery record, so another session's outcome is never
# read as this one's. Read without sourcing the client: the supervisor stays process-free.
_mmry_outcome() {
    local tok="${MMRY_FND_SID:-}" f="${_FOUND_TMPDIR}/mmry-foundation.session"
    [[ -z "$tok" && -f "$f" && -r "$f" ]] && { tok="$(<"$f")" 2>/dev/null || tok=""; }
    # One redirect, no process (#31411 QA round 2, latency). The first version wrote a temp file and
    # renamed it into place, which cost two process starts, mv and rm, on every prompt: measured on
    # Windows, part 1 alone ran 975 ms against 797 ms for the hook before it. The line is a few dozen
    # bytes and is read only by /mmry:foundation-status, on a later prompt, never during this one.
    printf '%s %s' "$tok" "$1" > "${_FOUND_TMPDIR}/mmry-foundation.outcome${MMRY_FND_SID:+.$MMRY_FND_SID}${_SFX}" 2>/dev/null
    return 0
}

_mmry_emit() {
    local ctx="$1" msg="$2"
    [[ -z "$ctx" && -z "$msg" ]] && return 0
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}' \
        "$(_mmry_fnd_json_escape "$ctx")"
    # Omit systemMessage entirely when there is nothing to say, rather than emitting an
    # empty string that a client could render as a blank notice.
    if [[ -n "$msg" ]]; then
        printf ',"systemMessage":"%s"' "$(_mmry_fnd_json_escape "$msg")"
    fi
    printf '}'
}

# THE OFF-SWITCH LIVES IN ONE PLACE NOW (#31583 QA round 4, finding 4a).
#
# These three functions used to be defined here and the status command derived the same
# answer a different way, from mmry_load_config, which only sees the value when jq parses the
# config. A config jq cannot read therefore split them, and the command told the customer
# re-injection was ON while this hook was sending nothing. Sourced rather than moved into
# mmry-client.sh because the SUPERVISOR has to answer before it spawns anything, and sourcing
# the whole client on every prompt is the cost #31434 removed. This file defines functions
# only and spawns no process.
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/lib-foundation-switch.sh"

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

    # THIS SESSION'S ID, from the first bytes of the payload (#31583 QA round 6, R4(c)). Claude Code
    # sends session_id as the first field (captured from a real payload: offset 1), so 160 bytes is
    # enough whatever the prompt size; bash reads a pipe a byte at a time, and reading the whole
    # payload would make a long pasted prompt cost every part process. The rest is left unread, as
    # this hook has always left all of it. No id means the old token-named records, unchanged.
    MMRY_FND_SID=""
    if [[ ! -t 0 ]]; then
        _fnd_head=""
        IFS= read -r -n 160 -t 1 _fnd_head 2>/dev/null || true
        if [[ "$_fnd_head" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]{1,100})\" ]]; then
            MMRY_FND_SID="${BASH_REMATCH[1]}"
        fi
    fi
    export MMRY_FND_SID
    _INFLIGHT="${_FOUND_TMPDIR}/.mmry-foundation-inflight${MMRY_FND_SID:+.$MMRY_FND_SID}${_SFX}"

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
    # All three file families end in the supervisor's PID deliberately, so one loop reaps them
    # and none can accumulate in the customer's temp directory across a long session. The
    # pending delivery record joined them in #31583: a supervisor killed inside its emit never
    # promotes or removes its own, by design, so somebody else has to.
    for _stale in "${_FOUND_TMPDIR}"/.mmry-foundation-out.* \
                  "${_FOUND_TMPDIR}"/.mmry-foundation-deadline.* \
                  "${_FOUND_TMPDIR}"/mmry-foundation.status.pending.*; do
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

    # THE WORKER DOES NOT GET TO SAY THE TURN WAS DELIVERED (#31583, security on QA round 4).
    #
    # It used to write the delivery record itself, and it did so BEFORE this supervisor had
    # emitted anything. Every way a turn can still lose its output after that point - the
    # harness killing this process past the hook budget, the JSON never reaching a reader -
    # left a record saying the set had been sent, so /mmry:foundation-status answered
    # "Delivered: IN FULL, last sent 1 second ago" for a turn that delivered nothing. That is
    # the defect this ticket exists to close, reappearing in the command built to detect it.
    #
    # The worker now writes a PENDING record, scoped to this supervisor, and only this process
    # promotes it, and only after its own emit has returned success.
    _STATUS="${_FOUND_TMPDIR}/mmry-foundation.status${MMRY_FND_SID:+.$MMRY_FND_SID}"
    _PENDING="${_STATUS}.pending.$$"
    rm -f "$_PENDING" 2>/dev/null || true
    MMRY_FOUNDATION_WORKER=1 MMRY_FOUNDATION_PENDING="$_PENDING" \
        bash "${PLUGIN_ROOT}/hooks-handlers/userpromptsubmit-foundation.sh" --part "$MMRY_FND_PART" \
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
    # What the worker says it is sending, on its first characters: @@MMRY-PART k n@@,
    # @@MMRY-BYREF n@@ or @@MMRY-NONE k n@@. Stripped here, before anything else reads BODY, and
    # kept for the outcome record so /mmry:foundation-status can count delivered parts.
    _FND_KIND=""
    [[ -f "$DEADLINE_MARK" ]] && HIT_DEADLINE=1

    BODY=""
    # `$(<file)`, not `$(cat file)` - one fewer process on every prompt (#31434 QA).
    [[ -s "$OUTFILE" ]] && BODY="$(<"$OUTFILE")"
    if [[ "$BODY" =~ ^@@MMRY-(PART|BYREF|NONE)([^@]*)@@ ]]; then
        _FND_KIND="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        BODY="${BODY#@@MMRY-*@@}"
    fi
    rm -f "$OUTFILE" 2>/dev/null || true
    rm -f "$DEADLINE_MARK" 2>/dev/null || true
    # THE IN-FLIGHT MARKER IS NOT CLEARED HERE. It is cleared immediately before each exit,
    # after the emit (#31411 QA).
    #
    # It used to be cleared at this point, which left the rest of this path unreported: the
    # emit ran after it and the watchdog only ever kills the WORKER.
    #
    # CORRECTED (#31411 QA). This comment used to say the escape's cost was "nowhere near" the
    # deadline at any size a customer has, extrapolating roughly 700 KB to reach 10 s. That
    # was wrong: QA measured turns lost in silence at 400 KB, and it reproduced here at 17 s.
    # The cost was two whole-set whitespace scans plus a JSON escape that is quadratic in the
    # number of lines, all after the watchdog had let go. The scans are now a search for one
    # character, the escape runs in chunks and INSIDE the worker's deadline, and the supervisor
    # only copies bytes. Measured after: 400 KB 822 ms, 2 MB 3,211 ms, 8 MB stopped at the
    # deadline and reported. The largest set on the platform is 34,343 characters (2026-10-02).
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
    if (( WORKER_RC == 3 && MMRY_FND_PART > 1 )); then
        # NO EMIT ON THIS PATH: a refusal is about the whole set and part 1 reports it.
        _mmry_outcome "failed refused"
        rm -f "$_INFLIGHT" "$_PENDING" 2>/dev/null || true
        exit 0
    fi
    if (( WORKER_RC == 3 )); then
        # THE REMEDY HAS TO MATCH THE CAUSE (#31583 QA round 4).
        #
        # One sentence used to cover every refusal: "the local copy did not match the record
        # MMRY wrote when it fetched them". For a damaged or substituted file that is exactly
        # right. For the three states where there IS no record, no comparison happened at all
        # and the sentence contradicted its own first clause. Six of eight reviewers raised it
        # independently, and the no-manifest case is the one EVERY upgrading customer meets.
        REASON="${BODY#*|}"
        _STATE="${BODY%%|*}"
        [[ "$BODY" == *"|"* ]] || { REASON="${BODY:-the cached directives could not be verified}"; _STATE=""; }
        case "$_STATE" in
            no-manifest)
                # Not damage. The manifest is what this release introduced, so every cache
                # written by an earlier version looks like this once, and the rebuild started
                # above normally clears it by the next prompt without the customer doing anything.
                # Led with the reassurance and without the words cache or manifest (#31583 QA r5).
                # It no longer promises "a fresh copy is already being fetched": inside the
                # rebuild window, or offline, that is not true.
                _UPGRADE=1
                ;;
            gone|missing)
                _WHY="Nothing was truncated and nothing was guessed at; the stored copy is no longer there to check, so nothing was sent rather than something unverified."
                ;;
            bad-manifest)
                # No comparison happened here either, so the generic sentence below would be
                # false for it (#31583 QA r5): the record could not be read at all.
                _WHY="Nothing was truncated and nothing was guessed at; the record MMRY keeps to check your directives could not be read, so nothing could be checked and nothing was sent."
                ;;
            unreadable)
                _WHY="Nothing was truncated and nothing was guessed at; the stored copy could not be read, so nothing was sent."
                ;;
            blank)
                _WHY="Nothing was truncated and nothing was guessed at; the stored copy checks out but contains no readable text, so there was nothing to send."
                ;;
            *)
                # The states where a comparison really did happen and fail: size, contents,
                # inconsistent. Only these get the sentence that says so.
                _WHY="Nothing was truncated and nothing was guessed at; the local copy did not match the record MMRY wrote when it fetched them, so it was refused rather than used."
                ;;
        esac
        NOTICE="MMRY AI could not verify this account's FOUNDATION directives for this turn: ${REASON}. This turn is running WITHOUT the account's standing directives. Do not act on any partial or leftover directive text, and do not claim to be following them. Tell the user plainly that Foundation directives were not applied to this turn."
        if (( ${_UPGRADE:-0} )); then
            USERMSG="MMRY AI: you have just updated the MMRY plugin, so this one turn ran without your Foundation directives while they are fetched again in the new format. Normally the next prompt has them. No action needed; if you still see this after a few prompts, run /mmry:load-memories."
        else
            USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn - ${REASON}. ${_WHY} Run /mmry:load-memories to rebuild it, then /mmry:foundation-status to confirm."
        fi
        printf '%s foundation reinjection REFUSED: %s
'             "$(date +%FT%T 2>/dev/null || echo now)" "$REASON" >> "$_FOUND_LOG" 2>/dev/null || true
        _mmry_emit "$NOTICE" "$USERMSG"
        if (( ${_UPGRADE:-0} )); then
            _mmry_outcome "failed upgrade"
        else
            # A CAUSE CODE, NOT PROSE (#31583 QA round 6). The status command used to print whatever
            # text this record held, and the record sits in a shared temp directory. It now holds a
            # code and a number only; the command turns those into fixed sentences.
            _mmry_outcome "failed refused ${_STATE:-unknown}"
        fi
        rm -f "$_INFLIGHT" "$_PENDING" 2>/dev/null || true
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
            _FOUND_OUTCOME="deadline ${DEADLINE}"
        else
            # NOT a timeout. Saying "it took too long" here would be three lies at once: a
            # false cause, an invented duration, and a remedy (re-send the prompt) that cannot
            # work, because whatever made the worker exit non-zero will do it again.
            NOTICE="MMRY AI could not load this account's FOUNDATION directives for this turn: the loader failed with exit code ${WORKER_RC}. This was a failure, not a slow turn. This turn is running WITHOUT the account's standing directives. Do not claim to be following them. Tell the user plainly that Foundation directives were not applied to this turn."
            USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn — the loader exited with code ${WORKER_RC}. This is a failure rather than a slow load, so re-sending the prompt will not help; the usual cause is an incomplete plugin install. Run /mmry:load-memories to rebuild the local cache, reinstall the plugin if that fails, or set foundationReinject to false in ~/.claude/mmry-config.json to turn re-injection off."
            _FOUND_EVENT="worker exited ${WORKER_RC} without hitting the ${DEADLINE}s deadline"
            _FOUND_OUTCOME="crash"
        fi
        printf '%s foundation reinjection FAILED: %s\n' \
            "$(date +%FT%T 2>/dev/null || echo now)" "$_FOUND_EVENT" >> "$_FOUND_LOG" 2>/dev/null || true
        if (( MMRY_FND_PART > 1 )); then
            NOTICE="[Foundation part ${MMRY_FND_PART}] ${NOTICE}"
            USERMSG="${USERMSG/MMRY AI: your Foundation directives were NOT applied/MMRY AI: part ${MMRY_FND_PART} of your Foundation directives was NOT applied}"
        fi
        _mmry_emit "$NOTICE" "$USERMSG"
        _mmry_outcome "failed ${_FOUND_OUTCOME}"
        rm -f "$_INFLIGHT" "$_PENDING" 2>/dev/null || true
        exit 0
    fi

    # Worker finished inside the deadline with nothing to inject (toggle off, no cache,
    # empty cache). Nothing was lost, so say nothing — including about a previous miss,
    # which would be a false alarm when there are no directives to apply.
    # Same fix as the verifier's blank check, for the same measured reason (#31411 QA): this
    # was a whole-set rewrite costing 8,306 ms at 400 KB and sat OUTSIDE every guard, after the
    # watchdog had already let the worker go, so on a large set it alone could carry the turn
    # past the hook budget, where the harness discards the output and nothing is said.
    if [[ ! "$BODY" =~ [^[:space:]] ]]; then
        # NO EMIT ON THIS PATH: there is nothing to send, so nothing can go missing.
        # Nothing to send, so nothing can go missing in the sending. A verified-empty record
        # is a true answer and is promoted; for toggle-off or no-cache there is no pending
        # record and this is a no-op.
        [[ -e "$_PENDING" ]] && { mv -f "$_PENDING" "$_STATUS" 2>/dev/null; _mmry_outcome "ok part 1 of 1"; }
        # A part beyond the end of the set: nothing to send, and that is the right answer.
        [[ "$_FND_KIND" == NONE* ]] && _mmry_outcome "none"
        rm -f "$_INFLIGHT" "$_PENDING" 2>/dev/null || true
        exit 0
    fi

    USERMSG=""
    if (( MISSED_PREVIOUS == 1 )); then
        # BODY is already escaped by the worker, so only the note is escaped here, and the
        # blank line between them is written as its escaped form.
        BODY="$(_mmry_fnd_json_escape "NOTE: on the PREVIOUS turn these directives were not applied - loading them was cut short and its output discarded. Treat that turn's response as having been produced without them.")\n\n${BODY}"
        USERMSG="MMRY AI: your Foundation directives were not applied to the previous turn (the hook was cut short). They are applied again now."
        (( MMRY_FND_PART > 1 )) && USERMSG="MMRY AI: part ${MMRY_FND_PART} of your Foundation directives was not applied to the previous turn (the hook was cut short). It is applied again now."
    fi

    # BY REFERENCE: the customer is told once per session, not on every prompt. The assistant is
    # told on every prompt, because it needs the instruction every time.
    if [[ "$_FND_KIND" == BYREF* ]]; then
        _told="${_FOUND_TMPDIR}/.mmry-foundation-byref-told" _tok="" _told_tok=""
        _tok="${MMRY_FND_SID:-}"
        [[ -z "$_tok" && -f "${_FOUND_TMPDIR}/mmry-foundation.session" ]] && { _tok="$(<"${_FOUND_TMPDIR}/mmry-foundation.session")" 2>/dev/null || _tok=""; }
        [[ -f "$_told" ]] && { _told_tok="$(<"$_told")" 2>/dev/null || _told_tok=""; }
        if [[ -z "$_tok" || "$_tok" != "$_told_tok" ]]; then
            USERMSG="MMRY AI: your Foundation set is larger than Claude Code lets a plugin show on each prompt (${MMRY_FND_PARTS_MAX} parts of under 10,000 characters), so each turn your assistant is pointed to the full copy and asked to read it before answering. That works, but it relies on the assistant opening the file. To have the set applied directly, keep it under about $(( MMRY_FND_PARTS_MAX * MMRY_FND_PART_CAP )) characters. ${USERMSG}"
            printf '%s' "$_tok" > "$_told" 2>/dev/null || true
        fi
    fi

    # Promoted only if the emit itself succeeded. If this process is killed inside the emit,
    # or the reader is gone, the record keeps describing the last turn that DID deliver,
    # which stays true.
    if _mmry_emit_escaped "$BODY" "$USERMSG"; then
        [[ -e "$_PENDING" ]] && mv -f "$_PENDING" "$_STATUS" 2>/dev/null
        case "$_FND_KIND" in
            "PART "*)  _fk="${_FND_KIND#PART }"; _mmry_outcome "ok part ${_fk% *} of ${_fk#* }" ;;
            "BYREF "*) _mmry_outcome "ok by-reference ${_FND_KIND#BYREF }" ;;
            *)         _mmry_outcome "ok part 1 of 1" ;;
        esac
    fi
    rm -f "$_INFLIGHT" "$_PENDING" 2>/dev/null || true
    exit 0
fi

# ============================================================================
# WORKER — the real work. Writes PLAIN TEXT to stdout; the supervisor does the
# JSON. Anything that goes wrong here means "emit nothing", never "fail".
# ============================================================================

# The REAL environment value of the switch, taken before the client is sourced, because
# mmry_load_config populates that same variable from the config file (defaulting it to true) and
# afterwards an inherited value and a derived one cannot be told apart (#31583 QA round 5, 4d).
_MMRY_ENV_REINJECT="${MMRY_FOUNDATION_REINJECT-}"

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

# Toggle off -> no-op. The supervisor checks this too, before it ever spawns this worker, so
# that the remedy the crash notice recommends actually works (#31434 QA).
#
# ONE INPUT, NOT TWO (#31583 QA round 5, 4d). This used to decide from REINJECT, the jq-parsed
# value, while the supervisor and /mmry:foundation-status decide with the text scan in
# lib-foundation-switch.sh. Wherever the two disagree the customer was misled: a config saying
# true and then false (an ordinary hand-edit) has the scan reading ON and jq reading OFF, so the
# supervisor spawned this worker, this worker exited silently, and the status command promised
# the next prompt would send the set. It now asks the same routine, with the same input, that
# the other two use.
MMRY_FOUNDATION_REINJECT="$_MMRY_ENV_REINJECT" _mmry_reinject_is_off_here && exit 0

# TTL-gated BACKGROUND refresh (#30579): if the cache is older than the refresh window,
# re-fetch Foundation memories in the background so an admin-added memory propagates without
# a Claude restart. This is non-blocking - the CURRENT prompt still uses the existing cache;
# the refreshed cache is picked up on the next prompt. A lock file (touched on each attempt)
# bounds this to one refresh per window per session even when a fetch fails. Default daily;
# users can force an immediate refresh with /mmry:load-memories or by restarting.
# Part 1 only (#31411 split): six firings asking for one refresh is five too many.
if (( MMRY_FND_PART == 1 )) && [[ "$REFRESH_SECS" =~ ^[0-9]+$ ]] && (( REFRESH_SECS > 0 )) && [[ -n "${MMRY_API_KEY:-}" ]]; then
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
# Named, like every other window on this path (#31583 QA round 4). Short enough that an
# upgrading customer recovers within a prompt or two, long enough that a rebuild which keeps
# failing - offline, dead key - does not make one API call per prompt.
REBUILD_RETRY_SECS="${MMRY_FOUNDATION_REBUILD_RETRY_SECONDS:-60}"
if (( MMRY_FND_PART == 1 )) && [[ -e "$CACHE" && ! -e "${CACHE}.manifest" && -n "${MMRY_API_KEY:-}" ]]; then
    _rebuild_lock="${MMRY_TMPDIR}/.mmry-foundation-rebuild"
    _rb_now="$(date +%s 2>/dev/null || echo 0)"
    if (( _rb_now - $(_mmry_mtime "$_rebuild_lock") >= REBUILD_RETRY_SECS )); then
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
STATUS="${MMRY_TMPDIR}/mmry-foundation.status${MMRY_FND_SID:+.$MMRY_FND_SID}"
# Where the worker writes its delivery record. Under the supervisor this is a pending file the
# supervisor promotes after a successful emit; run on its own, as the unit tests do, the
# worker has no supervisor and writes the record directly.
STATUS_OUT="${MMRY_FOUNDATION_PENDING:-$STATUS}"
# The delivery record describes the set and is part 1's to write (#31411 split).
(( MMRY_FND_PART > 1 )) && STATUS_OUT=""

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
    # The delivery record is what separates them, and it must be THIS SESSION'S record.
    #
    # Round 3 closed the first half: a set that vanished after delivery emitted nothing at
    # all, no notice to the customer and no note to the assistant. Round 4 found the second
    # half, which the first half created. The record sat at a fixed name in a shared temp
    # directory and nothing cleared it, so its mere presence meant "some session on this
    # machine once delivered". A brand new session whose fetch failed, on a machine an earlier
    # session had used, was told on every prompt that its directives had disappeared when it
    # had never had any. Reviewers reproduced it at 932 characters a prompt, indefinitely.
    #
    # The record now carries the id of the session that wrote it and SessionStart clears it,
    # so this asks the question it always meant to ask. The check lives in mmry-client.sh
    # because the status command has to reach the same answer, and a second copy of a
    # Foundation question is what has drifted twice on this branch already.
    if [[ "$_reason" == "absent" ]]; then
        if mmry_foundation_delivered_this_session "$MMRY_TMPDIR" "${MMRY_FND_SID:-}"; then
            printf '%s' 'gone|the local copy of your Foundation directives has disappeared since it was last delivered in this session'
            exit 3
        fi
        exit 0
    fi
    # Verified and genuinely empty. Not damage, not worth a word, but it IS an answer,
    # so it goes on the record the status command reads.
    [[ -n "$STATUS_OUT" ]] && printf '%s ok entries=0 bytes=0
' "${MMRY_FND_SID:-$(mmry_foundation_session_token "$MMRY_TMPDIR" || true)}" > "$STATUS_OUT" 2>/dev/null || true
    exit 0
fi

if (( _verdict != 0 )); then
    # The state token is for the status command's label; this channel is prose only.
    # THE STATE TRAVELS WITH THE PROSE (#31583 QA round 4). The supervisor has to pick the
    # remedy, and the remedy differs: a cache carried over from an older plugin clears itself
    # on the next prompt, while a damaged one needs rebuilding. It used to strip the state and
    # then describe every refusal as a failed comparison.
    printf '%s' "$_reason"
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

# STAMPED WITH THE SESSION THAT WROTE IT (#31583 QA round 4, finding 4c). Without the stamp
# this record outlives its session and the next one reads it as its own.
[[ -n "$STATUS_OUT" ]] && printf '%s ok entries=%s bytes=%s
' "${MMRY_FND_SID:-$(mmry_foundation_session_token "$MMRY_TMPDIR" || true)}" "$_exp_entries" "$_act_bytes" > "$STATUS_OUT" 2>/dev/null || true

# ESCAPED HERE, INSIDE THE DEADLINE (#31411 QA, R6). See _mmry_emit_escaped. The supervisor
# treats a successful worker's output as already-escaped JSON string content and copies it.
# CUT THE SET INTO PARTS, the same way in every firing (#31411 split, QA round 2 R1 and TC3).
#
# THE LIMIT IS IN CHARACTERS, NOT BYTES. Claude Code's 10,000 counts characters of the decoded
# text, measured for non-ASCII text on 2026-10-04: a hook of 9,800 Japanese characters, 24,630
# bytes, reached the model whole (it read the last marker, at character 9,780), while 10,400
# characters was cut to a preview. Characters are counted as JavaScript counts them, in UTF-16
# units: one per character, two for one outside the Basic Multilingual Plane (most emoji). That is
# also how the account page counts, so the page and the plugin agree on what fits.
#
# WHERE A PART ENDS. The longest run that fits, pulled back to the last line end in its second
# half, else the last sentence end (". ", "! ", "? ", or the Japanese full stop), else the last
# blank, so a directive is not cut mid-line and one longer than a part is not cut mid-word (#31411
# QA round 2, TC3). Only a run of more than half a part with no blank at all, a URL or unspaced
# text, is cut hard, and then always between characters. Every part but the last is therefore at
# least half a part long, which is what lets parts 2..K leave at once on a small set.
#
# WHEN THAT NEEDS MORE THAN K PARTS, CUT AGAIN, FULLER (#31411 QA round 2, R1). Pulling back to a
# line end can leave a part half full: seven long memories of about 5,000 characters, 35,147 bytes,
# needed seven parts and went by reference although they fit in four. So the set is cut again with
# every part filled to the cap, pulled back only to a blank within its last 256 characters. By
# reference therefore means the set does not fit: more than about K x 9,500 characters.
#
# THREE ATTEMPTS, CHEAPEST FIRST. 1) The tidy cut, then 2) the full cut, counted in BYTES here in
# bash with no process: a byte count is never smaller than the character count, so a part that fits
# in bytes fits in characters, and for plain ASCII the two are the same. That settles every ASCII
# set and every other set that fits in K parts even counted in bytes. Only a set that still needs
# more than K parts AND holds non-ASCII text is 3) cut again counting characters, by
# foundation-cut.awk, which follows the same rules. That costs one process (measured: starting awk
# alone took 270 ms on this Windows host), so it is kept to the sets that need it, the ones QA
# found going by reference while they fit: a 24,700-character Japanese set is about 74,000 bytes.
_mmry_fnd_cut_bytes() {
    # Sets FND_PARTS from $1, mode $2 (tidy or fill), counting bytes, stopping one part past the
    # maximum. Caller has LC_ALL=C.
    local s="$1" mode="$2" cap="$MMRY_FND_PART_CAP" stop=$(( MMRY_FND_PARTS_MAX + 1 )) w t cut wb
    local cont=$'^[\x80-\xbf]'
    FND_PARTS=()
    while [[ -n "$s" ]] && (( ${#FND_PARTS[@]} < stop )); do
        if (( ${#s} <= cap )); then
            FND_PARTS+=("$s"); s=""; break
        fi
        # Never between the bytes of one character.
        wb=$cap
        while (( wb > 0 )) && [[ "${s:wb:1}" =~ $cont ]]; do wb=$(( wb - 1 )); done
        w="${s:0:wb}"
        cut=$wb
        if [[ "$mode" == "fill" ]]; then
            t="${w%[ $'\t\n\r']*}"
            [[ "$t" != "$w" ]] && (( wb - ${#t} <= 256 )) && cut=$(( ${#t} + 1 ))
        else
            t="${w%$'\n'*}"
            if [[ "$t" != "$w" ]] && (( ${#t} + 1 >= wb / 2 )); then
                cut=$(( ${#t} + 1 ))
            else
                t="${w%[.!?][ $'\t']*}"
                if [[ "$t" != "$w" ]] && (( ${#t} + 2 >= wb / 2 )); then
                    cut=$(( ${#t} + 2 ))
                else
                    t="${w%$'\xe3\x80\x82'*}"
                    if [[ "$t" != "$w" ]] && (( ${#t} + 3 >= wb / 2 )); then
                        cut=$(( ${#t} + 3 ))
                    else
                        t="${w%[ $'\t']*}"
                        [[ "$t" != "$w" ]] && (( ${#t} + 1 >= wb / 2 )) && cut=$(( ${#t} + 1 ))
                    fi
                fi
            fi
        fi
        FND_PARTS+=("${s:0:cut}")
        s="${s:cut}"
    done
    return 0
}

_mmry_fnd_parts() {
    local LC_ALL=C
    # Only the first K + 1 parts can ever matter, so only as much of the set as they could hold is
    # cut: four bytes is the most a character takes. A set longer than that goes by reference
    # whatever its content, and copying the rest of a very large set on every cut cost 947 ms on 1 MB.
    local whole="$1"
    local s="${whole:0:$(( (MMRY_FND_PARTS_MAX + 1) * MMRY_FND_PART_CAP * 4 ))}" nonascii=$'[\x80-\xff]' lens L off=0 parts=()
    _mmry_fnd_cut_bytes "$s" tidy
    (( ${#FND_PARTS[@]} > MMRY_FND_PARTS_MAX )) || return 0
    _mmry_fnd_cut_bytes "$s" fill
    (( ${#FND_PARTS[@]} > MMRY_FND_PARTS_MAX )) || return 0
    # Plain ASCII: bytes are characters, so the set really does not fit.
    [[ "$s" =~ $nonascii ]] || return 0
    # Counted in characters. Only as much of the set as K + 1 parts could hold is passed: four bytes
    # is the most a character takes, and anything beyond that is by reference regardless.
    lens="$(LC_ALL=C awk -v cap="$MMRY_FND_PART_CAP" -v max="$MMRY_FND_PARTS_MAX" \
        -f "${PLUGIN_ROOT}/hooks-handlers/foundation-cut.awk" \
        <<<"$s" 2>/dev/null)" || return 0
    while IFS= read -r L; do
        [[ "$L" =~ ^[0-9]+$ ]] || return 0
        parts+=("${s:off:L}")
        off=$(( off + L ))
    done <<<"$lens"
    # Fail safe: keep the byte result, which goes by reference, unless these parts are within K and
    # account for every byte of the set.
    (( ${#parts[@]} >= 1 && ${#parts[@]} <= MMRY_FND_PARTS_MAX && off == ${#whole} )) || return 0
    FND_PARTS=("${parts[@]}")
    return 0
}

_mmry_fnd_parts "$content"
_fnd_n=${#FND_PARTS[@]}
_fnd_head="The following are the account's FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive."

if (( _fnd_n > MMRY_FND_PARTS_MAX )); then
    # BY REFERENCE. More than K parts cannot be shown, so part 1 points the assistant at the full,
    # verified copy and tells it to read it before answering; parts 2..K stay silent.
    if (( MMRY_FND_PART > 1 )); then
        printf '@@MMRY-NONE %s %s@@' "$MMRY_FND_PART" "$_fnd_n"
        exit 0
    fi
    _fnd_path="$CACHE"
    command -v cygpath >/dev/null 2>&1 && _fnd_path="$(cygpath -w "$CACHE" 2>/dev/null || printf '%s' "$CACHE")"
    _payload="The account's FOUNDATION memories - authoritative directives that take precedence over defaults - are too large to show here: the complete set is ${_act_bytes} bytes, more than Claude Code lets a plugin show on one prompt (${MMRY_FND_PARTS_MAX} parts of under 10,000 characters). BEFORE YOU ANSWER, read this file in full with your file-reading tool; it is the complete, verified set: ${_fnd_path}
If a response would conflict with any directive in it, follow the directive. If you cannot read the file, tell the user plainly that their Foundation directives were not applied to this turn."
    printf '@@MMRY-BYREF %s@@' "$_fnd_n"
elif (( MMRY_FND_PART > _fnd_n )); then
    printf '@@MMRY-NONE %s %s@@' "$MMRY_FND_PART" "$_fnd_n"
    exit 0
elif (( _fnd_n == 1 )); then
    # One part: exactly the payload a single hook always sent.
    _payload="${_fnd_head}

${content}"
    printf '@@MMRY-PART 1 1@@'
else
    _payload="${_fnd_head} This is PART ${MMRY_FND_PART} OF ${_fnd_n} of the set. The other parts arrive alongside this one, in any order, and together they are the whole set.

${FND_PARTS[$(( MMRY_FND_PART - 1 ))]}"
    printf '@@MMRY-PART %s %s@@' "$MMRY_FND_PART" "$_fnd_n"
fi

# ESCAPED HERE, INSIDE THE DEADLINE (#31411 QA, R6). See _mmry_emit_escaped. The supervisor
# treats a successful worker's output as already-escaped JSON string content and copies it.
printf '%s' "$(_mmry_fnd_json_escape "$_payload")" || {
    # A FAILED EMIT IS A FAILURE, NOT A DELIVERY (#31411 QA). Non-zero takes the supervisor's
    # crash path, which tells the customer, and the pending delivery record is withdrawn.
    [[ -n "$STATUS_OUT" ]] && rm -f "$STATUS_OUT" 2>/dev/null
    exit 5
}
exit 0
