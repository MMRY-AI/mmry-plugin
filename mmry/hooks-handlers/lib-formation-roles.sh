#!/usr/bin/env bash
# lib-formation-roles.sh - the rule each formation member is given for its role, and the question a
# finished member ends its report with, held once (#32683).
#
# WHY THIS FILE EXISTS. In the Magento 1.11.1 Formation a member reported "Idle until..." and
# waited, while the lead worked alone until the person reminded it that members were free. The
# report-to-lead rule (#31744, formation-join.sh) made members report. Nothing told the lead to
# answer, and nothing told a finished member to ask for more.
#
# BESIDE THE TWO STANDING RULES, NOT INSIDE THEM. formation-join.sh still prints the report and
# acknowledge rules to every joiner, unchanged. A member is given ONE of the rules below as well,
# chosen by its role: the lead rule or the member rule, never both.
#
# ONE TEXT, EVERY SURFACE. formation-join.sh and formation-start.sh print these on Claude Code and
# Codex; formation-progress.sh prints the sent line on this session's own Done. The service holds
# the same literals in MMRY-AI/mmry src/Mnemo.Api/Services/FormationRoleRule.cs (the connector) and
# in the assignment and PROGRESS notices its migration writes; the command page and the Codex skill
# quote the two rules. tests/structural/formation-role-rules.bats pins every copy.
#
# ASCII, NO APOSTROPHES, as the report-to-lead rule: the service holds this text as T-SQL N''
# literals, and text that needs no escaping there cannot drift by an escape.
set -euo pipefail

# #33205, #34521 (DD-202 in MMRY-AI/mmry): cmo-mmry's approved lead rule, item 1 revision 1
# (wording-33205-34521-cmo-approved.md): keep every member working, hand each new piece of work out
# with assign so MMRY AI knows what each member is doing, check five places before saying there is
# none, and say so only with the reason.
MMRY_FORMATION_LEAD_RULE="As the lead, keep every member working. Hand each new piece of work to a member with assign, so MMRY AI knows what it is doing; the brief can still go as a message or a file. When a member is idle or reports Done, give it its next job now. Before deciding there is none, check five places: open quality gaps on work in flight, follow-ups promised to the person, preparation for the next stage, records that do not match what was built, and a hand-back from another member waiting for review. Say there is no work only with the reason, naming what everything is waiting on. Do not do work yourself that an idle member could take; keep the coordinating, the deciding and the reviewing for yourself."
MMRY_FORMATION_MEMBER_RULE="As a member, never go idle silently: when you finish, report Done to the lead and end the report by asking whether there is anything else you can do, then keep listening for the answer."
# #34089 (DD-203 in MMRY-AI/mmry): cmo-mmry's B3 (Revision 1, wording-34088-34089-cmo.md), NO APOSTROPHES.
# A member is given it on its own line straight after the member rule; a lead is not. B3 places it after
# the existing member rules and before 34011's rules M and S, with the 34161 background-work sentence
# after all of them on Claude Code (formation-join.sh prints that sentence after this rule).
MMRY_FORMATION_PROGRESS_RULE="Report progress to the lead at each milestone of your assignment, so the lead can see the work is moving."
# #34650: cmo-mmry's approved item 2 (wording-free-release-cmo.md), NO APOSTROPHES. A member is given it
# on its own line after the milestone line; a lead is not. The approved placement is after 34011's rules
# M and S as well; until those land it follows the milestone line directly. The service holds the same
# literal in FormationRoleRule.Free (the connector join's freeRule).
MMRY_FORMATION_FREE_RULE="When you finish your work, report that you are free with a progress report, not only in a message, so the lead can give you your next job."
# #34650: cmo-mmry's approved item 1, the confirmation after a free report, NO APOSTROPHES. The service
# holds the same two sentences in FormationFreeReport (WithWork, NoWork) for the connector.
MMRY_FORMATION_FREE_DONE="Your work is recorded as Done and you are free. The lead is told, so it can give you your next job."
MMRY_FORMATION_FREE_NONE="You have no work, so you are already free. Nothing was changed."
# #34650 fix round 1: cmo-mmry's item 7, the refusal while this session's own work is reported as Blocked
# (lead ruling 2026-11-24: Done would tell the lead unfinished work is finished), NO APOSTROPHES. The
# service holds the same sentence in FormationFreeReport.Blocked for the connector.
MMRY_FORMATION_FREE_BLOCKED="Your work is reported as Blocked, so you cannot report that you are free. Nothing was changed. Keep the block reported so the lead can help you clear it or release you from the work."
MMRY_FORMATION_OFFER="Is there anything else I can do?"
# What the member that reported its own Done is shown: its report carried the question.
MMRY_FORMATION_OFFER_SENT="Your report to the lead ends with: ${MMRY_FORMATION_OFFER} Keep listening for the answer."

# The rule for a role as the roster stores it. Lead gets the lead rule; anything else, including no
# role at all, gets the member rule, then the progress rule, then the free rule (#34650), because a join
# never makes a new lead.
mmry_formation_role_rule() {
    case "${1:-}" in
        [Ll][Ee][Aa][Dd]) printf '%s\n' "$MMRY_FORMATION_LEAD_RULE" ;;
        *)                printf '%s\n%s\n%s\n' "$MMRY_FORMATION_MEMBER_RULE" "$MMRY_FORMATION_PROGRESS_RULE" "$MMRY_FORMATION_FREE_RULE" ;;
    esac
}
