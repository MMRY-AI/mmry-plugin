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

# ---- Long work in the background, Claude Code members only (#34161) -------------------------------
# Held once. Printed by formation-join.sh at a Claude Code join and by formation-check.sh right after
# a delivered assignment notice. PLACEHOLDER until cmo-mmry's approved sentence (wording-34161-cmo.md)
# is wired byte for byte; tests/structural/formation-background-work.bats pins it.
MMRY_FORMATION_BACKGROUND_WORK="PLACEHOLDER 34161 awaiting approved wording: run long commands and long delegated work in the background so your lead can reach you while it runs."

# ---- Each member's availability on the roster (#33847, DD-191 in MMRY-AI/mmry) -------------------
#
# The service decides each member's state and when it began, from what MMRY AI has recorded, and
# sends the state as a plain word (availability) with its start (availabilitySince). The words are
# held once in the service (FormationAvailability); this file holds what the plugin adds around them:
# the label, the duration and the footer, each once. formation-roster.sh and formation-status.sh
# both read them from here. Cleared by cmo-mmry and approved by Eric, 2026-11-18.
#
# THE DURATION: under 60 minutes in minutes ("for 12 minutes"); from 60 minutes in hours and minutes
# ("for 1 hour", "for 2 hours 15 minutes"), singular units, no zero part (cmo-mmry follow-up,
# 2026-11-18, because the roster is often heard aloud). With no
# stored start, or under a minute, the state is shown alone ("Availability: unknown."), never
# "since unknown". A member that has left, a lead and a server that sends no availability show
# nothing, so an older server's roster reads exactly as before. A value that is not a short plain
# lowercase word is not shown at all.
#
# NO strptime AND NO BACKSLASH. jq 1.6 on Windows has no strptime, so the start is turned into
# seconds by arithmetic; and a backslash in a jq program given on the command line is not reliable
# on Windows, where MSYS rewrites it before jq.exe sees it.
MMRY_FORMATION_AVAILABILITY_FOOTER="Availability is based on the activity MMRY AI has recorded for each member in this Formation. No recent activity means the member holds no work and has shown no activity for the quiet limit; MMRY AI cannot tell why."

MMRY_JQ_AVAILABILITY_DEFS='
def mmry_iso_epoch: tostring | .[0:19] as $s
    | if ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$")) | not then null
      else ($s[0:4] | tonumber) as $y | ($s[5:7] | tonumber) as $mo | ($s[8:10] | tonumber) as $d
        | (if $mo <= 2 then $y - 1 else $y end) as $yy
        | (($yy / 400) | floor) as $era
        | ($yy - $era * 400) as $yoe
        | ((((153 * (if $mo > 2 then $mo - 3 else $mo + 9 end) + 2) / 5) | floor) + $d - 1) as $doy
        | ($yoe * 365 + (($yoe / 4) | floor) - (($yoe / 100) | floor) + $doy) as $doe
        | ($era * 146097 + $doe - 719468) * 86400
          + ($s[11:13] | tonumber) * 3600 + ($s[14:16] | tonumber) * 60 + ($s[17:19] | tonumber)
      end;
def mmry_unit($n; $one; $many): ($n | tostring) + " " + (if $n == 1 then $one else $many end);
def mmry_duration_words: ((. / 60) | floor) as $h | (. - $h * 60) as $mm
    | if $h == 0 then mmry_unit($mm; "minute"; "minutes")
      elif $mm == 0 then mmry_unit($h; "hour"; "hours")
      else mmry_unit($h; "hour"; "hours") + " " + mmry_unit($mm; "minute"; "minutes") end;
def mmry_availability_word:
    if .leftDate != null then null
    elif ((.availability // null) | type) != "string" then null
    elif (.availability | test("^[a-z][a-z ]{0,39}$")) then .availability
    else null end;
def mmry_availability_suffix:
    mmry_availability_word as $w
    | if $w == null then ""
      else ((.availabilitySince // null) | if . == null then null else mmry_iso_epoch end) as $t
        | (if $t == null then null else (((now - $t) / 60) | floor) end) as $m
        | "  Availability: " + $w
          + (if $m == null or $m < 1 then "" else ", for " + ($m | mmry_duration_words) end)
          + "."
      end;
def mmry_roster_has_availability: [(.members // [])[] | mmry_availability_word | select(. != null)] | length > 0;
'
