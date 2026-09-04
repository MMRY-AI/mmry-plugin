#!/usr/bin/env bash
# formation-say.sh - send a message to the other members of this session's formation (#31104).
#
# #31122: this now posts to the formation's own endpoint, which records the message VERBATIM. It
# used to go through memory processing, so a short message was interpreted and often discarded,
# and the ones that survived turned up in the subscriber's own recall, search and export.
#
# WHY THIS EXISTS. v1.21 shipped the whole receiving half of formation coordination and no way to
# speak. A session could start a formation, others could join, and every one of them would listen
# faithfully to a channel nobody could put anything into. UAT against production found it: the
# feature was deployed and inert. #31012's two-party proof looked like it covered this, but the
# lead's message in that proof was written straight to the stored procedure, which is not a route
# any customer has.
#
# EXPLICIT RATHER THAN AUTOMATIC. Transmitting is a deliberate act, not a side effect of saving a
# memory. The delivery hook already tells the model not to reply to the formation unless it has
# something worth transmitting, so sending on every save would contradict the instruction the model
# is given, and it would turn ordinary memories into chatter.
#
# THIS DOES NOT FAIL OPEN. That is the opposite of formation-check.sh, deliberately. The hook runs
# after every tool call and must never disturb a session, so it swallows everything. This runs
# because somebody asked for it and is waiting to know whether it worked, so a failure is reported.
# Reporting success for a message nobody received is the failure this whole task exists to fix.
#
# DIRECTED MESSAGES (#31045). An optional second argument names ONE roster entry, and the message
# then reaches that member and nobody else. Without it the message goes to the whole formation,
# which is what every message has done until now and what most messages should keep doing.
#
# Send a directed one when the message is an instruction with exactly one intended recipient.
# Broadcasting an instruction means every other member reads an order meant for somebody else, and
# any of them might act on it; with five members, four of them evaluate every instruction that does
# not concern them.
#
# The address is the ROSTER ENTRY id from /mmry:formation roster, never a session string. A sender
# has no legitimate way to learn another session's id, and it is not the kind of thing that should
# travel through a command line.
#
# Usage: formation-say.sh "message" [recipientMemberId]
# Exits 0 only when the server confirms it stored the transmission.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

message="${1:-}"
if [[ -z "$message" ]]; then
    echo "Say what? Usage: /mmry:formation say \"what you want the others to know\" [recipientMemberId]"
    exit 1
fi

# Validated here as well as on the server, because this is the one thing the server cannot judge
# for us: whether the caller meant to address anybody at all. A non-numeric value is a mistake at
# the keyboard, and refusing it here means the message is not sent to the WHOLE FORMATION by
# accident while the sender believes it went to one person. That is the failure worth preventing:
# an unaddressed instruction is not a smaller version of an addressed one, it is a broadcast.
recipient_member_id="${2:-}"
if [[ -n "$recipient_member_id" ]] && ! [[ "$recipient_member_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "A recipient is a roster entry id, a positive whole number from /mmry:formation roster. Nothing was sent, because sending this without the recipient would have told the whole formation."
    exit 1
fi

# #31122: the ten-character floor is GONE, and removing it is a fix rather than a relaxation. It
# was written on the assumption that a very short message was probably an accident, when the real
# reason short messages went nowhere was that the server ran them through AI extraction and
# discarded whatever it judged not worth keeping. "done", "stop" and "files locked" are among the
# most useful things one assistant can tell another. Blank is still refused above.

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nobody to send this as. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nobody to tell. Run /mmry:formation list to see what is active, then /mmry:formation join <id>."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run /mmry:formation leave and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be sent."
    exit 1
fi

if ! mmry_send_formation_transmission "$formation_id" "$session_id" "$message" "$PWD" "$recipient_member_id"; then
    code="${MMRY_HTTP_CODE:-0}"
    # #31195: EVERY BRANCH HERE MAY ONLY SAY WHAT ITS STATUS ACTUALLY MEANS. The gateway branch
    # below used to read "the formation may have been closed out, or you may no longer be a member
    # of it". Hit in production on 2026-09-03 by the Lead of a live formation with an intact roster,
    # and both explanations were false. The cost is not the wording: after reading that sentence the
    # operator checks the roster and re-joins, so the message spends an investigation on the one
    # place the fault is not. It did exactly that, across three formations. A status code is
    # evidence about the server's answer, not about the state of the world behind it, and where the
    # two are guessed at they must be guessed at OUT LOUD.
    case "$code" in
        # A refusal, and the only branch entitled to talk about membership. One answer covers
        # not-a-member, closed-out and another account's formation, because the server deliberately
        # does not distinguish them: telling them apart would disclose whether somebody else's
        # formation exists.
        403) echo "Refused, and nothing was sent. This session is not a current member of formation ${formation_id}, or the formation has been closed out. Run /mmry:formation join ${formation_id} from this window, or /mmry:formation list to see what is active." ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        # Two things land on 400 and both need the SERVER's own words rather than a summary. An
        # out-of-date plugin still posting to the old memory-processing path gets a body naming the
        # endpoint to use. A directed message naming a recipient who is not in this formation, is on
        # another account, has left, or is the sender itself gets the reason from the procedure
        # (#31045).
        #
        # This branch may NOT guess which of those it is, for the #31195 reason: the person reading
        # it is working out why nothing arrived, and a wrong explanation costs them an investigation
        # in the one place the fault is not. So it prints what the server said, preferring the
        # message field when there is one and falling back to the whole body when there is not.
        400)
            server_said=""
            if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
                server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.message // empty' 2>/dev/null || true)"
            fi
            [[ -n "$server_said" ]] || server_said="${MMRY_RESPONSE:-}"
            echo "The server refused the message, and nothing was sent. ${server_said}"
            ;;
        # The gateway family: the server, or something in front of it, failed while handling the
        # request. That is not a refusal and carries no information about the roster, so this says
        # so explicitly, and stays clear of the words "member" and "join" so it cannot be read as
        # one. 503 and 504 are here with 502 because they are the same answer from the same layer,
        # and fixing only the code we happened to be shown would leave the identical misreport one
        # bad afternoon away.
        #
        # It does not claim the message was discarded either, only that it was not confirmed. A 502
        # can be raised after the row was written, so "nothing was recorded" would be the same
        # unsupported guess pointing the other way.
        502|503|504) echo "The server failed while handling the message (HTTP ${code}) and did not confirm it, so treat it as not delivered. This is a fault on the server side, not something about formation ${formation_id} or your standing in it. Try again shortly." ;;
        # Whatever nobody anticipated. This may name the code and refuse to claim delivery. It may
        # not narrate a cause, which is why the old "Nothing was recorded" is gone from here too.
        *)   echo "Could not send to formation ${formation_id} (HTTP ${code}). The server did not confirm the message, so treat it as not delivered." ;;
    esac
    # NO AUTOMATIC RETRY, DELIBERATELY (#31195 requirement 4). mmry-client.sh records that a failed
    # debrief is safe to retry, and that guarantee is specific to /debrief: DD-70 has the server
    # refuse to record the transition when the consolidation stored nothing, so the caller knows the
    # first attempt changed nothing. The transmissions insert makes no such promise and carries no
    # idempotency key, so a 502 raised after the row was written would put the same instruction into
    # the channel twice, and the other members cannot tell a duplicate from a repeat. Against that,
    # the sender is a person who is present and waiting, for whom retrying costs one command, and a
    # silent retry would also hide how often the service is failing. Re-opening this needs a
    # server-side idempotency key first, not a loop here.
    exit 1
fi

# A 2xx is not enough on its own. The count of what was recorded is checked even now that the
# write is a plain insert, because the rule is about what this script is allowed to claim rather
# than about which failure is currently possible: never report delivery on faith (#31012, DD-70).
stored="${MMRY_TRANSMISSION_STORED:-}"
if [[ -z "$stored" || ! "$stored" =~ ^[0-9]+$ || "$stored" -eq 0 ]]; then
    echo "The server accepted the request but recorded nothing, so nobody will see this. Try again shortly."
    exit 1
fi

# The report says which of the two things actually happened (#31045). A directed message and a
# broadcast are different acts with different consequences, and reporting both as "sent to the
# formation" would leave a sender believing four other people had read an instruction that reached
# one, or the reverse. Neither is recoverable once the sender has moved on.
if [[ -n "$recipient_member_id" ]]; then
    echo "Sent to member ${recipient_member_id} in formation ${formation_id}, and to nobody else. They will see it after their next tool call, marked as directed at them."
else
    echo "Sent to formation ${formation_id}. The other members will see it after their next tool call."
fi
exit 0
