#!/usr/bin/env bash
# formation-remove.sh - the lead or an administrator removes ONE member from the formation (#32270).
#
# WHY THIS EXISTS. A member leaves only from its own session. When that session drops (Formation 45,
# 2026-10-16: the Codex member on a Mac lost its session) nothing could take it off: it stayed on
# the roster for good, could still be addressed, and a message directed at it was accepted and
# never read. Marking its work Abandoned recorded what happened to the work and did nothing about
# the member.
#
# THE MEMBER IS NAMED BY ITS ROSTER ENTRY, from the roster, never by a session string or a person.
# Removing a person would also remove their other window, which is still working.
#
# WHO MAY DO IT IS THE SERVER'S DECISION: the flight lead, the person who started the formation, or
# an account administrator, derived from the server's own tables. Nothing here says who is asking.
#
# THIS DOES NOT FAIL OPEN. It runs because somebody asked and is waiting to know whether it worked,
# the rule formation-assign.sh follows. Reporting a removal that did not happen is worse than an
# error, because the lead stops worrying about a member that is still listed and still addressable.
#
# Usage: formation-remove.sh <memberId> [formationId]
#        The formation defaults to this session's own; name one to act on a formation this session
#        is not in, as an administrator who never joined it would.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

member_id="${1:-}"
named_formation="${2:-}"

if [[ -z "$member_id" ]]; then
    echo "Which member? Usage: $(mmry_host_formation_ref remove '<memberId>'). Run $(mmry_host_formation_ref roster) to see the ids."
    exit 1
fi

# Refused here as well as on the server, because whether the caller meant to name anybody at all
# is the one thing the server cannot judge. A mistake at the keyboard is named, not sent.
if ! [[ "$member_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "A member id is a positive whole number from $(mmry_host_formation_ref roster). Nobody was removed."
    exit 1
fi

if [[ -n "$named_formation" ]] && ! [[ "$named_formation" =~ ^[1-9][0-9]*$ ]]; then
    echo "A formation id is a positive whole number from $(mmry_host_formation_ref list). Nobody was removed."
    exit 1
fi

session_id="$(mmry_session_id)"  # the command runtime provides CLAUDE_CODE_SESSION_ID (#31143)

formation_id="$named_formation"
if [[ -z "$formation_id" ]]; then
    state=""
    if [[ -n "$session_id" ]]; then
        state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
    fi
    if [[ -z "$state" ]]; then
        echo "This session is not in a formation, so there is no formation to remove anybody from. Name one: $(mmry_host_formation_ref remove '<memberId> <formationId>'). Run $(mmry_host_formation_ref list) to see what is active."
        exit 1
    fi
    formation_id="${state%% *}"
    if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
        echo "The local formation state is not a number, so it cannot be trusted. Run $(mmry_host_formation_ref leave) and join again."
        exit 1
    fi
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nobody can be removed."
    exit 1
fi

if ! mmry_remove_formation_member "$formation_id" "$member_id"; then
    code="${MMRY_HTTP_CODE:-0}"
    # #31195: EVERY BRANCH MAY ONLY SAY WHAT ITS STATUS ACTUALLY MEANS.
    server_said=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.error // .message // empty' 2>/dev/null || true)"
    fi
    [[ -n "$server_said" ]] || server_said="${MMRY_RESPONSE:-}"

    case "$code" in
        # The only branch entitled to talk about standing, in the server's own words.
        403) echo "Refused, and nobody was removed. ${server_said}" ;;
        # A closed formation, no such member of it, and a member already gone: the server says which.
        400) echo "The server refused the removal, and nobody was removed. ${server_said}" ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Nobody was removed." ;;
        # Not a refusal. It does not claim the removal was discarded either: a 502 can be raised
        # after the row was written. The roster answers that; a retry only guesses.
        502|503|504) echo "The server failed while handling the removal (HTTP ${code}) and did not confirm it. This is a fault on the server side, not something about formation ${formation_id}. Check $(mmry_host_formation_ref roster) before trying again." ;;
        *)   echo "Could not remove member ${member_id} from formation ${formation_id} (HTTP ${code}). The server did not confirm it, so treat it as not removed and check $(mmry_host_formation_ref roster)." ;;
    esac
    exit 1
fi

# A 2xx is not enough on its own: report what the server says now stands (#31192).
removed_by=""
left_at=""
entry_session=""
if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
    removed_by="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.removedByEmail // empty' 2>/dev/null | tr -d '\r' || true)"
    left_at="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.leftDate // empty' 2>/dev/null | tr -d '\r' || true)"
    entry_session="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.sessionId // empty' 2>/dev/null | tr -d '\r' || true)"
fi

# THE ENTRY WAS THIS SESSION'S OWN. The server would accept it from a lead, so the client is where it
# is noticed: the session is no longer a member, and it must stop listening, exactly as leaving
# does. The server only returns a session id on the caller's own entries (#31235), so a match here
# can only be this window.
if [[ -n "$session_id" && -n "$entry_session" && "$entry_session" == "$session_id" ]]; then
    bash "${HANDLER_DIR}/formation-state.sh" clear "$session_id" || true
    echo "Member ${member_id} was this session's own place, so this session has left formation ${formation_id}. No further messages from it will be surfaced here. To leave a formation, $(mmry_host_formation_ref leave) is the command to use."
    exit 0
fi

if [[ -z "$left_at" ]]; then
    # No jq, or a body that could not be read: say only what is known.
    echo "The server accepted the removal of member ${member_id} from formation ${formation_id}. Run $(mmry_host_formation_ref roster) to see the roster as it now stands."
    exit 0
fi

# "2026-10-16T02:14:33.1234567" -> "2026-10-16 02:14 UTC", the same stamp the close-out record uses.
when="${left_at:0:10} ${left_at:11:5} UTC"
printf 'Member %s was removed from formation %s at %s' "$member_id" "$formation_id" "$when"
[[ -n "$removed_by" ]] && printf ' by %s' "$removed_by"
printf '.\n'
printf 'It receives nothing further from the formation, and a message directed at it is refused. The same person'"'"'s other windows in the formation are not affected. The report records who removed it and when.\n'
exit 0
