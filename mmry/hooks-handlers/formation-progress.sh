#!/usr/bin/env bash
# formation-progress.sh - say how the work is going, or how it ended (#31046).
#
# WHY THIS EXISTS. Since #31044 the lead can hand out work, and nothing could answer the obvious
# next question. A member that went quiet, gave up, or quietly worked something else left no trace
# at all, and the closing record - whatever the lead wrote, from the traffic the lead happened to
# read - said everything went to plan. A record that silently omits abandoned work is worse than no
# record, because it is confidently wrong.
#
# THIS SESSION REPORTS ITS OWN WORK. Given a member id first, it reports somebody ELSE's, which
# only the lead, the person who started the formation and an account administrator may do. The
# server decides that from the roster, and this script does not pre-judge it: a client-side guess
# at standing is a second copy of a rule that can drift from the enforced one.
#
# THE STATES ARE NOT LISTED IN A CONDITION HERE, on purpose. They live in a database constraint,
# and the server answers a wrong one with a sentence naming all five, which is a better message
# than anything this file could invent and cannot fall out of step with what is enforced. What is
# checked here is the shape of the ARGUMENTS - which one is the id and which is the state - because
# that is the one thing the server cannot judge for us.
#
# THIS DOES NOT FAIL OPEN. It runs because somebody asked and is waiting to know whether it worked,
# the same rule formation-say.sh and formation-assign.sh follow. Reporting progress as recorded
# when it was refused is worse than an error: the lead never learns the member is blocked.
#
# Usage: formation-progress.sh <state> ["note"]              # this session's own work
#        formation-progress.sh <memberId> <state> ["note"]   # the lead, for somebody else
#
# The note is optional, is delivered to the people who need to read it, and IS NEVER STORED. It
# cannot appear in the close-out record, because there is nowhere for it to be kept.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

first="${1:-}"
second="${2:-}"
third="${3:-}"

if [[ -z "$first" ]]; then
    echo "Say how it is going. Usage: /mmry:formation progress <Accepted|Done|Blocked|Abandoned> \"optional note\". Add a member id first to report for somebody else, which only the lead may do."
    exit 1
fi

# WHICH ARGUMENT IS WHICH, decided by shape rather than by counting. A member id is a positive
# whole number and a state never is, so a leading number can only be somebody else's entry. Getting
# this wrong in the other direction - treating a state as an id - is what would silently report the
# wrong member, so it is resolved here rather than sent and hoped for.
member_id=""
if [[ "$first" =~ ^[1-9][0-9]*$ ]]; then
    member_id="$first"
    progress="$second"
    note="$third"
    if [[ -z "$progress" ]]; then
        echo "Member ${member_id} needs a state. Usage: /mmry:formation progress ${member_id} <Accepted|Done|Blocked|Abandoned> \"optional note\"."
        exit 1
    fi
else
    progress="$first"
    note="$second"
    if [[ -n "$third" ]]; then
        echo "Too many arguments. Reporting for another member goes /mmry:formation progress <memberId> <state> \"note\", and a member id is a whole number. Nothing was sent."
        exit 1
    fi
fi

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # the command runtime provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is no participation to report on. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nothing to report. Run /mmry:formation list to see what is active, then /mmry:formation join <id>."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run /mmry:formation leave and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be reported."
    exit 1
fi

# REPORTING FOR THIS SESSION MEANS FINDING ITS OWN ROSTER ENTRY FIRST. The server addresses a
# member by roster entry, never by session string, so with no id given this reads the roster and
# picks out the entry belonging to this window. Doing it here rather than letting the server infer
# it keeps one rule on the server: the caller always names the entry it means.
if [[ -z "$member_id" ]]; then
    if ! mmry_get_formation "$formation_id"; then
        echo "Could not read the roster for formation ${formation_id} (HTTP ${MMRY_HTTP_CODE:-0}), so this session's own entry could not be found. Nothing was reported."
        exit 1
    fi
    if [[ -z "${MMRY_JQ:-}" ]]; then
        echo "jq is not available, so this session's own roster entry could not be identified. Run /mmry:formation roster and report with the member id: /mmry:formation progress <memberId> ${progress}."
        exit 1
    fi
    member_id="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r \
        --arg s "$session_id" \
        '[(.members // [])[] | select(.sessionId == $s and .leftDate == null)][0].id // empty' \
        2>/dev/null || true)"
    if [[ -z "$member_id" ]]; then
        echo "This session is not on formation ${formation_id}'s roster, so there is nothing to report against. It may have been released. Run /mmry:formation leave and join again."
        exit 1
    fi
fi

if ! mmry_update_formation_member_progress "$formation_id" "$member_id" "$session_id" "$progress" "$note"; then
    code="${MMRY_HTTP_CODE:-0}"
    # #31195: EVERY BRANCH MAY ONLY SAY WHAT ITS STATUS ACTUALLY MEANS. A status code is evidence
    # about the server's answer, not about the state of the world behind it.
    server_said=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.error // .message // empty' 2>/dev/null || true)"
    fi
    [[ -n "$server_said" ]] || server_said="${MMRY_RESPONSE:-}"

    case "$code" in
        # The only branch entitled to talk about standing, and the server says why in its own
        # words: a member may move its own state, and the lead, the person who set the mission and
        # an administrator may move anybody's.
        403) echo "Refused, and nothing was recorded. ${server_said}" ;;
        # Three different things land on 400 with three different remedies - no such member of this
        # formation, a formation already closed out, and a state outside the permitted set - so
        # this prints the server's own reason rather than guessing which one it was.
        400) echo "The server refused it, and nothing was recorded. ${server_said}" ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        # The gateway family. Not a refusal, and it says nothing about standing or about the
        # roster, so this stays clear of both. It does not claim the report was discarded either: a
        # 502 can be raised after the row was written.
        502|503|504) echo "The server failed while handling the report (HTTP ${code}) and did not confirm it, so treat it as not recorded. This is a fault on the server side, not something about formation ${formation_id} or your standing in it. Check /mmry:formation roster before trying again." ;;
        *)   echo "Could not record progress for member ${member_id} in formation ${formation_id} (HTTP ${code}). The server did not confirm it, so treat it as not recorded." ;;
    esac
    # NO AUTOMATIC RETRY. A retry after an unconfirmed failure sends a SECOND notification for a
    # change that may already have happened, and the lead cannot tell a duplicate from a new report.
    exit 1
fi

# A 2xx is not enough on its own. The roster entry the server returns is what stands now, and
# reporting from it rather than from the request is the #31192 rule: never report a value that was
# asked for as though it had been read back.
applied=""
if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
    applied="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.progress // empty' 2>/dev/null || true)"
fi

if [[ -z "$applied" ]]; then
    # No jq, or a body that could not be read. Say what is known rather than inventing a
    # confirmation.
    echo "The server accepted the report for member ${member_id} in formation ${formation_id}. Run /mmry:formation report to see what the record now says."
    exit 0
fi

printf 'Member %s in formation %s is now recorded as %s.\n' "$member_id" "$formation_id" "$applied"
printf 'It is in the close-out record from here on. The lead sees this after its next tool call; no other member was told.\n'
exit 0
