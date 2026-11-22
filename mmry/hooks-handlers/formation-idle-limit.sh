#!/usr/bin/env bash
# formation-idle-limit.sh - read or set the Formation's idle limit (#34432, DD-200 in MMRY-AI/mmry).
#
# How long a member of this Formation can have no work before the lead is reminded: 1 to 1440 minutes,
# 15 by default. Any member can read it; only the lead, the person who created the Formation or an
# account administrator can set it, and the server decides that (usp_Mnemo_SetFormationIdleLimit). The
# refusals and the success sentence are the server's, cmo-mmry's approved wording
# (copy-34432-cmo-approved.md item 9), printed as they come.
#
# THIS DOES NOT FAIL OPEN (formation-remove.sh's rule): it runs because somebody asked and is waiting
# to know whether it worked, so a refusal prints the reason and exits non-zero.
#
# Usage: formation-idle-limit.sh            the current limit
#        formation-idle-limit.sh <minutes>  set it, 1 to 1440
#        formation-idle-limit.sh default    back to 15 minutes
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"
mmry_formation_command  # #34285: an upgrade refusal ends this command with its sentence, once

# cmo-mmry item 12, approved 2026-11-21: the help line, naming all three forms.
IDLE_LIMIT_HELP="idle-limit <minutes> sets how long a member of this Formation can have no work before the lead is reminded, from 1 to 1440 minutes (15 by default). Use idle-limit default to go back to 15, or idle-limit alone to see the current limit."
# cmo-mmry item 9, out of range. The server says the same; this answers before asking it.
IDLE_LIMIT_RANGE="The idle limit is between 1 and 1440 minutes. Leave it unset to use the default of 15 minutes."

arg="${1:-}"
mode="read"
minutes=""
case "$arg" in
    "") mode="read" ;;
    default) mode="set"; minutes="null" ;;
    -h|--help|help) echo "$IDLE_LIMIT_HELP"; exit 0 ;;
    *)
        if [[ "$arg" =~ ^[0-9]{1,6}$ ]]; then
            minutes="$((10#$arg))"
            if (( minutes < 1 || minutes > 1440 )); then echo "$IDLE_LIMIT_RANGE"; exit 1; fi
            mode="set"
        else
            echo "$IDLE_LIMIT_HELP"
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
    echo "This session is not in a Formation, so it has no idle limit. Run $(mmry_host_formation_ref list) to see what is active."
    exit 1
fi
formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run $(mmry_host_formation_ref leave) and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so the idle limit cannot be reached."
    exit 1
fi

# The sentence for an effective limit in seconds, "1 minute" for one. A change says "is now" (cmo-mmry
# item 9, success); a read says "is" (cmo-mmry D4, approved 2026-11-22), since nothing changed.
sentence() {
    local m=$(( $1 / 60 )) verb="$2"
    if (( m == 1 )); then echo "This Formation's idle limit ${verb} 1 minute."; else echo "This Formation's idle limit ${verb} ${m} minutes."; fi
}
clean() { printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | tr '\n\t' '  ' | cut -c1-500; }

if [[ "$mode" == "read" ]]; then
    ok=0; mmry_get_formation "$formation_id" "$session_id" && ok=1
else
    ok=0; mmry_set_formation_idle_limit "$formation_id" "$minutes" && ok=1
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
        *)   echo "MMRY AI did not answer (HTTP ${code}), so nothing is confirmed. Run $(mmry_host_formation_ref idle-limit) to check the limit before trying again." ;;
    esac
    exit 1
fi

seconds=""
if [[ -n "${MMRY_JQ:-}" ]]; then
    if [[ "$mode" == "read" ]]; then
        seconds="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '.idleNoticeAfterSeconds // empty' 2>/dev/null | tr -d '\r' || true)"
    else
        said="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '.message // empty' 2>/dev/null | tr -d '\r' || true)"
        if [[ -n "$said" ]]; then echo "$(clean "$said")"; exit 0; fi
        seconds="$(printf '%s' "${MMRY_RESPONSE:-}" | "$MMRY_JQ" -r '.idleNoticeAfterSeconds // empty' 2>/dev/null | tr -d '\r' || true)"
    fi
fi
# A server from before the per-Formation limit reports no number: its limit is the default.
[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=900
if [[ "$mode" == "read" ]]; then sentence "$seconds" "is"; else sentence "$seconds" "is now"; fi
exit 0
