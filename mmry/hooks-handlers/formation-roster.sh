#!/usr/bin/env bash
# formation-roster.sh - who is in this session's formation, and the id to address each of them by.
#
# WHY THIS EXISTS (#31045). A message can now be directed at ONE member, and the address is that
# member's roster entry id. Without a way to see the roster, a sender has no way to learn the id,
# and a feature nobody can invoke is a feature that shipped inert - which is exactly what happened
# to formation transmissions in v1.21, when the whole receiving half was delivered with no way to
# speak into it.
#
# THE ROSTER ENTRY, NOT THE SESSION STRING. A session id is secret-adjacent and a sender has no
# legitimate way to learn somebody else's, so it could never be the address. The roster entry is
# the formation's own identifier for one participation and is already visible to its members.
#
# LEAVING IS SHOWN, NOT HIDDEN. Since #31194 a session releases its place when it moves on, and a
# message cannot be directed at a member who has gone: the server refuses it. Showing who has left,
# rather than silently omitting them, is what makes that refusal legible instead of baffling.
#
# THIS DOES NOT FAIL OPEN. It runs because somebody asked and is waiting for an answer, so a
# failure is reported with the status that caused it, the same rule formation-list.sh follows.
#
# Usage: formation-roster.sh [formationId]
#        With no argument it reads this session's own formation from local state.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

formation_id="${1:-}"

if [[ -z "$formation_id" ]]; then
    session_id="$(mmry_session_id)"  # #31143: the command runtime provides CLAUDE_CODE_SESSION_ID
    if [[ -z "$session_id" ]]; then
        echo "No session id is available and no formation id was given, so there is no roster to show."
        exit 1
    fi
    state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
    if [[ -z "$state" ]]; then
        echo "This session is not in a formation. Run $(mmry_host_formation_ref list) to see what is active, then $(mmry_host_formation_ref join "<id>")."
        exit 1
    fi
    formation_id="${state%% *}"
fi

if ! [[ "$formation_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "A formation id is a positive whole number. Run $(mmry_host_formation_ref list) to see what is active."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so the roster cannot be read."
    exit 1
fi

if ! mmry_get_formation "$formation_id"; then
    # #31195: a status is evidence about the server's answer, not about the state of the world.
    # HTTP 000 is the only status that proves nothing was reached, and mmry-client puts its
    # explanation in MMRY_RESPONSE, so that one is passed through as the unreachable case.
    if [[ "${MMRY_HTTP_CODE:-0}" == "000" ]]; then
        echo "Could not reach the service. ${MMRY_RESPONSE:-}"
    elif [[ "${MMRY_HTTP_CODE:-0}" == "404" ]]; then
        echo "Formation ${formation_id} does not exist, or it belongs to another account."
    else
        echo "Could not read the roster for formation ${formation_id} (HTTP ${MMRY_HTTP_CODE:-0}). ${MMRY_RESPONSE:-}"
    fi
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    # No safe way to read it, so hand over what came back rather than half-parsing it.
    echo "$MMRY_RESPONSE"
    exit 0
fi

printf 'Formation %s: %s\n\n' "$formation_id" \
    "$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.formation.objective // "(no objective)"' 2>/dev/null || printf '?')"

# The id first, because it is the thing the sender is here to get. Members who have left are listed
# last and marked, so "left" reads as a fact about the formation rather than as a missing row.
printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
    (.members // [])
    | sort_by(.leftDate != null, .id)
    | .[]
    | "  " + (.id | tostring)
      + "  " + (.role // "member")
      + "  " + (.email // "?")
      + (if .assignment then "  - " + .assignment else "" end)
      + (if .progress then "  [" + (if .progress == "Assigned" then "not started" else .progress end) + "]" else "" end)
      + (if .leftDate != null then "   (has left; cannot be addressed)" else "" end)
' 2>/dev/null || { echo "$MMRY_RESPONSE"; exit 0; }

# WHETHER WHAT THIS SESSION SENT HAS BEEN READ (#31721). A sender used to have no way to tell "I sent
# it" from "they have read it", and on 2026-10-04 that cost a formation an hour of unread questions
# and assignments. Each directed message this session sent is listed with whether its recipient
# has been shown it yet, newest first, read back from the service rather than remembered here.
#
# Supplementary to the roster, so it never stands in its way: if the service cannot answer, or is
# too old to have the route, the section is left out and the roster above stands on its own. An
# empty list prints nothing, because most sessions have sent no directed message.
_mmry_sender_sid="$(mmry_session_id 2>/dev/null || true)"
if [[ -n "$_mmry_sender_sid" ]] && mmry_get_formation_sent "$formation_id" "$_mmry_sender_sid" 2>/dev/null \
    && [[ "${MMRY_HTTP_CODE:-}" =~ ^2[0-9][0-9]$ ]]; then
    _mmry_sent_lines="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '
        if type == "object" and .member == true and ((.messages // []) | length) > 0 then
            "Directed messages this session sent, newest first:",
            (.messages[]
             | "  to member " + (.recipientMemberId | tostring)
               + (if .recipientRole then " (" + .recipientRole + ")" else "" end)
               + "  " + (if .read == true then "READ " + ((.readDate // "") | tostring | .[0:19] | sub("T"; " ")) + " UTC"
                         else "NOT READ YET" end)
               + (if .recipientHasLeft == true then "  (has since left)" else "" end)
               + "  \"" + ((.preview // "") | tostring) + "\"")
        else empty end' 2>/dev/null || true)"
    if [[ -n "$_mmry_sent_lines" ]]; then
        # jq.exe on Windows writes CRLF; the CRs go so the lines read the same on every platform.
        printf '\n%s\n' "${_mmry_sent_lines//$'\r'/}"
        printf 'Read means it has been shown to that member: printed into their session, or attached to\n'
        printf 'one of their tool responses. Not read yet means they have not been shown it.\n'
    fi
fi

# THE RECIPIENT IS SPELLED DIFFERENTLY ON EACH HOST, AND THIS LINE USED TO GET IT WRONG
# (#31245, 2026-09-21).
#
# "--to <id>" is a CLAUDE CODE convention: the user types /mmry:formation say "..." --to 12 and
# commands/formation.md translates it into a positional argument before the script ever sees it.
# The script itself only ever took the id positionally.
#
# Codex has no commands, so the model runs the script directly, and this footer was handing it a
# flag the script refuses outright: "A recipient is a roster entry id, a positive whole number...
# Nothing was sent". Reproduced while testing delivery: the first send failed exactly this way.
#
# So the example matches the thing the reader will actually run.
if [[ "$(mmry_host)" == "codex" ]]; then
    _mmry_say_example='"..." <id>'
else
    _mmry_say_example='"..." --to <id>'
fi
printf '\nDirect a message at one of them with %s. Leave the id off\n' "$(mmry_host_formation_ref say "$_mmry_say_example")"
printf 'and the message goes to the whole formation.\n'
# #31046. The state in brackets is the last thing that member reported, and "not started" means
# nothing has been reported against work that WAS handed out, which is the thing worth noticing on
# this list. The full account, one section per member, is /mmry:formation report.
#
# THE LINE BREAKS ARE PART OF THE CLAUDE OUTPUT, NOT A DETAIL OF IT (#31245 QA round 6).
#
# The first cut of this derivation printed the same 199 bytes with the WRAP MOVED: it ended
# "...Abandoned>,\nand read the whole account with /mmry:formation report." where this footer has
# always read "...Abandoned>, and read the whole account\nwith /mmry:formation report." That is a
# change in what an existing Claude Code customer sees, which requirement 4 forbids - and the
# substring assertions meant to protect it could not see it, because every substring was still
# present in a different arrangement.
#
# The format strings below put the breaks back exactly where they were, and the Claude control in
# codex-formation-instructions.bats now compares the WHOLE footer byte for byte rather than
# hunting for three fragments inside it.
printf 'The state in brackets is the last thing that member reported. Report your own with\n'
printf '%s, and read the whole account\n' "$(mmry_host_formation_ref progress '<Accepted|Done|Blocked|Abandoned>')"
printf 'with %s.\n' "$(mmry_host_formation_ref report)"
exit 0
