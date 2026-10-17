#!/usr/bin/env bats
# codex-formation-lead.bats - what a Codex lead is told about hearing its members (#31789).
#
# Codex cannot wake an idle conversation (established from openai/codex rust-v0.160.0; the evidence
# is in docs/evidence/31789/README.md), so a lead on Codex hears its members only on its next
# action. Requirement 0 (Eric Barone, 2026-10-07): when that is so, the start-formation reply in
# Codex states the limit and recommends Claude Code as lead. Requirement 3: a Codex lead is told
# plainly that members' messages arrive on its next action, not while it sits idle, and what to do
# instead. Both are asserted here on the confirmations the handlers PRINT, run as Codex runs them,
# and each Codex assertion has a Claude Code control pinned byte for byte, because Claude Code is
# unchanged by this task. Whether the wording reads plainly is for a person to judge; that it is
# there, complete, and only on Codex is for this file.

load '../helpers/test-helper'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$BIN" "$CODEX_DIR/mmry" "$TEST_TMPDIR/proj"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
# A fake MMRY AI: starting a formation returns id 42; assigning returns the member as it now stands.
out=""; method="GET"; url=""; prev=""
for arg in "$@"; do
    case "$prev" in -o) out="$arg" ;; -X) method="$arg" ;; esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
code=200; resp='{}'
case "$method $url" in
    "POST "*/api/sessions) code=201; resp='' ;;
    "POST "*/api/formations) code=201; resp='{"id":42,"objective":"migrate the billing schema"}' ;;
    "PUT "*/api/formations/*/members/*) resp='{"id":7,"role":"Wingman","assignment":"write the migration"}' ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
    export CLAUDE_SESSION_ID="bats-lead-$$"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" clear "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
}

teardown() {
    bash "$HH/formation-state.sh" clear "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
}

_codex() { env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash "$@" 2>&1; }
_claude() { env -u MMRY_HOST bash "$@" 2>&1; }

# The tools the server offers, from its own tools/list table.
_server_tools() {
    grep -o '"name": "[a-z_]*"' "$HH/mcp-server.sh" | sed 's/"name": "//; s/"$//' | sort -u
}

# The parts of the lead notice that carry its meaning. Each is one fact the customer must be told.
_assert_lead_notice_start() {
    local out="$1" phrase
    for phrase in \
        "Tell the customer this in your reply" \
        "Codex cannot wake an idle conversation" \
        "hears its members only on its next action" \
        "never while it sits idle" \
        "we recommend it does not lead one" \
        "start the formation from a Claude Code session" \
        "join it from here" \
        "check in while the work runs" \
        "the mmry_plugin formation_roster tool" \
        "ask the customer to send a message here"; do
        [[ "$out" == *"$phrase"* ]] || { echo "the Codex start confirmation lacks: $phrase"; echo "$out"; return 1; }
    done
}

_assert_customer_typography() {
    # No em dash, en dash or curly quote in anything a customer may be read.
    if printf '%s' "$1" | grep -q $'\xe2\x80\x94\|\xe2\x80\x93\|\xe2\x80\x98\|\xe2\x80\x99\|\xe2\x80\x9c\|\xe2\x80\x9d'; then
        echo "customer text carries a dash or curly quote: $1"; return 1
    fi
}

# ---------------------------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------------------------

@test "R0/R3 start: on Codex the confirmation states the limit, says what to do, and recommends a Claude Code lead" {
    local out; out="$(CODEX_SESSION_ID="conv-lead-$$" _codex "$HH/formation-start.sh" "migrate the billing schema")"
    [[ "$out" == *"Started formation 42: migrate the billing schema"* ]] || { echo "$out"; return 1; }
    _assert_lead_notice_start "$out"
    _assert_customer_typography "$out"
    # Every tool it names is one the server offers.
    local t
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        _server_tools | grep -qx "$t" || { echo "names a tool the server does not offer: $t"; return 1; }
    done < <(printf '%s' "$out" | grep -o 'the mmry_plugin [a-z_]* tool' | sed 's/^the mmry_plugin //; s/ tool$//' | sort -u)
    bash "$HH/formation-state.sh" clear "conv-lead-$$" >/dev/null 2>&1 || true
}

@test "R0 start: the notice comes after the id, so the id the customer must share is read first" {
    local out; out="$(CODEX_SESSION_ID="conv-lead2-$$" _codex "$HH/formation-start.sh" "migrate the billing schema")"
    local id_at notice_at
    id_at="$(printf '%s\n' "$out" | grep -n 'Started formation 42' | head -1 | cut -d: -f1)"
    notice_at="$(printf '%s\n' "$out" | grep -n 'Codex cannot wake an idle conversation' | head -1 | cut -d: -f1)"
    [ -n "$id_at" ] && [ -n "$notice_at" ] && [ "$id_at" -lt "$notice_at" ] || { echo "$out"; return 1; }
    bash "$HH/formation-state.sh" clear "conv-lead2-$$" >/dev/null 2>&1 || true
}

@test "req: on Claude Code the start confirmation is unchanged, byte for byte" {
    local out; out="$(_claude "$HH/formation-start.sh" "migrate the billing schema")"
    local expected
    expected="$(printf '%s\n' 'Started formation 42: migrate the billing schema' \
        'You are the lead. Tell the others to run /mmry:formation join 42, then use /mmry:formation say to keep them posted.')"
    [ "$out" = "$expected" ] || { echo "--- expected"; echo "$expected"; echo "--- actual"; echo "$out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# assign
# ---------------------------------------------------------------------------------------------

@test "R3 assign: on Codex the lead is told the member's report reaches it on its next action, and how to check in" {
    bash "$HH/formation-state.sh" set 42 "conv-lead3-$$"
    local out; out="$(CODEX_SESSION_ID="conv-lead3-$$" _codex "$HH/formation-assign.sh" 7 "write the migration")"
    [[ "$out" == *"Member 7 in formation 42 is now Wingman, working on: write the migration."* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"Tell the customer this in your reply, every time you assign work"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"Their report reaches me only when you next send a message here, not while this conversation sits idle, so check in with me once they have had time to work."* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"reach you only on your next action"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"call the mmry_plugin formation_roster tool"* ]] || { echo "$out"; return 1; }
    _assert_customer_typography "$out"
    bash "$HH/formation-state.sh" clear "conv-lead3-$$" >/dev/null 2>&1 || true
}

@test "R3 assign (QA round 2): the line to tell the customer comes straight after the confirmation, not last" {
    # On Mac and Windows the lead's reply kept the confirmation and the member line, and dropped the
    # next-action line that came last. It is now line 2, labelled for the customer.
    bash "$HH/formation-state.sh" set 42 "conv-lead4-$$"
    local out; out="$(CODEX_SESSION_ID="conv-lead4-$$" _codex "$HH/formation-assign.sh" 7 "write the migration")"
    local second; second="$(printf '%s\n' "$out" | sed -n 2p)"
    [[ "$second" == "Tell the customer this in your reply, every time you assign work"* ]] || { echo "$out"; return 1; }
    [[ "$(printf '%s\n' "$out" | sed -n 3p)" == "They will see it after their next tool call"* ]] || { echo "$out"; return 1; }
    bash "$HH/formation-state.sh" clear "conv-lead4-$$" >/dev/null 2>&1 || true
}

@test "req: on Claude Code the assign confirmation is unchanged, byte for byte" {
    bash "$HH/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local out; out="$(_claude "$HH/formation-assign.sh" 7 "write the migration")"
    local expected
    expected="$(printf '%s\n' 'Member 7 in formation 42 is now Wingman, working on: write the migration.' \
        'They will see it after their next tool call, marked as directed at them. No other member was told.')"
    [ "$out" = "$expected" ] || { echo "--- expected"; echo "$expected"; echo "--- actual"; echo "$out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# the function itself
# ---------------------------------------------------------------------------------------------

@test "lib: mmry_host_lead_notice prints nothing and returns 1 on Claude Code, for every kind" {
    local k out rc
    for k in start assign; do
        out="$(env -u MMRY_HOST MMRY_ALLOW_NO_CREDENTIAL=1 bash -c 'source "$1/hooks-handlers/lib-host.sh"; mmry_host_lead_notice "$2"' _ "$PLUGIN_ROOT" "$k")" && rc=0 || rc=$?
        [ -z "$out" ] || { echo "$k printed on Claude Code: $out"; return 1; }
        [ "$rc" -eq 1 ] || { echo "$k returned $rc on Claude Code"; return 1; }
    done
}

@test "lib: an unknown kind prints nothing on Codex either" {
    local out
    out="$(env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_ALLOW_NO_CREDENTIAL=1 bash -c 'source "$1/hooks-handlers/lib-host.sh"; mmry_host_lead_notice nope' _ "$PLUGIN_ROOT" || true)"
    [ -z "$out" ]
}

@test "server: formation_start through the tool server carries the whole notice" {
    local out text
    out="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"formation_start","arguments":{"objective":"migrate the billing schema"},"_meta":{"sessionId":"conv-srv-'"$$"'"}}}' \
        | env MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" bash "$HH/mcp-server.sh" 2>/dev/null)"
    text="$(printf '%s\n' "$out" | jq -r 'select(.id == 2) | .result.content[0].text')"
    [[ "$text" == *"Started formation 42"* ]] || { echo "$out"; return 1; }
    _assert_lead_notice_start "$text"
    bash "$HH/formation-state.sh" clear "conv-srv-$$" >/dev/null 2>&1 || true
}
