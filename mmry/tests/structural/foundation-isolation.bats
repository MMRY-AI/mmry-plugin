#!/usr/bin/env bats
# foundation-isolation.bats - two MMRY sessions on one machine never swap Foundation directives (#32889).
#
# THE INCIDENT, 2026-10-24 01:16 UTC, RICOADMIN07. A Codex session on the Integration test account (one
# Foundation directive, "Always answer in plain English") started while a Claude Code session on
# PRODUCTION (Eric's account, 18 directives) was running. Both wrote the one machine-wide file
# %TEMP%\mmry-foundation-set.md and the one marker %TEMP%\mmry-foundation.session. The production
# session's next prompts injected the Integration account's one directive, and
# /mmry:foundation-status said "VERIFIED - 1 directives". The server was right throughout.
#
# The first test below is that sequence: two sessions, two accounts on two servers, one TMPDIR. It was
# run against the develop handlers before any fix and failed there (the red run is recorded in the
# task's QA statement). Every test here drives the real entry points - session-start.sh, the
# UserPromptSubmit hook, foundation-status.sh, and codex-hook.sh for the Codex session - with a mock
# curl standing in for the service, so the only thing shared between the two sessions is the temp
# directory, which is exactly what is shared on a real machine.

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_HOST CODEX_HOME || true
    # A real plugin layout for session-start.sh's self-update and formation sweep to find nothing in.
    mkdir -p "$HOME/.claude/mmry/hooks-handlers"
    # Two accounts on two servers. Keys are throwaway strings, never real credentials.
    PROD_URL="https://prod.example.test"   PROD_KEY="prod-account-key-000000000000000000000001"
    INT_URL="https://integration.example.test" INT_KEY="integration-account-key-00000000000002"
    PROD_DIRECTIVE_1="Production directive one: keep every claim backed by something you ran."
    PROD_DIRECTIVE_2="Production directive two: no em dashes, ever."
    INT_DIRECTIVE="Always answer in plain English."
}

# The startup response the mock service gives an account: one Foundation memory per directive given.
_startup_body() {
    local body="[" first=1 d
    for d in "$@"; do
        (( first )) || body+=","
        first=0
        body+="{\"id\":1,\"topic\":\"Rule\",\"content\":\"${d}\",\"memoryTier\":\"Foundation\",\"scope\":\"global\",\"category\":\"Fact\"}"
    done
    printf '%s]' "$body"
}

# A Claude Code SessionStart for the account given by its URL and key, with the session id Claude Code
# puts first in the payload. The mock service answers with the directives given.
#   _claude_start <sid> <url> <key> <directive>...
_claude_start() {
    local sid="$1" url="$2" key="$3"; shift 3
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$sid" \
        | env MMRY_API_URL="$url" MMRY_API_KEY="$key" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}

# A Claude Code prompt for that session: part 1 of the UserPromptSubmit hook, exactly as hooks.json
# registers it. The daily refresh is off so no background process outlives the test.
#   _claude_prompt <sid> <url> <key>
_claude_prompt() {
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" \
        | env MMRY_API_URL="$2" MMRY_API_KEY="$3" MMRY_AUTH_METHOD=apikey MMRY_FOUNDATION_REFRESH_SECONDS=0 \
              bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 2>/dev/null
}

# /mmry:foundation-status for that session.
_claude_status() {
    env MMRY_API_URL="$2" MMRY_API_KEY="$3" MMRY_AUTH_METHOD=apikey CLAUDE_CODE_SESSION_ID="$1" \
        bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh" 2>/dev/null
}

# A Codex session: its own CODEX_HOME holding its own mmry-config.json, every hook through
# codex-hook.sh, the real Codex entry point, which declares the host and points the client at that
# config. Nothing about the account is in the environment.
_codex_home() {
    local dir="$TEST_TMPDIR/codexhome-$1"
    mkdir -p "$dir/mmry"
    printf '{\n  "apiUrl": "%s",\n  "authMethod": "apikey",\n  "apiKey": "%s",\n  "foundationRefreshSeconds": 0\n}\n' "$2" "$3" > "$dir/mmry-config.json"
    printf '%s' "$dir"
}
#   _codex_start <codex-home> <sid> <directive>...
_codex_start() {
    local home="$1" sid="$2"; shift 2
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$sid" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$home" \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" session-start 2>/dev/null
}
#   _codex_prompt <codex-home> <sid> [part]
_codex_prompt() {
    printf '{"session_id":"%s","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"hi"}' "$2" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$1" MMRY_FOUNDATION_REFRESH_SECONDS=0 \
              bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" userpromptsubmit-foundation --part "${3:-1}" 2>/dev/null
}
#   _codex_status <codex-home> <sid>
_codex_status() {
    env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$1" CLAUDE_CODE_SESSION_ID="$2" \
        bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" foundation-status 2>/dev/null
}

_ctx() { jq -j '.hookSpecificOutput.additionalContext // ""' <<<"$1" | tr -d '\r'; }

# ---------------------------------------------------------------------------------------------
# TEST CASE 1, requirements 1 and 2. The incident, replayed: the production Claude Code session is
# running and has delivered its own set; the Integration Codex session starts on the same machine; the
# production session's next prompt must still inject its own two directives and nothing of the other
# account's, and the other way round.
# ---------------------------------------------------------------------------------------------
@test "isolation: the 2026-10-24 swap - a Codex session on Integration starting beside a Claude Code session on production leaves both injecting only their own directives" {
    local prod_sid="claude-prod-session-01" int_sid="codex-int-thread-01" codex out ctx

    _claude_start "$prod_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" "$PROD_DIRECTIVE_2" >/dev/null
    out="$(_claude_prompt "$prod_sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" == *"$PROD_DIRECTIVE_2"* ]] || { echo "production session did not get its own set before the other started: ${ctx:0:300}"; return 1; }

    # 01:16:42 UTC: the Integration session starts, on the same machine.
    codex="$(_codex_home int "$INT_URL" "$INT_KEY")"
    _codex_start "$codex" "$int_sid" "$INT_DIRECTIVE" >/dev/null

    # The production session's next prompt.
    out="$(_claude_prompt "$prod_sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" != *"$INT_DIRECTIVE"* ]] || { echo "the PRODUCTION session injected the INTEGRATION account's directive: ${ctx:0:300}"; return 1; }
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" == *"$PROD_DIRECTIVE_2"* ]] || { echo "the production session lost its own directives: ${ctx:0:300}"; return 1; }

    # And the Integration session's prompt is its own, and only its own.
    out="$(_codex_prompt "$codex" "$int_sid")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* ]] || { echo "the Integration session did not get its own directive: ${ctx:0:300}"; return 1; }
    [[ "$ctx" != *"$PROD_DIRECTIVE_1"* && "$ctx" != *"$PROD_DIRECTIVE_2"* ]] || { echo "the INTEGRATION session injected the PRODUCTION account's directives: ${ctx:0:300}"; return 1; }

    # The status each customer would see: their own count, never the other's.
    out="$(_claude_status "$prod_sid" "$PROD_URL" "$PROD_KEY")"
    [[ "$out" == *"VERIFIED - 2 directives"* ]] || { echo "production status is not its own two directives: $out"; return 1; }
    [[ "$out" != *"1 directives"* ]] || { echo "production status reports the other account's count: $out"; return 1; }
    out="$(_codex_status "$codex" "$int_sid")"
    [[ "$out" == *"VERIFIED - 1 directives"* ]] || { echo "Integration status is not its own one directive: $out"; return 1; }
}

@test "isolation: two Claude Code sessions with different MMRY_API_URL values and accounts in one TMPDIR each inject only their own set" {
    local a_sid="claude-a-01" b_sid="claude-b-01" out ctx
    _claude_start "$a_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" "$PROD_DIRECTIVE_2" >/dev/null
    _claude_start "$b_sid" "$INT_URL"  "$INT_KEY"  "$INT_DIRECTIVE" >/dev/null

    out="$(_claude_prompt "$a_sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" == *"$PROD_DIRECTIVE_2"* && "$ctx" != *"$INT_DIRECTIVE"* ]] \
        || { echo "session A did not inject exactly its own set: ${ctx:0:300}"; return 1; }
    out="$(_claude_prompt "$b_sid" "$INT_URL" "$INT_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* && "$ctx" != *"$PROD_DIRECTIVE_1"* ]] \
        || { echo "session B did not inject exactly its own set: ${ctx:0:300}"; return 1; }
}

@test "isolation: the same account on two servers is two sets - the server is part of the key" {
    # One key, two servers (a customer whose Integration and production accounts share a key string).
    local a_sid="claude-srv-a" b_sid="claude-srv-b" out ctx
    _claude_start "$a_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" >/dev/null
    _claude_start "$b_sid" "$INT_URL"  "$PROD_KEY" "$INT_DIRECTIVE" >/dev/null
    out="$(_claude_prompt "$a_sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" != *"$INT_DIRECTIVE"* ]] || { echo "server A got server B's set: ${ctx:0:300}"; return 1; }
    out="$(_claude_prompt "$b_sid" "$INT_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* && "$ctx" != *"$PROD_DIRECTIVE_1"* ]] || { echo "server B got server A's set: ${ctx:0:300}"; return 1; }
}

@test "isolation: two Codex sessions in two CODEX_HOMEs on different accounts, one TMPDIR, each inject only their own set" {
    local a b out ctx
    a="$(_codex_home a "$PROD_URL" "$PROD_KEY")"
    b="$(_codex_home b "$INT_URL" "$INT_KEY")"
    _codex_start "$a" codex-a-01 "$PROD_DIRECTIVE_1" "$PROD_DIRECTIVE_2" >/dev/null
    _codex_start "$b" codex-b-01 "$INT_DIRECTIVE" >/dev/null
    out="$(_codex_prompt "$a" codex-a-01)"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" == *"$PROD_DIRECTIVE_2"* && "$ctx" != *"$INT_DIRECTIVE"* ]] \
        || { echo "Codex session A did not inject exactly its own set: ${ctx:0:300}"; return 1; }
    out="$(_codex_prompt "$b" codex-b-01)"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* && "$ctx" != *"$PROD_DIRECTIVE_1"* ]] \
        || { echo "Codex session B did not inject exactly its own set: ${ctx:0:300}"; return 1; }
    out="$(_codex_status "$a" codex-a-01)"
    [[ "$out" == *"VERIFIED - 2 directives"* ]] || { echo "Codex A status: $out"; return 1; }
    out="$(_codex_status "$b" codex-b-01)"
    [[ "$out" == *"VERIFIED - 1 directives"* ]] || { echo "Codex B status: $out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 5. One session, either host: the set is delivered on every prompt, as before.
# ---------------------------------------------------------------------------------------------
@test "isolation: a single Claude Code session still gets its set on every prompt, and status says IN FULL" {
    local sid="claude-solo-01" out ctx i
    _claude_start "$sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" "$PROD_DIRECTIVE_2" >/dev/null
    for i in 1 2 3; do
        out="$(_claude_prompt "$sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
        [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" == *"$PROD_DIRECTIVE_2"* ]] || { echo "prompt $i: ${ctx:0:300}"; return 1; }
    done
    out="$(_claude_status "$sid" "$PROD_URL" "$PROD_KEY")"
    [[ "$out" == *"VERIFIED - 2 directives"* && "$out" == *"Delivered:    IN FULL"* ]] || { echo "$out"; return 1; }
}

@test "isolation: a single Codex session still gets its set on every prompt, and status says IN FULL" {
    local home out ctx i
    home="$(_codex_home solo "$INT_URL" "$INT_KEY")"
    _codex_start "$home" codex-solo-01 "$INT_DIRECTIVE" >/dev/null
    for i in 1 2 3; do
        out="$(_codex_prompt "$home" codex-solo-01)"; ctx="$(_ctx "$out")"
        [[ "$ctx" == *"$INT_DIRECTIVE"* ]] || { echo "prompt $i: ${ctx:0:300}"; return 1; }
    done
    out="$(_codex_status "$home" codex-solo-01)"
    [[ "$out" == *"VERIFIED - 1 directives"* && "$out" == *"Delivered:    IN FULL"* ]] || { echo "$out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 2, requirement 3. A copy stamped for another account or server, standing where this
# session's copy would be, is reported as not this configuration and never as VERIFIED, and the prompt
# hook refuses it rather than injecting it. The ordinary case, another account's copy beside this one
# under its own name, is NOT LOADED YET for this session, never that account's count.
# ---------------------------------------------------------------------------------------------
@test "isolation: foundation-status on a copy written for another account or server says NOT THIS CONFIGURATION, never VERIFIED" {
    local sid="claude-foreign-01" out ctx theirs mine
    # The Integration account's set, sealed as its writer would, but placed under the production
    # session's name: a copied file, or a key collision, whichever way it got there.
    export MMRY_API_URL="$INT_URL" MMRY_API_KEY="$INT_KEY"
    theirs="$(fnd_acct)"
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"
    mine="$(fnd_set_file)"
    printf -- '- Rule: %s\n' "$INT_DIRECTIVE" > "$TEST_TMPDIR/theirs.md"
    fnd_seal "$TEST_TMPDIR/theirs.md" 1 "$mine" "$theirs"
    printf '%s' "$sid" > "$(fnd_session_file)"

    out="$(_claude_status "$sid" "$PROD_URL" "$PROD_KEY")"
    [[ "$out" == *"NOT THIS CONFIGURATION"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"different account or server"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"REFUSED, not used"* ]] || { echo "$out"; return 1; }
    [[ "$out" != *"VERIFIED"* ]] || { echo "reported VERIFIED: $out"; return 1; }

    # And the prompt hook: nothing of it is injected, and the turn is told so.
    out="$(_claude_prompt "$sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" != *"$INT_DIRECTIVE"* ]] || { echo "the foreign copy was injected: ${ctx:0:300}"; return 1; }
    [[ "$ctx" == *"could not verify this account"* ]] || { echo "no refusal notice: ${ctx:0:300}"; return 1; }
    [[ "$out" == *"different account or server"* ]] || { echo "the person was not told why: $out"; return 1; }
}

@test "isolation: another account's copy beside this session's, under its own name, reads as NOT LOADED YET here, never as its count" {
    local int_sid="codex-int-02" prod_sid="claude-prod-02" codex out
    codex="$(_codex_home int2 "$INT_URL" "$INT_KEY")"
    _codex_start "$codex" "$int_sid" "$INT_DIRECTIVE" >/dev/null
    # The production session has not loaded anything yet.
    out="$(_claude_status "$prod_sid" "$PROD_URL" "$PROD_KEY")"
    [[ "$out" == *"NOT LOADED YET"* ]] || { echo "$out"; return 1; }
    [[ "$out" != *"1 directives"* && "$out" != *"VERIFIED"* ]] || { echo "reported the other account's copy: $out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 3, requirement 4. The machine-wide, unkeyed mmry-foundation-set.md and mmry-foundation.session
# an older plugin left are never read: a session that has fetched its own set injects its own, a session
# that has not injects nothing and is told NOT LOADED YET, and nothing of the legacy file reaches a prompt.
# The files are left alone unless nothing has touched them for a week, when SessionStart's sweep takes
# them with the other week-old Foundation leftovers; an older plugin still running keeps its copy.
# ---------------------------------------------------------------------------------------------
_legacy_copy() {
    # Sealed exactly as plugin 2.10 to 2.14 wrote it: a v2 record, no account key, the unkeyed name.
    local body="$TEST_TMPDIR/legacy-body.md" s b
    printf -- '- Rule: %s\n' "$1" > "$body"
    read -r s b < <(cksum < "$body")
    { printf 'mmry-foundation v2 entries=1 bytes=%s cksum=%s\n' "$b" "$s"; cat "$body"; printf 'END OF FOUNDATION SET'; } > "$TEST_TMPDIR/mmry-foundation-set.md"
    printf 'legacy-session-id' > "$TEST_TMPDIR/mmry-foundation.session"
}

@test "isolation: a legacy unkeyed mmry-foundation-set.md is ignored - the upgraded hook injects the account's own set, fetched fresh" {
    local sid="claude-upgrade-01" out ctx
    _legacy_copy "LEGACY: a directive left by an older plugin version, possibly another account's."
    _claude_start "$sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" "$PROD_DIRECTIVE_2" >/dev/null
    out="$(_claude_prompt "$sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" == *"$PROD_DIRECTIVE_2"* ]] || { echo "own set not injected: ${ctx:0:300}"; return 1; }
    [[ "$ctx" != *"LEGACY:"* ]] || { echo "the legacy copy was injected: ${ctx:0:300}"; return 1; }
    # The legacy file is untouched: an older plugin in another session may still be using it.
    [[ -f "$TEST_TMPDIR/mmry-foundation-set.md" && -f "$TEST_TMPDIR/mmry-foundation.session" ]] || { echo "the legacy files were removed on sight"; return 1; }
    [[ "$(cat "$TEST_TMPDIR/mmry-foundation.session")" == "legacy-session-id" ]] || { echo "the legacy marker was rewritten"; return 1; }
}

@test "isolation: with only a legacy copy present and nothing fetched, the hook injects nothing and status says NOT LOADED YET" {
    local sid="claude-upgrade-02" out ctx
    _legacy_copy "LEGACY: a directive left by an older plugin version."
    out="$(_claude_prompt "$sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ -z "$ctx" ]] || { echo "something was injected from nothing but a legacy copy: ${ctx:0:300}"; return 1; }
    out="$(_claude_status "$sid" "$PROD_URL" "$PROD_KEY")"
    [[ "$out" == *"NOT LOADED YET"* && "$out" != *"VERIFIED"* ]] || { echo "$out"; return 1; }
}

@test "isolation: the legacy files are swept by SessionStart only once they are a week old" {
    _legacy_copy "LEGACY"
    touch -t 202001010000 "$TEST_TMPDIR/mmry-foundation-set.md" "$TEST_TMPDIR/mmry-foundation.session"
    _claude_start claude-sweep-01 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" >/dev/null
    [[ ! -e "$TEST_TMPDIR/mmry-foundation-set.md" && ! -e "$TEST_TMPDIR/mmry-foundation.session" ]] || { echo "week-old legacy files were kept"; return 1; }
    # And this session's own keyed copy, just written, is there.
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"
    [[ -f "$(fnd_set_file)" ]] || { echo "the session's own copy is missing"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 2, the session marker. With no session id in the payload the hook files its records under
# the marker SessionStart wrote. The marker is keyed too, so another account's start does not replace it,
# and this session's status still recognises its own delivery afterwards.
# ---------------------------------------------------------------------------------------------
@test "isolation: the session marker is per account - another account starting does not take over this session's records" {
    local prod_sid="claude-marker-01" out codex
    _claude_start "$prod_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" >/dev/null
    # A prompt with no session id: records are stamped with the marker's token.
    out="$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' \
        | env MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY" MMRY_AUTH_METHOD=apikey MMRY_FOUNDATION_REFRESH_SECONDS=0 \
              bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 2>/dev/null)"
    [[ "$(_ctx "$out")" == *"$PROD_DIRECTIVE_1"* ]] || { echo "control: no delivery: ${out:0:200}"; return 1; }
    # The other account starts on the same machine.
    codex="$(_codex_home marker "$INT_URL" "$INT_KEY")"
    _codex_start "$codex" codex-marker-01 "$INT_DIRECTIVE" >/dev/null
    # Asked with no session id, the production status reads its own marker, which still names its own
    # session, so the delivery it made a moment ago is still its own.
    out="$(env MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY" MMRY_AUTH_METHOD=apikey bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh" 2>/dev/null)"
    [[ "$out" == *"Delivered:    IN FULL"* ]] || { echo "the delivery was lost to the other account's start: $out"; return 1; }
}

# Found by the mutation harness (tests/mutation/run-32889-mutations.sh): every two-account test above
# also used two servers, so a key hashed from the server alone passed them all. A customer with two
# accounts on one server is the ordinary case.
@test "isolation: two accounts on ONE server are two sets - the account is part of the key" {
    local a_sid="claude-acct-a" b_sid="claude-acct-b" out ctx
    _claude_start "$a_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE_1" >/dev/null
    _claude_start "$b_sid" "$PROD_URL" "$INT_KEY"  "$INT_DIRECTIVE" >/dev/null
    out="$(_claude_prompt "$a_sid" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE_1"* && "$ctx" != *"$INT_DIRECTIVE"* ]] || { echo "account A got account B's set: ${ctx:0:300}"; return 1; }
    out="$(_claude_prompt "$b_sid" "$PROD_URL" "$INT_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* && "$ctx" != *"$PROD_DIRECTIVE_1"* ]] || { echo "account B got account A's set: ${ctx:0:300}"; return 1; }
}

# Found by the same harness: a supervisor that keyed the name from the environment alone, ignoring the
# config file, still delivered part 1 on Codex, because the worker it fell back to parses the config with
# jq and found the set under its right name. Parts 2 to 6 have no such fallback: their quick exit reads
# the record under the supervisor's name, and under the wrong name they leave saying "none". So a Codex
# session whose identity comes only from its config file must get a multi-part set whole.
@test "isolation: a Codex session identified by its config file alone gets a multi-part set whole, every part under its own name" {
    local home out ctx k i directives=()
    for (( i = 1; i <= 140; i++ )); do
        directives+=("Directive $(printf '%03d' "$i"): keep every sentence short and every claim backed by something you ran.")
    done
    home="$(_codex_home multipart "$INT_URL" "$INT_KEY")"
    _codex_start "$home" codex-multipart-01 "${directives[@]}" >/dev/null
    for k in 1 2; do
        out="$(_codex_prompt "$home" codex-multipart-01 "$k")"; ctx="$(_ctx "$out")"
        [[ "$ctx" == *"This is PART $k OF 2 of the set, version "* ]] || { echo "part $k missing or not labelled $k of 2: ${ctx:0:200}"; return 1; }
    done
    [[ "$ctx" == *"Directive 140:"* ]] || { echo "the last directive did not arrive in part 2: ${ctx: -200}"; return 1; }
}
