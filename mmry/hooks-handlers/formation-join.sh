#!/usr/bin/env bash
# formation-join.sh - join a formation and make delivery reachable (#31012 QA).
#
# WHY THIS EXISTS. The delivery hook reads which formation a session belongs to from local state,
# and nothing in the shipped plugin ever wrote that state. The mechanism worked when the state was
# populated by hand and was therefore unreachable in practice, which is what QA found. This is the
# missing half: it enrols the session server-side AND records it locally, in that order, so local
# state can never claim a membership the server did not grant.
#
# Usage: formation-join.sh <formationId> [--name "<name>"]
#
# THE MEMBER'S NAME (#31410). Without --name the session's OWN name is used: the Claude Code
# session title or the Codex thread name (mmry_session_display_name). --name always wins. With no
# name available none is sent, and the others see this member by role and member id.
# Exits 0 on success. On failure it exits non-zero and explains itself on stdout, because the
# calling command passes that explanation straight to the user.
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/lib-formation-roles.sh"

# The two standing rules a member is given when it joins (#31744). One sentence pair each, ASCII
# only, no apostrophes, so the same text can be held unchanged in a T-SQL literal on the service.
MMRY_FORMATION_REPORT_RULE="Report to the lead at every stopping point, with a message directed to the lead: when you finish, when you are blocked, when you are waiting, and when you stop with work still running, saying what is still running. Never hold finished work back for a slow check; report it and say the check is still running."
MMRY_FORMATION_ACK_RULE="When you receive an assignment, a brief or a question, acknowledge it before you start, with substance: what you understood, anything you cannot do, and when to expect the result. If the job is short, fold that into your first update. Findings and status updates need no acknowledgement."

formation_id="${1:-}"
[[ $# -gt 0 ]] && shift
explicit_name=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) explicit_name="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
        *) shift ;;
    esac
done
if [[ -z "$formation_id" ]]; then
    echo "Which formation? Usage: $(mmry_host_formation_ref join "<formationId>")"
    exit 1
fi
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "A formation id is a number. Got: $formation_id"
    exit 1
fi

session_id="$(mmry_session_id)"  # CLAUDE_SESSION_ID is unset in the command runtime; the Bash tool provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is nothing to enrol. This needs to run inside a session."
    exit 1
fi

mmry_load_config || true

# Register the session first. A formation is joined by a session, and the server refuses a session
# it has never seen, which would otherwise read as a permission problem.
# #31245 QA round 3: the client name is the HOST's, not the constant "claude-code". A Codex session
# registered as claude-code is a session the customer cannot find in their own session list - and
# docs/codex.md tells them, in as many words, that Codex sessions are listed as `codex`. The
# resolver is reached through mmry-client.sh; the fallback keeps the old literal if it is not.
if declare -F mmry_host_client_name >/dev/null 2>&1; then
    _mmry_client_name="$(mmry_host_client_name)"
else
    _mmry_client_name="claude-code"
fi
mmry_register_session "$session_id" "$_mmry_client_name" "$PWD" 2>/dev/null || true

# The name to join under (#31410): the one given, else the session's own, else none.
display_name="$explicit_name"
name_was_captured=""
if [[ -z "$display_name" ]]; then
    display_name="$(mmry_session_display_name "$session_id" 2>/dev/null || true)"
    [[ -n "$display_name" ]] && name_was_captured=1
fi

joined=""
if mmry_join_formation "$formation_id" "$session_id" "$display_name"; then
    joined=1
elif [[ "${MMRY_HTTP_CODE:-0}" == "400" && -n "$name_was_captured" ]]; then
    # A name nobody typed must never cost the join. The service refused it (400), and a refusal
    # writes nothing, so join once more without it; the member is then shown by role and id.
    display_name=""
    mmry_join_formation "$formation_id" "$session_id" "" && joined=1
fi

if [[ -z "$joined" ]]; then
    code="${MMRY_HTTP_CODE:-0}"
    case "$code" in
        403) echo "Refused. Either you share no access group with whoever created formation ${formation_id}, or your account is not active. An administrator can add you to the group." ;;
        404) echo "Formation ${formation_id} does not exist, or it belongs to another account." ;;
        409) mmry_formation_held_refusal; echo ;;   # names the formation that holds the session (#32401)
        400) if [[ -n "$explicit_name" ]]; then
                 echo "The server refused that name, and nothing was joined. $(printf '%s' "${MMRY_RESPONSE:-}" | "${MMRY_JQ:-cat}" -r '.errors // .error // . | tostring' 2>/dev/null || true)"
             else
                 echo "Could not join formation ${formation_id} (HTTP ${code}). Nothing has been changed locally."
             fi ;;
        *)   echo "Could not join formation ${formation_id} (HTTP ${code}). Nothing has been changed locally." ;;
    esac
    exit 1
fi

# Only now record it locally. Writing state first would leave a session believing it was in a
# formation the server had refused, and the hook would poll it after every tool call forever.
bash "${HANDLER_DIR}/formation-state.sh" set "$formation_id" "$session_id"

# A return picks up where it left off (#32385). If this session left THIS formation, leave kept its
# delivery position, and it goes back on the record now, so the next poll asks for what was said
# since rather than for everything. A position kept for another formation is dropped.
bash "${HANDLER_DIR}/formation-state.sh" resume "$formation_id" "$session_id"

objective=""
if [[ -n "${MMRY_JQ:-}" && -n "${MMRY_RESPONSE:-}" ]]; then
    objective="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.formation.objective // empty' 2>/dev/null || true)"
fi

if [[ -n "$objective" ]]; then
    echo "Joined formation ${formation_id}: ${objective}. Messages from the other members will now be surfaced automatically."
else
    echo "Joined formation ${formation_id}. Messages from the other members will now be surfaced automatically."
fi

# WHO THE OTHERS SEE (#31410): this session's own roster entry, read back from the server's answer
# (the roster carries a session id only on the caller's own rows), never the name that was asked for.
#
# A RETURN IS SAID TO BE ONE (#32385). When the own row carries returnedDate the service gave this
# session its earlier seat back: the same member id the others already know it by, with its name,
# role, assignment and progress as it left them. The line says so, because a member that reports
# "member 31" to a lead who assigned work to member 31 an hour ago should not leave the lead
# wondering whether that is the same assistant.
own_line=""
if [[ -n "${MMRY_JQ:-}" && -n "${MMRY_RESPONSE:-}" ]]; then
    own_line="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r --arg sid "$session_id" "${MMRY_JQ_NAME_DEFS}"'
        [(.members // [])[] | select(.sessionId == $sid and .leftDate == null)] | last
        | if . == null then empty
          elif (.returnedDate // null) != null then
              "You are back as member \(.id), the id you had before you left, shown to the others as "
              + (if ((.displayName // "") | mmry_name_clean) != ""
                 then "\"\(.displayName | mmry_name_label)\"."
                 else "\(.role // "Member") \(.id), because this session has no name." end)
              + " Your name, role, assignment and progress are as you left them. Anything said while you were out arrives marked SENT WHILE YOU WERE AWAY."
          elif ((.displayName // "") | mmry_name_clean) != "" then
              "You are member \(.id), shown to the others as \"\(.displayName | mmry_name_label)\"."
          else
              "You are member \(.id), shown to the others as \(.role // "Member") \(.id), because this session has no name."
          end' 2>/dev/null || true)"
fi
if [[ -n "$own_line" ]]; then
    printf '%s\n' "${own_line//$'\r'/}"
    case "$own_line" in
        *"has no name"*) echo "Give it one with $(mmry_host_formation_ref assign '--name "<name>"')." ;;
    esac
fi

# THE MEMBER'S STANDING RULES (#31744). Said at the moment of joining, because it is the one moment
# every member passes through on every host. Before this a member was told only that messages
# would reach it, so whether it ever reported back depended on the lead remembering to say so in
# every brief; on 2026-10-04 a member held finished work for about 40 minutes behind a slow check
# and the sponsor had to ask whether the lead had been told.
#
# THE WORDING IS SHARED, NOT RESTATED. The same two rules are in the connector's join response
# and the service's assignment notice (MMRY-AI/mmry: FormationReportRule.cs, migration 066) and on
# the formation command page. tests/structural/formation-report-rule.bats pins them here byte for
# byte, and the service repository pins its copies to the same text (DD-109 there). Change one and
# change all of them.
echo "${MMRY_FORMATION_REPORT_RULE}"
echo "${MMRY_FORMATION_ACK_RULE}"

# THE RULE FOR THIS SESSION'S OWN ROLE (#32683), after the two above, which are unchanged. The role
# is read off this session's own row in the server's answer, so a lead returning to its seat gets
# the lead rule. Anything else, or a row that cannot be read, gets the member rule: a join never
# makes a new lead. The wording is held in lib-formation-roles.sh.
own_role=""
if [[ -n "${MMRY_JQ:-}" && -n "${MMRY_RESPONSE:-}" ]]; then
    own_role="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r --arg sid "$session_id"         '[(.members // [])[] | select(.sessionId == $sid and .leftDate == null)] | last | .role // empty'         2>/dev/null || true)"
    own_role="${own_role//$''/}"
fi
mmry_formation_role_rule "$own_role"
exit 0
