#!/usr/bin/env bash
# lib-hookread.sh — read the Claude Code hook payload from stdin using nothing but bash (#31385).
#
# WHY THIS FILE EXISTS
# --------------------
# Both hook handlers that need the stdin payload used to read it like this:
#
#     payload="$(timeout 2 cat 2>/dev/null || true)"
#
# `timeout` is GNU coreutils. It is NOT on a stock macOS: the base system ships no `timeout`, and
# the Homebrew coreutils build installs it as `gtimeout`, which is not on PATH under the plain name
# either. On any Mac without GNU coreutils that line therefore ran a command that does not exist.
# `2>/dev/null` hid "command not found", `|| true` discarded exit 127, and the payload came back
# EMPTY with nothing anywhere reporting a fault.
#
# The payload is not optional decoration. It carries session_id AND hook_event_name, which is how
# one handler serves four hook registrations. Losing it meant formation-check.sh saw no event and
# fell through its case statement to the PostToolUse contract for every registration, so on a Mac:
#
#   Stop             ran one un-looped pass instead of polling, so a message never reached an idle
#                    session — the headline feature simply did not work.
#   UserPromptSubmit exited 2 with the message on stderr, which BLOCKS the human's prompt instead of
#                    handing the message over quietly.
#   SessionStart     exited 2 into a runtime that records that as an error and DISCARDS the text, so
#                    the missed-message sweep was thrown away.
#
# And with no session_id on stdin the handler fell back to env vars the hook runtime does not
# reliably set, so it frequently returned at the id check having done nothing at all.
#
# THE REPLACEMENT
# ---------------
# `read -t` is a bash builtin. It is present in bash 3.2, which is the bash macOS ships at
# /bin/bash, so this needs nothing installed on any supported platform. Nothing is forked, which
# also makes it cheaper than the `timeout cat` it replaces in the hottest path in the plugin.
#
# Deliberately NOT chosen: probing for `gtimeout` and falling back (still depends on something a
# user has to install, and leaves two code paths where one has coverage), and bundling a coreutils
# binary next to vendor/jq (weight and per-platform maintenance for a builtin we already have).
#
# AN EMPTY READ MUST SAY SO
# -------------------------
# The defect was not only the missing binary. It was that an empty payload was indistinguishable
# from a payload that legitimately said nothing, so a total failure looked exactly like a quiet
# hook. This function therefore reports HOW the read ended, and never collapses the outcomes:
#
#   return 0  ok       stdin was a pipe and produced bytes.
#   return 1  notty    stdin is a terminal. There was never a payload; this is not a fault.
#   return 2  empty    stdin was a pipe, the read completed, and it produced ZERO bytes. THIS is
#                      the shape the missing binary made, and it is now a distinct, testable state.
#   return 3  timeout  the budget expired before end-of-input. Whatever arrived is still returned.
#
# Callers get the bytes in MMRY_HOOK_PAYLOAD and the word in MMRY_HOOK_READ_STATUS.
#
# Test seam: MMRY_HOOK_READ_TIMEOUT overrides the default budget so the suite need not wait 2s.

# Matches the repository convention every other handler and library follows (file-integrity.bats
# enforces it). Harmless when sourced: both call sites already run under these options, and the
# reader is written to survive them - `read` returning non-zero at end-of-input is caught with
# `|| rc=$?` rather than being allowed to kill the caller.
set -euo pipefail

# Read the hook payload from stdin within a budget in whole seconds (default 2).
# Sets MMRY_HOOK_PAYLOAD and MMRY_HOOK_READ_STATUS. See the return-code table above.
mmry_read_hook_payload() {
    local budget="${1:-${MMRY_HOOK_READ_TIMEOUT:-2}}"

    MMRY_HOOK_PAYLOAD=""
    MMRY_HOOK_READ_STATUS="notty"

    # No pipe, no payload. A terminal on stdin means this was run by hand, not by Claude Code.
    if [ -t 0 ]; then
        return 1
    fi

    # `read -t` on bash 3.2 takes whole seconds only, and rejects anything non-numeric.
    case "$budget" in
        ''|*[!0-9]*) budget=2 ;;
    esac
    [ "$budget" -lt 1 ] && budget=1

    # SECONDS is a builtin, so the deadline costs no fork. The budget is a whole-payload deadline,
    # not a per-line one: a stream that emits a line just inside the per-read timeout forever would
    # otherwise never expire, which is the exact hang the old 2s cap existed to prevent.
    local deadline=$(( SECONDS + budget ))
    local line rc remaining timed_out=0

    while :; do
        remaining=$(( deadline - SECONDS ))
        # Never pass 0: `read -t 0` tests for readiness without reading, which would spin.
        if [ "$remaining" -le 0 ]; then
            timed_out=1
            break
        fi

        line=""
        rc=0
        # `|| rc=$?` keeps this a tested command, so a caller running under `set -e` (every handler
        # here does) is not killed by the ordinary non-zero that read returns at end-of-input.
        IFS= read -r -t "$remaining" line || rc=$?

        # Data arrives on a partial final line too, where read reports failure and still fills the
        # variable. Appending before inspecting rc is what keeps a payload with no trailing newline
        # from being silently dropped — and a hook payload frequently has none.
        if [ -n "$line" ]; then
            if [ -n "$MMRY_HOOK_PAYLOAD" ]; then
                MMRY_HOOK_PAYLOAD="${MMRY_HOOK_PAYLOAD}
${line}"
            else
                MMRY_HOOK_PAYLOAD="$line"
            fi
        fi

        # rc 0 is a complete line: there may be more.
        [ "$rc" -eq 0 ] && continue

        # THE DEADLINE IS THE AUTHORITY, NOT THE RETURN CODE.
        #
        # bash >= 4 reports a `read -t` timeout with a status above 128, and the first version of
        # this loop trusted that alone. bash 3.2 - which is what macOS ships at /bin/bash, i.e. the
        # exact platform this whole change exists for - returns plain 1 for BOTH a timeout and
        # end-of-input. On that shell the >128 test never fires, so a stream that ran out the clock
        # was classified `empty` (or `ok`, if some bytes had arrived) and the caller was told the
        # hook had simply gone quiet. That is the same "a total failure looks healthy" collapse this
        # file was written to end, reintroduced one line below the comment describing it.
        #
        # The clock does not vary by shell version. If the budget has expired, the read stopped
        # because time ran out, whatever the status says; if time remains, a non-zero status can
        # only be end-of-input. A genuine end-of-input landing in the same second as the deadline is
        # reported as a timeout, which is the safe way round: it names a state a caller can act on
        # rather than one that reads as normal.
        if [ "$rc" -gt 128 ] || [ "$SECONDS" -ge "$deadline" ]; then
            timed_out=1
        fi
        break
    done

    if [ "$timed_out" -eq 1 ]; then
        MMRY_HOOK_READ_STATUS="timeout"
        return 3
    fi
    if [ -z "$MMRY_HOOK_PAYLOAD" ]; then
        MMRY_HOOK_READ_STATUS="empty"
        return 2
    fi
    MMRY_HOOK_READ_STATUS="ok"
    return 0
}

# Record a hook-read fault where something can find it later.
#
# formation-check.sh may not speak: its governing rule is to fail open and SILENT, because it runs
# after every tool call in every session and a fault there would be a fault in everybody's work.
# But silent must not mean untraceable, which is the whole complaint of #31385. The breadcrumb is
# how a hook that is forbidden from talking to the model still leaves evidence, and session-start.sh
# — which does have a channel to the model — reads it and says so out loud.
#
# Best-effort and bounded: never fails, and never grows without limit.
mmry_note_hook_read_fault() {
    local who="${1:-unknown}" status="${2:-${MMRY_HOOK_READ_STATUS:-unknown}}"
    local log="${TMPDIR:-/tmp}/mmry-hook-read-faults.log"
    local stamp
    stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown-time')"

    # Keep the tail only. A session that faults on every tool call must not fill the disk.
    if [ -f "$log" ]; then
        local lines
        lines="$(wc -l < "$log" 2>/dev/null || printf '0')"
        case "$lines" in
            ''|*[!0-9]*) lines=0 ;;
        esac
        if [ "$lines" -gt 200 ]; then
            tail -n 50 "$log" > "${log}.trim" 2>/dev/null && mv "${log}.trim" "$log" 2>/dev/null || true
        fi
    fi

    printf '%s\t%s\t%s\n' "$stamp" "$who" "$status" >> "$log" 2>/dev/null || true
    return 0
}
