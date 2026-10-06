#!/usr/bin/env bats
# foundation-31597-edges.bats - #31597 round 2: the four items QA failed at 8eacd09.
#
#   R3   a set the background refresh stored, after SessionStart's own fetch failed, and then removed
#        before its first delivery, is reported missing. The evidence used to be written only by
#        SessionStart, so this path was silent where develop reported it.
#   TC4  an account with no Foundation directives is TOLD, once per session (Lead/PM decision
#        2026-10-06): at SessionStart, or on the first prompt when SessionStart could not know. Never
#        on every prompt, so #31583's no-nagging behaviour stands.
#   TC5  what the assistant receives is byte-identical to what the service returned: a last directive
#        ending in newlines keeps them, and a NUL inside a directive arrives as a NUL.
#
# Every comparison here is done on FILES, with cmp, never through a bash variable: bash cannot hold a
# NUL, and $( ) drops trailing newlines, which are the two losses being tested for.

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey" >/dev/null
    unset CLAUDE_SESSION_ID
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    SET="$TEST_TMPDIR/mmry-foundation-set.md"
    HOOK="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    START="$PLUGIN_ROOT/hooks-handlers/session-start.sh"
}

# A hook payload carrying a session id, as Claude Code sends one.
_payload() { printf '{"session_id":"%s","hook_event_name":"x"}' "$1" > "$TEST_TMPDIR/payload-$1.json"; printf '%s' "$TEST_TMPDIR/payload-$1.json"; }

# SessionStart for session $1, its JSON to $TEST_TMPDIR/start-$1.json.
_start() { bash "$START" < "$(_payload "$1")" > "$TEST_TMPDIR/start-$1.json" 2>/dev/null; }

# One prompt, every part, for session $1. Raw JSON of each part to prompt.json, one per line.
_prompt() {
    local k f
    : > "$TEST_TMPDIR/prompt.json"
    for k in 1 2 3 4 5 6; do
        f="$TEST_TMPDIR/prompt-part$k.json"
        bash "$HOOK" --part "$k" < "$(_payload "$1")" > "$f" 2>/dev/null
        [ -s "$f" ] && { cat "$f"; printf '\n'; } >> "$TEST_TMPDIR/prompt.json"
    done
    return 0
}

# What the assistant received on the last _prompt, byte for byte, into $1: each part's decoded
# additionalContext with its heading line and the blank line after it removed, in part order.
_received() {
    local out="$1" k f ctx head
    : > "$out"
    for k in 1 2 3 4 5 6; do
        f="$TEST_TMPDIR/prompt-part$k.json"
        [ -s "$f" ] || continue
        ctx="$TEST_TMPDIR/ctx$k.bin"
        jq -b -j '.hookSpecificOutput.additionalContext' "$f" > "$ctx" || return 1
        head="$(head -n 1 "$ctx")"
        LC_ALL=C tail -c +$(( $(printf '%s' "$head" | LC_ALL=C wc -c) + 3 )) "$ctx" >> "$out"
    done
}

# Wait up to 20 s for the set file to appear (the background refresh writing it).
_await_set() {
    local i
    # Half a second more once it is there: the writer leaves the stored marker just after the rename.
    for (( i = 0; i < 100; i++ )); do [ -f "$SET" ] && { sleep 0.5; return 0; }; sleep 0.2; done
    echo "the background refresh never stored a set"; return 1
}

_show() { echo "expected: $(od -c "$1" | tail -4)"; echo "received: $(od -c "$2" | tail -4)"; }

# ============================================================================
# R3
# ============================================================================

@test "#31597 R3: SessionStart's fetch fails, the refresh stores 2 directives, the set is removed before delivery: reported missing" {
    export MOCK_CURL_HTTP_CODE="500" MOCK_CURL_RESPONSE='{"error":"server down"}'
    _start r3sess
    [ ! -f "$SET" ] || { echo "control: SessionStart stored a set although its fetch failed"; return 1; }

    # The first prompt starts the age-gated background refresh, which now succeeds. The fetch is held
    # for 3 s so it cannot land before this prompt has read the (absent) set.
    export MOCK_CURL_HTTP_CODE="200" MOCK_CURL_DELAY=3
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"One","content":"first"},{"memoryTier":"Foundation","topic":"Two","content":"second"}]'
    _prompt r3sess
    [ ! -s "$TEST_TMPDIR/prompt.json" ] || { echo "prompt 1 said something: $(cat "$TEST_TMPDIR/prompt.json")"; return 1; }
    _await_set || return 1
    unset MOCK_CURL_DELAY

    rm -f "$SET"
    _prompt r3sess
    local out; out="$(cat "$TEST_TMPDIR/prompt.json")"
    [[ "$out" == *'records 2 Foundation directives but the cache holding them is missing'* ]] || { echo "said: [$out]"; return 1; }
    [[ "$out" == *'systemMessage'* ]] || return 1
    [[ "$out" != *'first'* ]]
}

# The same, with a second session started after the first in the same temp directory, so the shared
# token names the OTHER session. The refresh must file its marker under the session that ran it, not
# under whatever the token says.
@test "#31597 R3: the refresh files its marker under its own session, not the shared token" {
    export MOCK_CURL_HTTP_CODE="500" MOCK_CURL_RESPONSE='{"error":"server down"}'
    _start r3a
    _start r3b
    [ "$(cat "$TEST_TMPDIR/mmry-foundation.session")" = "r3b" ] || { echo "control: the token is not session b's"; return 1; }

    export MOCK_CURL_HTTP_CODE="200" MOCK_CURL_DELAY=3
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"One","content":"first"},{"memoryTier":"Foundation","topic":"Two","content":"second"}]'
    _prompt r3a
    _await_set || return 1
    unset MOCK_CURL_DELAY
    [ -f "$TEST_TMPDIR/mmry-foundation.stored.r3a" ] || { echo "no marker for session a"; ls -a "$TEST_TMPDIR"; return 1; }

    rm -f "$SET"
    _prompt r3a
    [[ "$(cat "$TEST_TMPDIR/prompt.json")" == *'records 2 Foundation directives but the cache holding them is missing'* ]]
}

# ============================================================================
# TC4
# ============================================================================

_EMPTY_WORDS='this account has no Foundation directives'

@test "#31597 TC4: no Foundation directives is told to the customer once, at SessionStart, and not on each prompt" {
    export MOCK_CURL_HTTP_CODE="200"
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Strategic","topic":"Plan","content":"not a directive"}]'
    _start tc4a
    [[ "$(fnd_set_record "$SET")" == 'mmry-foundation v2 entries=0 bytes=0 '* ]] || { echo "control: no empty set stored"; return 1; }
    run jq -r '.systemMessage // empty' "$TEST_TMPDIR/start-tc4a.json"
    [[ "$output" == *"$_EMPTY_WORDS"* ]] || { echo "SessionStart said: $(cat "$TEST_TMPDIR/start-tc4a.json")"; return 1; }
    # It is a notice, not a fault.
    [[ "$output" != *'NOT applied'* ]] || return 1

    _prompt tc4a
    [ ! -s "$TEST_TMPDIR/prompt.json" ] || { echo "prompt 1 repeated it: $(cat "$TEST_TMPDIR/prompt.json")"; return 1; }
    _prompt tc4a
    [ ! -s "$TEST_TMPDIR/prompt.json" ]
}

@test "#31597 TC4: an account with no memories at all is told about its directives at SessionStart too" {
    export MOCK_CURL_HTTP_CODE="200" MOCK_CURL_RESPONSE='[]'
    _start tc4b
    run jq -r '.systemMessage // empty' "$TEST_TMPDIR/start-tc4b.json"
    [[ "$output" == *"$_EMPTY_WORDS"* ]] || { echo "SessionStart said: $(cat "$TEST_TMPDIR/start-tc4b.json")"; return 1; }
    # The welcome is still there for the assistant.
    run jq -r '.hookSpecificOutput.additionalContext' "$TEST_TMPDIR/start-tc4b.json"
    [[ "$output" == *'Welcome to MMRY AI'* ]]
}

@test "#31597 TC4: a set with directives says nothing about being empty at SessionStart" {
    export MOCK_CURL_HTTP_CODE="200" MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"T","content":"C"}]'
    _start tc4c
    run jq -r '.systemMessage // empty' "$TEST_TMPDIR/start-tc4c.json"
    [ -z "$output" ]
}

@test "#31597 TC4: when SessionStart could not know, the first prompt that finds the set empty says so, once" {
    export MOCK_CURL_HTTP_CODE="500" MOCK_CURL_RESPONSE='{"error":"server down"}'
    _start tc4d
    [ ! -f "$SET" ] || { echo "control: SessionStart stored a set although its fetch failed"; return 1; }

    export MOCK_CURL_HTTP_CODE="200" MOCK_CURL_DELAY=3
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Strategic","topic":"Plan","content":"not a directive"}]'
    _prompt tc4d
    [ ! -s "$TEST_TMPDIR/prompt.json" ] || { echo "prompt 1 said something: $(cat "$TEST_TMPDIR/prompt.json")"; return 1; }
    _await_set || return 1
    unset MOCK_CURL_DELAY

    _prompt tc4d
    local out; out="$(cat "$TEST_TMPDIR/prompt.json")"
    [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || { echo "expected one part to speak: [$out]"; return 1; }
    run jq -r '.systemMessage // empty' <<<"$out"
    [[ "$output" == *"$_EMPTY_WORDS"* ]] || { echo "prompt 2 said: [$out]"; return 1; }
    [[ "$output" != *'NOT applied'* ]] || return 1
    # Nothing is framed for the assistant as a directive.
    [[ "$out" != *'authoritative'* ]] || return 1

    _prompt tc4d
    [ ! -s "$TEST_TMPDIR/prompt.json" ] || { echo "prompt 3 repeated it: $(cat "$TEST_TMPDIR/prompt.json")"; return 1; }
}

@test "#31597 TC4: once per SESSION, so another session on the same machine is told too" {
    fnd_set_with 'mmry-foundation v2 entries=0 bytes=0 cksum=4294967295' ''
    _prompt tc4e1
    [[ "$(cat "$TEST_TMPDIR/prompt.json")" == *"$_EMPTY_WORDS"* ]] || { echo "session 1 not told"; return 1; }
    _prompt tc4e1
    [ ! -s "$TEST_TMPDIR/prompt.json" ] || { echo "session 1 told twice"; return 1; }
    _prompt tc4e2
    [[ "$(cat "$TEST_TMPDIR/prompt.json")" == *"$_EMPTY_WORDS"* ]] || { echo "session 2 not told"; return 1; }
}

# ============================================================================
# TC5
# ============================================================================

@test "#31597 TC5: a last directive ending in two newlines arrives with both newlines" {
    export MOCK_CURL_HTTP_CODE="200"
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"A","content":"first"},{"memoryTier":"Foundation","topic":"B","content":"ends with two\n\n"}]'
    printf -- '- A: first\n- B: ends with two\n\n' > "$TEST_TMPDIR/want.bin"
    [ "$(wc -c < "$TEST_TMPDIR/want.bin" | tr -d ' ')" -eq 31 ]

    _start tc5a
    _prompt tc5a
    _received "$TEST_TMPDIR/got.bin" || return 1
    cmp "$TEST_TMPDIR/want.bin" "$TEST_TMPDIR/got.bin" || { _show "$TEST_TMPDIR/want.bin" "$TEST_TMPDIR/got.bin"; return 1; }
}

@test "#31597 TC5: a NUL inside a directive arrives as a NUL (17 bytes, not 16)" {
    export MOCK_CURL_HTTP_CODE="200"
    export MOCK_CURL_RESPONSE='[{"memoryTier":"Foundation","topic":"N","content":"before\u0000after"}]'
    printf -- '- N: before\000after' > "$TEST_TMPDIR/want.bin"
    [ "$(wc -c < "$TEST_TMPDIR/want.bin" | tr -d ' ')" -eq 17 ]

    _start tc5b
    _prompt tc5b
    _received "$TEST_TMPDIR/got.bin" || return 1
    cmp "$TEST_TMPDIR/want.bin" "$TEST_TMPDIR/got.bin" || { _show "$TEST_TMPDIR/want.bin" "$TEST_TMPDIR/got.bin"; return 1; }
    # And the status command still calls it VERIFIED: the set is not refused for holding one.
    run bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [[ "$output" == *'VERIFIED'* ]]
}

@test "#31597 TC5: a set in several parts, with a NUL and trailing newlines, rejoins byte for byte" {
    local w i resp
    w="$(printf 'w%.0s' $(seq 1 6000))"
    resp='['
    for i in 1 2 3; do resp+="{\"memoryTier\":\"Foundation\",\"topic\":\"D$i\",\"content\":\"$w\"},"; done
    resp+='{"memoryTier":"Foundation","topic":"Nul","content":"a\u0000b"},{"memoryTier":"Foundation","topic":"Last","content":"tail\n\n\n"}]'
    export MOCK_CURL_HTTP_CODE="200" MOCK_CURL_RESPONSE="$resp"
    { for i in 1 2 3; do printf -- '- D%s: %s\n' "$i" "$w"; done; printf -- '- Nul: a\000b\n- Last: tail\n\n\n'; } > "$TEST_TMPDIR/want.bin"

    _start tc5c
    _prompt tc5c
    [ "$(grep -c '"additionalContext"' "$TEST_TMPDIR/prompt.json")" -ge 2 ] || { echo "control: the set did not need more than one part"; return 1; }
    _received "$TEST_TMPDIR/got.bin" || return 1
    cmp "$TEST_TMPDIR/want.bin" "$TEST_TMPDIR/got.bin" || { _show "$TEST_TMPDIR/want.bin" "$TEST_TMPDIR/got.bin"; return 1; }
}

# By reference: a set larger than six parts. Written by the writer itself, from a response held in a
# file, because a response this size cannot travel in an environment variable on Windows.
@test "#31597 TC5: the by-reference copy holds the NUL and the trailing newlines, byte for byte" {
    local w i
    w="$(printf 'r%.0s' $(seq 1 7900))"
    { printf '['
      for i in 1 2 3 4 5 6 7 8; do printf '{"memoryTier":"Foundation","topic":"R%s","content":"%s"},' "$i" "$w"; done
      printf '%s' '{"memoryTier":"Foundation","topic":"Nul","content":"x\u0000y"},{"memoryTier":"Foundation","topic":"Last","content":"end\n\n"}]'
    } > "$TEST_TMPDIR/resp.json"
    { for i in 1 2 3 4 5 6 7 8; do printf -- '- R%s: %s\n' "$i" "$w"; done; printf -- '- Nul: x\000y\n- Last: end\n\n'; } > "$TEST_TMPDIR/want.bin"

    bash -c 'source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1; mmry_write_foundation_cache "$(cat "$2")" "$3"' \
        _ "$PLUGIN_ROOT" "$TEST_TMPDIR/resp.json" "$SET" || { echo "the writer failed"; return 1; }

    _prompt tc5d
    local out id copy
    out="$(cat "$TEST_TMPDIR/prompt.json")"
    [[ "$out" == *'too large to show here'* ]] || { echo "control: not delivered by reference: ${out:0:300}"; return 1; }
    id="$(fnd_set_record "$SET")"; id="${id##*cksum=}"
    copy="$TEST_TMPDIR/mmry-foundation.byref.tc5d.md"
    [ -f "$copy" ] || { echo "no copy at $copy"; ls -a "$TEST_TMPDIR"; return 1; }
    { cat "$TEST_TMPDIR/want.bin"; printf '\n\nEND OF FOUNDATION SET %s\n' "$id"; } > "$TEST_TMPDIR/want-copy.bin"
    cmp "$TEST_TMPDIR/want-copy.bin" "$copy" || { _show "$TEST_TMPDIR/want-copy.bin" "$copy"; return 1; }
}

# ============================================================================
# Checks QA named in TC6 that had no test able to see them broken.
# ============================================================================

# The parts 2-6 gate reads only the record line. A first line that is not a version 2 record is part
# 1's to report; parts 2-6 must stay quiet rather than each run the check and each print a banner.
@test "#31597 TC6: parts 2-6 stay quiet when the first line is not a version 2 record, whatever bytes= it claims" {
    printf 'mmry-foundation v1 entries=9 bytes=999999 cksum=1\n- x\nEND OF FOUNDATION SET' > "$SET"
    local k
    for k in 2 3 4 5 6; do
        run bash "$HOOK" --part "$k" < "$(_payload tc6g)"
        [ -z "$output" ] || { echo "part $k spoke: ${output:0:300}"; return 1; }
    done
    # Part 1 reports it.
    run bash "$HOOK" --part 1 < "$(_payload tc6g)"
    [[ "$output" == *'could not verify'* ]]
}

# The marker is believed only when it is digits. Anything else must not reach the customer's words,
# and must never reach arithmetic, where bash would evaluate it.
@test "#31597 TC6: a stored marker that is not digits is ignored, and never evaluated" {
    printf '%s' '1+1' > "$TEST_TMPDIR/mmry-foundation.stored.tc6m"
    _prompt tc6m
    [[ "$(cat "$TEST_TMPDIR/prompt.json")" != *'records 1+1'* ]] || return 1
    [[ "$(cat "$TEST_TMPDIR/prompt.json")" != *'records 2 '* ]] || return 1
    printf '%s' 'x[$(touch '"$TEST_TMPDIR"'/evaluated)]' > "$TEST_TMPDIR/mmry-foundation.stored.tc6m"
    _prompt tc6m
    [ ! -e "$TEST_TMPDIR/evaluated" ] || { echo "the marker's contents were executed"; return 1; }
}
