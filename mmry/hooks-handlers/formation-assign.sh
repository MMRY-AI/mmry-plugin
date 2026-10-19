#!/usr/bin/env bash
# formation-assign.sh - the lead sets what ONE member of the formation is working on (#31044).
#
# WHY THIS EXISTS. A formation had a lead in name only. The roster has stored a role and an
# assignment since #31009, but the only thing that could ever set them was the joining session
# declaring its own, so the customer stayed the dispatcher: opening each window and telling it
# what to do, one at a time, exactly as before the formation existed.
#
# THE MEMBER IS NAMED BY ITS ROSTER ENTRY, from /mmry:formation roster, never by a session string.
# A session id is secret-adjacent and a caller has no legitimate way to learn somebody else's.
#
# THE MEMBER IS TOLD, AND NOBODY ELSE IS. The server sends a message directed at that member
# alone, which surfaces in its session after its next tool call. Broadcasting an instruction would
# mean every other member reads an order meant for somebody else, and any of them might act on it.
# That is the waste #31045 shipped to remove and this must not reintroduce.
#
# THIS DOES NOT FAIL OPEN. It runs because somebody asked and is waiting to know whether it
# worked, the same rule formation-say.sh follows. Reporting an assignment as delivered when it was
# refused is worse than an error, because the lead moves on believing the work is handed out.
#
# Usage: formation-assign.sh <memberId> "<assignment>" [role]
#        formation-assign.sh <memberId> "" <role>          # role only, assignment left alone
#        formation-assign.sh <memberId> --name "<name>"    # rename a member (#31410)
#        formation-assign.sh --name "<name>"               # rename THIS session's own member
#
# RENAMING (#31410). The lead, the person who started the formation and an administrator may rename
# anybody; any member may rename ITSELF. The server decides which from the roster and this session,
# so this script sends the session along with the name and states no authority of its own.
#
# An OMITTED field is left alone rather than cleared. There is deliberately no way to blank an
# assignment back to empty: the same non-clobbering rule the formation update has always had.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

member_id=""
assignment=""
role=""
new_name=""
_positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) new_name="${2:-}"; shift; [[ $# -gt 0 ]] && shift
                [[ -n "$new_name" ]] || { echo "A name cannot be blank. Nothing was changed."; exit 1; } ;;
        *) _positional+=("$1"); shift ;;
    esac
done
member_id="${_positional[0]:-}"
assignment="${_positional[1]:-}"
role="${_positional[2]:-}"

if [[ -z "$member_id" && -z "$new_name" ]]; then
    echo "Which member? Usage: $(mmry_host_formation_ref assign '<memberId> "what they should work on"'). Run $(mmry_host_formation_ref roster) to see the ids."
    exit 1
fi

# Validated here as well as on the server, because this is the thing the server cannot judge for
# us: whether the caller meant to name anybody at all. A non-numeric value is a mistake at the
# keyboard, and refusing it here means the mistake is named rather than turned into a round trip.
if [[ -n "$member_id" ]] && ! [[ "$member_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "A member id is a positive whole number from $(mmry_host_formation_ref roster). Nothing was changed."
    exit 1
fi

if [[ -z "$assignment" && -z "$role" && -z "$new_name" ]]; then
    echo "Nothing to change. Give an assignment, a role, a --name, or a combination. Nothing was sent."
    exit 1
fi

if [[ -n "$role" ]] && ! [[ "$role" =~ ^([Ll]ead|[Ww]ingman)$ ]]; then
    echo "A role is either Lead or Wingman. Nothing was changed."
    exit 1
fi

session_id="$(mmry_session_id)"  # the command runtime provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is no formation to act in. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nobody to assign. Run $(mmry_host_formation_ref list) to see what is active, then $(mmry_host_formation_ref join '<id>')."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run $(mmry_host_formation_ref leave) and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be assigned."
    exit 1
fi

# --name with no member id renames THIS session's own member (#31410). Its id is found on the
# roster, which carries a session id only on the caller's own rows, so this can only ever find us.
if [[ -z "$member_id" ]]; then
    if ! mmry_get_formation "$formation_id" || [[ -z "${MMRY_JQ:-}" ]]; then
        echo "Could not read the roster to find this session's own member id (HTTP ${MMRY_HTTP_CODE:-0}). Give the id: $(mmry_host_formation_ref assign '<memberId> --name "<name>"')."
        exit 1
    fi
    member_id="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r --arg sid "$session_id" \
        '[(.members // [])[] | select(.sessionId == $sid and .leftDate == null) | .id] | last // empty' 2>/dev/null || true)"
    member_id="${member_id//$'\r'/}"
    if ! [[ "$member_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "This session has no current place on formation ${formation_id}'s roster, so there is nobody to rename. Nothing was changed."
        exit 1
    fi
fi

if ! mmry_update_formation_member "$formation_id" "$member_id" "$role" "$assignment" "$new_name" "$session_id"; then
    code="${MMRY_HTTP_CODE:-0}"
    # #31195: EVERY BRANCH MAY ONLY SAY WHAT ITS STATUS ACTUALLY MEANS. A status code is evidence
    # about the server's answer, not about the state of the world behind it, and where the two are
    # guessed at they are guessed at out loud.
    server_said=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.error // .message // empty' 2>/dev/null || true)"
    fi
    [[ -n "$server_said" ]] || server_said="${MMRY_RESPONSE:-}"

    case "$code" in
        # The only branch entitled to talk about standing, and the server says why in its own
        # words: this route is open to the flight lead, the person who set the mission, and an
        # account administrator. Nothing was changed.
        403) echo "Refused, and nothing was changed. ${server_said}" ;;
        # Four different things land on 400 with four different remedies - no such member of this
        # formation, a member who has left, a bad role, and nothing named to change - so this
        # prints the server's own reason rather than guessing which one it was.
        400) echo "The server refused the change, and nothing was changed. ${server_said}" ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run $(mmry_host_formation_ref leave)." ;;
        # The gateway family. Not a refusal, and it carries no information about the roster or
        # about standing, so this stays clear of both words. It does not claim the change was
        # discarded either: a 502 can be raised after the row was written.
        502|503|504) echo "The server failed while handling the change (HTTP ${code}) and did not confirm it, so treat it as not applied. This is a fault on the server side, not something about formation ${formation_id} or your standing in it. Check $(mmry_host_formation_ref roster) before trying again." ;;
        *)   echo "Could not change member ${member_id} in formation ${formation_id} (HTTP ${code}). The server did not confirm it, so treat it as not applied." ;;
    esac
    # NO AUTOMATIC RETRY. The update is idempotent in its effect, but a retry after an unconfirmed
    # failure would send a SECOND notification for a change that already happened, and the member
    # cannot tell a duplicate instruction from a new one. Re-reading the roster costs one command
    # and answers the question a retry only guesses at.
    exit 1
fi

# A 2xx is not enough on its own. The roster entry the server returns is what actually stands now,
# and reporting from it rather than from the request is the #31192 rule: never report a value that
# was asked for as though it had been read back.
applied_assignment=""
applied_role=""
applied_name=""
if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
    applied_assignment="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.assignment // empty' 2>/dev/null || true)"
    applied_role="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.role // empty' 2>/dev/null || true)"
    applied_name="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r "${MMRY_JQ_NAME_DEFS}"' (.displayName // "") | mmry_name_label' 2>/dev/null || true)"
    applied_name="${applied_name//$'\r'/}"
fi

# A rename and nothing else is not an instruction, and the server tells nobody about it, so the
# reply says what the member is now called and stops (#31410).
if [[ -n "$new_name" && -z "$assignment" && -z "$role" && -n "$applied_role" ]]; then
    if [[ -n "$applied_name" ]]; then
        printf 'Member %s in formation %s is now shown as "%s".\n' "$member_id" "$formation_id" "$applied_name"
    else
        printf 'The server accepted the change for member %s in formation %s but returned no name. Run %s to see what it now holds.\n' "$member_id" "$formation_id" "$(mmry_host_formation_ref roster)"
    fi
    exit 0
fi

if [[ -z "$applied_role" ]]; then
    # No jq, or a body that could not be read. Say what is actually known rather than inventing a
    # confirmation: the server accepted it, and what it now holds was not readable from here.
    echo "The server accepted the change for member ${member_id} in formation ${formation_id}. Run $(mmry_host_formation_ref roster) to see what it now holds."
    exit 0
fi

printf 'Member %s in formation %s is now %s' "$member_id" "$formation_id" "$applied_role"
if [[ -n "$applied_name" ]]; then
    printf ', shown as "%s"' "$applied_name"
fi
if [[ -n "$applied_assignment" ]]; then
    printf ', working on: %s' "$applied_assignment"
fi
printf '.\n'
# #31789: a Codex lead hears the member's report only on its next action. Nothing on Claude Code.
# QA round 2: it comes straight after the confirmation, ahead of the line about the member, so the
# line the customer must be told is not the trailing one a reply drops.
if declare -F mmry_host_lead_notice >/dev/null 2>&1; then
    mmry_host_lead_notice assign || true
fi
printf 'They will see it after their next tool call, marked as directed at them. No other member was told.\n'
exit 0
