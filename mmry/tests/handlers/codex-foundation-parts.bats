#!/usr/bin/env bats
# =============================================================================================
# #31411's FOUNDATION WORK, AS A CODEX CUSTOMER RECEIVES IT (#31245 merged onto #31411).
#
# Nothing in the merge conflicted here, and that is the problem. #31411 changed what the Foundation
# hook delivers and what it says; #31245 put the same hook on a second host. Each was green alone.
#
# 1. THE SPLIT. #31411 cuts a large set into up to six labelled parts, one per registered hook,
#    because Claude Code previews any one hook's text over 10,000 characters. codex-hooks.json
#    registered the hook ONCE, so on Codex only part 1 ever ran, and a set over about 9.5 KB lost
#    the rest without a word. Codex has the same kind of cap: rust-v0.154.0
#    hooks/src/output_spill.rs spills any hook's text over 2,500 tokens to a file and shows a
#    preview, and utils/string/src/truncate.rs counts a token as 4 BYTES, so the line is 10,000
#    bytes. It also runs same-event hooks together (engine/dispatcher.rs, FuturesUnordered) and
#    returns them in configured order, so six registrations cost Codex what they cost Claude Code.
#
# 2. THE WORDS. #31411's new notices named /mmry:load-memories, /mmry:foundation-status and
#    "Claude Code". A Codex customer has nothing to type and is not running Claude Code.
#
# Every test runs the hook through codex-hook.sh, the real Codex entry point, with a Codex home
# that is not the default, and with the CONTROL on Claude Code beside it where a wording is
# asserted, so requirement 4 is checked by the same run that checks the Codex text.
# =============================================================================================

load '../helpers/test-helper'
load '../helpers/mock-config'

CODEX_DIR=""
CACHE=""

# The byte line Codex 0.154.0 spills at: 2,500 tokens of 4 bytes.
CODEX_SPILL_BYTES=10000

setup() {
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$CODEX_DIR/mmry"
    cat > "$CODEX_DIR/mmry-config.json" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationRefreshSeconds": 0
}
EOF
    # The Claude credential the control runs use. Same values, the other product's location.
    cp "$CODEX_DIR/mmry-config.json" "$MMRY_CONFIG_FILE"
}

# Record a planted cache the way the writer does; #31411 refuses an unrecorded one.
manifest_now() {
    local c="${1:-$CACHE}" n s b
    read -r s b < <(cksum < "$c")
    n="$(grep -c '^- ' "$c" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s\n' "$n" "$b" "$s" > "${c}.manifest"
}

# A Codex hook firing: codex-hook.sh sets the host, the payload is Codex's (session_id first, as
# hooks/src/schema.rs UserPromptSubmitCommandInput declares it).
_codex_part() {
    local k="$1" sid="${2:-codex-thread-1}"
    printf '{"session_id":"%s","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"hi"}' "$sid" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$CODEX_DIR" \
            bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" userpromptsubmit-foundation --part "$k" 2>/dev/null
}

_claude_part() {
    local k="$1" sid="${2:-claude-session-1}"
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$sid" \
        | env -u MMRY_HOST -u CODEX_HOME bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part "$k" 2>/dev/null
}

_ctx() { jq -j '.hookSpecificOutput.additionalContext // ""' | tr -d '\r'; }
_msg() { jq -j '.systemMessage // ""' | tr -d '\r'; }

# --- 1. the split ------------------------------------------------------------------------------

@test "codex parts: the largest set six parts carry arrives WHOLE on Codex, every part under its spill line" {
    # Two-byte characters on every line, because Codex counts bytes and Claude Code characters:
    # a part sized by characters alone would cross Codex's line before Claude Code's.
    awk -v n=600 'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: keep every sentence short, every claim backed by something you ran, caf\303\251.\n", i }' > "$CACHE"
    manifest_now
    local k out ctx bytes joined="" stored
    for k in 1 2 3 4 5 6; do
        out="$(_codex_part "$k")"
        ctx="$(printf '%s' "$out" | _ctx; printf '.')"; ctx="${ctx%.}"
        # 31411 QA round 2 (aecdd6b) ties every part to its set: the label now carries the version.
        [[ "$ctx" == *"This is PART $k OF 6 of the set, version "* ]] || { echo "part $k missing or not labelled $k of 6: ${ctx:0:200}"; return 1; }
        bytes="$(printf '%s' "$ctx" | LC_ALL=C wc -c | tr -d ' ')"
        echo "part $k: $bytes bytes" >&3
        (( bytes <= CODEX_SPILL_BYTES )) || { echo "part $k is $bytes bytes; Codex would spill it to a file"; return 1; }
        [[ "$out" != *systemMessage* ]] || { echo "part $k reported a problem: $out"; return 1; }
        joined="${joined}${ctx#*$'\n\n'}"
    done
    stored="$(<"$CACHE")"
    [ "$joined" = "$stored" ] || { echo "the six parts do not rejoin to the stored set"; return 1; }
}

@test "codex parts: the Codex manifest registers every part the handler can send" {
    # The handler's own ceiling, read from the shipped file rather than restated.
    local max codex
    max="$(grep -o 'MMRY_FOUNDATION_PARTS_MAX:-[0-9][0-9]*' "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" | head -1 | sed 's/.*:-//')"
    [[ "$max" =~ ^[0-9]+$ ]] || { echo "could not read the parts ceiling: [$max]"; return 1; }
    codex="$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[] | .command | select(test("userpromptsubmit-foundation --part [0-9]+$")) | capture("--part (?<k>[0-9]+)$").k | tonumber] | sort | map(tostring) | join(",")' "$PLUGIN_ROOT/hooks/codex-hooks.json" | tr -d '\r')"
    local want="" i
    for (( i = 1; i <= max; i++ )); do want="${want:+$want,}$i"; done
    echo "handler ceiling $max; codex registers parts [$codex]" >&3
    [[ "$codex" == "$want" ]] || { echo "codex registers [$codex], the handler can send [$want]"; return 1; }
}

# --- 2. the words --------------------------------------------------------------------------------

@test "codex parts: a set too large for six parts names Codex to both audiences, not Claude Code" {
    awk -v n=12000 'BEGIN { for (i = 0; i < n; i++) print "- Directive: keep every sentence short and every claim backed by something you ran." }' > "$CACHE"
    manifest_now
    local out ctx msg
    out="$(_codex_part 1 codex-byref)"
    ctx="$(printf '%s' "$out" | _ctx)"; msg="$(printf '%s' "$out" | _msg)"
    [[ "$ctx" == *"BEFORE YOU ANSWER, read this file in full"* ]] || { echo "not the by-reference path: ${ctx:0:300}"; return 1; }
    [[ "$ctx" == *"more than Codex lets a plugin show"* ]] || { echo "assistant: ${ctx:0:300}"; return 1; }
    [[ "$msg" == *"larger than Codex lets a plugin show"* ]] || { echo "customer: $msg"; return 1; }
    [[ "$out" != *"Claude Code"* ]] || { echo "named the other product: $out"; return 1; }
}

@test "codex parts: req4 control - on Claude Code that by-reference text is unchanged" {
    awk -v n=12000 'BEGIN { for (i = 0; i < n; i++) print "- Directive: keep every sentence short and every claim backed by something you ran." }' > "$CACHE"
    manifest_now
    local out
    out="$(_claude_part 1 claude-byref)"
    [[ "$(printf '%s' "$out" | _ctx)" == *"more than Claude Code lets a plugin show on one prompt"* ]] || { echo "$out"; return 1; }
    [[ "$(printf '%s' "$out" | _msg)" == *"larger than Claude Code lets a plugin show on each prompt"* ]] || { echo "$out"; return 1; }
}

@test "codex parts: a refused cache tells a Codex customer commands that exist on Codex" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    printf -- '- x\n' > "$CACHE"
    local out msg
    out="$(_codex_part 1)"
    msg="$(printf '%s' "$out" | _msg)"
    [[ "$msg" == *"NOT applied to this turn"* ]] || { echo "not the refusal path: $out"; return 1; }
    [[ "$msg" == *"bash ${CODEX_DIR}/mmry/hooks-handlers/session-start.sh"* ]] || { echo "$msg"; return 1; }
    [[ "$msg" == *"bash ${CODEX_DIR}/mmry/hooks-handlers/foundation-status.sh"* ]] || { echo "$msg"; return 1; }
    [[ "$msg" != *"/mmry:"* ]] || { echo "named a slash command Codex cannot type: $msg"; return 1; }
    # The script it names is one session-init.sh copies into that directory.
    [ -f "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh" ]
}

@test "codex parts: req4 control - on Claude Code the refusal names the slash commands, as it did" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    printf -- '- x\n' > "$CACHE"
    local msg
    msg="$(_claude_part 1 | _msg)"
    [[ "$msg" == *"Run /mmry:load-memories to rebuild it, then /mmry:foundation-status to confirm."* ]] || { echo "$msg"; return 1; }
}

@test "codex parts: foundation-status on Codex points at the Codex config file and the Codex script" {
    printf '%s' '{"apiKey":"test-key","foundationReinject":"false"}' > "$CODEX_DIR/mmry-config.json"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_FOUNDATION_REINJECT CODEX_HOME="$CODEX_DIR" MMRY_HOST=codex \
        bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TURNED OFF"* ]] || { echo "not the switched-off path: $output"; return 1; }
    [[ "$output" == *"Set foundationReinject to true in ${CODEX_DIR}/mmry-config.json"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *".claude"* ]] || { echo "named the other product's file: $output"; return 1; }
}

@test "codex parts: and its remedies are the Codex script, never a slash command" {
    # No cache at all: the status command's rebuild advice.
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_FOUNDATION_REINJECT CODEX_HOME="$CODEX_DIR" MMRY_HOST=codex \
        bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Action:"* ]] || { echo "no remedy offered, so this checked nothing: $output"; return 1; }
    [[ "$output" == *"bash ${CODEX_DIR}/mmry/hooks-handlers/session-start.sh"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"/mmry:"* ]] || { echo "named a slash command: $output"; return 1; }
}

@test "codex parts: req4 control - foundation-status on Claude Code is word for word what it was" {
    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_FOUNDATION_REINJECT bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"run /mmry:load-memories"* ]] || { echo "$output"; return 1; }
}

@test "codex parts: a Foundation store failure at session start gives the Codex assistant a script to run" {
    setup_mock_curl
    local root="$TEST_TMPDIR/plugin" client
    cp -R "$PLUGIN_ROOT" "$root"
    client="$root/hooks-handlers/mmry-client.sh"
    awk '{ print } /^mmry_write_foundation_cache\(\) \{$/ { print "    return 1" }' "$client" > "$client.tmp"
    mv "$client.tmp" "$client"
    # The injected failure really is the first line of the writer, or this tests the healthy path.
    [[ "$(grep -A1 '^mmry_write_foundation_cache() {$' "$client" | tail -1)" == "    return 1" ]] || return 1

    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_NO_SELF_UPDATE=1 \
        bash -c "bash '$root/hooks-handlers/session-start.sh' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not be stored"* ]] || { echo "not the failure path: ${output:0:400}"; return 1; }
    [[ "$output" == *"offer to run bash ${CODEX_DIR}/mmry/hooks-handlers/session-start.sh to try again"* ]] || { echo "${output:0:1500}"; return 1; }
    [[ "$output" != *"/mmry:load-memories"* && "$output" != *"/mmry:foundation-status"* ]] || { echo "named a slash command"; return 1; }
}
