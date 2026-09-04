#!/usr/bin/env bash
# formation-claim.sh - declare the area this session is about to work, so two members are warned
#                      before they collide (#31044).
#
# WHY THIS EXISTS. Nothing noticed when two members were working the same thing, which is the
# specific waste a formation exists to remove. On a release with five members that is the
# difference between a coordinated run and five people editing one file.
#
# WHAT IS DECLARED, AND WHY IT IS NOT THE ASSIGNMENT. Two structured values a session states on
# purpose: a repository and a path prefix. What a member is working on IN PROSE is never matched.
# Guessing from prose whether two people are in each other's way produces warnings that are wrong,
# and a coordination feature that cries wolf is ignored on the day it is right.
#
# THE REPOSITORY IS DERIVED, NOT TYPED. Two members who spell one repository differently are never
# warned about each other, and nothing detects that they have. git rev-parse gives every session
# working the same checkout the same answer, which is what makes the comparison mean anything.
#
# WARNED, NOT BLOCKED. Two sessions legitimately touch one file during a rebase, so declaring an
# overlapping area succeeds. Both sides are told and the lead decides.
#
# THIS DOES NOT FAIL OPEN, the same rule formation-say.sh follows: somebody asked and is waiting.
#
# Usage:
#   formation-claim.sh <path> [repository]     declare an area
#   formation-claim.sh --list                  what the formation is holding
#   formation-claim.sh --release <claimId>     release one of YOUR OWN areas
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HANDLER_DIR}/mmry-client.sh"

mode="declare"
arg1="${1:-}"
case "$arg1" in
    --list)    mode="list"; shift || true ;;
    --release) mode="release"; shift || true ;;
esac

session_id="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"  # the command runtime provides CLAUDE_CODE_SESSION_ID (#31143)
if [[ -z "$session_id" ]]; then
    echo "No session id is available, so there is no area to declare. This needs to run inside a session."
    exit 1
fi

state="$(bash "${HANDLER_DIR}/formation-state.sh" get "$session_id" 2>/dev/null || true)"
if [[ -z "$state" ]]; then
    echo "This session is not in a formation, so there is nobody to deconflict with. Run /mmry:formation list to see what is active, then /mmry:formation join <id>."
    exit 1
fi

formation_id="${state%% *}"
if ! [[ "$formation_id" =~ ^[0-9]+$ ]]; then
    echo "The local formation state is not a number, so it cannot be trusted. Run /mmry:formation leave and join again."
    exit 1
fi

mmry_load_config || true

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not available, so nothing can be declared."
    exit 1
fi

# ---------------------------------------------------------------- list
if [[ "$mode" == "list" ]]; then
    if ! mmry_get_formation_claims "$formation_id" "$session_id"; then
        if [[ "${MMRY_HTTP_CODE:-0}" == "000" ]]; then
            echo "Could not reach the service. ${MMRY_RESPONSE:-}"
        else
            echo "Could not read the declared areas for formation ${formation_id} (HTTP ${MMRY_HTTP_CODE:-0})."
        fi
        exit 1
    fi

    if [[ -z "${MMRY_JQ:-}" ]]; then
        echo "$MMRY_RESPONSE"
        exit 0
    fi

    count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r 'if type == "array" then length else 0 end' 2>/dev/null || printf '0')"
    if [[ "$count" == "0" ]]; then
        # An empty list is also what a session that is not a current member is given, on purpose,
        # so this may not report it as "nobody has declared anything" with any confidence.
        echo "No declared areas came back for formation ${formation_id}. Either nobody has declared one, or this session is no longer a current member of it."
        exit 0
    fi

    printf 'Declared areas in formation %s:\n\n' "$formation_id"
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
        .[] | "  " + (.claimId | tostring)
              + "  member " + (.memberId | tostring)
              + "  " + (.repository // "?")
              + " :: " + (.pathPrefix // "?")' 2>/dev/null || { echo "$MMRY_RESPONSE"; exit 0; }
    printf '\nRelease one of your own with /mmry:formation claim --release <id>. Leaving the formation\n'
    printf 'releases all of yours on its own.\n'
    exit 0
fi

# ---------------------------------------------------------------- release
if [[ "$mode" == "release" ]]; then
    claim_id="${1:-}"
    if ! [[ "$claim_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "Which area? A claim id is a positive whole number from /mmry:formation claim --list. Nothing was released."
        exit 1
    fi

    if ! mmry_release_formation_claim "$formation_id" "$claim_id" "$session_id"; then
        code="${MMRY_HTTP_CODE:-0}"
        server_said=""
        if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
            server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.message // .error // empty' 2>/dev/null || true)"
        fi
        case "$code" in
            # One answer covers an id that does not exist, one belonging to another member, one in
            # another formation and one already released. The server does not distinguish them on
            # purpose, so this does not invent a distinction either.
            400) echo "Nothing was released. ${server_said:-This session holds no such live area. Run /mmry:formation claim --list.}" ;;
            403) echo "Refused, and nothing was released. This session is not a current member of formation ${formation_id}, or the formation has been closed out." ;;
            *)   echo "Could not release area ${claim_id} (HTTP ${code}). The server did not confirm it, so treat it as still held." ;;
        esac
        exit 1
    fi

    echo "Released area ${claim_id}. It no longer collides with anybody, and nobody was notified: a release is not news."
    exit 0
fi

# ---------------------------------------------------------------- declare
path_prefix="${1:-}"
repository="${2:-}"

if [[ -z "$path_prefix" ]]; then
    echo "Which area? Usage: /mmry:formation claim \"src/Billing\". Use . for the whole repository if that is really what you mean."
    exit 1
fi

if [[ -z "$repository" ]]; then
    # DERIVED, NOT ASKED FOR. Two members who type the repository differently are never warned
    # about each other, and nothing detects that they have not been; the git root's name is the
    # value every session on the same checkout agrees on. The working directory's name is the
    # fallback, which is right often enough to be worth having and is why the value is echoed back
    # below rather than assumed.
    repository="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")")"
fi

if [[ -z "$repository" ]]; then
    echo "Could not work out which repository this is, and an area needs one: the same path in two different repositories is not a collision. Pass it: /mmry:formation claim \"<path>\" \"<repository>\"."
    exit 1
fi

if ! mmry_add_formation_claim "$formation_id" "$session_id" "$repository" "$path_prefix"; then
    code="${MMRY_HTTP_CODE:-0}"
    server_said=""
    if [[ -n "${MMRY_RESPONSE:-}" && -n "${MMRY_JQ:-}" ]]; then
        server_said="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.message // .error // empty' 2>/dev/null || true)"
    fi
    case "$code" in
        # Blank, carrying a control character, or a fifty-first area. The server names which, and
        # this passes it through rather than guessing: #31195 is the record of what a wrong
        # explanation costs the person reading it.
        400) echo "The server refused the area, and nothing was declared. ${server_said}" ;;
        403) echo "Refused, and nothing was declared. This session is not a current member of formation ${formation_id}, or the formation has been closed out. Run /mmry:formation join ${formation_id} from this window." ;;
        404) echo "Formation ${formation_id} no longer exists, or it belongs to another account. Run /mmry:formation leave." ;;
        502|503|504) echo "The server failed while handling the area (HTTP ${code}) and did not confirm it, so treat it as not declared. This is a fault on the server side, not something about formation ${formation_id} or your standing in it." ;;
        *)   echo "Could not declare that area in formation ${formation_id} (HTTP ${code}). The server did not confirm it, so treat it as not declared." ;;
    esac
    exit 1
fi

if [[ -z "${MMRY_JQ:-}" ]]; then
    echo "Declared. The server accepted the area, and whether it overlaps anybody could not be read from here without jq."
    exit 0
fi

is_new="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.isNew // false' 2>/dev/null || printf 'false')"
overlap_count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '(.overlaps // []) | length' 2>/dev/null || printf '0')"
[[ "$overlap_count" =~ ^[0-9]+$ ]] || overlap_count=0

if [[ "$is_new" == "true" ]]; then
    printf 'Declared %s :: %s in formation %s.\n' "$repository" "$path_prefix" "$formation_id"
else
    # Reported rather than hidden: re-declaring is deliberately not news, and a caller that
    # believed it had just warned somebody would be wrong.
    printf 'Already declared: %s :: %s in formation %s. Nothing was sent, because nothing changed.\n' \
        "$repository" "$path_prefix" "$formation_id"
fi

if [[ "$overlap_count" -eq 0 ]]; then
    printf 'Nobody else has declared an overlapping area.\n'
    exit 0
fi

printf '\nThis overlaps %s declared area(s):\n' "$overlap_count"
printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '
    (.overlaps // [])[] | "  member " + (.otherMemberId | tostring)
                          + "  " + (.otherRepository // "?")
                          + " :: " + (.otherPathPrefix // "?")' 2>/dev/null || true

# What this may and may not claim. The server warned both sides when the area was NEW; on a
# re-declaration it warned nobody, and saying otherwise would leave a member believing somebody
# had been told when they had not.
if [[ "$is_new" == "true" ]]; then
    printf '\nBoth you and each of those members have been told, each privately. Nothing is blocked:\n'
else
    printf '\nNobody was told this time, because this area was already declared. Nothing is blocked:\n'
fi
printf 'an overlap means two declared paths overlap as text, not that you are editing the same\n'
printf 'file. Agree who takes it, or carry on if you are not in fact in each other'"'"'s way.\n'
exit 0
