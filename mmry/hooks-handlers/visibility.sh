#!/usr/bin/env bash
# visibility.sh - Show or set the current user's default memory visibility (#29901).
#
# Usage:
#   bash visibility.sh                     # show the current default
#   bash visibility.sh global              # save to everyone in the organization
#   bash visibility.sh private             # save only to yourself
#   bash visibility.sh group               # list your groups so one can be chosen
#   bash visibility.sh group "Sales"       # set the default to a group by name
#
# Memories are Global by default. Group creation and membership are managed by an
# administrator in the portal; this only selects among groups you already belong to.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

if [[ -z "${MMRY_JQ:-}" ]]; then
    mmry_jq_unavailable_message
    exit 1
fi

MODE="${1:-}"
GROUP_NAME="${2:-}"

show_current() {
    if mmry_get_default_visibility; then
        local vis gid
        vis="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.visibility // "Global"')"
        gid="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.permissionGroupID // empty')"
        if [[ "$vis" == "Group" && -n "$gid" ]]; then
            local name=""
            if mmry_get_my_groups; then
                name="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r --arg id "$gid" '.[] | select((.id|tostring) == $id) | .groupName' | head -1)"
            fi
            echo "Current default: Group${name:+ (${name})}"
        else
            echo "Current default: ${vis}"
        fi
    else
        _mmry_format_error "read default visibility"
        exit 1
    fi
}

list_groups_for_choice() {
    if ! mmry_get_my_groups; then
        _mmry_format_error "list groups"
        exit 1
    fi
    local count
    count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" 'length')"
    if [[ "$count" -eq 0 ]]; then
        echo "You are not in any groups yet. Ask an account administrator to create a group"
        echo "and add you to it, then run this again to choose it."
        exit 0
    fi
    echo "Your groups:"
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r '.[] | "  - \(.groupName)"'
    echo ""
    echo "Choose one with: /mmry:visibility group \"NAME\""
}

resolve_group_id_by_name() {
    # Prints the group id for an exact (case-insensitive) name match, else empty.
    local wanted="$1"
    if ! mmry_get_my_groups; then
        _mmry_format_error "list groups"
        exit 1
    fi
    printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r --arg n "$wanted" \
        '.[] | select((.groupName|ascii_downcase) == ($n|ascii_downcase)) | .id' | head -1
}

case "$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')" in
    "")
        show_current
        ;;
    global|private)
        target="Global"
        [[ "$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')" == "private" ]] && target="Private"
        if mmry_set_default_visibility "$target"; then
            if [[ "$target" == "Private" ]]; then
                echo "Default set to Private. New memories are visible only to you until you change this."
            else
                echo "Default set to Global. New memories are shared with your organization."
            fi
        else
            _mmry_format_error "set default visibility"
            exit 1
        fi
        ;;
    group)
        if [[ -z "$GROUP_NAME" ]]; then
            list_groups_for_choice
            exit 0
        fi
        gid="$(resolve_group_id_by_name "$GROUP_NAME")"
        if [[ -z "$gid" ]]; then
            echo "No group named \"${GROUP_NAME}\" found among your groups."
            echo ""
            list_groups_for_choice
            exit 1
        fi
        if mmry_set_default_visibility "Group" "$gid"; then
            echo "Default set to the ${GROUP_NAME} group. New memories are shared with that group."
        else
            _mmry_format_error "set default visibility"
            exit 1
        fi
        ;;
    *)
        echo "Unknown option: ${MODE}"
        echo "Use: global | private | group [\"NAME\"], or no argument to show the current default."
        exit 1
        ;;
esac
