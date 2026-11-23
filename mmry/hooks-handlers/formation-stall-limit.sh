#!/usr/bin/env bash
# formation-stall-limit.sh - read or set the Formation's progress limit (#34089, DD-203 in MMRY-AI/mmry).
#
# How long a member with an assignment can go without progress before the lead is told: 5 to 1440
# minutes, 5 by default. Progress is a progress report, a declared area, a new assignment or the member
# doing work on its task; messages do not count. Any member can read the limit; only the lead, the
# person who created the Formation or an account administrator can set it, and the server decides that
# (usp_Mnemo_SetFormationStallLimit). The refusals and the success sentence are the server's, cmo-mmry's
# approved wording (wording-34088-34089-cmo.md C4 to C6, Revision 1's range), printed as they come.
#
# A copy of formation-idle-limit.sh's pattern (#34432). The command is /mmry:formation progress-limit
# (C1); its route in commands/formation.md, the Codex skills and the tool in mcp-server.sh follow once
# Seat A's change to those files merges.
#
# THIS DOES NOT FAIL OPEN (formation-remove.sh's rule): it runs because somebody asked and is waiting
# to know whether it worked, so a refusal prints the reason and exits non-zero.
#
# Usage: formation-stall-limit.sh            the current limit
#        formation-stall-limit.sh <minutes>  set it, 5 to 1440
#        formation-stall-limit.sh default    back to 5 minutes
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"
mmry_formation_command  # #34285: an upgrade refusal ends this command with its sentence, once

# cmo-mmry C2 (Revision 1), the help line naming all three forms, {stall_default} = 5.
STALL_LIMIT_HELP="progress-limit <minutes> sets how long a member with an assignment can go without progress before the lead is told, from 5 to 1440 minutes (5 by default). Use progress-limit default to go back to 5, or progress-limit alone to see the current limit."
# cmo-mmry C4 (Revision 1), out of range. The server says the same; this answers before asking it.
STALL_LIMIT_RANGE="The progress limit is between 5 and 1440 minutes. Leave it unset to use the default of 5 minutes."
STALL_DEFAULT_SECONDS=300

arg="${1:-}"
mode="read"
minutes=""
case "$arg" in
    "") mode="read" ;;
    default) mode="set"; minutes="null" ;;
    -h|--help|help) echo "$STALL_LIMIT_HELP"; exit 0 ;;
    *)
        if [[ "$arg" =~ ^[0-9]{1,6}$ ]]; then
            minutes="$((10#$arg))"
            if (( minutes < 5 || minutes > 1440 )); then echo "$STALL_LIMIT_RANGE"; exit 1; fi
            mode="set"
        else
            echo "$STALL_LIMIT_HELP"
            exit 1
        fi
        ;;
esac

session_id="$(mmry_session_id)"
state=""
if [[ -n "$session_id" ]]; then
    state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
fi
if [[ -z "$state" ]]; then
    echo "This session is not in a Formation, so it has no progress limit. Run $(mmry_host_formation_ref list) to see what is active."
    exit 1
fi
formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run $(mmry_host_formation_ref leave) and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so the progress limit cannot be reached."
    exit 1
fi

# The set call. mmry-client.sh is held by another change this round, so the request is made here with
# the client's own transport; it moves into the client as mmry_set_formation_stall_limit after that
# merges, beside mmry_set_formation_idle_limit.
_set_stall_limit() {
    local fid="$1" value="$2"
    [[ "$value" =~ ^([0-9]{1,6}|null)$ ]] || return 1
    _mmry_request PUT "/api/formations/${fid}/stall-limit" "{\"minutes\":${value}}"
}

# The sentence for an effective limit in seconds, "1 minute" for one. A change says "is now" (C6); a
# read says "is", since nothing changed.
sentence() {
    local m=$(( $1 / 60 )) verb="$2"
    if (( m == 1 )); then echo "This Formation's progress limit ${verb} 1 minute."; else echo "This Formation's progress limit ${verb} ${m} minutes."; fi
}
clean() { printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | tr '\n\t' '  ' | cut -c1-500; }

if [[ "$mode" == "read" ]]; then
    ok=0; mmry_get_formation "$formation_id" "$session_id" && ok=1
else
    ok=0; _set_stall_limit "$formation_id" "$minutes" && ok=1
fi

if (( ok == 0 )); then
    code="${MMRY_HTTP_CODE:-0}"
    server_said=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.error // .message // (.errors // {} | [.[]] | flatten | join(" ")) // empty' 2>/dev/null || true)"
    fi
    case "$code" in
        400|403) [[ -n "$server_said" ]] && echo "$(clean "$server_said")" || echo "MMRY AI refused the change (HTTP ${code}). Nothing was changed." ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Nothing was changed." ;;
        *)   echo "MMRY AI did not answer (HTTP ${code}), so nothing is confirmed. Run $(mmry_host_formation_ref progress-limit) to check the limit before trying again." ;;
    esac
    exit 1
fi

seconds=""
if [[ -n "${MMRY_JQ:-}" ]]; then
    if [[ "$mode" == "read" ]]; then
        seconds="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '.stallNoticeAfterSeconds // empty' 2>/dev/null | tr -d '\r' || true)"
    else
        said="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '.message // empty' 2>/dev/null | tr -d '\r' || true)"
        if [[ -n "$said" ]]; then echo "$(clean "$said")"; exit 0; fi
        seconds="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '.stallNoticeAfterSeconds // empty' 2>/dev/null | tr -d '\r' || true)"
    fi
fi
# A server whose Formation answer carries no progress limit reports the default.
[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=$STALL_DEFAULT_SECONDS
if [[ "$mode" == "read" ]]; then sentence "$seconds" "is"; else sentence "$seconds" "is now"; fi
exit 0
