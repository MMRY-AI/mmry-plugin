#!/usr/bin/env bash
# formation-debrief.sh - close out this session's formation with the lead's summary (#31104).
#
# WHY THIS EXISTS. Eric's review of 2.8.0 caught the gap in one line: a lead could start a
# formation, speak to it and leave it, and could not close it out without calling the API by hand.
# The close-out is not an administrative afterthought, it is the point of the exercise: the summary
# is consolidated into lasting memories readable by someone who was never in the formation, and the
# running chatter stops being served. Leaving THAT as the one manual step meant most formations
# would simply never be closed out.
#
# The server enforces who may do this (lead, creator or admin), so this does not pre-check the
# role; it translates the refusal into words instead. And per DD-70, the server refuses to record
# the transition when the close-out record could not be saved, returning 502 with the formation
# left Active, so that failure is safe to retry.
#
# #31738: THE SERVER'S REASON IS PRINTED, NOT REPLACED. Every 502 used to print one fixed sentence,
# "could not be consolidated ... Try again shortly", whatever the server had said. The server's own
# cause was that the AI found nothing durable to keep, which no retry changes, so a lead was told to
# retry something that could never succeed and never shown why. The server now saves the record
# itself and names each remaining refusal and whether a retry helps (already closed, a default
# visibility it cannot save under, the store not answering), so its words are what is shown. This
# script's own sentences remain for a reply that carries no reason, or only a sanitised one.
#
# #31046: THE SUMMARY IS NO LONGER THE WHOLE RECORD. The server returns the close-out account with
# the transition - every member, the work it was given, and the state it ended in - and this prints
# it, because a lead that never sees the account cannot notice that a member it thought was
# finished never reported anything. The summary is one part of the record now, and the printing
# order says so: the account first, the confirmation after.
#
# Usage: formation-debrief.sh "summary of what was accomplished, decided, and learned"
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

summary="${1:-}"
if [[ -z "$summary" ]]; then
    echo "A debrief needs a summary. Usage: /mmry:formation debrief \"what was accomplished, what was decided, what went wrong\""
    exit 1
fi
# The server refuses under 20 characters with its own message; catching the obvious case here saves
# a round trip without duplicating the real rule.
if [[ "${#summary}" -lt 20 ]]; then
    echo "That summary is too short to be worth keeping. Say what was accomplished, what was decided, and what went wrong."
    exit 1
fi

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nothing to close out. Run /mmry:formation list to see what is active."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run /mmry:formation leave and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be closed out."
    exit 1
fi

# Removes the control characters a terminal acts on, C0 and C1 alike, keeping tab and newline
# (#31738 QA round 2). jq's regex works on characters, so it sees C1 controls, which tr cannot.
# Carriage return goes too (#31738 QA round 3): a bare CR sends the cursor back to the start of the
# line, so "did nothing", CR, "finished all work" showed the lead only the second half.
_MMRY_JQ_CLEAN='def clean: gsub("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]"; "");'

if ! mmry_debrief_formation "$formation_id" "$summary"; then
    code="${MMRY_HTTP_CODE:-0}"
    reason=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        # The reason is cleaned inside jq as well as by tr below (#31738 QA round 2): tr works on
        # bytes, so it cannot see a C1 control (U+0080 to U+009F, two bytes in UTF-8, CSI among
        # them), which a terminal still acts on. A validation refusal (RFC 7807) carries its
        # messages under .errors rather than .error, and those are read the same way.
        reason="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r \
            "${_MMRY_JQ_CLEAN}"' if type == "object" and (.error | type) == "string" then (.error | clean) elif type == "object" and (.errors | type) == "object" then ([.errors[] | if type == "array" then .[] else . end | select(type == "string") | clean] | join(" ")) else empty end' \
            2>/dev/null || true)"
    fi
    # Printed to a terminal, so nothing in it may drive one (#31738 QA round 1): control
    # characters, escape sequences and carriage returns included, are removed. Newlines and tabs are
    # kept.
    reason="$(printf '%s' "$reason" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
    # The sanitised placeholders carry no reason, and this script's sentence for that status says
    # more than they do. "Resource not found" is what the server sends for a 404.
    case "$reason" in
        "Invalid request"|"Access denied"|"Resource not found"|"Not found"|"An internal error occurred") reason="" ;;
    esac
    # NOTHING HERE SAYS "IT HAS NOT BEEN CHANGED" UNLESS THAT IS KNOWN (#31738 QA round 1). A 5xx or
    # a request that got no answer may come after the close-out record was saved, and possibly
    # after the formation was closed; saying it was not changed was false in exactly those cases.
    # Plain assignments rather than ${reason:-...}: an apostrophe inside that form, within double
    # quotes, opens a quote in bash.
    fallback=""
    case "$code" in
        409) fallback="Formation ${formation_id} is not active, so there is nothing to close out."
             # Already closed or stood down: the local state points at a formation that will never
             # serve again, so it is cleared exactly as a successful close-out clears it.
             bash "${HANDLER_DIR}/formation-state.sh" clear "$session_id" 2>/dev/null || true ;;
        403) fallback="Refused. Only the formation's lead, its creator, or an administrator can close it out." ;;
        404) reason=""
             fallback="Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        400) fallback="The server refused the summary, so formation ${formation_id} was not closed out. Check its length and wording, then close it out again." ;;
        402) fallback="Credits exhausted. Your MMRY AI subscription has run out of API credits, so formation ${formation_id} was not closed out." ;;
        429) fallback="Too many requests just now. Wait a moment, then close formation ${formation_id} out again." ;;
        000) reason=""
             if [[ "${MMRY_RESPONSE:-}" == "Authentication failed" ]]; then
                 fallback="Could not sign in to MMRY AI, so nothing was sent and formation ${formation_id} was not closed out. Run /mmry:setup."
             else
                 fallback="MMRY AI did not answer, so whether formation ${formation_id} was closed out is not known. Closing it out again is safe: if it already was, you will be told so."
             fi ;;
        5[0-9][0-9]) fallback="The close-out of formation ${formation_id} could not be completed or confirmed (HTTP ${code}). Closing it out again is safe: if its record was saved, it is used rather than saved twice." ;;
        *)   reason=""
             fallback="Could not close out formation ${formation_id} (HTTP ${code}). It has not been changed." ;;
    esac
    # printf, not echo: a reason that is exactly "-n" or "-e" was taken as an option and printed
    # nothing (#31738 QA round 2).
    if [[ -n "$reason" ]]; then printf '%s\n' "$reason"; else printf '%s\n' "$fallback"; fi
    exit 1
fi

# The formation is closed out server-side. Clear the local state so the delivery hook stops polling
# a channel that will never serve anything again; the membership record itself is the server's.
bash "${HANDLER_DIR}/formation-state.sh" clear "$session_id" 2>/dev/null || true

# THE ACCOUNT, AS THE SERVER RENDERED IT (#31046). Printed rather than rebuilt here: it is
# assembled in one place on purpose, and a second version written in bash would be a second answer
# that can disagree with what every other reader sees. A body that cannot be read is not faked into
# one - the close-out is still readable with /mmry:formation report.
record=""
if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
    # Printed to a terminal like a refusal's reason, so it is cleaned the same way (#31738 QA round
    # 2): it carries what members typed, and it was printed raw. jq removes C0 and C1 controls; tr
    # then removes any control byte a jq without that regex support let through.
    record="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r "${_MMRY_JQ_CLEAN}"' (.closeOut.record // empty) | clean' 2>/dev/null || true)"
    record="$(printf '%s' "$record" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
fi

if [[ -n "$record" ]]; then
    printf '%s\n\n' "$record"
fi

echo "Formation ${formation_id} closed out. The summary and the account above have been recorded as lasting memories, and the formation's chatter has stopped."
if [[ -z "$record" ]]; then
    echo "The account itself could not be read from the reply. Run /mmry:formation report ${formation_id} to see it."
fi
exit 0
