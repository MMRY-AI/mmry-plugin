#!/usr/bin/env bash
# formation-waiting.sh - tell the lead when this member is waiting on a permission prompt, and when it
# has continued (#33452, DD-187 in the API repository).
#
# WHY. A Formation member that reaches an approval prompt in its own window stops and waits for a
# person. Its progress still reads Accepted and the idle notice does not fire, because the member has
# not finished its turn, so the lead sees it working and the work stalls until somebody looks at that
# window. This sends one signal per prompt; the service records it and tells the lead.
#
# TWO WAYS IN, ONE PAYLOAD READ:
#   Claude Code  the Notification hook, notification_type "permission_prompt". The payload carries no
#                tool field, only a sentence ("Claude needs your permission to use Bash"); the tool's
#                name is the one bare word after "permission to use", or nothing.
#   Codex        the PermissionRequest hook (Codex CLI 0.165.0 and later): tool_name is in the payload.
#                CODEX READS THIS HOOK'S STDOUT AS AN APPROVAL DECISION, so this handler prints
#                NOTHING, ever: no stdout, no stderr. An empty answer leaves Codex's own prompt in place.
# Every other notification (idle_prompt, auth_success, ...) and every other event: nothing happens.
#
# WHAT IS SENT (requirement 4). The member's own session id and the bare name of the tool asking:
# letters, digits and _ . : - only, at most 64 characters, or no name at all. Never the command, its
# arguments, a path, a file's contents or anything else of the prompt. The service refuses anything
# that is not a bare name, and its table cannot store one.
#
# WHO IS SENT. Only a member: a session in no formation makes no call at all (one file test), and a
# lead's own prompt makes none, because there is nobody to tell.
#
# ONE CALL PER PROMPT. A marker file, .mmry-waiting-<session>, records "formation member" once the
# service has the flag. While it is there no second call is made. formation-check.sh, which runs on
# the member's next tool call, prompt and turn end, sees the marker and runs this with --clear, which
# asks the service to clear the flag and removes the marker. Not named .mmry-formation-*, which the
# hook gates would take for a membership record.
#
# FAIL OPEN AND SILENT, like formation-check.sh: any error, missing tool or unreachable service is
# exit 0 with nothing said. A prompt signal that broke a session would be worse than none.
#
# USAGE
#   (hook)  formation-waiting.sh            reads the hook payload on stdin
#   (clear) formation-waiting.sh --clear SESSION_ID
set -euo pipefail
trap 'exit 0' ERR
exec 2>/dev/null

HANDLER_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HANDLER_DIR" == "${BASH_SOURCE[0]}" ]] && HANDLER_DIR="."
MMRY_TMPDIR="${TMPDIR:-/tmp}"

# The bare tool name rule, the same set as the service's FormationWaitingNotice.IsToolName and the
# table's CK_FormationMemberWaiting_ToolName. Bash 3.2 [[ =~ ]] (ERE).
_MMRY_WAITING_TOOL_RE='^[A-Za-z0-9_.:-]{1,64}$'
# A session id this handler keys a marker by: the shape every Claude Code and Codex id has. Anything
# else gets no marker and no call, so a marker name can never be built from unusual text.
_MMRY_WAITING_SID_RE='^[A-Za-z0-9._-]{1,100}$'

_mmry_waiting_marker() { MMRY_WAITING_MARKER="${MMRY_TMPDIR}/.mmry-waiting-$1"; }

# Load what a call needs: the host resolver, the credential check, jq and the client. Returns 1 when
# anything is missing, and the caller exits 0.
_mmry_waiting_load() {
    [[ -f "${HANDLER_DIR}/lib-host.sh" ]] || return 1
    source "${HANDLER_DIR}/lib-host.sh" || return 1
    mmry_host_assert_own_credential || return 1
    source "${HANDLER_DIR}/mmry-client.sh" || return 1
    command -v curl >/dev/null 2>&1 || return 1
    mmry_load_config || return 1
    # Each request may take 3 seconds at most: the registrations allow 15 and there are two requests.
    MMRY_HTTP_CONNECT_TIMEOUT=3
    MMRY_HTTP_MAX_TIME=3
    [[ -n "${MMRY_JQ:-}" ]] || mmry_resolve_jq >/dev/null || return 1
    [[ -n "${MMRY_JQ:-}" ]]
}

# ---- --clear: the member has continued ------------------------------------------------------
if [[ "${1:-}" == "--clear" ]]; then
    sid="${2:-}"
    [[ "$sid" =~ $_MMRY_WAITING_SID_RE ]] || exit 0
    _mmry_waiting_marker "$sid"
    [[ -f "$MMRY_WAITING_MARKER" ]] || exit 0
    fid="" mid=""
    { read -r fid mid || true; } < "$MMRY_WAITING_MARKER"
    if ! [[ "$fid" =~ ^[0-9]+$ && "$mid" =~ ^[0-9]+$ ]]; then
        rm -f "$MMRY_WAITING_MARKER"; exit 0
    fi
    _mmry_waiting_load >/dev/null || exit 0
    mmry_clear_formation_member_waiting "$fid" "$mid" "$sid" >/dev/null || true
    # Cleared (2xx), or the service will never accept this clear (the member left, the formation
    # closed, the entry is not this session's): the marker goes. No answer, a 5xx or a 429: it stays,
    # and the member's next event asks again.
    case "${MMRY_HTTP_CODE:-000}" in
        2??|400|403|404) rm -f "$MMRY_WAITING_MARKER" ;;
    esac
    exit 0
fi

# ---- the hook: a permission prompt is showing ------------------------------------------------
[[ ! -t 0 ]] || exit 0
[[ -f "${HANDLER_DIR}/lib-hookread.sh" ]] || exit 0
source "${HANDLER_DIR}/lib-hookread.sh" || exit 0
mmry_read_hook_payload "${MMRY_HOOK_READ_TIMEOUT:-2}" || true
payload="${MMRY_HOOK_PAYLOAD:-}"
[[ -n "$payload" ]] || exit 0

# Cheap refusals first, without a process: is this one of the two events, and is it a prompt?
case "$payload" in
    *'"PermissionRequest"'*|*'"permission_prompt"'*) ;;
    *) exit 0 ;;
esac

[[ -f "${HANDLER_DIR}/lib-host.sh" ]] || exit 0
source "${HANDLER_DIR}/lib-host.sh" || exit 0
mmry_host_assert_own_credential || exit 0
source "${HANDLER_DIR}/lib-jq.sh" || exit 0
mmry_resolve_jq >/dev/null || exit 0
[[ -n "${MMRY_JQ:-}" ]] || exit 0

# Five fields in one jq call, joined by the ASCII unit separator (0x1F), each with that character and
# line breaks removed, so a crafted value cannot shift the fields after it. NOT a tab: a tab is IFS
# whitespace, so read collapses empty fields and every later field moves one place left (seen red: the
# tool name arrived empty on every event). The message is reduced here to the one word after
# "permission to use", so the rest of the sentence never reaches a shell variable.
_fields='[(.session_id // "" | tostring), (.hook_event_name // "" | tostring),
          (.notification_type // "" | tostring), (.tool_name // "" | tostring),
          ((.message // "" | tostring) | (capture("permission to use (?<t>[^ ]+)") // {t: ""}) | .t)]
         | map(gsub("[\u001f\r\n]"; " ")) | join("\u001f")'
parsed="$("$MMRY_JQ" -r "$_fields" <<< "$payload" || true)"
[[ "$parsed" == *$'\037'* ]] || exit 0
IFS=$'\037' read -r sid event ntype ptool mtool <<< "$parsed" || true

tool=""
case "$event" in
    Notification)
        [[ "$ntype" == "permission_prompt" ]] || exit 0
        tool="$mtool" ;;
    PermissionRequest)
        tool="$ptool" ;;
    *) exit 0 ;;
esac
# A name that is not bare is dropped, never trimmed into one.
[[ "$tool" =~ $_MMRY_WAITING_TOOL_RE ]] || tool=""

[[ -n "$sid" ]] || sid="$(mmry_session_id || true)"
[[ "$sid" =~ $_MMRY_WAITING_SID_RE ]] || exit 0

# A member at all? One file test, and a session in no formation stops here with no call.
[[ -f "${HANDLER_DIR}/formation-state.sh" ]] || exit 0
source "${HANDLER_DIR}/formation-state.sh" || exit 0
mmry_formation_state_read "$sid" || exit 0
fid="$MMRY_FS_FORMATION"
[[ "$fid" =~ ^[0-9]+$ ]] || exit 0

# Already reported for this prompt: no second call.
_mmry_waiting_marker "$sid"
[[ ! -f "$MMRY_WAITING_MARKER" ]] || exit 0

_mmry_waiting_load >/dev/null || exit 0

# This session's own live entry and its role, from the roster (as formation-progress.sh finds it).
mmry_get_formation "$fid" >/dev/null || exit 0
own="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" -r --arg s "$sid" \
    '[(.members // [])[] | select(.sessionId == $s and .leftDate == null)][0] | "\(.id // "") \(.role // "")"' || true)"
mid="${own%% *}"; role="${own#* }"
[[ "$mid" =~ ^[0-9]+$ ]] || exit 0
# A lead's own prompt: nobody to tell.
[[ "$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" != "lead" ]] || exit 0

if mmry_set_formation_member_waiting "$fid" "$mid" "$sid" "$tool" >/dev/null; then
    printf '%s %s\n' "$fid" "$mid" > "$MMRY_WAITING_MARKER" || true
fi
exit 0
