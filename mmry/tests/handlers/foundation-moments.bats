#!/usr/bin/env bats
# foundation-moments.bats - each Foundation memory reaches the assistant on the moments the account
# chose for it, and on no other (#33480, DD-172).
#
# THE CONTRACT. The account chooses, per Foundation memory, any of four moments: when a conversation
# starts, with every message, when the assistant reloads memories, and before a long conversation is
# shortened. The plugins ASK THE API for each moment's memories; they never filter a cached full set
# locally. Text is passed on verbatim, and a size problem is reported, never solved by trimming.
#
#   Claude Code   SessionStart -> conversation-start    UserPromptSubmit -> every-message
#                 the reload command -> reload          PreCompact -> before-shortening
#   Codex         SessionStart, UserPromptSubmit and the reload tool the same way; Codex gives no
#                 signal before it shortens a conversation, so nothing is registered for it.
#
# THE ACCOUNT these tests run against is tests/helpers/mock-curl.sh answering from mock-moments.json:
# one memory per moment, one chosen for two, one with none chosen, and one that is not Foundation.
# Every memory's text carries what a careless pipeline loses: a tab, quotes, a backslash, accents,
# an emoji, an internal newline and trailing spaces.

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey" >/dev/null
    export MMRY_NO_SELF_UPDATE=1
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_HOST CODEX_HOME || true
    export MMRY_HOOK_READ_TIMEOUT=2
    _write_account
}

# One memory per moment, one for two moments, one with none, one not Foundation (#33480 TC2/TC3).
_write_account() {
    jq -n '[
      {id: 11, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Start only",
       content: "START-11 opens:\tTab, \"quoted\", back\\slash, café, rocket 🚀,\nsecond line and trailing   ",
       moments: ["conversation-start"]},
      {id: 12, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Every only",
       content: "EVERY-12 holds:\tTab, \"quoted\", back\\slash, naïve, 🎉,\nsecond line   ",
       moments: ["every-message"]},
      {id: 13, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Reload only",
       content: "RELOAD-13 says:\t\"quoted\" über 🔁\nsecond line  ",
       moments: ["reload"]},
      {id: 14, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Shorten only",
       content: "SHORTEN-14 keeps:\t\"quoted\" résumé 📜\nsecond line ",
       moments: ["before-shortening"]},
      {id: 15, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Start and every",
       content: "BOTH-15 applies at the start and on every message.",
       moments: ["conversation-start", "every-message"]},
      {id: 16, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "None chosen",
       content: "NONE-16 must never be sent anywhere.",
       moments: []},
      {id: 17, memoryTier: "Strategic", scope: "global", category: "Fact", topic: "Not foundation",
       content: "STRATEGIC-17 is an ordinary memory."}
    ]' > "$TEST_TMPDIR/mock-moments.json"
}

# The exact text of memory $1 as the account stored it, and its "- topic: content" line. No memory in
# the fixture ends in a newline (each ends in spaces), so command substitution keeps every byte; -b so
# a native Windows jq writes the bytes as they are.
_content() { jq -b -j --argjson i "$1" '.[] | select(.id == $i) | .content' "$TEST_TMPDIR/mock-moments.json"; }
_line() { jq -b -j --argjson i "$1" '.[] | select(.id == $i) | "- \(.topic): \(.content)"' "$TEST_TMPDIR/mock-moments.json"; }

# Holds "$2" exactly, byte for byte, somewhere in "$1".
_holds() { [[ "$1" == *"$2"* ]]; }

_requests() { cat "$TEST_TMPDIR/curl-log.txt" 2>/dev/null; }

# ---- Claude Code ------------------------------------------------------------------------------

_cc_start() {
    printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "${1:-cc-moments-1}" \
        | bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}

# The memories file a start or reload wrote for this session.
_memfile() { local f; for f in "$TEST_TMPDIR"/mmry-memories.*."${1:-cc-moments-1}".md; do [[ -f "$f" ]] && { cat "$f"; printf .; return 0; }; done; return 1; }

# Every part of one prompt, as Claude Code fires them, decoded.
_cc_prompt() {
    local k f all=""
    for k in 1 2 3 4 5 6; do
        f="$TEST_TMPDIR/p$k.json"
        printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "${1:-cc-moments-1}" \
            | bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part "$k" > "$f" 2>/dev/null
        [[ -s "$f" ]] || continue
        all+="$(jq -b -j '(.hookSpecificOutput.additionalContext // "") + (.systemMessage // "")' "$f"; printf .)"
        all="${all%.}"
    done
    printf '%s.' "$all"
}

_cc_precompact() {
    local k out="" one
    for k in 1 2 3 4 5 6; do
        one="$(printf '{"session_id":"%s","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}' "${1:-cc-moments-1}" \
            | bash "$PLUGIN_ROOT/hooks-handlers/precompact-foundation.sh" --part "$k" 2>/dev/null; printf .)"
        out+="${one%.}"
    done
    printf '%s.' "$out"
}

@test "#33480 CC SessionStart: asks for the conversation-start memories and loads exactly them, verbatim" {
    run _cc_start
    [ "$status" -eq 0 ]
    _requests | grep -q 'api/memories/startup?.*foundationMoment=conversation-start' || { _requests; return 1; }
    local mem; mem="$(_memfile)" || { echo "no memories file"; return 1; }
    _holds "$mem" "$(_content 11)" || { echo "start-only memory missing or altered"; return 1; }
    _holds "$mem" "$(_content 15)" || return 1
    _holds "$mem" "STRATEGIC-17" || return 1
    for x in EVERY-12 RELOAD-13 SHORTEN-14 NONE-16; do
        ! _holds "$mem" "$x" || { echo "$x was loaded at conversation start"; return 1; }
    done
}

@test "#33480 CC UserPromptSubmit: sends exactly the every-message memories, fetched per moment, verbatim" {
    _cc_start >/dev/null
    _requests | grep -q 'api/memories/foundation?moment=every-message' || { echo "the every-message set was not asked for"; _requests; return 1; }
    local got; got="$(_cc_prompt)"
    _holds "$got" "$(_line 12)" || { echo "every-message memory missing or altered: ${got:0:600}"; return 1; }
    _holds "$got" "$(_line 15)" || return 1
    for x in START-11 RELOAD-13 SHORTEN-14 NONE-16 STRATEGIC-17; do
        ! _holds "$got" "$x" || { echo "$x was sent with a message"; return 1; }
    done
}

@test "#33480 CC UserPromptSubmit: the stored set is the API's every-message answer, not the start set filtered" {
    _cc_start >/dev/null
    local set; set="$(fnd_set_body "$(fnd_set_file)"; printf .)"
    _holds "$set" "$(_line 12)" || return 1
    ! _holds "$set" "START-11" || { echo "the start-only memory reached the per-prompt set"; return 1; }
}

@test "#33480 CC reload: the reload command asks for the reload memories and loads exactly them, verbatim" {
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    run bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" --reload < /dev/null
    [ "$status" -eq 0 ]
    _requests | grep -q 'api/memories/startup?.*foundationMoment=reload' || { _requests; return 1; }
    local mem; mem="$(_memfile)" || return 1
    _holds "$mem" "$(_content 13)" || { echo "reload memory missing or altered"; return 1; }
    for x in START-11 EVERY-12 SHORTEN-14 BOTH-15 NONE-16; do
        ! _holds "$mem" "$x" || { echo "$x was loaded on reload"; return 1; }
    done
}

@test "#33480 CC reload: the command file runs the reload, not a conversation start" {
    grep -q 'session-start.sh" --reload' "$PLUGIN_ROOT/commands/load-memories.md"
}

@test "#33480 CC reload: still refreshes the every-message set from the API" {
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" --reload < /dev/null >/dev/null 2>&1
    _requests | grep -q 'api/memories/foundation?moment=every-message' || { _requests; return 1; }
    local set; set="$(fnd_set_body "$(fnd_set_file)"; printf .)"
    _holds "$set" "$(_line 12)"
}

@test "#33480 CC PreCompact: a handler is registered, and it sends exactly the before-shortening memories, verbatim" {
    jq -e '[.hooks.PreCompact[].hooks[].command | select(test("precompact-foundation.sh\" --part 1$"))] | length == 1' "$PLUGIN_ROOT/hooks/hooks.json" >/dev/null \
        || { echo "no PreCompact registration for the before-shortening memories"; return 1; }
    local got; got="$(_cc_precompact)"
    _requests | grep -q 'api/memories/foundation?moment=before-shortening' || { _requests; return 1; }
    _holds "$got" "$(_line 14)" || { echo "before-shortening memory missing or altered: ${got:0:400}"; return 1; }
    for x in START-11 EVERY-12 RELOAD-13 BOTH-15 NONE-16 STRATEGIC-17; do
        ! _holds "$got" "$x" || { echo "$x was sent before shortening"; return 1; }
    done
}

@test "#33480 CC PreCompact: every part the handler can send is registered, and each exits 0 (never blocks compaction)" {
    local regs; regs="$(jq -r '[.hooks.PreCompact[].hooks[].command | select(test("precompact-foundation.sh")) | capture("--part (?<k>[0-9]+)$").k] | join(",")' "$PLUGIN_ROOT/hooks/hooks.json" | tr -d '\r')"
    [ "$regs" = "1,2,3,4,5,6" ] || { echo "registered parts: [$regs]"; return 1; }
    local k
    for k in 1 2 3 4 5 6; do
        printf '{"session_id":"cc-moments-1","hook_event_name":"PreCompact","trigger":"manual"}' \
            | bash "$PLUGIN_ROOT/hooks-handlers/precompact-foundation.sh" --part "$k" >/dev/null 2>&1 || { echo "part $k exited $?"; return 1; }
    done
}

@test "#33480 CC: a memory with no moment chosen is never sent, on any moment" {
    _cc_start > "$TEST_TMPDIR/start.out"
    local all
    all="$(cat "$TEST_TMPDIR/start.out"; _memfile; _cc_prompt; _cc_precompact)"
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    all+="$(bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" --reload < /dev/null 2>/dev/null; _memfile)"
    ! _holds "$all" "NONE-16"
}

@test "#33480 CC PreCompact: nothing chosen for it means nothing is printed" {
    jq 'map(if .moments then .moments -= ["before-shortening"] else . end)' "$TEST_TMPDIR/mock-moments.json" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mock-moments.json"
    local got; got="$(_cc_precompact)"
    [ "$got" = "." ] || { echo "printed: ${got:0:300}"; return 1; }
}

@test "#33480 CC PreCompact: an oversized set is reported and sent whole, never trimmed" {
    # Eight memories of 8,000 characters: 64,000 in all, over the 57,000 the API reports above.
    jq --arg f "$(printf 'z%.0s' $(seq 1 8000))" '[.[] | select(.id != 14)] + [range(1;9) | {id: (100 + .), memoryTier: "Foundation", scope: "global", topic: "Big \(.)", content: "BIG-\(.)-START \($f) BIG-\(.)-END", moments: ["before-shortening"]}]' \
        "$TEST_TMPDIR/mock-moments.json" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mock-moments.json"
    local got; got="$(_cc_precompact)"
    _holds "$got" "more than about 57,000" || { echo "the size was not reported: ${got:0:600}"; return 1; }
    # Whole: every memory, start to end, either in the printed text or in the file it names.
    local whole="$got" f
    for f in "$TEST_TMPDIR"/mmry-foundation-shortening.*.md; do [[ -f "$f" ]] && whole+="$(cat "$f")"; done
    local i
    for i in 1 2 3 4 5 6 7 8; do
        _holds "$whole" "$(_line $(( 100 + i )))" || { echo "Big $i was not delivered whole"; return 1; }
    done
}

@test "#33480 CC: an oversized every-message set is reported by the status check, and sent whole" {
    jq --arg f "$(printf 'q%.0s' $(seq 1 8000))" '[.[] | select(.id != 12)] + [range(1;9) | {id: (200 + .), memoryTier: "Foundation", scope: "global", topic: "Huge \(.)", content: "HUGE-\(.)-START \($f) HUGE-\(.)-END", moments: ["every-message"]}]' \
        "$TEST_TMPDIR/mock-moments.json" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mock-moments.json"
    _cc_start >/dev/null
    local set; set="$(fnd_set_body "$(fnd_set_file)"; printf .)"
    local i
    for i in 1 2 3 4 5 6 7 8; do _holds "$set" "$(_line $(( 200 + i )))" || { echo "Huge $i stored short"; return 1; }; done
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    run bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [[ "$output" == *'"With every message" come to '*'more than about 57,000'* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"never shortens them"* ]] || return 1
}

@test "#33480 CC status: reports the every-message set, and says none is chosen when the account has some but none for it" {
    jq 'map(if .moments then .moments -= ["every-message"] else . end)' "$TEST_TMPDIR/mock-moments.json" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mock-moments.json"
    run _cc_start
    # The once-a-session notice must not claim the account has no Foundation directives: it has six.
    [[ "$output" != *"this account has no Foundation directives"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"none of this account's 6 Foundation directives is chosen to be sent with every message"* ]] || { echo "$output"; return 1; }
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    run bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [[ "$output" == *"none chosen"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Foundation Memories page"* ]] || { echo "$output"; return 1; }
}

@test "#33480 CC status: with directives chosen, it names how many are sent with every message" {
    _cc_start >/dev/null
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    run bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [[ "$output" == *"With every message: 2 directives"* ]] || { echo "$output"; return 1; }
}

@test "#33480 CC: when the every-message request fails, nothing is guessed from the start set and the session is told" {
    printf '500' > "$TEST_TMPDIR/mock-override-foundation-every-message-code"
    run _cc_start
    [[ "$output" == *"could not be stored for this session"* ]] || { echo "$output"; return 1; }
    [ ! -f "$(fnd_set_file)" ] || { echo "a per-prompt set was stored anyway:"; fnd_set_body "$(fnd_set_file)"; return 1; }
}

@test "#33480 CC: the per-prompt refresh asks for the every-message set, never the startup set" {
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    mmry_load_config
    : > "$TEST_TMPDIR/curl-log.txt"
    mmry_refresh_foundation_cache "$PWD" "$(fnd_set_file)" "cc-moments-1"
    grep -q 'api/memories/foundation?moment=every-message' "$TEST_TMPDIR/curl-log.txt"
    ! grep -q 'api/memories/startup' "$TEST_TMPDIR/curl-log.txt"
    _holds "$(fnd_set_body "$(fnd_set_file)"; printf .)" "$(_line 12)"
}

# ---- Codex ------------------------------------------------------------------------------------

_codex_env() {
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$CODEX_DIR/mmry"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key","foundationRefreshSeconds":0}' > "$CODEX_DIR/mmry-config.json"
    export FND_CONFIG_OVERRIDE="$CODEX_DIR/mmry-config.json"
}

_cx_start() {
    printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup","cwd":"/w"}' "${1:-cx-moments-1}" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$CODEX_DIR" bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" session-init 2>/dev/null
}

_cx_prompt() {
    local k out="" one
    for k in 1 2 3 4 5 6; do
        one="$(printf '{"session_id":"%s","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"hi"}' "${1:-cx-moments-1}" \
            | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$CODEX_DIR" bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" userpromptsubmit-foundation --part "$k" 2>/dev/null)"
        [[ -n "$one" ]] || continue
        out+="$(printf '%s' "$one" | jq -b -j '(.hookSpecificOutput.additionalContext // "") + (.systemMessage // "")'; printf .)"
        out="${out%.}"
    done
    printf '%s.' "$out"
}

@test "#33480 Codex SessionStart: asks for the conversation-start memories and loads exactly them, verbatim" {
    _codex_env
    _cx_start >/dev/null
    _requests | grep -q 'api/memories/startup?.*foundationMoment=conversation-start' || { _requests; return 1; }
    local mem; mem="$(_memfile cx-moments-1)" || { echo "no memories file"; ls -a "$TEST_TMPDIR"; return 1; }
    _holds "$mem" "$(_content 11)" || return 1
    _holds "$mem" "$(_content 15)" || return 1
    for x in EVERY-12 RELOAD-13 SHORTEN-14 NONE-16; do ! _holds "$mem" "$x" || { echo "$x loaded at start"; return 1; }; done
}

@test "#33480 Codex UserPromptSubmit: sends exactly the every-message memories, verbatim" {
    _codex_env
    _cx_start >/dev/null
    _requests | grep -q 'api/memories/foundation?moment=every-message' || { _requests; return 1; }
    local got; got="$(_cx_prompt)"
    _holds "$got" "$(_line 12)" || { echo "${got:0:600}"; return 1; }
    _holds "$got" "$(_line 15)" || return 1
    for x in START-11 RELOAD-13 SHORTEN-14 NONE-16 STRATEGIC-17; do ! _holds "$got" "$x" || { echo "$x sent with a message"; return 1; }; done
}

@test "#33480 Codex reload: the memory_load tool asks for the reload memories and loads exactly them" {
    _codex_env
    export MMRY_HOST=codex CODEX_HOME="$CODEX_DIR"
    export MMRY_API_KEY="test-api-key" MMRY_API_URL="http://localhost:5291" MMRY_AUTH_METHOD="apikey"
    unset MMRY_CONFIG_FILE
    mkdir -p "$TEST_TMPDIR/proj"
    local req
    req='{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"memory_load","arguments":{"working_dir":"'"$TEST_TMPDIR/proj"'"},"_meta":{"sessionId":"cx-moments-1"}}}'
    run bash -c 'printf "%s\n" "$1" | bash "$0"' "$PLUGIN_ROOT/hooks-handlers/mcp-server.sh" "$req"
    _requests | grep -q 'api/memories/startup?.*foundationMoment=reload' || { _requests; echo "$output"; return 1; }
    local mem; mem="$(_memfile cx-moments-1)" || return 1
    _holds "$mem" "$(_content 13)" || return 1
    for x in START-11 EVERY-12 SHORTEN-14 BOTH-15 NONE-16; do ! _holds "$mem" "$x" || { echo "$x loaded on reload"; return 1; }; done
}

@test "#33480 Codex: nothing is registered before shortening, because Codex gives no signal for it" {
    [ "$(jq -r '.hooks | has("PreCompact")' "$PLUGIN_ROOT/hooks/codex-hooks.json")" = "false" ]
    ! grep -q 'precompact-foundation' "$PLUGIN_ROOT/hooks/codex-hooks.json"
}

@test "#33480 Codex: a memory with no moment chosen is never sent" {
    _codex_env
    local all
    all="$(_cx_start; _memfile cx-moments-1; _cx_prompt)"
    ! _holds "$all" "NONE-16"
}

# ---- the files this adds are never named by a bare session id (#33363, S1) -------------------------

@test "#33480: no file this work writes is named by the bare session id" {
    _cc_start sess-bare-77 >/dev/null
    printf '{"session_id":"sess-bare-77","hook_event_name":"PreCompact","trigger":"auto"}' \
        | bash "$PLUGIN_ROOT/hooks-handlers/precompact-foundation.sh" --part 1 >/dev/null 2>&1
    local acct f bad=""
    acct="$(fnd_acct)"
    for f in "$TEST_TMPDIR"/*sess-bare-77* "$TEST_TMPDIR"/.*sess-bare-77*; do
        [[ -e "$f" ]] || continue
        [[ "${f##*/}" == *"${acct}.sess-bare-77"* || "${f##*/}" == *"${acct}"*"sess-bare-77"* ]] || bad+=" ${f##*/}"
    done
    [ -z "$bad" ] || { echo "named by the bare session id:$bad"; return 1; }
}

@test "#33480 CC status: an account with no Foundation directives is not told that none is chosen" {
    jq '[.[] | select(.memoryTier != "Foundation")]' "$TEST_TMPDIR/mock-moments.json" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mock-moments.json"
    _cc_start >/dev/null
    export CLAUDE_CODE_SESSION_ID="cc-moments-1"
    run bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [[ "$output" != *"none chosen"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"With every message: none - this account has no Foundation directives"* ]] || { echo "$output"; return 1; }
}
