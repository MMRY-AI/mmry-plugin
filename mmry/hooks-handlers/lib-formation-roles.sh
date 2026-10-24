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

MMRY_FORMATION_LEAD_RULE="As the lead, delegate and check in: when a member is idle or reports Done, give it the next piece of work or tell it there is none, and do not do work yourself that an idle member could take. Keep for yourself the coordinating, the deciding and the reviewing."
MMRY_FORMATION_MEMBER_RULE="As a member, never go idle silently: when you finish, report Done to the lead and end the report by asking whether there is anything else you can do, then keep listening for the answer."
MMRY_FORMATION_OFFER="Is there anything else I can do?"
# What the member that reported its own Done is shown: its report carried the question.
MMRY_FORMATION_OFFER_SENT="Your report to the lead ends with: ${MMRY_FORMATION_OFFER} Keep listening for the answer."

# The rule for a role as the roster stores it. Lead gets the lead rule; anything else, including no
# role at all, gets the member rule, because a join never makes a new lead.
mmry_formation_role_rule() {
    case "${1:-}" in
        [Ll][Ee][Aa][Dd]) printf '%s\n' "$MMRY_FORMATION_LEAD_RULE" ;;
        *)                printf '%s\n' "$MMRY_FORMATION_MEMBER_RULE" ;;
    esac
}
