#!/usr/bin/env bats
# mcp-server.bats - MMRY's commands as MCP tools for Codex (#31743).
#
# Every test drives hooks-handlers/mcp-server.sh the way Codex does: JSON-RPC lines on stdin, one
# answer per request on stdout. The API is a fake curl that records each request (method, URL,
# body) and answers by route, so each tool is checked twice over: the request that reaches MMRY AI,
# and the response the assistant is given.
#
# Test case 1 asks for "plugin BATS cover each tool's request and response": the "tool:" tests below
# are that, one per tool. Test case 3 (two conversations, each its own membership) is the
# "identity:" group.

load '../helpers/test-helper'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    mkdir -p "$BIN" "$TEST_TMPDIR/codexhome" "$TEST_TMPDIR/proj"
    export REQLOG="$TEST_TMPDIR/requests.log"
    : > "$REQLOG"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
# A fake MMRY AI. Logs "METHOD URL BODY" per request; answers by route.
out=""; method="GET"; body=""; url=""; prev=""
for arg in "$@"; do
    case "$prev" in
        -o) out="$arg" ;;
        -X) method="$arg" ;;
        --data-binary) [[ "$arg" == @* ]] && body="$(cat "${arg#@}")" || body="$arg" ;;
        -d) body="$arg" ;;
    esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s %s\n' "$method" "$url" "$body" >> "$REQLOG"
code=200; resp='{}'
if [[ -n "${FAKE_FAIL_ALL:-}" ]]; then
    code=500; resp='{"error":"boom"}'
else
case "$method $url" in
    "POST "*/api/memories/process*) code=202; resp='{"message":"Memory sent to MMRY AI for processing.","stored":1}' ;;
    "GET "*/api/memories/search*) resp='[{"id":41,"memoryTier":"Operational","scope":"backend","topic":"Refund Handling","content":"Refund through the API."}]' ;;
    "POST "*/api/memories/*/reinforce) code=204; resp='' ;;
    "POST "*/api/memories/*/links) code=201; resp='{"id":3}' ;;
    "DELETE "*/api/memories/*) code=204; resp='' ;;
    "GET "*/api/memories/startup*) resp='[]' ;;
    "GET "*/api/memories*) resp='[]' ;;
    "POST "*/api/sessions) code=201; resp='' ;;
    "POST "*/api/formations/leave) resp='{"left":true}' ;;
    "POST "*/api/formations/*/join) resp='{"formation":{"id":77,"objective":"Ship it"}}' ;;
    "POST "*/api/formations/*/transmissions) code=201; resp='{"transmissionId":7,"stored":1}' ;;
    "GET "*/api/formations/*/transmissions/sent*) resp='{"member":true,"messages":[]}' ;;
    "PUT "*/api/formations/*/members/*/progress) resp='{"progress":"Accepted"}' ;;
    "GET "*/api/formations/[0-9]*) resp='{"formation":{"id":77,"objective":"Ship it"},"members":[{"id":5,"sessionId":"conv-A","role":"Lead","email":"a@test.mnemo"},{"id":6,"sessionId":"conv-B","role":"Wingman","email":"b@test.mnemo"}]}' ;;
    *) code=404; resp='{"error":"no fake route"}' ;;
esac
fi
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_HOST=codex CODEX_HOME="$TEST_TMPDIR/codexhome"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_CONFIG_FILE CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    SERVER="$PLUGIN_ROOT/hooks-handlers/mcp-server.sh"
}

# Feed the server one JSON-RPC message per argument; the answers land in $output.
mcp() {
    run bash -c 'printf "%s\n" "$@" | bash "$0"' "$SERVER" "$@"
}
# A tools/call request. $1 id, $2 tool, $3 arguments JSON, $4 _meta JSON (optional).
call() {
    local meta="${4:-}"
    if [[ -n "$meta" ]]; then
        printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s,"_meta":%s}}' "$1" "$2" "$3" "$meta"
    else
        printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"
    fi
}
# The answer with id $1, from $output.
answer() { printf '%s\n' "$output" | jq -c --argjson i "$1" 'select(.id == $i)'; }
text_of() { answer "$1" | jq -r '.result.content[0].text'; }
is_error() { answer "$1" | jq -r '.result.isError'; }

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex","version":"0.160.0"}}}'

# ---------------------------------------------------------------------------------------------
# protocol
# ---------------------------------------------------------------------------------------------

@test "protocol: initialize answers with the client's protocol version, tools capability and MMRY's name" {
    mcp "$INIT"
    assert_success
    [ "$(answer 1 | jq -r '.result.protocolVersion')" = "2025-06-18" ]
    [ "$(answer 1 | jq -r '.result.capabilities.tools | type')" = "object" ]
    [ "$(answer 1 | jq -r '.result.serverInfo.name')" = "mmry" ]
    [[ "$(answer 1 | jq -r '.result.instructions')" == *"no Internet access approval"* ]] || return 1
}

@test "protocol: an unknown protocol version is answered with the newest this server speaks" {
    mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'
    [ "$(answer 1 | jq -r '.result.protocolVersion')" = "2025-06-18" ]
}

@test "protocol: a notification gets no answer, and stdout carries nothing but protocol" {
    mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"ping"}'
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
    [ "$(answer 2 | jq -c '.result')" = "{}" ]
}

@test "protocol: an unknown method is -32601 and a line that is not JSON is -32700, and the server goes on" {
    mcp '{"jsonrpc":"2.0","id":"x","method":"nope"}' 'this is not json' '{"jsonrpc":"2.0","id":3,"method":"ping"}'
    [ "$(printf '%s\n' "$output" | jq -r 'select(.id == "x") | .error.code')" = "-32601" ]
    [ "$(printf '%s\n' "$output" | jq -r 'select(.id == null) | .error.code')" = "-32700" ]
    [ "$(answer 3 | jq -c '.result')" = "{}" ]
}

@test "protocol: a CRLF line, as a Windows client may write, is read as the same request" {
    run bash -c 'printf "%s\r\n" "$1" | bash "$0"' "$SERVER" '{"jsonrpc":"2.0","id":9,"method":"ping"}'
    [ "$(answer 9 | jq -c '.result')" = "{}" ]
}

@test "protocol: tools/list names the eleven tools, each with an object input schema" {
    mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    [ "$(answer 2 | jq -r '.result.tools | map(.name) | sort | join(",")')" = \
      "formation_join,formation_leave,formation_progress,formation_roster,formation_say,memory_link,memory_load,memory_reinforce,memory_retire,memory_save,memory_search" ]
    [ "$(answer 2 | jq -r '[.result.tools[] | .inputSchema.type] | unique | join(",")')" = "object" ]
}

# ---------------------------------------------------------------------------------------------
# annotations: what decides whether Codex asks (codex-rs core/src/mcp_tool_call.rs,
# requires_mcp_tool_approval). Auto mode prompts unless readOnlyHint, or unless destructiveHint and
# openWorldHint are both false.
# ---------------------------------------------------------------------------------------------

_codex_would_prompt() { # tool name -> "prompt" or "no-prompt", by Codex 0.160's auto-mode rule
    # Absent hints default as Codex defaults them: destructive and open-world to TRUE. Spelled with
    # == null, not jq's //, because // treats an explicit false as absent.
    answer 2 | jq -r --arg n "$1" '.result.tools[] | select(.name == $n) | .annotations
        | (if .destructiveHint == null then true else .destructiveHint end) as $d
        | (if .openWorldHint == null then true else .openWorldHint end) as $o
        | if .destructiveHint == true then "prompt"
          elif .readOnlyHint == true then "no-prompt"
          elif ($d or $o) then "prompt"
          else "no-prompt" end'
}

@test "annotations: every tool declares all four hints, and none claims an open world" {
    mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    [ "$(answer 2 | jq '[.result.tools[] | .annotations | has("readOnlyHint") and has("destructiveHint") and has("idempotentHint") and has("openWorldHint")] | all')" = "true" ]
    [ "$(answer 2 | jq '[.result.tools[] | .annotations.openWorldHint] | any')" = "false" ]
}

@test "annotations: search and roster are read-only; nothing that changes anything claims to be" {
    mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    [ "$(answer 2 | jq -r '[.result.tools[] | select(.annotations.readOnlyHint) | .name] | sort | join(",")')" = "formation_roster,memory_search" ]
}

@test "annotations: retiring a memory is the one destructive tool, so Codex asks once and offers always" {
    mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    [ "$(answer 2 | jq -r '[.result.tools[] | select(.annotations.destructiveHint) | .name] | join(",")')" = "memory_retire" ]
    [ "$(_codex_would_prompt memory_retire)" = "prompt" ]
}

@test "annotations: by Codex's own rule, every other tool runs with no prompt at all" {
    mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    local t
    for t in memory_save memory_search memory_reinforce memory_link memory_load \
             formation_join formation_say formation_progress formation_roster formation_leave; do
        [ "$(_codex_would_prompt "$t")" = "no-prompt" ] || { echo "$t would prompt"; return 1; }
    done
}

# ---------------------------------------------------------------------------------------------
# tool: each tool's request and response (test case 1, requirement 2)
# ---------------------------------------------------------------------------------------------

@test "tool: memory_save sends the content for processing and says MMRY received it" {
    mcp "$(call 10 memory_save '{"content":"DECISION: MARK-31743 use UPC.","working_dir":"'"$TEST_TMPDIR/proj"'"}' '{"sessionId":"conv-A"}')"
    [ "$(is_error 10)" = "false" ]
    [[ "$(text_of 10)" == *"Memory sent to MMRY AI"* ]] || return 1
    grep -q '^POST http://fake.invalid/api/memories/process .*MARK-31743 use UPC' "$REQLOG"
}

@test "tool: memory_save with supersedes names the memory being replaced" {
    mcp "$(call 11 memory_save '{"content":"corrected","supersedes":42}')"
    grep -q '^POST http://fake.invalid/api/memories/process .*42' "$REQLOG"
}

@test "tool: memory_save refuses with no content and sends nothing" {
    mcp "$(call 12 memory_save '{}')"
    [ "$(is_error 12)" = "true" ]
    [[ "$(text_of 12)" == *"content is required"* ]] || return 1
    [ ! -s "$REQLOG" ]
}

@test "tool: memory_search sends the query and prints each match with its id" {
    mcp "$(call 20 memory_search '{"query":"refund","scope":"backend"}')"
    [ "$(is_error 20)" = "false" ]
    [[ "$(text_of 20)" == *"id 41 | Operational | backend | Refund Handling"* ]] || return 1
    grep -q '^GET http://fake.invalid/api/memories/search?.*refund' "$REQLOG"
    grep -q '^GET http://fake.invalid/api/memories/search?.*backend' "$REQLOG"
}

@test "tool: memory_reinforce posts to the memory's reinforce route" {
    mcp "$(call 30 memory_reinforce '{"id":41}')"
    [ "$(is_error 30)" = "false" ]
    [[ "$(text_of 30)" == *"Memory reinforced."* ]] || return 1
    grep -q '^POST http://fake.invalid/api/memories/41/reinforce' "$REQLOG"
}

@test "tool: memory_link posts the link with its type" {
    mcp "$(call 40 memory_link '{"source_id":41,"target_id":87,"link_type":"related"}')"
    [ "$(is_error 40)" = "false" ]
    [[ "$(text_of 40)" == *"Memories linked."* ]] || return 1
    grep -q '^POST http://fake.invalid/api/memories/41/links .*87.*related' "$REQLOG"
}

@test "tool: memory_link refuses a link type MMRY does not have, and sends nothing" {
    mcp "$(call 41 memory_link '{"source_id":41,"target_id":87,"link_type":"likes"}')"
    [ "$(is_error 41)" = "true" ]
    [ ! -s "$REQLOG" ]
}

@test "tool: memory_retire deactivates the memory" {
    mcp "$(call 50 memory_retire '{"id":41}')"
    [ "$(is_error 50)" = "false" ]
    [[ "$(text_of 50)" == *"Memory deactivated."* ]] || return 1
    grep -q '^DELETE http://fake.invalid/api/memories/41' "$REQLOG"
}

@test "tool: an id that is not a positive whole number is refused before anything is sent" {
    mcp "$(call 51 memory_retire '{"id":"41; rm -rf /"}')" "$(call 52 memory_retire '{"id":-3}')" "$(call 53 memory_reinforce '{"id":1.5}')"
    [ "$(is_error 51)" = "true" ]
    [ "$(is_error 52)" = "true" ]
    [ "$(is_error 53)" = "true" ]
    [ ! -s "$REQLOG" ]
}

@test "tool: an argument is never interpreted by a shell" {
    # The content reaches the API byte for byte: no expansion, no command substitution.
    mcp "$(call 13 memory_save '{"content":"$(touch PWNED) `id` ${HOME} '"'"'q'"'"' \"dq\""}')"
    [ "$(is_error 13)" = "false" ]
    [ ! -e "$PLUGIN_ROOT/PWNED" ] || return 1
    [ ! -e PWNED ] || return 1
    grep -qF '$(touch PWNED) `id` ${HOME}' "$REQLOG"
}

@test "tool: memory_load runs the session-start load for this conversation and returns its message, not hook JSON" {
    mcp "$(call 60 memory_load '{"working_dir":"'"$TEST_TMPDIR/proj"'"}' '{"sessionId":"conv-A"}')"
    [ "$(is_error 60)" = "false" ]
    [[ "$(text_of 60)" != *"hookSpecificOutput"* ]] || return 1
    [[ "$(text_of 60)" != *"could not be read from stdin"* ]] || return 1
    grep -q '^GET http://fake.invalid/api/memories/startup' "$REQLOG"
    grep -q '^POST http://fake.invalid/api/sessions .*conv-A' "$REQLOG"
}

@test "tool: formation_join enrols THIS conversation and records it locally" {
    mcp "$(call 70 formation_join '{"formation_id":77}' '{"sessionId":"conv-A","threadId":"conv-A"}')"
    [ "$(is_error 70)" = "false" ]
    [[ "$(text_of 70)" == *"Joined formation 77: Ship it"* ]] || return 1
    [[ "$(text_of 70)" == *"Report to the lead at every stopping point"* ]] || return 1
    grep -q '^POST http://fake.invalid/api/formations/77/join .*"sessionId":"conv-A"' "$REQLOG"
    [ "$(head -1 "$TMPDIR/.mmry-formation-conv-A")" = "77" ]
}

@test "tool: formation_say sends to the formation, or to one member" {
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-A"
    mcp "$(call 80 formation_say '{"message":"heads up"}' '{"sessionId":"conv-A"}')" \
        "$(call 81 formation_say '{"message":"for the lead","to_member_id":5}' '{"sessionId":"conv-A"}')"
    [ "$(is_error 80)" = "false" ]
    [[ "$(text_of 80)" == *"Sent to formation 77"* ]] || return 1
    grep -q '^POST http://fake.invalid/api/formations/77/transmissions .*"sessionId":"conv-A".*heads up' "$REQLOG"
    grep -q '^POST http://fake.invalid/api/formations/77/transmissions .*for the lead.*"recipientMemberId":5' "$REQLOG"
}

@test "tool: formation_progress reports this conversation's own roster entry" {
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-B"
    mcp "$(call 90 formation_progress '{"state":"Blocked","note":"waiting on keys"}' '{"sessionId":"conv-B"}')"
    [ "$(is_error 90)" = "false" ]
    grep -q '^PUT http://fake.invalid/api/formations/77/members/6/progress .*"progress":"Blocked".*waiting on keys' "$REQLOG"
}

@test "tool: formation_progress refuses a state MMRY does not have, and sends nothing" {
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-B"
    mcp "$(call 91 formation_progress '{"state":"Finished"}' '{"sessionId":"conv-B"}')"
    [ "$(is_error 91)" = "true" ]
    [ ! -s "$REQLOG" ]
}

@test "tool: formation_roster reads this conversation's formation and lists ids and the lead" {
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-A"
    mcp "$(call 100 formation_roster '{}' '{"sessionId":"conv-A"}')"
    [ "$(is_error 100)" = "false" ]
    [[ "$(text_of 100)" == *"5  Lead"* ]] || return 1
    grep -q '^GET http://fake.invalid/api/formations/77 ' "$REQLOG"
}

@test "tool: formation_leave releases this conversation on the service and here" {
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-A"
    mcp "$(call 110 formation_leave '{}' '{"sessionId":"conv-A"}')"
    [ "$(is_error 110)" = "false" ]
    grep -q '^POST http://fake.invalid/api/formations/leave .*"sessionId":"conv-A"' "$REQLOG"
    [ ! -e "$TMPDIR/.mmry-formation-conv-A" ]
}

@test "tool: an unknown tool is a JSON-RPC error, not a silent success" {
    mcp "$(call 120 memory_delete_everything '{}')"
    [ "$(answer 120 | jq -r '.error.code')" = "-32602" ]
}

@test "tool: a failure from MMRY AI is reported as an error and the server keeps serving" {
    FAKE_FAIL_ALL=1 mcp "$(call 130 memory_reinforce '{"id":41}')" '{"jsonrpc":"2.0","id":131,"method":"ping"}'
    [ "$(is_error 130)" = "true" ]
    [ "$(answer 131 | jq -c '.result')" = "{}" ]
}

@test "tool: with no credential the assistant is told how to set up, and the server keeps serving" {
    unset MMRY_API_KEY
    mcp "$(call 140 memory_search '{"query":"x"}')" '{"jsonrpc":"2.0","id":141,"method":"ping"}'
    [ "$(is_error 140)" = "true" ]
    [[ "$(text_of 140)" == *"no Codex credential was found"* ]] || return 1
    [ "$(answer 141 | jq -c '.result')" = "{}" ]
    [ ! -s "$REQLOG" ]
}

# ---------------------------------------------------------------------------------------------
# identity: which conversation a call belongs to (requirement 3, test case 3)
# ---------------------------------------------------------------------------------------------

@test "identity: two conversations on ONE server join different formations, each under its own id" {
    mcp "$(call 200 formation_join '{"formation_id":77}' '{"sessionId":"conv-A"}')" \
        "$(call 201 formation_join '{"formation_id":88}' '{"sessionId":"conv-B"}')"
    [ "$(is_error 200)" = "false" ]
    [ "$(is_error 201)" = "false" ]
    [ "$(head -1 "$TMPDIR/.mmry-formation-conv-A")" = "77" ]
    [ "$(head -1 "$TMPDIR/.mmry-formation-conv-B")" = "88" ]
    grep -q '/api/formations/77/join .*"sessionId":"conv-A"' "$REQLOG"
    grep -q '/api/formations/88/join .*"sessionId":"conv-B"' "$REQLOG"
    ! grep -q '/api/formations/77/join .*conv-B' "$REQLOG" || return 1
}

@test "identity: interleaved calls each speak for their own conversation" {
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-A"
    printf '88\n' > "$TMPDIR/.mmry-formation-conv-B"
    mcp "$(call 210 formation_say '{"message":"from A"}' '{"sessionId":"conv-A"}')" \
        "$(call 211 formation_say '{"message":"from B"}' '{"sessionId":"conv-B"}')" \
        "$(call 212 formation_say '{"message":"A again"}' '{"sessionId":"conv-A"}')"
    grep -q '/api/formations/77/transmissions .*"sessionId":"conv-A".*from A' "$REQLOG"
    grep -q '/api/formations/88/transmissions .*"sessionId":"conv-B".*from B' "$REQLOG"
    grep -q '/api/formations/77/transmissions .*"sessionId":"conv-A".*A again' "$REQLOG"
    [ "$(grep -c '/api/formations/88/' "$REQLOG")" -eq 1 ]
}

@test "identity: threadId is used when sessionId is absent (Codex's app call carries only threadId)" {
    mcp "$(call 220 formation_join '{"formation_id":77}' '{"threadId":"conv-T"}')"
    [ "$(is_error 220)" = "false" ]
    [ "$(head -1 "$TMPDIR/.mmry-formation-conv-T")" = "77" ]
}

@test "identity: sessionId wins over threadId, because it is the id Codex's hooks poll with" {
    mcp "$(call 225 formation_join '{"formation_id":77}' '{"sessionId":"conv-S","threadId":"conv-sub"}')"
    [ -e "$TMPDIR/.mmry-formation-conv-S" ]
    [ ! -e "$TMPDIR/.mmry-formation-conv-sub" ]
}

@test "identity: a formation call that names no conversation is refused, never guessed" {
    export CODEX_SESSION_ID="inherited-from-somewhere"
    mcp "$(call 230 formation_join '{"formation_id":77}')"
    [ "$(is_error 230)" = "true" ]
    [[ "$(text_of 230)" == *"did not say which conversation"* ]] || return 1
    [ ! -s "$REQLOG" ]
    [ ! -e "$TMPDIR/.mmry-formation-inherited-from-somewhere" ]
}

@test "identity: a Claude Code session id in the server's environment never stands in for the conversation" {
    export CLAUDE_CODE_SESSION_ID="claude-window" CLAUDE_SESSION_ID="claude-window"
    mcp "$(call 240 formation_join '{"formation_id":77}' '{"sessionId":"conv-A"}')"
    grep -q '"sessionId":"conv-A"' "$REQLOG"
    ! grep -q 'claude-window' "$REQLOG" || return 1
}

@test "identity: the server keeps nothing between calls; the conversation is read from each one" {
    # conv-A joins, then a call for conv-B with no state of its own must not see A's formation.
    mcp "$(call 250 formation_join '{"formation_id":77}' '{"sessionId":"conv-A"}')" \
        "$(call 251 formation_say '{"message":"who am I"}' '{"sessionId":"conv-B"}')"
    [ "$(is_error 251)" = "true" ]
    [[ "$(text_of 251)" == *"not in a formation"* ]] || return 1
    ! grep -q 'who am I' "$REQLOG" || return 1
}

@test "handlers never read the protocol stream: a burst of requests is answered one for one, in order" {
    mcp "$(call 300 memory_reinforce '{"id":1}')" "$(call 301 memory_reinforce '{"id":2}')" \
        "$(call 302 memory_reinforce '{"id":3}')" '{"jsonrpc":"2.0","id":303,"method":"ping"}'
    [ "$(printf '%s\n' "$output" | jq -r '.id' | tr -d '\r' | paste -sd, -)" = "300,301,302,303" ]
}
