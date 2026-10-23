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
# last sentence lets a member that has saved everything move on.
#
# ASCII, NO APOSTROPHES, as the report-to-lead rule (#31744): text that needs no escaping in any
# surface's literal is text that cannot drift by an escape.
#
# Other standing member prompts belong beside this one.
#
# set -euo pipefail is the repository convention for every script in this directory
# (file-integrity.bats); both handlers that source this already run under it.
set -euo pipefail

MMRY_FORMATION_SAVE_OUTCOME="Save your own outcome to MMRY now, so the next session has it: the tasks you worked on and the final state of each, what shipped, what you handed to whom, and where your notes are. If you have saved all of that since your last report, there is nothing more to save."

# Print the save prompt with this host's save route, as one line.
mmry_formation_save_outcome_prompt() {
    local route=""
    if declare -F mmry_host_command_ref >/dev/null 2>&1; then
        route="$(mmry_host_command_ref save 2>/dev/null || true)"
    fi
    if [[ -n "$route" ]]; then
        printf '%s Save it with %s.\n' "$MMRY_FORMATION_SAVE_OUTCOME" "$route"
    else
        printf '%s\n' "$MMRY_FORMATION_SAVE_OUTCOME"
    fi
}
