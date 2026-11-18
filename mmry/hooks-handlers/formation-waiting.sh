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
#                name is the one bare word after "permission to use", or for an MCP tool the name
#                built from the sentence (THE TOOL'S NAME below, #33898), or nothing.
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
# service has the flag. While it is there no second call is made for the same prompt.
# formation-check.sh, which runs on the member's next tool call, prompt and turn end, sees the marker
# and runs this with --clear, which asks the service to clear the flag and removes the marker. Not
# named .mmry-formation-*, which the hook gates would take for a membership record.
#
# A MARKER NEVER OUTLIVES ITS PROMPT (#33901). A marker left behind used to silence every later prompt
# in that session, so the lead was never told again. The marker now says which prompt it is for:
#   line 1   "<formationId> <memberId>"     unchanged; --clear reads only this line
#   line 2   "prompt <key> <epoch>"          key: Codex "codex:<turn_id>:<tool>", Claude Code "cc"
#   then     "asker <agent|->", "tool <name|->", "input <sha256|->", "turn <id|->"   who asked, for
#            which call (#33900, WHICH PROMPT and WHICH CALL below); "-" is the main thread or unknown
#   last     "answered <epoch>"              written by --clear BEFORE it asks the service
# A raise treats a marker as left over from an earlier prompt, and replaces it with one call, when it
# names another formation, when a clear was already attempted for it (its prompt was answered and only
# the service failed to confirm), or when Codex names another turn or another tool. Codex's
# PermissionRequest carries no tool_use_id (codex-rs hooks/src/schema.rs: only PreToolUse and
# PostToolUse have one), so its turn_id and tool_name are the prompt's key. Claude Code's Notification
# carries nothing that tells one prompt from the next, so its line 2 records only the time, and the
# answered line is what tells them apart. Two reports of ONE prompt still make one call: nothing
# between them stamps the marker answered, and their key is the same.
# Not by age: an approval can rightly stay open for hours, and re-reporting it would tell the lead twice.
# The two other ways a marker is left behind remove it outright, with no call (--forget):
#   a session start   formation-check.sh on SessionStart: no prompt of an earlier process is still open
#   leaving           formation-leave.sh; formation-remove.sh when the entry removed is this session's
#                     own; formation-debrief.sh when the formation is closed out
#
# FAIL OPEN AND SILENT, like formation-check.sh: any error, missing tool or unreachable service is
# exit 0 with nothing said. A prompt signal that broke a session would be worse than none.
#
# USAGE
#   (hook)   formation-waiting.sh                reads the hook payload on stdin
#   (clear)  formation-waiting.sh --clear SESSION_ID
#   (forget) formation-waiting.sh --forget SESSION_ID   remove the marker; ask the service nothing
#   (answer) formation-waiting.sh --answer SESSION_ID [EVENT] [MODE]   from formation-check.sh
#   (hook)   formation-waiting.sh --answer-hook         a stop hook; the session from the payload
#   (ask)    formation-waiting.sh --ask                 Claude Code's PermissionRequest hook
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

# ---- THE TOOL'S NAME (#33898) -----------------------------------------------------------------
# Claude Code's sentence (2.1.322, read from the client) is "Claude needs your permission to use X",
# where X is the tool's display name. For a built-in tool that is its name (Bash, Write). For an MCP
# tool it is "<server> - <title or name> (MCP)": the server as configured (a plugin's server is
# plugin:<plugin>:<server>) and the tool's annotation title when it has one, its name otherwise. The
# first word, which is all this used to take, is therefore the SERVER, and the lead was told "mmry".
#
# The name sent for an MCP tool is the one Claude Code itself uses, in permission settings and in
# every PostToolUse: mcp__<server>__<tool>, the server with every character outside A-Z a-z 0-9 _ -
# made "_" (and, for a "claude.ai " server, runs of "_" made one and the ends trimmed), as Claude Code
# builds it. Wording approved by cmo-mmry 2026-11-17 (33898-wording-cmo-verdict.md): the shipped
# sentence "The tool asking is <name>." stays; no new customer sentence.
#   1. The part after " - " is a plain name: the sentence builds mcp__<server>__<it>.
#   2. That name is sent only when the transcript the payload names ties it to THIS prompt (QA finding
#      C1, lead 439's ruling 2026-11-18): the call with that name is STILL WAITING (no tool_result
#      carries its id) and it is the ONLY still-waiting call of that server in the transcript
#      (_mmry_waiting_open_call). The part after " - " may be a title, and a one-word title can build
#      the real name of ANOTHER tool of the server, or a name that is no tool at all; neither is the
#      one still-waiting call, so neither is sent. The transcript only confirms; it never supplies a
#      name of its own: not "the latest" call, not one of two parallel calls. A subagent's prompt
#      names the MAIN transcript while its calls are in the subagent's own, so it gets no name.
#      Calls are read by parsing each line as JSON, never by matching text in a call's input.
#   3. Anything else (no " - ", text after "(MCP)", a title, no readable transcript, no still-waiting
#      call of that name, two or more still-waiting calls of that server, or a built name that breaks
#      the field rule) sends NO name, and the lead's sentence is left out, exactly as when no name
#      arrives (the cmo-mmry fallback). Never a cut or cleaned name: a shortened name could name the
#      wrong tool. Where Claude Code fired its PermissionRequest hook, 33900's ask record can give an
#      MCP tool's exact name, but only under the same test: it must be the one still-waiting call of
#      its server (_mmry_waiting_record_name). A record never supplies a name on its own; a record
#      that disagrees with the sentence and is not confirmed sends no name.
# Codex's PermissionRequest carries tool_name itself, and for an MCP tool it is already
# mcp__<server>__<tool> (the Codex CLI's own naming rule), so it passes through the same field rule.
#
# This jq turns the message into [name, mcp-prefix]; mmry_waiting_tool_name finishes the job. 33900
# reuses both, so the name the marker records is the name the asked tool's PostToolUse carries.
_MMRY_WAITING_SENTENCE_JQ='
    def ccname: gsub("[^A-Za-z0-9_-]"; "_");
    . as $m
    | if ($m | test("\\(MCP\\)")) then
        (($m | capture("permission to use (?<s>.+?) - (?<t>.+?) ?\\(MCP\\)$")) // {s: "", t: ""}) as $c
        | if $c.s == "" then ["", ""]
          else ($c.s | ccname
                | if ($c.s | startswith("claude.ai ")) then gsub("_+"; "_") | ltrimstr("_") | rtrimstr("_") else . end) as $srv
               | [(if ($c.t | test("^[A-Za-z0-9_-]+$")) then "mcp__\($srv)__\($c.t)" else "" end), "mcp__\($srv)__"]
          end
      else [((($m | capture("permission to use (?<t>[^ ]+)")) // {t: ""}) | .t), ""]
      end'

# _mmry_waiting_open_call MCP_PREFIX TRANSCRIPT_PATH  (#33898 round 3, QA finding C1)
# Sets MMRY_WAITING_OPEN to the name of THE still-waiting call of that server in the transcript, or
# empty. A call is still waiting when no tool_result in the transcript carries its id. Empty unless
# there is exactly one such call (two parallel calls of one server, even of one tool, give none).
# Calls are found by parsing each transcript line as JSON and reading message.content[] blocks of
# type tool_use (name, id) and tool_result (tool_use_id), never by matching raw text, so a name or id
# inside some call's input is not a call. grep -F only narrows the lines jq parses; nothing of any
# call's input reaches a shell variable.
_mmry_waiting_open_call() {
    local prefix="${1:-}" tp="${2:-}" uses="" ids="" open="" oid="" id n
    local -a pat=()
    MMRY_WAITING_OPEN=""
    [[ "$prefix" =~ ^mcp__[A-Za-z0-9_-]+__$ && -f "$tp" && -r "$tp" && -n "${MMRY_JQ:-}" ]] || return 0
    uses="$(grep -F -- "\"${prefix}" "$tp" 2>/dev/null | "$MMRY_JQ" -R -r --arg p "$prefix" '
        (fromjson? // empty) | (.message?.content? // empty) | if type == "array" then .[] else empty end
        | select(type == "object" and .type == "tool_use" and (.id | type) == "string" and (.name | type) == "string")
        | select((.name | startswith($p)) and (.id | test("^[A-Za-z0-9_-]{1,100}$")))
        | "\(.id) \(.name)"' 2>/dev/null || true)"
    # No sort: on Windows the PATH a hook sees can put sort.exe first. A Windows jq may end lines CR LF.
    uses="${uses//$'\r'/}"
    [[ -n "$uses" ]] || return 0
    while read -r id n; do
        [[ -n "$id" ]] && pat+=(-e "\"${id}\"")
    done <<< "$uses"
    ids="$(grep -F "${pat[@]}" -- "$tp" 2>/dev/null | "$MMRY_JQ" -R -r '
        (fromjson? // empty) | (.message?.content? // empty) | if type == "array" then .[] else empty end
        | select(type == "object" and .type == "tool_result" and (.tool_use_id | type) == "string")
        | .tool_use_id' 2>/dev/null || true)"
    ids="${ids//$'\r'/}"
    while read -r id n; do
        [[ -n "$id" ]] || continue
        [[ $'\n'"${ids}"$'\n' == *$'\n'"${id}"$'\n'* ]] && continue
        # The same call written twice is one call.
        [[ "$id" == "$oid" ]] && continue
        # A second still-waiting call (another id) of this server: no single call to name.
        [[ -z "$open" ]] || return 0
        open="$n" oid="$id"
    done <<< "$uses"
    MMRY_WAITING_OPEN="$open"
}

# mmry_waiting_tool_name EVENT CODEX_TOOL SENTENCE_NAME MCP_PREFIX TRANSCRIPT_PATH
# Sets MMRY_WAITING_TOOL to the asking tool's bare name, or empty, and MMRY_WAITING_OPEN as above for an
# MCP sentence. One small fork-free path for every ordinary tool; the transcript is read only for an
# MCP sentence.
mmry_waiting_tool_name() {
    local event="${1:-}" ptool="${2:-}" name="${3:-}" prefix="${4:-}" tp="${5:-}"
    MMRY_WAITING_TOOL="" MMRY_WAITING_OPEN=""
    if [[ "$event" == "PermissionRequest" ]]; then
        name="$ptool"
    elif [[ -n "$prefix" ]]; then
        # An MCP sentence: the built name stands only if it is the name of the one still-waiting call
        # of its server in the transcript (C1).
        _mmry_waiting_open_call "$prefix" "$tp"
        [[ -n "$MMRY_WAITING_OPEN" && "$name" == "$MMRY_WAITING_OPEN" ]] || name=""
    fi
    # A name that is not bare, or too long, is dropped, never trimmed into one.
    [[ "$name" =~ $_MMRY_WAITING_TOOL_RE ]] || name=""
    MMRY_WAITING_TOOL="$name"
}

# _mmry_waiting_record_name RECORD_TOOL SENTENCE_NAME MCP_PREFIX TRANSCRIPT_PATH  (#33898 C1 in 33900)
# Sets MMRY_WAITING_TOOL to the name to send when a fresh ask record exists. The record never supplies
# a name on its own: an MCP name in it must be the one still-waiting call of its server in the
# transcript (_mmry_waiting_open_call); a built-in name in it must equal the sentence's word.
_mmry_waiting_record_name() {
    local rec="${1:-}" name="${2:-}" prefix="${3:-}" tp="${4:-}" rest rp
    MMRY_WAITING_TOOL="$name"
    # The sentence's own MCP name, confirmed by the transcript: it stands.
    [[ -n "$prefix" && -n "$name" ]] && return 0
    if [[ "$rec" == mcp__* ]]; then
        rest="${rec#mcp__}"; rp="mcp__${rest%%__*}__"
        MMRY_WAITING_TOOL=""
        # An MCP sentence of another server: the record is not this prompt's.
        [[ -z "$prefix" || "$rp" == "$prefix" ]] || return 0
        [[ "$rp" == "$prefix" ]] || _mmry_waiting_open_call "$rp" "$tp"
        [[ -n "$MMRY_WAITING_OPEN" && "$rec" == "$MMRY_WAITING_OPEN" ]] && MMRY_WAITING_TOOL="$rec"
    elif [[ "$rec" != "$name" ]]; then
        MMRY_WAITING_TOOL=""
    fi
    return 0
}

_mmry_waiting_marker() { MMRY_WAITING_MARKER="${MMRY_TMPDIR}/.mmry-waiting-$1"; }
_mmry_waiting_ask_path() { MMRY_WAITING_ASK="${MMRY_TMPDIR}/.mmry-asking-$1"; }

# THE ONE WAY A MARKER IS DELETED (#33901). A file, never a folder, named only from a session id that
# passes the id rule, inside a TMPDIR that must be set: ${MMRY_TMPDIR:?} stops the shell before rm
# runs if it ever is not (scripts/check-folder-deletes.sh, #33618). The ask record (#33900) goes with it.
_mmry_waiting_forget() {
    [[ "${1:-}" =~ $_MMRY_WAITING_SID_RE ]] || return 0
    rm -f -- "${MMRY_TMPDIR:?}/.mmry-waiting-${1}" "${MMRY_TMPDIR:?}/.mmry-asking-${1}" || true
}

# ---- WHICH PROMPT, AND WHO ASKED (#33900) -----------------------------------------------------
# The waiting state clears only when the prompt it waits on is answered, or the person sends a new
# prompt. Measured on Claude Code 2.1.322 (the #33900 PR description), a prompt stays open while these
# arrive in the same session, and NONE of them answers it:
#   a background agent's PostToolUse        carries that agent's agent_id
#   a parallel tool of the same agent        the same agent_id (none on the main thread), another tool_name
#   another agent's SubagentStop             that agent's agent_id
#   the main turn's Stop                     while a background agent's own prompt is open
#   a background agent's completion          injected as a UserPromptSubmit whose prompt is <task-notification>
#   a parallel call of the SAME tool         the same agent_id and tool_name, another tool_input (A2)
# What does answer it:
#   Allow    the asked CALL's PostToolUse: the agent that asked, the asked tool_name, and the asked
#            call's input (WHICH CALL below)
#   Deny     no PostToolUse at all; the asking agent's turn ends next: Stop on the main thread (on
#            Codex, the asking turn's Stop), SubagentStop for a subagent (--answer-hook, registered
#            on Claude Code's SubagentStop and Codex's Stop and SubagentStop)
#   the person's next prompt (UserPromptSubmit)
# So the marker records who asked (agent_id, empty for the main thread) and the asked tool's exact name
# when it is known. Claude Code's Notification carries neither: no agent_id even when a subagent asks,
# and the tool's display name ("Ping" for mcp__probe__ping in an SDK host). Claude Code's own
# PermissionRequest hook carries both, about 0.2 s after the ask and 6 to 14 s before the Notification,
# so it is registered to write a small ask record (.mmry-asking-<session>: the agent and the tool name,
# nothing else, no call) that the Notification then reads. Codex's PermissionRequest is the raise
# itself and carries both (agent_id only for a thread-spawned subagent).
# The clear rule is in --answer below; formation-check.sh hands it every event while a marker exists.
_MMRY_WAITING_ASK_FRESH_SECS=300

# ---- WHICH CALL (#33900 round 2, QA finding A2) ------------------------------------------------
# Agent and tool name are not enough: a PARALLEL call of the same tool by the same agent, allowed and
# finishing after the notice, carried the same agent and name, and told the lead "APPROVAL ANSWERED."
# while the prompt was still open. The answer must be tied to the asked CALL. Neither host's
# PermissionRequest carries a tool_use_id (Claude Code 2.1.322, measured; codex-rs schema.rs), so the
# closest exact identifier is the call's input, which the asked call's own PostToolUse repeats:
#   Claude Code  measured on every asked call (Bash, MCP tools, a subagent's MCP tool): PostToolUse
#                tool_input is identical to the PermissionRequest's.
#   Codex        from source, not measured (openai/codex 9f80bb5): a shell command's PermissionRequest
#                is {command, description} and its PostToolUse is {command}, the same hook_command; an
#                MCP call's is its arguments in both.
# So the identifier is a one-way digest (SHA-256) of tool_input.command when that is a string, and of
# the whole tool_input, keys sorted, otherwise. Only the digest is kept, never the input. With no
# identifier (no PermissionRequest hook fired, no tool_input, or no sha256sum or shasum on the
# machine), NO tool call answers the prompt: it clears on the asking agent's end or the person's next
# prompt instead. Two calls of the same tool by the same agent with byte-identical input cannot be told
# apart; both would have asked for approval, so neither is a call the person did not answer.
_MMRY_WAITING_INPUT_JQ='if (type == "object" and has("tool_input")) then (.tool_input | if (type == "object" and ((.command // null) | type) == "string") then {command: .command} else . end) else empty end'
_MMRY_WAITING_EMPTY_SHA='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
# _mmry_waiting_digest PAYLOAD: sets MMRY_WAITING_DIGEST to 64 hex characters, or empty. Needs MMRY_JQ.
_mmry_waiting_digest() {
    local h=""
    MMRY_WAITING_DIGEST=""
    [[ -n "${MMRY_JQ:-}" ]] || return 0
    if command -v sha256sum >/dev/null 2>&1; then
        h="$("$MMRY_JQ" -cS "$_MMRY_WAITING_INPUT_JQ" <<< "${1:-}" 2>/dev/null | sha256sum 2>/dev/null)" || h=""
    elif command -v shasum >/dev/null 2>&1; then
        h="$("$MMRY_JQ" -cS "$_MMRY_WAITING_INPUT_JQ" <<< "${1:-}" 2>/dev/null | shasum -a 256 2>/dev/null)" || h=""
    fi
    h="${h%% *}"
    if [[ "$h" =~ ^[0-9a-f]{64}$ && "$h" != "$_MMRY_WAITING_EMPTY_SHA" ]]; then
        MMRY_WAITING_DIGEST="$h"
    fi
    return 0
}


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

# ---- --forget: the marker's prompt cannot still be open (#33901) ------------------------------
if [[ "${1:-}" == "--forget" ]]; then
    _mmry_waiting_forget "${2:-}"
    exit 0
fi

# The clear itself: ask the service to clear the flag (it tells the lead "APPROVAL ANSWERED.", DD-187
# point 3) and remove the marker. Returns; the caller exits.
_mmry_waiting_clear() {
    local sid="$1" fid="" mid="" _a _rest _ans=""
    _mmry_waiting_marker "$sid"
    [[ -f "$MMRY_WAITING_MARKER" ]] || return 0
    { read -r fid mid || true; } < "$MMRY_WAITING_MARKER"
    if ! [[ "$fid" =~ ^[0-9]+$ && "$mid" =~ ^[0-9]+$ ]]; then
        _mmry_waiting_forget "$sid"; return 0
    fi
    # The prompt has been answered, whatever the service says next (#33901). Recorded first, so a
    # clear that does not go through leaves a marker the next raise knows is over, not one that
    # silences the next prompt.
    while IFS=' ' read -r _a _rest || [[ -n "$_a" ]]; do
        [[ "$_a" == "answered" ]] && _ans=1
    done < "$MMRY_WAITING_MARKER"
    [[ -n "$_ans" ]] || printf 'answered %s\n' "$(date +%s || echo 0)" >> "$MMRY_WAITING_MARKER" || true
    _mmry_waiting_load >/dev/null || return 0
    mmry_clear_formation_member_waiting "$fid" "$mid" "$sid" >/dev/null || true
    # Cleared (2xx), or the service will never accept this clear (the member left, the formation
    # closed, the entry is not this session's): the marker goes. No answer, a 5xx or a 429: it stays,
    # and the next answering event asks again.
    case "${MMRY_HTTP_CODE:-000}" in
        2??|400|403|404) _mmry_waiting_forget "$sid" ;;
    esac
    return 0
}

# ---- --clear SID: clear now, whatever the event (kept for callers that know the prompt is over) ---
if [[ "${1:-}" == "--clear" ]]; then
    [[ "${2:-}" =~ $_MMRY_WAITING_SID_RE ]] || exit 0
    _mmry_waiting_clear "$2"
    exit 0
fi

# ---- --answer SID [EVENT] [MODE]: does this event answer the prompt? (#33900) ------------------
# formation-check.sh runs this, with the event's payload on stdin, for every event of a session that
# has a marker. EVENT is the payload's hook_event_name as formation-check.sh read it, MODE its
# MMRY_FORMATION_MODE (the suite's way of naming an event without a payload). See WHICH PROMPT, AND WHO
# ASKED above for the measurements behind each line of the rule.
# ---- --answer-hook: the same, registered directly on the events formation-check.sh does not serve
# (#33900 round 2, QA finding B2): Claude Code's SubagentStop, and Codex's Stop and SubagentStop. The
# session comes from the payload. Without these a subagent's Deny, and any Codex Deny, cleared only on
# the person's next prompt. Prints nothing (Codex reads a Stop hook's stdout), makes a call only to clear.
if [[ "${1:-}" == "--answer" || "${1:-}" == "--answer-hook" ]]; then
    hookmode=""
    [[ "$1" == "--answer-hook" ]] && hookmode=1
    sid="${2:-}" ev="${3:-}" mode="${4:-}"
    if [[ -n "$hookmode" ]]; then
        sid="" ev="" mode=""
        [[ ! -t 0 ]] || exit 0
    else
        [[ "$sid" =~ $_MMRY_WAITING_SID_RE ]] || exit 0
        _mmry_waiting_marker "$sid"
        [[ -f "$MMRY_WAITING_MARKER" ]] || exit 0
    fi
    agent="" ptool="" tasknote="" hasbg="" running="" psid="" pturn=""
    payload=""
    if [[ ! -t 0 && -f "${HANDLER_DIR}/lib-hookread.sh" ]] && source "${HANDLER_DIR}/lib-hookread.sh"; then
        mmry_read_hook_payload "${MMRY_HOOK_READ_TIMEOUT:-2}" || true
        payload="${MMRY_HOOK_PAYLOAD:-}"
    fi
    if [[ "$payload" == *'{'* ]] && [[ -f "${HANDLER_DIR}/lib-jq.sh" ]] && source "${HANDLER_DIR}/lib-jq.sh" \
       && { [[ -n "${MMRY_JQ:-}" ]] || mmry_resolve_jq >/dev/null; } && [[ -n "${MMRY_JQ:-}" ]]; then
        # Eight fields, the unit separator between them (see the raise below for why not a tab). The
        # prompt is reduced to one yes or no, so no prompt text reaches a shell variable.
        _afields='[(.hook_event_name // "" | tostring), (.agent_id // "" | tostring), (.tool_name // "" | tostring),
                   (if ((.prompt // "") | tostring | startswith("<task-notification>")) then "1" else "" end),
                   (if (type == "object" and has("background_tasks")) then "1" else "" end),
                   ((.background_tasks // []) | if type == "array" then map(select(((.status // "") | tostring) == "running") | (.id // "" | tostring)) | join(",") else "" end),
                   (.session_id // "" | tostring), (.turn_id // "" | tostring)]
                  | map(gsub("[\u001f\r\n]"; " ")) | join("\u001f")'
        parsed="$("$MMRY_JQ" -r "$_afields" <<< "$payload" || true)"
        if [[ "$parsed" == *$'\037'* ]]; then
            IFS=$'\037' read -r _pev agent ptool tasknote hasbg running psid pturn <<< "$parsed" || true
            [[ -n "$_pev" ]] && ev="$_pev"
        fi
    fi
    if [[ -n "$hookmode" ]]; then
        # Only the events it is registered on, for the session the payload names, and only while that
        # session has a marker.
        case "$ev" in Stop|SubagentStop) ;; *) exit 0 ;; esac
        sid="$psid"
        [[ "$sid" =~ $_MMRY_WAITING_SID_RE ]] || exit 0
        _mmry_waiting_marker "$sid"
        [[ -f "$MMRY_WAITING_MARKER" ]] || exit 0
    fi
    [[ "$pturn" =~ $_MMRY_WAITING_SID_RE ]] || pturn=""
    if [[ -z "$ev" ]]; then
        case "$mode" in
            start)  ev="SessionStart" ;;
            prompt) ev="UserPromptSubmit" ;;
            idle)   ev="Stop" ;;
            tool)   ev="PostToolUse" ;;
        esac
    fi
    # A session start has no prompt of an earlier process still open (#33901): forget, no call.
    if [[ "$ev" == "SessionStart" ]]; then
        _mmry_waiting_forget "$sid"; exit 0
    fi
    # Who asked, and for which tool, as the raise recorded it ("-" or absent: the main thread, or a
    # tool whose exact name was not known).
    asker="" mtool="" minput="" mturn=""
    while IFS=' ' read -r _a _b _rest || [[ -n "$_a" ]]; do
        case "$_a" in
            asker) asker="$_b" ;;
            tool)  mtool="$_b" ;;
            input) minput="$_b" ;;
            turn)  mturn="$_b" ;;
        esac
    done < "$MMRY_WAITING_MARKER"
    [[ "$asker" == "-" ]] && asker=""
    [[ "$mtool" == "-" ]] && mtool=""
    [[ "$minput" =~ ^[0-9a-f]{64}$ ]] || minput=""
    [[ "$mturn" =~ $_MMRY_WAITING_SID_RE ]] || mturn=""
    answered=""
    case "$ev" in
        UserPromptSubmit)
            # The person's next prompt. Not a background agent's completion notice, which Claude Code
            # injects as a prompt while another agent's approval can still be open.
            [[ -n "$tasknote" ]] || answered=1 ;;
        PostToolUse)
            # The asked CALL ran: the same agent, the same tool, and the same input (WHICH CALL above).
            # With no identifier recorded, no tool call answers it.
            if [[ -n "$mtool" && -n "$minput" && "$agent" == "$asker" && "$ptool" == "$mtool" ]]; then
                _mmry_waiting_digest "$payload"
                [[ -n "$MMRY_WAITING_DIGEST" && "$MMRY_WAITING_DIGEST" == "$minput" ]] && answered=1
            fi ;;
        Stop)
            # The asking agent's turn ended (after a Deny there is no PostToolUse: measured). Codex's Stop
            # carries the turn's id (codex-rs schema.rs), and Codex also sends Stop for its own memory
            # consolidation, so there only the asking turn's Stop answers the main thread's prompt; a
            # Codex subagent's prompt is answered by its SubagentStop. Claude Code's Stop is the main
            # thread's. For a background agent's prompt, the main turn's end answers it only when that
            # agent is no longer running; without a background_tasks list there is no telling, and it
            # waits for another event.
            if [[ -n "$pturn" ]]; then
                [[ -z "$asker" && -n "$mturn" && "$pturn" == "$mturn" ]] && answered=1
            elif [[ "$agent" == "$asker" ]]; then
                answered=1
            elif [[ -z "$agent" && -n "$asker" && -n "$hasbg" && ",${running}," != *",${asker},"* ]]; then
                answered=1
            fi ;;
        SubagentStop)
            # The asking subagent finished: its prompt cannot still be open (Claude Code and Codex).
            [[ -n "$asker" && "$agent" == "$asker" ]] && answered=1 ;;
    esac
    [[ -n "$answered" ]] || exit 0
    _mmry_waiting_clear "$sid"
    exit 0
fi

# ---- --ask: Claude Code's PermissionRequest; record who asked and for which tool (#33900) --------
# No call, nothing printed (Claude Code reads this hook's stdout as an approval decision, exactly as
# Codex does), and nothing kept but the agent id and the tool's bare name. A session in no formation
# stops at one file test.
if [[ "${1:-}" == "--ask" ]]; then
    [[ ! -t 0 ]] || exit 0
    _env_sid="${CLAUDE_CODE_SESSION_ID:-}"
    if [[ "$_env_sid" =~ $_MMRY_WAITING_SID_RE && ! -f "${MMRY_TMPDIR}/.mmry-formation-${_env_sid}" ]]; then
        exit 0
    fi
    [[ -f "${HANDLER_DIR}/lib-hookread.sh" ]] || exit 0
    source "${HANDLER_DIR}/lib-hookread.sh" || exit 0
    mmry_read_hook_payload "${MMRY_HOOK_READ_TIMEOUT:-2}" || true
    payload="${MMRY_HOOK_PAYLOAD:-}"
    [[ "$payload" == *'"PermissionRequest"'* ]] || exit 0
    source "${HANDLER_DIR}/lib-jq.sh" || exit 0
    mmry_resolve_jq >/dev/null || exit 0
    [[ -n "${MMRY_JQ:-}" ]] || exit 0
    parsed="$("$MMRY_JQ" -r '[(.session_id // "" | tostring), (.hook_event_name // "" | tostring), (.agent_id // "" | tostring), (.tool_name // "" | tostring)] | map(gsub("[\u001f\r\n]"; " ")) | join("\u001f")' <<< "$payload" || true)"
    [[ "$parsed" == *$'\037'* ]] || exit 0
    IFS=$'\037' read -r sid event agent tool <<< "$parsed" || true
    [[ "$event" == "PermissionRequest" ]] || exit 0
    [[ "$sid" =~ $_MMRY_WAITING_SID_RE ]] || exit 0
    [[ -f "${MMRY_TMPDIR}/.mmry-formation-${sid}" ]] || exit 0
    [[ "$agent" =~ $_MMRY_WAITING_SID_RE ]] || agent="-"
    [[ "$tool" =~ $_MMRY_WAITING_TOOL_RE ]] || tool="-"
    # The asked call's identifier: a digest of its input, never the input (WHICH CALL above).
    _mmry_waiting_digest "$payload"
    _mmry_waiting_ask_path "$sid"
    printf 'asker %s\ntool %s\ninput %s\nat %s\n' "$agent" "$tool" "${MMRY_WAITING_DIGEST:--}" "$(date +%s || echo 0)" \
        > "$MMRY_WAITING_ASK" || true
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

# Nine fields in one jq call, joined by the ASCII unit separator (0x1F), each with that character and
# line breaks removed, so a crafted value cannot shift the fields after it. NOT a tab: a tab is IFS
# whitespace, so read collapses empty fields and every later field moves one place left (seen red: the
# tool name arrived empty on every event). The message is reduced here, by _MMRY_WAITING_SENTENCE_JQ, to
# a tool name and an MCP name prefix, so the rest of the sentence never reaches a shell variable.
_fields='[(.session_id // "" | tostring), (.hook_event_name // "" | tostring),
          (.notification_type // "" | tostring), (.tool_name // "" | tostring),
          ((.message // "" | tostring) | '"$_MMRY_WAITING_SENTENCE_JQ"'),
          (.turn_id // "" | tostring), (.transcript_path // "" | tostring), (.agent_id // "" | tostring)]
         | flatten | map(gsub("[\u001f\r\n]"; " ")) | join("\u001f")'
parsed="$("$MMRY_JQ" -r "$_fields" <<< "$payload" || true)"
[[ "$parsed" == *$'\037'* ]] || exit 0
IFS=$'\037' read -r sid event ntype ptool mtool mprefix turn tpath pagent <<< "$parsed" || true

case "$event" in
    Notification)
        [[ "$ntype" == "permission_prompt" ]] || exit 0 ;;
    PermissionRequest) ;;
    *) exit 0 ;;
esac
# The asking tool's name, or none (#33898): see THE TOOL'S NAME above.
mmry_waiting_tool_name "$event" "$ptool" "$mtool" "$mprefix" "$tpath"
tool="$MMRY_WAITING_TOOL"

# Which prompt this is (#33901, A MARKER NEVER OUTLIVES ITS PROMPT above). A turn id that is not the
# plain id shape is not used, so the key, like the marker's name, is never built from unusual text.
key="cc"
if [[ "$event" == "PermissionRequest" ]]; then
    [[ "$turn" =~ $_MMRY_WAITING_SID_RE ]] || turn=""
    key="codex:${turn}:${tool}"
fi

[[ -n "$sid" ]] || sid="$(mmry_session_id || true)"
[[ "$sid" =~ $_MMRY_WAITING_SID_RE ]] || exit 0

# Who asked, and the asked tool's exact name when known (#33900, WHICH PROMPT, AND WHO ASKED above).
# Codex: from this payload. Claude Code: from the ask record its PermissionRequest left moments ago,
# which also gives the lead the exact name where the sentence has only a display name, but only when
# the transcript confirms it as the one still-waiting call of that server (#33898 C1); without a fresh
# record, the main thread and no exact name (the clear then waits for the main thread's own events).
asker="" exact="" input="" mturn=""
if [[ "$event" == "PermissionRequest" ]]; then
    [[ "$pagent" =~ $_MMRY_WAITING_SID_RE ]] && asker="$pagent"
    exact="$tool"
    mturn="$turn"
    # The asked call's identifier (WHICH CALL above): only when there is an exact tool to tie it to.
    if [[ -n "$exact" ]]; then
        _mmry_waiting_digest "$payload"
        input="$MMRY_WAITING_DIGEST"
    fi
else
    _mmry_waiting_ask_path "$sid"
    if [[ -f "$MMRY_WAITING_ASK" ]]; then
        _k_asker="" _k_tool="" _k_at="" _k_used="" _k_input=""
        while IFS=' ' read -r _a _b _rest || [[ -n "$_a" ]]; do
            case "$_a" in
                asker) _k_asker="$_b" ;;
                tool)  _k_tool="$_b" ;;
                input) _k_input="$_b" ;;
                at)    _k_at="$_b" ;;
            esac
        done < "$MMRY_WAITING_ASK"
        _now="$(date +%s || echo 0)"
        if [[ "$_k_at" =~ ^[0-9]+$ && "$_now" =~ ^[0-9]+$ ]] && (( _now - _k_at <= _MMRY_WAITING_ASK_FRESH_SECS )); then
            _k_used=1
            [[ "$_k_asker" =~ $_MMRY_WAITING_SID_RE ]] && asker="$_k_asker"
            if [[ "$_k_tool" =~ $_MMRY_WAITING_TOOL_RE ]]; then
                exact="$_k_tool"
                # The NAME SENT (#33898 C1): a record can be left over from an earlier prompt, so it
                # never supplies a name on its own. An MCP name in the record is sent only when the
                # transcript holds it as the one still-waiting call of its server (THE TOOL'S NAME,
                # point 2). Measured on Claude Code 2.1.322, an MCP prompt's sentence can be a bare
                # display word ("use Echo", "use Ping"), so the record's own server is the one
                # checked when the sentence names none. A name the sentence already established
                # stands. A record that disagrees with the sentence and is not confirmed: no name.
                # The clear's own identity (asker, exact, input) is 33900's and unchanged.
                _mmry_waiting_record_name "$_k_tool" "$tool" "$mprefix" "$tpath"
                tool="$MMRY_WAITING_TOOL"
                [[ "$_k_input" =~ ^[0-9a-f]{64}$ ]] && input="$_k_input"
            fi
        fi
        rm -f -- "${MMRY_TMPDIR:?}/.mmry-asking-${sid}" || true
        # The ask record names this prompt, so a different one (another agent, another tool) is told
        # apart from the marker's (#33901's key). A second report of the same prompt finds the record
        # already used, keeps the key "cc", and stays one call.
        [[ -z "$_k_used" ]] || key="cc:${asker:--}:${exact:--}"
    fi
fi

# A member at all? One file test, and a session in no formation stops here with no call.
[[ -f "${HANDLER_DIR}/formation-state.sh" ]] || exit 0
source "${HANDLER_DIR}/formation-state.sh" || exit 0
mmry_formation_state_read "$sid" || exit 0
fid="$MMRY_FS_FORMATION"
[[ "$fid" =~ ^[0-9]+$ ]] || exit 0

# Already reported for this prompt: no second call. A marker left over from an earlier prompt is no
# reason to stay silent; it is replaced below once the service has this one (#33901).
_mmry_waiting_marker "$sid"
if [[ -f "$MMRY_WAITING_MARKER" ]]; then
    _m_fid="" _m_key="" _m_ans="" _first=1
    while IFS=' ' read -r _a _b _rest || [[ -n "$_a" ]]; do
        if [[ -n "$_first" ]]; then _m_fid="$_a"; _first=""; continue; fi
        case "$_a" in
            prompt)   _m_key="$_b" ;;
            answered) _m_ans=1 ;;
        esac
    done < "$MMRY_WAITING_MARKER"
    _stale=""
    [[ "$_m_fid" == "$fid" ]] || _stale=1
    [[ -z "$_m_ans" ]] || _stale=1
    [[ "$key" == "cc" || "$_m_key" == "$key" ]] || _stale=1
    [[ -n "$_stale" ]] || exit 0
fi

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
    printf '%s %s\nprompt %s %s\nasker %s\ntool %s\ninput %s\nturn %s\n' "$fid" "$mid" "$key" "$(date +%s || echo 0)" \
        "${asker:--}" "${exact:--}" "${input:--}" "${mturn:--}" > "$MMRY_WAITING_MARKER" || true
fi
exit 0
