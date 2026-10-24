#!/usr/bin/env bash
# lib-formation-prompts.sh - the standing prompts a formation member is shown, held once (#32682).
#
# WHY THIS FILE EXISTS. On 2026-10-22, in the formation running the 1.30.1 release, a member
# recorded Done, sent its handover and left without saving anything to MMRY, and the person running
# the work had to ask whether its progress was saved. Only the lead's close-out saved anything, and
# that is the formation's account, not each member's own outcome.
#
# ONE TEXT, EVERY SURFACE. The prompt below is printed by formation-leave.sh on a completed leave
# and by formation-progress.sh when this session records its own Done or Abandoned, on Claude Code
# and on Codex (Codex runs the same scripts through its tool server). The connector holds the same
# literal in MMRY-AI/mmry src/Mnemo.Api/Services/FormationMemberPrompts.cs, and the command page and
# the Codex skill quote it. tests/structural/formation-save-outcome.bats pins every copy.
#
# ONLY THE SAVE ROUTE DIFFERS BY HOST, and it is derived, never spelled out here:
# mmry_host_command_ref save is /mmry:save on Claude Code and the mmry_plugin memory_save tool on
# Codex (codex-customer-strings.bats sweeps for a hand-written command).
#
# NOT A GATE AND NOT STORED (DD-156). Printing it makes no call and changes no exit code. It is
# shown every time, even to a member that has already saved: the plugin cannot see every save route
# a member has, and a prompt wrongly withheld loses the outcome, which is the defect this fixes. Its
# last sentence, which follows the save route, lets a member that has saved everything move on.
#
# ASCII, NO APOSTROPHES, as the report-to-lead rule (#31744): text that needs no escaping in any
# surface's literal is text that cannot drift by an escape.
#
# Other standing member prompts belong beside this one.
#
# set -euo pipefail is the repository convention for every script in this directory
# (file-integrity.bats); both handlers that source this already run under it.
set -euo pipefail

# The prompt is three sentences: the ask, the save route ("Use <route>."), then the skip sentence.
# The skip sentence is last, never before the route: a route that follows "skip this" reads as a
# contradiction.
MMRY_FORMATION_SAVE_OUTCOME_ASK="Save what you did before you go: tasks and their status, what shipped, handoffs, and where your notes are."
MMRY_FORMATION_SAVE_OUTCOME_SKIP="Skip this if you already saved it."

# Print the save prompt with this host's save route between the ask and the skip sentence, as one
# line. The route is derived from the host, then shortened on Codex to "the memory_save tool", the
# form Eric approved (#32682); the host reference says "the mmry_plugin memory_save tool".
mmry_formation_save_outcome_prompt() {
    local route=""
    if declare -F mmry_host_command_ref >/dev/null 2>&1; then
        route="$(mmry_host_command_ref save 2>/dev/null || true)"
    fi
    if [[ -n "$route" ]]; then
        route="${route/the mmry_plugin /the }"
        printf '%s Use %s. %s\n' "$MMRY_FORMATION_SAVE_OUTCOME_ASK" "$route" "$MMRY_FORMATION_SAVE_OUTCOME_SKIP"
    else
        printf '%s %s\n' "$MMRY_FORMATION_SAVE_OUTCOME_ASK" "$MMRY_FORMATION_SAVE_OUTCOME_SKIP"
    fi
}
