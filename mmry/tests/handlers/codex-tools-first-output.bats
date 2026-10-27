#!/usr/bin/env bats
# codex-tools-first-output.bats - on Codex, nothing MMRY PRINTS to a model names a script for an
# operation MMRY's own tools cover (#31743, fix round 1).
#
# The static surfaces (skill, customer page, manifests, the tool server's own words) are pinned in
# structural/codex-tools-first.bats. This file runs the hooks and handlers as Codex runs them and
# reads what comes out: the session-start load and its empty-account welcome (which is also what
# the memory_load tool returns), the per-turn save prompt, the Foundation remedies, every formation
# handler's remedies, the roster footer, and the sandbox-access hint. Each one used to name a
# script; in the live Mac CLI run the model ran the script it was shown, got HTTP 000 from the
# sandbox, and only then found the tool.
#
# EVERY CODEX ASSERTION HAS A CLAUDE CODE CONTROL, byte for byte where the string is short enough
# to state, because requirement 4 is that Claude Code does not change, and because "names no
# script" alone is satisfied by a message that names nothing at all.

load '../helpers/test-helper'

# The scripts of the operations the tool server covers.
# #31789 added the lead's four: start, assign, report and debrief. #32270 added remove.
TOOL_COVERED_SCRIPTS_RE='(save-memory|search-memories|deactivate-memory|session-start|formation-(join|say|roster|leave|start|assign|report|debrief|remove))\.sh'
# formation-progress.sh is tool-covered only for this conversation's own report; the lead reporting
# for ANOTHER member (a member id first) has no tool and keeps the script.
PROGRESS_OWN_RE='formation-progress\.sh( <Accepted|$|[^ 0-9<]| [^0-9<])'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$BIN" "$CODEX_DIR/mmry" "$TEST_TMPDIR/proj"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
# A fake MMRY AI with an EMPTY account: no memories, sessions accepted, a one-member roster.
out=""; method="GET"; url=""; prev=""
for arg in "$@"; do
    case "$prev" in -o) out="$arg" ;; -X) method="$arg" ;; esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
code=200; resp='[]'
case "$method $url" in
    "POST "*/api/sessions) code=201; resp='' ;;
    "GET "*/api/formations/[0-9]*) resp='{"formation":{"id":42,"objective":"migrate the billing schema"},"members":[{"id":11,"sessionId":"s1","role":"Lead","email":"lead@test.mnemo","assignment":"coordinate","leftDate":null}]}' ;;
    "POST "*/api/formations/*/join) code=409; resp='{"error":"already"}' ;;
    "GET "*/api/memories*) resp='[]' ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE CODEX_SESSION_ID CODEX_THREAD_ID
    export CLAUDE_SESSION_ID="bats-toolsfirst-$$"
    bash "$PLUGIN_ROOT/hooks-handlers/formation-state.sh" clear "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
    SERVER="$PLUGIN_ROOT/hooks-handlers/mcp-server.sh"
}

teardown() {
    bash "$PLUGIN_ROOT/hooks-handlers/formation-state.sh" clear "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
}

# Lines of $1 that name a tool-covered script.
_script_hits() {
    printf '%s\n' "$1" | grep -E "$TOOL_COVERED_SCRIPTS_RE|$PROGRESS_OWN_RE" || true
}

_assert_no_tool_covered_script() {
    local hits; hits="$(_script_hits "$1")"
    [ -z "$hits" ] || { echo "Codex output names a tool-covered script:"; echo "$hits"; return 1; }
}

_server_tools() {
    grep -o '"name": "[a-z_]*"' "$SERVER" | sed 's/"name": "//; s/"$//' | sort -u
}

# Every "the mmry_plugin <tool> tool" in $1 is a tool the server offers, and there is at least one.
_assert_names_real_tools() {
    local tools t
    tools="$(printf '%s' "$1" | grep -o 'the mmry_plugin [a-z_]* tool' | sed 's/^the mmry_plugin //; s/ tool$//' | sort -u)"
    [ -n "$tools" ] || { echo "no mmry_plugin tool named in: $1"; return 1; }
    while IFS= read -r t; do
        _server_tools | grep -qx "$t" || { echo "names a tool the server does not offer: $t"; return 1; }
    done <<< "$tools"
}

_session_start() {
    # $1 host (codex|claude). The hook's additionalContext.
    local payload='{"session_id":"bats-ss-1","hook_event_name":"SessionStart","source":"startup","cwd":"'"$TEST_TMPDIR/proj"'"}'
    if [[ "$1" == "codex" ]]; then
        printf '%s\n' "$payload" | env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
    else
        printf '%s\n' "$payload" | bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
    fi | jq -r '.hookSpecificOutput.additionalContext // empty'
}

# ---------------------------------------------------------------------------------------------
# session start, and memory_load, on an empty account
# ---------------------------------------------------------------------------------------------

@test "session start: an empty Codex account is told to save with memory_save, not save-memory.sh" {
    local ctx; ctx="$(_session_start codex)"
    [[ "$ctx" == *"fresh start"* ]] || { echo "not the empty-account branch: $ctx"; return 1; }
    [[ "$ctx" == *"Use the mmry_plugin memory_save tool for each one"* ]] || { echo "$ctx"; return 1; }
    _assert_no_tool_covered_script "$ctx"
    _assert_names_real_tools "$ctx"
}

@test "session start: req4 - on Claude Code the empty-account welcome is unchanged" {
    local ctx; ctx="$(_session_start claude)"
    [[ "$ctx" == *"fresh start"* ]] || { echo "not the empty-account branch: $ctx"; return 1; }
    [[ "$ctx" == *"Keep it conversational — not a checklist. Use save-memory.sh with --working-dir and --session-id for each one. When done, let them know they can always say remember this to save something new, or /mmry:help for a quick reference."* ]] || { echo "$ctx"; return 1; }
    [[ "$ctx" != *"mmry_plugin"* ]]
}

@test "memory_load: what the tool returns on an empty account names the tool, not the script" {
    local out text
    out="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_load","arguments":{"working_dir":"'"$TEST_TMPDIR/proj"'"},"_meta":{"sessionId":"conv-load-1"}}}' \
        | env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash "$SERVER" 2>/dev/null)"
    text="$(printf '%s\n' "$out" | jq -r 'select(.id == 2) | .result.content[0].text')"
    [[ "$text" == *"fresh start"* ]] || { echo "not the empty-account answer: $out"; return 1; }
    _assert_no_tool_covered_script "$text"
    _assert_names_real_tools "$text"
}

# ---------------------------------------------------------------------------------------------
# the save prompt
# ---------------------------------------------------------------------------------------------

_stop() {
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-count" "$TMPDIR/.mmry-last-save"
    if [[ "$1" == "codex" ]]; then
        MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" 2>&1
    else
        env -u MMRY_HOST bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" 2>&1
    fi
}

@test "save prompt: on Codex it names memory_save and no script" {
    local out; out="$(_stop codex || true)"
    [[ "$out" == *"Save what is new"* ]] || { echo "the prompt did not fire: $out"; return 1; }
    [[ "$out" == *"call the mmry_plugin memory_save tool for each"* ]] || { echo "$out"; return 1; }
    _assert_no_tool_covered_script "$out"
    _assert_names_real_tools "$out"
}

@test "save prompt: req4 - on Claude Code the directive is the one it always was" {
    local out; out="$(_stop claude || true)"
    [[ "$out" == *'Save what is new since the last memory: identify decisions, findings, and corrections from this segment of the session, then call "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" with --context for each. If nothing new is worth keeping, skip and proceed.'* ]] || { echo "$out"; return 1; }
    [[ "$out" != *"mmry_plugin"* ]]
}

# ---------------------------------------------------------------------------------------------
# the derived references every handler message is built from
# ---------------------------------------------------------------------------------------------

_ref() {
    # $1 host, rest: a shell snippet using the lib-host functions.
    local host="$1"; shift
    env ${host:+MMRY_HOST=$host} CODEX_HOME="$CODEX_DIR" MMRY_ALLOW_NO_CREDENTIAL=1 \
        bash -c 'source "$1/hooks-handlers/lib-host.sh"; shift; eval "$*"' _ "$PLUGIN_ROOT" "$@"
}

@test "references: on Codex each tool-covered operation is the tool, and the tool exists" {
    local out
    out="$(_ref codex '
        for a in "join" "join 12" "leave" "roster" "say" "progress"; do set -- $a; mmry_host_formation_ref "$@"; echo; done
        mmry_host_formation_ref say "\"...\" <id>"; echo
        mmry_host_formation_ref progress "<Accepted|Done|Blocked|Abandoned>"; echo
        for c in save search load-memories; do mmry_host_command_ref "$c"; echo; done
        for s in start assign report debrief; do mmry_host_formation_ref "$s"; echo; done
        mmry_host_formation_ref start "\"what the formation is for\""; echo
        mmry_host_formation_ref report 42; echo
        mmry_host_formation_ref remove; echo
        mmry_host_formation_ref remove "<memberId>"; echo
        mmry_host_formation_ref remove "<memberId> <formationId>"; echo')"
    # 20: #32270 added the three forms formation-remove.sh prints.
    [ "$(printf '%s\n' "$out" | grep -c '^the mmry_plugin ')" -eq 20 ] || { echo "$out"; return 1; }
    _assert_no_tool_covered_script "$out"
    _assert_names_real_tools "$out"
    [[ "$out" == *"the mmry_plugin formation_join tool with formation_id 12"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *'the mmry_plugin formation_start tool with objective "what the formation is for"'* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"the mmry_plugin formation_report tool with formation_id 42"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"the mmry_plugin formation_remove tool with member_id (from the roster)"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"the mmry_plugin formation_remove tool with member_id (from the roster) and formation_id"* ]] || { echo "$out"; return 1; }
}

@test "references: on Codex the operations with no tool keep their runnable script" {
    local out
    out="$(_ref codex '
        for s in list claim; do mmry_host_formation_ref "$s"; echo; done
        mmry_host_formation_ref progress 7 Done; echo
        for c in setup visibility feedback foundation-status; do mmry_host_command_ref "$c"; echo; done')"
    [ "$(printf '%s\n' "$out" | grep -c "^bash ${CODEX_DIR}/mmry/")" -eq 7 ] || { echo "$out"; return 1; }
    [[ "$out" != *"mmry_plugin"* ]]
}

@test "references: req4 - on Claude Code every one of them is the slash command it always was" {
    local out expected
    out="$(_ref "" '
        for a in "join" "join 12" "leave" "roster" "say" "progress"; do set -- $a; mmry_host_formation_ref "$@"; echo; done
        for c in save search load-memories; do mmry_host_command_ref "$c"; echo; done
        for s in start assign report debrief remove; do mmry_host_formation_ref "$s"; echo; done')"
    expected="$(printf '%s\n' '/mmry:formation join' '/mmry:formation join 12' '/mmry:formation leave' \
        '/mmry:formation roster' '/mmry:formation say' '/mmry:formation progress' \
        '/mmry:save' '/mmry:search' '/mmry:load-memories' \
        '/mmry:formation start' '/mmry:formation assign' '/mmry:formation report' '/mmry:formation debrief' \
        '/mmry:formation remove')"
    [ "$out" = "$expected" ] || { echo "--- expected"; echo "$expected"; echo "--- actual"; echo "$out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# every formation handler's remedies, and the roster footer
# ---------------------------------------------------------------------------------------------

_codex_handler() {
    env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash "$@" 2>&1 || true
}

@test "formation handlers: no Codex remedy names a tool-covered script, with no argument, a bad one, or out of a formation" {
    local f base op out failures="" seen=0
    for f in "$PLUGIN_ROOT"/hooks-handlers/formation-*.sh; do
        base="$(basename "$f")"; op="${base#formation-}"; op="${op%.sh}"
        case "$op" in state|check) continue ;; esac
        for args in "" "not-a-number" "a message"; do
            # shellcheck disable=SC2086
            out="$(_codex_handler "$f" $args)"
            [[ "$out" == *"mmry_plugin"* ]] && seen=$((seen + 1))
            [ -z "$(_script_hits "$out")" ] || failures="${failures}
  ${base} [${args}]: $(_script_hits "$out" | head -1)"
        done
    done
    [ -z "$failures" ] || { echo "Codex remedies naming a tool-covered script:${failures}"; return 1; }
    # The control: the sweep really reached remedies that name tools, or it proved nothing.
    [ "$seen" -ge 8 ] || { echo "only ${seen} outputs named a tool; the sweep is not reaching the remedies"; return 1; }
}

@test "roster footer: on Codex it hands the model the say and progress tools" {
    bash "$PLUGIN_ROOT/hooks-handlers/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local out; out="$(_codex_handler "$PLUGIN_ROOT/hooks-handlers/formation-roster.sh")"
    [[ "$out" == *"migrate the billing schema"* ]] || { echo "not the roster: $out"; return 1; }
    [[ "$out" == *"the mmry_plugin formation_say tool"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"the mmry_plugin formation_progress tool"* ]] || { echo "$out"; return 1; }
    _assert_no_tool_covered_script "$out"
    _assert_names_real_tools "$out"
}

@test "join: a 409 on Codex sends the model to the formation_leave tool" {
    local out; out="$(env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" CODEX_SESSION_ID="conv-409" \
        bash "$PLUGIN_ROOT/hooks-handlers/formation-join.sh" 42 2>&1 || true)"
    [[ "$out" == *"Run the mmry_plugin formation_leave tool first."* ]] || { echo "$out"; return 1; }
    _assert_no_tool_covered_script "$out"
}

# ---------------------------------------------------------------------------------------------
# the sandbox-access hint, the one message a model sees AFTER running a script by mistake
# ---------------------------------------------------------------------------------------------

@test "access hint: on Codex an HTTP 000 from a script sends tool-covered operations to the tool first" {
    printf '%s' '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"k"}' > "$CODEX_DIR/mmry-config.json"
    local out
    out="$(env -u MMRY_API_KEY -u MMRY_API_URL -u MMRY_AUTH_METHOD MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash -c '
        source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1 || exit 9
        MMRY_HTTP_CODE=000 MMRY_RESPONSE="curl failed"
        _mmry_print_error save' _ "$PLUGIN_ROOT" 2>&1)"
    [[ "$out" == *"request_permissions"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"do not ask for access: call the"* ]] || { echo "$out"; return 1; }
    # The tools come before the request, so the model reads them first.
    local tools_at req_at
    tools_at="$(printf '%s\n' "$out" | grep -n 'memory_save' | head -1 | cut -d: -f1)"
    req_at="$(printf '%s\n' "$out" | grep -n 'request_permissions' | head -1 | cut -d: -f1)"
    [ -n "$tools_at" ] && [ "$tools_at" -lt "$req_at" ] || { echo "$out"; return 1; }
    _assert_no_tool_covered_script "$out"
}

@test "access hint: it names every tool the server offers, the lead's included, and the lead's operations in words (#31789)" {
    # Derived from the server, so a tool added there and missing here fails. Found by
    # run-31789-mutations.sh: the hint could stop naming start, assign, report and debrief and no
    # test noticed.
    printf '%s' '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"k"}' > "$CODEX_DIR/mmry-config.json"
    local out t missing=""
    out="$(env -u MMRY_API_KEY -u MMRY_API_URL -u MMRY_AUTH_METHOD MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash -c '
        source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1 || exit 9
        MMRY_HTTP_CODE=000 MMRY_RESPONSE="curl failed"
        _mmry_print_error save' _ "$PLUGIN_ROOT" 2>&1)"
    [[ "$out" == *"do not ask for access: call the"* ]] || { echo "$out"; return 1; }
    while IFS= read -r t; do
        [[ "$out" == *"$t"* ]] || missing="${missing} ${t}"
    done < <(_server_tools)
    [ -z "$missing" ] || { echo "the access hint does not name:${missing}"; echo "$out"; return 1; }
    local flat; flat="$(printf '%s' "$out" | tr '\n' ' ')"
    [[ "$flat" == *"formation start, join, say, assign,"* ]] || { echo "$out"; return 1; }
    [[ "$flat" == *"report, debrief, remove a member or leave"* ]] || { echo "$out"; return 1; }
}
