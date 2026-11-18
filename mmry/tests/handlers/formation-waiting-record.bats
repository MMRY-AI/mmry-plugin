#!/usr/bin/env bats
# formation-waiting-record.bats - which tool the lead is told about when Claude Code fired its
# PermissionRequest hook (the ask record, #33900) and the round-4 naming rules (#33898). Split from
# formation-waiting.bats in #33900 round 4 to keep each file under the 64000-byte limit; the shared
# setup and helpers are in helpers/formation-waiting.bash.

load '../helpers/test-helper'
load '../helpers/formation-waiting'


# #33898 C1 in the 33900 stack (round 3): a fresh ask record names an MCP tool only when the transcript
# holds it as the one still-waiting call of its server. Claude Code 2.1.322 was measured sending an MCP
# prompt's sentence as a bare display word ("use Echo", "use Ping"; captures s1, s3, s5), so both that
# shape and the "<server> - <title> (MCP)" shape are covered.
@test "X-24 33898 C1 in the 33900 stack: a fresh ask record names an MCP tool only when the transcript holds it as the one still-waiting call of its server" {
    local tp="$TEST_TMPDIR/transcript.jsonl" m
    for m in 'Ping' 'probe - Ping the probe (MCP)'; do
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"; : > "$URLS"; : > "$NOTICES"
        _transcript "$tp" mcp__probe__ping
        _ask "$(_cc_ask mcp__probe__ping)" || true
        _waiting "$(_notification_tp "Claude needs your permission to use $m" "$tp")"
        [ "$(_puts)" -eq 1 ] || { echo "for: $m"; cat "$URLS"; return 1; }
        "$(command -v jq)" -e '.toolName == "mcp__probe__ping"' < "$BODIES" >/dev/null || { echo "for: $m"; cat "$BODIES"; return 1; }
        _check "$(_cc_post mcp__probe__ping)" || true
        _cleared_once
        # The same record once the call has been answered (a leftover): no name.
        rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
        _tool_result "$tp" toolu_1
        _ask "$(_cc_ask mcp__probe__ping)" || true
        _waiting "$(_notification_tp "Claude needs your permission to use $m" "$tp")"
        "$(command -v jq)" -e '.toolName == null' < "$BODIES" >/dev/null || { echo "for: $m"; cat "$BODIES"; return 1; }
    done
}

@test "X-25 33898 C1 in the 33900 stack: two still-waiting calls of the record's server, or a record that disagrees with a built-in prompt, send no name" {
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # Measured shape s3: slow_read and ping both waiting when ping's prompt shows.
    _transcript "$tp" mcp__probe__slow_read mcp__probe__ping
    _ask "$(_cc_ask mcp__probe__ping)" || true
    _waiting "$(_notification_tp 'Claude needs your permission to use Ping' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    "$(command -v jq)" -e '.toolName == null' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
    # A leftover Bash record and an Edit prompt: the record is not this prompt's, so no name.
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _leftover_ask Bash
    _waiting "$(_notification_tp 'Claude needs your permission to use Edit' "$tp")"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
    "$(command -v jq)" -e '.toolName == null' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
    # A record that agrees with the built-in prompt: the word is sent.
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _leftover_ask Bash
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    "$(command -v jq)" -e '.toolName == "Bash"' < "$BODIES" >/dev/null || { cat "$BODIES"; return 1; }
}

# #33898 round 3b (lead 439's ruling 2026-11-18): without a fresh ask record, the one word after
# "permission to use" is sent only when it is a Claude Code built-in tool's name
# (_MMRY_WAITING_BUILTIN_TOOLS). On Claude Code 2.1.322 an MCP prompt's sentence can be a bare display
# word ("use Echo"), which cannot be told from a built-in's name, so any other word sends no name and
# the lead's tool sentence is left out. Codex's PermissionRequest carries tool_name and is unchanged.

@test "W-41 33898 req1 (3b): an MCP display word, use Echo, with no ask record and no matching call sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # No transcript at all.
    run _waiting "$(_notification permission_prompt 'Claude needs your permission to use Echo')"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # A transcript holding only other calls (a built-in, and an answered call of another server).
    : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    _transcript "$tp" Bash mcp__other__thing
    _tool_result "$tp" toolu_2
    run _waiting "$(_notification_tp 'Claude needs your permission to use Ping' "$tp")"
    [ "$(_puts)" -eq 2 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    ! grep -q 'Ping\|Echo' "$BODIES" "$TEST_TMPDIR"/.mmry-waiting-* || { echo "a display word was sent or stored"; return 1; }
}

@test "W-42 33898 req2 (3b): use Bash still sends Bash, also for a subagent's prompt, and other built-ins send their names" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl" w
    # A subagent's prompt: the main transcript holds only the waiting Agent call, not the Bash call.
    _transcript "$tp" Agent
    run _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    [ "$(_tool_sent)" = "Bash" ] || { cat "$BODIES"; return 1; }
    for w in Edit WebFetch NotebookEdit PowerShell Task MultiEdit; do
        _check "$(_event UserPromptSubmit)" || true
        : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
        run _waiting "$(_notification permission_prompt "Claude needs your permission to use $w")"
        [ "$(_tool_sent)" = "$w" ] || { echo "for: $w"; cat "$BODIES"; return 1; }
    done
}

@test "W-43 33898 req1 (3b): a word that is not a built-in tool's name sends no name; Codex's tool_name is unchanged" {
    JQ_BIN="$(command -v jq)"
    local w n=0
    # Memory is the first word of mcp__mmry__memory_save's display name, Memory Save. bash is not
    # Bash: the names are matched exactly.
    for w in Frobnicate Memory bash Code; do
        n=$((n + 1))
        : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
        run _waiting "$(_notification permission_prompt "Claude needs your permission to use $w")"
        [ "$(_puts)" -eq "$n" ] || { echo "for: $w"; cat "$URLS"; return 1; }
        [ "$(_tool_sent)" = "<none>" ] || { echo "for: $w"; cat "$BODIES"; return 1; }
    done
    # Codex names its tool in the payload, so a name off the list still passes the field rule.
    : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
    run _waiting "$(_permission_request apply_patch '')"
    grep -q '"toolName":"apply_patch"' "$BODIES" || { cat "$BODIES"; return 1; }
}

@test "X-26 33898 round 3b in the 33900 stack: with a fresh ask record the word is judged as before; a stale record counts as none and the built-in list applies" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" Agent
    # A fresh record that agrees with a word off the built-in list: sent, exactly as at c0d8f18.
    _leftover_ask Frobnicate
    _waiting "$(_notification_tp 'Claude needs your permission to use Frobnicate' "$tp")"
    [ "$(_tool_sent)" = "Frobnicate" ] || { cat "$BODIES"; return 1; }
    # A fresh MCP record whose call the main transcript does not hold (a subagent's call) and a display
    # word off the list: the sentence confirms no name, so the record wins (round 4, lead ruling (b);
    # until round 4 this sent no name). A record whose call the transcript holds answered, or alongside
    # another still-waiting call of its server, still sends none (X-24, X-25).
    _check "$(_event UserPromptSubmit)" || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _leftover_ask mcp__probe__echo
    _waiting "$(_notification_tp 'Claude needs your permission to use Echo' "$tp")"
    [ "$(_tool_sent)" = "mcp__probe__echo" ] || { cat "$BODIES"; return 1; }
    # A record older than the freshness window is no record: Echo is off the list, so no name.
    _check "$(_event UserPromptSubmit)" || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    printf 'asker -\ntool Echo\ninput -\nat %s\n' "$(( $(date +%s) - 3600 ))" > "$TEST_TMPDIR/.mmry-asking-$SID"
    _waiting "$(_notification_tp 'Claude needs your permission to use Echo' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # No record, a subagent's Bash prompt: Bash.
    _check "$(_event UserPromptSubmit)" || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-* "$TEST_TMPDIR"/.mmry-asking-*; : > "$BODIES"
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    [ "$(_tool_sent)" = "Bash" ] || { cat "$BODIES"; return 1; }
}

@test "W-44 33898 req1 (round 4, D1): a multi-word display name with no ask record sends no name, never its first word" {
    JQ_BIN="$(command -v jq)"
    local w n=0
    # Claude Code 2.1.322 shows an untitled MCP tool read_file as "Read File" (QA round 3, measured).
    for w in 'Read File' 'Write File' 'Edit File' 'Task Create' 'Bash Exec' 'Grep Search'; do
        n=$((n + 1))
        : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
        run _waiting "$(_notification permission_prompt "Claude needs your permission to use $w")"
        [ "$(_puts)" -eq "$n" ] || { echo "for: $w"; cat "$URLS"; return 1; }
        [ "$(_tool_sent)" = "<none>" ] || { echo "for: $w"; cat "$BODIES"; return 1; }
    done
}

@test "W-45 33898 req1 (round 4, security F3): a list word followed by a newline and more text sends no name" {
    JQ_BIN="$(command -v jq)"
    # The JSON escape \n: the message the handler reads carries a real newline after the word. The
    # second form (a space, then the newline) sent Edit before round 4; the first was already refused.
    local m n=0
    for m in 'Edit\nEndConversation' 'Edit \nEndConversation' 'Edit\r\n'; do
        n=$((n + 1))
        : > "$BODIES"; rm -f "$TEST_TMPDIR"/.mmry-waiting-*
        run _waiting "$(_notification permission_prompt "Claude needs your permission to use $m")"
        [ "$(_puts)" -eq "$n" ] || { echo "for: $m"; cat "$URLS"; return 1; }
        [ "$(_tool_sent)" = "<none>" ] || { echo "for: $m"; cat "$BODIES"; return 1; }
    done
}

@test "X-27 33898 round 4 in the 33900 stack (lead ruling 5, QA T2): a fresh record whose name breaks the field rule counts as none, and the list rule applies" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl" long
    _transcript "$tp" Agent
    long="mcp__probe__$(printf 'x%.0s' $(seq 1 64))"
    # A 76-character record and a built-in prompt: the list's answer, Bash.
    _leftover_ask "$long"
    _waiting "$(_notification_tp 'Claude needs your permission to use Bash' "$tp")"
    [ "$(_tool_sent)" = "Bash" ] || { cat "$BODIES"; return 1; }
    # The same record and a multi-word display name: the list rule gives no name, never the record's.
    _check "$(_event UserPromptSubmit)" || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _leftover_ask "$long"
    _waiting "$(_notification_tp 'Claude needs your permission to use Read File' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    ! grep -q 'xxxxxxxx' "$BODIES" || { echo "the record's name was sent"; return 1; }
}

# Round 4, lead 439's ruling (b), 2026-11-18: a fresh ask record wins only when the sentence gives no
# confirmed name (a multi-word display name such as Read File, or the D2 title case). When the sentence
# confirms a list name and the record names a different tool, no name. W-39, X-24 and X-25 stand.

@test "X-28 33898 round 4 (D2) in the 33900 stack: a subagent's titled tool against a running main-thread call of the title's name sends the record's tool" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # QA probe QP-03: the main thread's mcp__acme__read_file is still running; a subagent asks for
    # mcp__acme__write_file, whose title is read_file. The fresh record names write_file.
    _transcript "$tp" mcp__acme__read_file
    _leftover_ask mcp__acme__write_file
    _waiting "$(_notification_tp 'Claude needs your permission to use acme - read_file (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "mcp__acme__write_file" ] || { cat "$BODIES"; return 1; }
}

@test "X-29 33898 round 4 (D1) in the 33900 stack: a fresh MCP record names a multi-word display name's tool, also for a subagent's call" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # The main thread's own call, still waiting.
    _transcript "$tp" mcp__probe__read_file
    _leftover_ask mcp__probe__read_file
    _waiting "$(_notification_tp 'Claude needs your permission to use Read File' "$tp")"
    [ "$(_tool_sent)" = "mcp__probe__read_file" ] || { cat "$BODIES"; return 1; }
    # A subagent's call: the main transcript holds only the waiting Agent call.
    _check "$(_event UserPromptSubmit)" || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    _transcript "$tp" Agent
    _leftover_ask mcp__probe__read_file
    _waiting "$(_notification_tp 'Claude needs your permission to use Read File' "$tp")"
    [ "$(_tool_sent)" = "mcp__probe__read_file" ] || { cat "$BODIES"; return 1; }
}

@test "X-30 33898 round 4 (ruling 4) in the 33900 stack: with no record, an MCP title equal to a list name sends no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    # mcp__acme__Read is the one still-waiting call, but its sentence's whole text is not one list entry.
    _transcript "$tp" mcp__acme__Read
    rm -f "$TEST_TMPDIR"/.mmry-asking-*
    _waiting "$(_notification_tp 'Claude needs your permission to use acme - Read (MCP)' "$tp")"
    [ "$(_puts)" -eq 1 ] || { cat "$URLS"; return 1; }
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}

@test "X-31 33898 round 4 (D1) in the 33900 stack: a leftover or stale Read record and use Read File send no name" {
    JQ_BIN="$(command -v jq)"
    local tp="$TEST_TMPDIR/transcript.jsonl"
    _transcript "$tp" Agent
    # A fresh record of the built-in Read: a built-in's sentence is exactly its name, so not this prompt's.
    _leftover_ask Read
    _waiting "$(_notification_tp 'Claude needs your permission to use Read File' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
    # A record older than the freshness window is no record: the list rule, no name.
    _check "$(_event UserPromptSubmit)" || true
    rm -f "$TEST_TMPDIR"/.mmry-waiting-*; : > "$BODIES"
    printf 'asker -\ntool Read\ninput -\nat %s\n' "$(( $(date +%s) - 3600 ))" > "$TEST_TMPDIR/.mmry-asking-$SID"
    _waiting "$(_notification_tp 'Claude needs your permission to use Read File' "$tp")"
    [ "$(_tool_sent)" = "<none>" ] || { cat "$BODIES"; return 1; }
}
