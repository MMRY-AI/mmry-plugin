#!/usr/bin/env bash
# mcp-server.sh - MMRY's own commands as MCP tools, for Codex (#31743).
#
# WHY THIS EXISTS. In Codex's default sandbox a command the assistant runs has no network, so every
# save, search and join the assistant ran itself failed until the customer approved "Internet access"
# for that conversation (#31245, measured on the Mac desktop app 2026-10-04). Codex offers that
# approval for a turn or a session only, so the customer was asked again in every conversation. A
# local MCP server is different: Codex starts it itself, outside the sandbox
# (codex-rs/rmcp-client/src/stdio_server_launcher.rs runs it as a plain child process), so its
# commands reach mmryai.com with no Internet access prompt at all.
#
# WHAT DECIDES WHETHER CODEX ASKS. Not the network: the tool's annotations
# (codex-rs/core/src/mcp_tool_call.rs, requires_mcp_tool_approval). Under the default "auto" mode a
# tool marked readOnlyHint, or marked neither destructive nor open-world, runs without a prompt; any
# other tool prompts once, and that prompt offers "always allow", which Codex records permanently.
# The annotations below are what each command really does, not what avoids a prompt: retiring a
# memory takes it out of recall, so it says destructive and the customer approves it once.
# The MCP specification itself names a memory tool as the example of a closed world, which is why
# no tool here says open-world: every one of them reaches only this customer's own MMRY account.
#
# WHICH CONVERSATION A CALL BELONGS TO. One server may serve several conversations, and the delivery
# hook keeps formation membership per conversation. Codex puts the conversation's identity on every
# tools/call it sends: params._meta.sessionId, the same value its hooks receive as session_id and
# its shell exports as CODEX_SESSION_ID (codex-rs/core/src/mcp_tool_call.rs,
# with_mcp_tool_call_ids_meta; codex-rs/core/src/hook_runtime.rs). So the identity is read from each
# call and handed to the handler as CODEX_SESSION_ID, and nothing about a conversation is kept in
# this process. A call that carries neither sessionId nor threadId is refused for the formation
# tools rather than guessed: two conversations silently sharing one membership is worse than an
# error.
#
# HOW IT WORKS. JSON-RPC 2.0, one message per line on stdin and stdout (the MCP stdio transport).
# Each tool runs the existing handler script, unchanged, exactly as the skill tells the assistant to
# run it, with stdin closed so a handler can never read the protocol stream. stdout carries nothing
# but protocol messages; anything else goes to stderr, which Codex logs.
#
# Started by codex-hook.sh (which sets MMRY_HOST=codex and the plugin root) through mcp/mmry-mcp on
# macOS and Linux and mcp/mmry-mcp.cmd on Windows, as registered in codex-mcp.json. Claude Code
# never reads that file and never starts this.

# The repository convention (structural/file-integrity.bats) holds for the start-up below, which
# must succeed or not run at all. -e is switched off once start-up is done; see "NO set -e".
set -euo pipefail

HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${HANDLER_DIR}/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export MMRY_HOST="${MMRY_HOST:-codex}"

# shellcheck source=/dev/null
source "${HANDLER_DIR}/lib-host.sh"

# The jq resolver only. lib-jq.sh refuses to load on Codex without a credential, which is right for a
# handler and wrong here: with no credential this server must still answer, so the assistant can be
# told to run setup. Each handler it starts makes that check for itself, unaffected by this.
MMRY_ALLOW_NO_CREDENTIAL=1
# shellcheck source=/dev/null
source "${HANDLER_DIR}/lib-jq.sh"
unset MMRY_ALLOW_NO_CREDENTIAL
mmry_resolve_jq >/dev/null 2>&1 || true
# NO set -e, and it is switched off here because a library above may have switched it on. This is a
# long-lived server: a handler that exits 1 is an answer to report, not a reason for the whole
# server, and every later call in every conversation, to stop.
set +e
if [[ -z "${MMRY_JQ:-}" ]]; then
    echo "MMRY AI MCP server: no usable jq was found, so it cannot start." >&2
    exit 1
fi
JQ="$MMRY_JQ"

MMRY_MCP_VERSION="$("$JQ" -r '.version // "0"' "${PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null || echo 0)"
MMRY_MCP_VERSION="${MMRY_MCP_VERSION%$'\r'}"

# The protocol versions this server speaks. It answers with the client's own version when it is one
# of these, as the specification asks, and with the newest otherwise.
MMRY_MCP_PROTOCOLS="2025-06-18 2025-03-26 2024-11-05"

# How long one handler may run before it is stopped, in seconds. Codex's own per-call limit is set
# above this in codex-mcp.json, so the customer sees MMRY's message rather than a bare timeout.
MMRY_MCP_HANDLER_TIMEOUT="${MMRY_MCP_HANDLER_TIMEOUT:-100}"

_mcp_send() {
    printf '%s\n' "$1"
}

_mcp_error() {
    # $1 id (JSON), $2 code, $3 message
    _mcp_send "$("$JQ" -cn --argjson id "$1" --argjson code "$2" --arg m "$3" \
        '{jsonrpc:"2.0", id:$id, error:{code:$code, message:$m}}')"
}

_mcp_result() {
    # $1 id (JSON), $2 result (JSON)
    _mcp_send "$("$JQ" -cn --argjson id "$1" --argjson r "$2" '{jsonrpc:"2.0", id:$id, result:$r}')"
}

_mcp_tool_text() {
    # $1 id, $2 text, $3 isError (true|false)
    _mcp_send "$("$JQ" -cn --argjson id "$1" --arg t "$2" --argjson e "$3" \
        '{jsonrpc:"2.0", id:$id, result:{content:[{type:"text", text:$t}], isError:$e}}')"
}

# ---------------------------------------------------------------------------------------------
# THE TOOLS. Names, descriptions, input schemas and annotations, as tools/list returns them.
# ---------------------------------------------------------------------------------------------
MMRY_MCP_TOOLS='[
  {
    "name": "memory_save",
    "title": "Save a memory",
    "description": "Save something worth remembering to MMRY AI: a decision, a fix and its root cause, a convention, a fact. Write it as short declarative statements, as though briefing a new team member. MMRY classifies it. To correct a memory that is wrong, pass supersedes with that memory'"'"'s id (from memory_search): the new one replaces it. Prints one line saying MMRY AI received it; it does not return the new memory'"'"'s id.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "content": {"type": "string", "description": "What to remember."},
        "supersedes": {"type": "integer", "description": "Id of a memory this one corrects. It is retired and linked to the new one."},
        "visibility": {"type": "string", "enum": ["Global", "Private", "Group"], "description": "Who can see it. Leave unset for the customer'"'"'s default."},
        "permission_group_id": {"type": "integer", "description": "The group, when visibility is Group."},
        "working_dir": {"type": "string", "description": "Absolute path of the project directory this is about."}
      },
      "required": ["content"]
    },
    "annotations": {"title": "Save a memory", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
  },
  {
    "name": "memory_search",
    "title": "Search memories",
    "description": "Search MMRY AI memories by keyword, regardless of age. Each match is printed with its id, tier, scope and topic, then its content. Use the id to reinforce, link, retire or correct a memory; do not show ids to the customer unless they ask.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {"type": "string", "description": "Keywords."},
        "scope": {"type": "string", "description": "Optional scope to narrow the search, for example backend."}
      },
      "required": ["query"]
    },
    "annotations": {"title": "Search memories", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "memory_reinforce",
    "title": "Reinforce a memory",
    "description": "Reset a memory'"'"'s expiry because it genuinely guided the work, so it keeps coming back on its own. Operational, Tactical and Momentary memories only.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "integer", "description": "The memory id, from memory_search."}},
      "required": ["id"]
    },
    "annotations": {"title": "Reinforce a memory", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "memory_link",
    "title": "Link two memories",
    "description": "Record a relationship between two memories. related and contradicts are symmetric; supersedes and elaborates run from the first memory to the second.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "source_id": {"type": "integer"},
        "target_id": {"type": "integer"},
        "link_type": {"type": "string", "enum": ["related", "contradicts", "supersedes", "elaborates"]}
      },
      "required": ["source_id", "target_id", "link_type"]
    },
    "annotations": {"title": "Link two memories", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "memory_retire",
    "title": "Retire a memory",
    "description": "Retire (deactivate) a memory so it is no longer recalled. Nothing is deleted; the record is kept. To correct a memory, prefer memory_save with supersedes, which retires the old one and links the two.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "integer", "description": "The memory id, from memory_search."}},
      "required": ["id"]
    },
    "annotations": {"title": "Retire a memory", "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "memory_load",
    "title": "Reload memories",
    "description": "Reload this conversation'"'"'s memories now and refresh the Foundation memories restated each turn: after an administrator changed a Foundation memory, after moving to another project directory, or when MMRY reported Foundation directives could not be applied. Returns where the loaded memories were written; read that file.",
    "inputSchema": {
      "type": "object",
      "properties": {"working_dir": {"type": "string", "description": "Absolute path of the project directory, so memories matching it are loaded."}}
    },
    "annotations": {"title": "Reload memories", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "formation_join",
    "title": "Join a coordination group",
    "description": "Join this conversation to a formation (coordination group) by its id. Messages from the other members then arrive on their own as you work. Use this, not the mmry_formation_* connector tools, to join: the connector enrols a different identity and no message would ever arrive. Joining prints two standing rules; follow them while in the formation.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "formation_id": {"type": "integer"},
        "working_dir": {"type": "string", "description": "Absolute path of the project directory."}
      },
      "required": ["formation_id"]
    },
    "annotations": {"title": "Join a coordination group", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
  },
  {
    "name": "formation_say",
    "title": "Message the coordination group",
    "description": "Send a message to this conversation'"'"'s formation, recorded verbatim. Without to_member_id it goes to every member; with it, to that one member only. Member ids come from formation_roster. Report to the lead with a message directed to the lead.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "message": {"type": "string"},
        "to_member_id": {"type": "integer", "description": "Roster entry id of the one member this is for."}
      },
      "required": ["message"]
    },
    "annotations": {"title": "Message the coordination group", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
  },
  {
    "name": "formation_progress",
    "title": "Report progress",
    "description": "Report how this conversation'"'"'s assigned work is going: Accepted, Done, Blocked or Abandoned, with an optional note for the lead.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "state": {"type": "string", "enum": ["Accepted", "Done", "Blocked", "Abandoned"]},
        "note": {"type": "string"}
      },
      "required": ["state"]
    },
    "annotations": {"title": "Report progress", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
  },
  {
    "name": "formation_roster",
    "title": "Show the coordination group roster",
    "description": "List the members of this conversation'"'"'s formation with the id to address each by, and which member is the lead.",
    "inputSchema": {"type": "object", "properties": {}},
    "annotations": {"title": "Show the coordination group roster", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  },
  {
    "name": "formation_leave",
    "title": "Leave the coordination group",
    "description": "Release this conversation'"'"'s place in its formation, on the service and here, so it can join another.",
    "inputSchema": {"type": "object", "properties": {}},
    "annotations": {"title": "Leave the coordination group", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
  }
]'

MMRY_MCP_INSTRUCTIONS="MMRY AI is this customer's persistent memory. These tools reach it directly and need no Internet access approval, so use them instead of running MMRY's bash scripts whenever a tool here does the job: saving, searching, reinforcing, linking, retiring and reloading memories, and joining, messaging, reporting progress in, reading the roster of and leaving a coordination group (formation). For anything without a tool here, follow the memory-system skill."

# ---------------------------------------------------------------------------------------------
# ONE TOOL CALL.
#
# $1 is the whole tools/call params object. One jq pass validates the arguments and turns them into
# the handler's command line, shell-quoted with @sh, so no argument value is ever interpreted by a
# shell: eval only ever sees single-quoted literals.
# ---------------------------------------------------------------------------------------------
# shellcheck disable=SC2016
MMRY_MCP_ARGV_JQ='
def str($k): (.arguments[$k] // null) | if . == null then null elif type == "string" then . else tostring end;
def int($k): (.arguments[$k] // null) | if . == null then null
    elif type == "number" and . == floor and . > 0 then tostring
    elif type == "string" and test("^[1-9][0-9]*$") then .
    else error("\($k) must be a positive whole number") end;
def need($k): if . == null or . == "" then error("\($k) is required") else . end;
def opt($flag; $v): if $v == null or $v == "" then [] else [$flag, $v] end;
(.name // "") as $n
| (._meta // {}) as $m
| (($m.sessionId // $m.threadId // "") | tostring) as $sid
| (str("working_dir") // "") as $wd
| (if $n == "memory_save" then
      ["save-memory.sh", "--context", (str("content") | need("content")), "--source", "codex"]
      + opt("--supersedes"; int("supersedes"))
      + opt("--visibility"; str("visibility"))
      + opt("--permission-group-id"; int("permission_group_id"))
      + (if $wd != "" then ["--working-dir", $wd] else [] end)
   elif $n == "memory_search" then
      ["search-memories.sh", "--ids", (str("query") | need("query"))] + (if (str("scope") // "") != "" then [str("scope")] else [] end)
   elif $n == "memory_reinforce" then ["reinforce-memory.sh", (int("id") | need("id"))]
   elif $n == "memory_retire" then ["deactivate-memory.sh", (int("id") | need("id"))]
   elif $n == "memory_link" then
      ["link-memories.sh", (int("source_id") | need("source_id")), (int("target_id") | need("target_id")),
       (str("link_type") | need("link_type") | if IN("related","contradicts","supersedes","elaborates") then . else error("link_type must be related, contradicts, supersedes or elaborates") end)]
   elif $n == "memory_load" then ["session-start.sh"]
   elif $n == "formation_join" then ["formation-join.sh", (int("formation_id") | need("formation_id"))]
   elif $n == "formation_say" then ["formation-say.sh", (str("message") | need("message"))] + (if int("to_member_id") == null then [] else [int("to_member_id")] end)
   elif $n == "formation_progress" then
      ["formation-progress.sh", (str("state") | need("state") | if IN("Accepted","Done","Blocked","Abandoned") then . else error("state must be Accepted, Done, Blocked or Abandoned") end)]
      + (if (str("note") // "") != "" then [str("note")] else [] end)
   elif $n == "formation_roster" then ["formation-roster.sh"]
   elif $n == "formation_leave" then ["formation-leave.sh"]
   else error("unknown tool: \($n)") end) as $argv
| "MMRY_SID=\([$sid] | @sh); MMRY_WD=\([$wd] | @sh); MMRY_ARGV=(\($argv | @sh))"
'

_mcp_run_handler() {
    # Runs MMRY_ARGV with the conversation identity; sets MMRY_OUT and MMRY_RC.
    local script="${MMRY_ARGV[0]}"
    local -a rest=("${MMRY_ARGV[@]:1}")
    local dir="$PWD" payload=""
    if [[ -n "$MMRY_WD" && -d "$MMRY_WD" ]]; then
        dir="$MMRY_WD"
    fi
    if [[ "$script" == "session-start.sh" ]]; then
        # The reload is the session-start hook run by hand, and that script reads its hook payload
        # from stdin. It is given the payload Codex itself would give it, so it learns this
        # conversation's id instead of reporting an unreadable payload.
        payload="$("$JQ" -cn --arg s "$MMRY_SID" --arg c "$dir" \
            '{session_id:$s, hook_event_name:"SessionStart", source:"resume", cwd:$c}')"
    fi
    MMRY_OUT="$(
        cd "$dir" 2>/dev/null || cd "$PLUGIN_ROOT" || exit 1
        if [[ -n "$MMRY_SID" ]]; then
            export CODEX_SESSION_ID="$MMRY_SID" CODEX_THREAD_ID="$MMRY_SID"
        else
            unset CODEX_SESSION_ID CODEX_THREAD_ID
        fi
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
        if [[ -n "$payload" ]]; then
            printf '%s\n' "$payload" | _mcp_timeout bash "${HANDLER_DIR}/${script}" ${rest[@]+"${rest[@]}"} 2>&1
        else
            _mcp_timeout bash "${HANDLER_DIR}/${script}" ${rest[@]+"${rest[@]}"} </dev/null 2>&1
        fi
    )"
    MMRY_RC=$?
}

# A handler that hangs must not hang the server, which serves every later call too. No `timeout`
# binary is assumed: macOS has none. The handler runs in the background and a watcher stops it.
_mcp_timeout() {
    local limit="$MMRY_MCP_HANDLER_TIMEOUT" pid watcher rc
    # <&0 is load-bearing. A background job's stdin defaults to /dev/null when job control is off,
    # and bash 3.2, the macOS bash, applies that even inside a pipeline, so the reload's hook
    # payload never reached session-start.sh there (macOS CI, 2026-10-10). Naming stdin keeps it.
    "$@" <&0 &
    pid=$!
    ( sleep "$limit" && kill "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    watcher=$!
    wait "$pid"
    rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    return "$rc"
}

_mcp_tools_call() {
    local id="$1" params="$2" setup name
    name="$("$JQ" -r '.name // ""' <<< "$params" 2>/dev/null)"
    name="${name%$'\r'}"
    if ! setup="$("$JQ" -r "$MMRY_MCP_ARGV_JQ" <<< "$params" 2>&1)"; then
        setup="${setup#jq: error (at <stdin>:*): }"
        if [[ "$setup" == unknown\ tool:* ]]; then
            _mcp_error "$id" -32602 "$setup"
        else
            _mcp_tool_text "$id" "Nothing was done: ${setup}" true
        fi
        return 0
    fi
    MMRY_SID="" MMRY_WD=""
    MMRY_ARGV=()
    eval "$setup"
    if [[ "$name" == formation_* || "$name" == memory_load ]] && [[ -z "$MMRY_SID" ]]; then
        _mcp_tool_text "$id" "Nothing was done: Codex did not say which conversation this call came from, and a coordination group is joined by one conversation. Run the same operation with the memory-system skill's bash script instead." true
        return 0
    fi
    _mcp_run_handler
    local out="$MMRY_OUT" rc="$MMRY_RC" is_error=false
    if [[ "$name" == memory_load ]]; then
        # The hook's answer is JSON for Codex; the assistant wants the sentence inside it.
        local ctx
        ctx="$("$JQ" -r '.hookSpecificOutput.additionalContext // empty' <<< "$out" 2>/dev/null || true)"
        [[ -n "$ctx" ]] && out="$ctx"
    fi
    if (( rc == 3 )) && [[ "$name" == memory_save ]]; then
        out="${out}"$'\n'"(Saved, but the memory it was meant to replace may still be active. Say so; do not claim it was replaced.)"
    elif (( rc != 0 )); then
        is_error=true
    fi
    [[ -n "$out" ]] || out="(no output, exit status ${rc})"
    _mcp_tool_text "$id" "$out" "$is_error"
}

_mcp_initialize() {
    local id="$1" params="$2" want version="" v
    want="$("$JQ" -r '.protocolVersion // ""' <<< "$params" 2>/dev/null)"
    want="${want%$'\r'}"
    for v in $MMRY_MCP_PROTOCOLS; do
        [[ -z "$version" ]] && version="$v"
        if [[ "$v" == "$want" ]]; then version="$v"; break; fi
    done
    _mcp_result "$id" "$("$JQ" -cn --arg pv "$version" --arg ver "$MMRY_MCP_VERSION" --arg ins "$MMRY_MCP_INSTRUCTIONS" \
        '{protocolVersion:$pv, capabilities:{tools:{listChanged:false}}, serverInfo:{name:"mmry", title:"MMRY AI", version:$ver}, instructions:$ins}')"
}

# ---------------------------------------------------------------------------------------------
# THE LOOP. One request in, one response out, in order. Notifications get no answer.
# ---------------------------------------------------------------------------------------------
_mcp_dispatch() {
    local line="$1" head method="" id="null" params="{}" has_id="false"
    # One jq process per message, its answer shell-quoted with @sh so eval sees only literals.
    # shellcheck disable=SC2016
    head="$("$JQ" -r 'if type == "object" then
            "method=\((.method // "") | tostring | @sh); has_id=\(has("id")); id=\((.id // null) | tojson | @sh); params=\((.params // {}) | tojson | @sh)"
        else "has_id=false" end' <<< "$line" 2>/dev/null)" || {
        _mcp_error null -32700 "Parse error"
        return 0
    }
    eval "$head"
    if [[ "$has_id" != "true" ]]; then
        return 0
    fi
    case "$method" in
        initialize) _mcp_initialize "$id" "$params" ;;
        ping) _mcp_result "$id" '{}' ;;
        tools/list) _mcp_result "$id" "$("$JQ" -c '{tools: .}' <<< "$MMRY_MCP_TOOLS")" ;;
        tools/call) _mcp_tools_call "$id" "$params" ;;
        resources/list) _mcp_result "$id" '{"resources":[]}' ;;
        prompts/list) _mcp_result "$id" '{"prompts":[]}' ;;
        *) _mcp_error "$id" -32601 "Method not found: ${method}" ;;
    esac
}

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    _mcp_dispatch "$line"
done
exit 0
