#!/usr/bin/env bats
# startup-memories-isolation.bats - two MMRY sessions on one machine never swap STARTUP memories, and
# the Foundation working files are each account's own (#32915).
#
# THE DEFECT, found by the independent QA of #32889 (NEW-1, HIGH). session-start.sh wrote every
# startup memory, Foundation included, to ONE machine-wide file, ${MMRY_TMPDIR}/mmry-memories.md,
# and its SessionStart context told the model "Read them now: <that path>". When a second session on
# another account started before the first session's model had opened the file, the first model read
# the second account's memories and directives. QA reproduced it with scripts/probe-memfile.sh on
# 2026-10-24; it had happened in practice on 2026-10-10, when a test account's memories replaced the
# PM session's for about two minutes (#31916).
#
# NEW-2: with no session id and no SessionStart marker the by-reference copy fell back to the shared
# name mmry-foundation.byref.md. NEW-3: the refresh throttle stamp, the refresh lock and the failure
# log were unkeyed, so one account's throttle could delay another's refresh by up to 300 s.
#
# Every test drives the real entry points - session-start.sh, codex-hook.sh for the Codex session,
# the UserPromptSubmit hook - with a mock curl standing in for the service. The only thing the two
# sessions share is the temp directory, which is exactly what they share on a real machine. The
# first test was run against the develop handlers before the fix and failed there: the file account
# A was told to read held account B's memories after B started (the red run is in the handback).

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
    PROD_DIRECTIVE="PRODUCTION-DIRECTIVE: keep every claim backed by something you ran."
    PROD_NOTE="PRODUCTION-NOTE: the production account prefers short sentences."
    INT_DIRECTIVE="INTEGRATION-DIRECTIVE: always answer in plain English."
    INT_NOTE="INTEGRATION-NOTE: the integration account is a throwaway."
}

# The startup response the mock service gives an account: one Foundation memory for the directive
# given, and one ordinary memory for the note, so the file holds more than the Foundation set.
#   _startup_body <directive> <note>
_startup_body() {
    printf '[{"id":1,"topic":"Rule","content":"%s","memoryTier":"Foundation","scope":"global","category":"Fact"},{"id":2,"topic":"Note","content":"%s","memoryTier":"Experience","scope":"global","category":"Fact"}]' "$1" "$2"
}

# A Claude Code SessionStart for the account given by its URL and key, with the session id Claude Code
# puts first in the payload. Prints the hook's JSON.
#   _claude_start <sid> <url> <key> <directive> <note>
_claude_start() {
    local sid="$1" url="$2" key="$3"; shift 3
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$sid" \
        | env MMRY_API_URL="$url" MMRY_API_KEY="$key" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}

# The same start with NO session id anywhere: no field in the payload, nothing in the environment.
# That is /mmry:load-memories run outside the Bash tool, or a host whose payload names the field
# differently; the session is registered as "unknown" and still loads its memories.
#   _claude_start_nosid <url> <key> <directive> <note>
_claude_start_nosid() {
    local url="$1" key="$2"; shift 2
    printf '{"hook_event_name":"SessionStart","cwd":"/w"}' \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID MMRY_API_URL="$url" MMRY_API_KEY="$key" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}

# A Claude Code SessionStart whose identity comes from a CONFIG FILE, for the fail-closed cases.
#   _claude_start_cfg <sid> <config-file> <directive> <note>
_claude_start_cfg() {
    local sid="$1" cfg="$2"; shift 2
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$sid" \
        | env MMRY_CONFIG_FILE="$cfg" MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}

# A Claude Code prompt for that session: part 1 of the UserPromptSubmit hook, exactly as hooks.json
# registers it. The refresh interval is the caller's; 0 turns the daily refresh off.
#   _claude_prompt <sid> <url> <key> [refresh-seconds]
_claude_prompt() {
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" \
        | env MMRY_API_URL="$2" MMRY_API_KEY="$3" MMRY_AUTH_METHOD=apikey MMRY_FOUNDATION_REFRESH_SECONDS="${4:-0}" \
              bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 2>/dev/null
}

# The same prompt with no session id in the payload and none in the environment.
#   _claude_prompt_nosid <url> <key>
_claude_prompt_nosid() {
    printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID MMRY_API_URL="$1" MMRY_API_KEY="$2" MMRY_AUTH_METHOD=apikey MMRY_FOUNDATION_REFRESH_SECONDS=0 \
              bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 2>/dev/null
}

# A Claude Code prompt whose identity comes from a CONFIG FILE, for the fail-closed cases, with the
# daily refresh ON (the interval given, in seconds) and a service that WOULD answer a fetch with a
# directive: if the hook's refresh worker fetches for this session, the set gets stored and the next
# prompt delivers it, which is what QA round 1 found (probe3) and requirement 3 forbids.
#   _claude_prompt_cfg <sid> <config-file> <refresh-seconds> [part]
_claude_prompt_cfg() {
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" \
        | env MMRY_CONFIG_FILE="$2" MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_FOUNDATION_REFRESH_SECONDS="$3" \
              MOCK_CURL_RESPONSE="$(_startup_body "$PROD_DIRECTIVE" "$PROD_NOTE")" \
              bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part "${4:-1}" 2>/dev/null
}

# A Codex session: its own CODEX_HOME holding its own mmry-config.json, every hook through
# codex-hook.sh, the real Codex entry point. Nothing about the account is in the environment.
_codex_home() {
    local dir="$TEST_TMPDIR/codexhome-$1"
    mkdir -p "$dir/mmry"
    printf '{\n  "apiUrl": "%s",\n  "authMethod": "apikey",\n  "apiKey": "%s",\n  "foundationRefreshSeconds": 0\n}\n' "$2" "$3" > "$dir/mmry-config.json"
    printf '%s' "$dir"
}
#   _codex_start <codex-home> <sid> <directive> <note>
_codex_start() {
    local home="$1" sid="$2"; shift 2
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$sid" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$home" \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" session-start 2>/dev/null
}

# The same Codex start with NO session id in the payload: the session is registered as "unknown".
#   _codex_start_nosid <codex-home> <directive> <note>
_codex_start_nosid() {
    local home="$1"; shift
    printf '{"hook_event_name":"SessionStart","cwd":"/w"}' \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_API_URL -u MMRY_API_KEY -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
              CODEX_HOME="$home" MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" session-start 2>/dev/null
}

# A Claude Code SessionStart with NO session id whose response carries NO Foundation memory at all (an
# empty set), for the empty-set notice.
#   _claude_start_nosid_empty <url> <key>
_claude_start_nosid_empty() {
    printf '{"hook_event_name":"SessionStart","cwd":"/w"}' \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID MMRY_API_URL="$1" MMRY_API_KEY="$2" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE='[{"id":2,"topic":"Note","content":"an ordinary memory","memoryTier":"Experience","scope":"global","category":"Fact"}]' \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}

_ctx() { jq -j '.hookSpecificOutput.additionalContext // ""' <<<"$1" | tr -d '\r'; }
_umsg() { jq -j '.systemMessage // ""' <<<"$1" | tr -d '\r'; }
# A directive padded past one part's capacity, so that with MMRY_FOUNDATION_PARTS_MAX=1 the set goes
# by reference: the directive text first, then 12,000 filler characters.
_big_directive() { printf '%s %s' "$1" "$(printf '%*s' 12000 '' | tr ' ' 'q')"; }

# THE FILE THE MODEL WAS TOLD TO READ, from a SessionStart output. On Codex for Windows the path is
# spelled for PowerShell (C:\...), so it is turned back into the path this shell can open.
_told_path() {
    local ctx p
    ctx="$(_ctx "$1")"
    [[ "$ctx" == *"Read them now: "* ]] || return 1
    p="${ctx##*Read them now: }"
    if [[ "$p" =~ ^[A-Za-z]:\\ ]] && command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$p")"; fi
    printf '%s' "$p"
}

# The whole file, bytes intact.
_file() { local t; t="$(cat "$1"; printf x)"; printf '%s' "${t%x}"; }

# Every file in the temp directory whose name starts "mmry-memories", one per line, sorted.
_memories_files() { ( cd "$TEST_TMPDIR" && ls -1 2>/dev/null | grep '^mmry-memories' | sort ); }

# ---------------------------------------------------------------------------------------------
# TEST CASE 1, requirements 1 and 2. Two sessions, two accounts on two servers, one temp directory,
# started one after the other in the incident order: the production Claude Code session first, then
# the Integration Codex session. Each session's instructed startup file holds only its own memories,
# and the first session's file is byte for byte what it was before the second started.
# ---------------------------------------------------------------------------------------------
@test "startup: the 2026-10-24 swap - the file the production session was told to read still holds only ITS memories after an Integration Codex session starts" {
    local prod_sid="claude-prod-session-01" int_sid="codex-int-thread-01" out pa pb before after codex

    out="$(_claude_start "$prod_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    pa="$(_told_path "$out")" || { echo "production session was not told to read anything: ${out:0:300}"; return 1; }
    [[ -f "$pa" ]] || { echo "the file the production session was told to read does not exist: $pa"; return 1; }
    before="$(_file "$pa")"
    [[ "$before" == *"$PROD_DIRECTIVE"* && "$before" == *"$PROD_NOTE"* ]] || { echo "production file lacks its own memories: ${before:0:300}"; return 1; }

    # 01:16:42 UTC: the Integration session starts, on the same machine, before the production
    # session's model has opened its file.
    codex="$(_codex_home int "$INT_URL" "$INT_KEY")"
    out="$(_codex_start "$codex" "$int_sid" "$INT_DIRECTIVE" "$INT_NOTE")"
    pb="$(_told_path "$out")" || { echo "Integration session was not told to read anything: ${out:0:300}"; return 1; }

    # The production session's model now opens the file it was told to read.
    after="$(_file "$pa")"
    [[ "$after" != *"$INT_DIRECTIVE"* && "$after" != *"$INT_NOTE"* ]] || { echo "the PRODUCTION session's file holds the INTEGRATION account's memories: ${after:0:300}"; return 1; }
    [[ "$after" == "$before" ]] || { echo "the production session's file changed when the other account started"; return 1; }

    # And the Integration session's file is its own, and only its own.
    [[ "$pb" != "$pa" ]] || { echo "both sessions were told to read the same file: $pa"; return 1; }
    [[ -f "$pb" ]] || { echo "the file the Integration session was told to read does not exist: $pb"; return 1; }
    after="$(_file "$pb")"
    [[ "$after" == *"$INT_DIRECTIVE"* && "$after" == *"$INT_NOTE"* ]] || { echo "Integration file lacks its own memories: ${after:0:300}"; return 1; }
    [[ "$after" != *"$PROD_DIRECTIVE"* && "$after" != *"$PROD_NOTE"* ]] || { echo "the INTEGRATION session's file holds the PRODUCTION account's memories: ${after:0:300}"; return 1; }
}

@test "startup: each session is told to read the file named by ITS account and server and session, and the file is stamped with that account" {
    local prod_sid="claude-prod-session-02" int_sid="codex-int-thread-02" out pa pb want codex first
    out="$(_claude_start "$prod_sid" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    pa="$(_told_path "$out")" || { echo "no instruction: ${out:0:300}"; return 1; }
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"
    want="$(fnd_memories_file "$prod_sid")"
    [[ "$pa" == "$want" ]] || { echo "production session told to read $pa, its own file is $want"; return 1; }
    IFS= read -r first < "$pa"
    [[ "$first" == *"$(fnd_acct)"* ]] || { echo "the file is not stamped with its account: $first"; return 1; }

    codex="$(_codex_home int2 "$INT_URL" "$INT_KEY")"
    out="$(_codex_start "$codex" "$int_sid" "$INT_DIRECTIVE" "$INT_NOTE")"
    pb="$(_told_path "$out")" || { echo "no instruction: ${out:0:300}"; return 1; }
    want="$(FND_CONFIG_OVERRIDE="$codex/mmry-config.json" fnd_memories_file "$int_sid")"
    # By name and content, not by spelling: on Windows the Codex path is spelled for PowerShell and
    # comes back as /tmp/..., the same folder $TEST_TMPDIR spells /c/Users/.../Temp/....
    [[ "${pb##*/}" == "${want##*/}" && -f "$pb" && -f "$want" && "$(_file "$pb")" == "$(_file "$want")" ]] \
        || { echo "Integration session told to read $pb, its own file is $want"; return 1; }
    IFS= read -r first < "$pb"
    [[ "$first" == *"$(FND_CONFIG_OVERRIDE="$codex/mmry-config.json" fnd_acct)"* ]] || { echo "the file is not stamped with its account: $first"; return 1; }
    # The machine-wide name is never written.
    [[ ! -e "$TEST_TMPDIR/mmry-memories.md" ]] || { echo "the unkeyed machine-wide file was written"; return 1; }
}

@test "startup: two Claude Code sessions on different accounts in one TMPDIR are each told to read their own file, holding only their own memories" {
    local out pa pb fa fb
    out="$(_claude_start claude-a-01 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"; pa="$(_told_path "$out")" || { echo "A: ${out:0:200}"; return 1; }
    out="$(_claude_start claude-b-01 "$INT_URL"  "$INT_KEY"  "$INT_DIRECTIVE"  "$INT_NOTE")";  pb="$(_told_path "$out")" || { echo "B: ${out:0:200}"; return 1; }
    [[ "$pa" != "$pb" ]] || { echo "one file for two accounts: $pa"; return 1; }
    fa="$(_file "$pa")"; fb="$(_file "$pb")"
    [[ "$fa" == *"$PROD_DIRECTIVE"* && "$fa" != *"$INT_DIRECTIVE"* ]] || { echo "A's file: ${fa:0:300}"; return 1; }
    [[ "$fb" == *"$INT_DIRECTIVE"* && "$fb" != *"$PROD_DIRECTIVE"* ]] || { echo "B's file: ${fb:0:300}"; return 1; }
}

# Found by reasoning about the mutation harness before it ran: every two-session test above also
# uses two session ids, so a name keyed by the session id ALONE would pass them all. A start with no
# session id at all is an ordinary case (a manual reload, or a host whose payload lacks the field),
# and two such starts on two accounts must still be two files.
@test "startup: two accounts starting with NO session id at all are still two files - the account is in the name, not only the session" {
    local out pa pb fa fb
    out="$(_claude_start_nosid "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"; pa="$(_told_path "$out")" || { echo "A: ${out:0:200}"; return 1; }
    out="$(_claude_start_nosid "$INT_URL"  "$INT_KEY"  "$INT_DIRECTIVE"  "$INT_NOTE")";  pb="$(_told_path "$out")" || { echo "B: ${out:0:200}"; return 1; }
    [[ "$pa" != "$pb" ]] || { echo "one file for two accounts with no session id: $pa"; return 1; }
    fa="$(_file "$pa")"; fb="$(_file "$pb")"
    [[ "$fa" == *"$PROD_DIRECTIVE"* && "$fa" != *"$INT_DIRECTIVE"* ]] || { echo "A's file: ${fa:0:300}"; return 1; }
    [[ "$fb" == *"$INT_DIRECTIVE"* && "$fb" != *"$PROD_DIRECTIVE"* ]] || { echo "B's file: ${fb:0:300}"; return 1; }
}

@test "startup: the same account on two servers is two files - the server is part of the name" {
    local out pa pb
    out="$(_claude_start claude-srv-a "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"; pa="$(_told_path "$out")" || return 1
    out="$(_claude_start claude-srv-a "$INT_URL"  "$PROD_KEY" "$INT_DIRECTIVE"  "$INT_NOTE")";  pb="$(_told_path "$out")" || return 1
    [[ "$pa" != "$pb" ]] || { echo "one file for one key on two servers: $pa"; return 1; }
    [[ "$(_file "$pa")" == *"$PROD_DIRECTIVE"* && "$(_file "$pa")" != *"$INT_DIRECTIVE"* ]] || { echo "server A's file holds server B's memories"; return 1; }
}

@test "startup: two sessions of ONE account are two files - a second session does not replace the file the first was told to read" {
    local out pa pb before
    out="$(_claude_start claude-same-1 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"; pa="$(_told_path "$out")" || return 1
    before="$(_file "$pa")"
    out="$(_claude_start claude-same-2 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "second session, different working directory")"; pb="$(_told_path "$out")" || return 1
    [[ "$pa" != "$pb" ]] || { echo "the second session was told to read the first session's file: $pa"; return 1; }
    [[ "$(_file "$pa")" == "$before" ]] || { echo "the first session's file was rewritten by the second"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 2, requirement 2. The per-prompt fallback copy, the refresh throttle and the log are
# named per account, and one account's refresh does not delay the other's.
# ---------------------------------------------------------------------------------------------
@test "startup: the failure log is each account's own - a refusal on one account is logged under its name and never under the shared name" {
    local out la lb
    # A stub where each account's set should be: the four-byte file #31583 is about. Part 1 refuses it
    # and logs the refusal.
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; la="$(fnd_log_file)"
    printf -- '- x\n' > "$(fnd_set_file)"
    export MMRY_API_URL="$INT_URL" MMRY_API_KEY="$INT_KEY"; lb="$(fnd_log_file)"
    [[ "$la" != "$lb" ]] || { echo "one log name for two accounts: $la"; return 1; }

    out="$(_claude_prompt claude-log-a "$PROD_URL" "$PROD_KEY")"
    [[ "$(_ctx "$out")" == *"could not verify"* ]] || { echo "control: no refusal on the stub: ${out:0:300}"; return 1; }
    [[ -f "$la" ]] || { echo "no log for account A at $la; files: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    grep -q 'foundation reinjection REFUSED' "$la" || { echo "A's log holds no refusal: $(cat "$la")"; return 1; }
    [[ ! -e "$lb" ]] || { echo "account B's log was written by account A's refusal"; return 1; }
    [[ ! -e "$TEST_TMPDIR/mmry-foundation.log" ]] || { echo "the shared, unkeyed log was written"; return 1; }
}

@test "startup: the refresh throttle stamp and lock are each account's own, and one account's fresh stamp does not delay the other account's refresh" {
    local out sa sb ka kb i now last
    # Both accounts have a set a year old, so a refresh is due for each. The interval is 600 s, so
    # the throttle window is the hook's own cap of 300 s: wide enough that a loaded machine (this PC
    # under three concurrent runs took over 60 s for one prompt and its wait) cannot age A's stamp
    # out of the window before B fires, which would fail the control, not the check.
    _claude_start claude-refresh-a "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE" >/dev/null
    _claude_start claude-refresh-b "$INT_URL"  "$INT_KEY"  "$INT_DIRECTIVE"  "$INT_NOTE"  >/dev/null
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; sa="$(fnd_refresh_checked_file)"; ka="$(fnd_refresh_file)"; touch -t 202501010000 "$(fnd_set_file)"
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY";  sb="$(fnd_refresh_checked_file)"; kb="$(fnd_refresh_file)"; touch -t 202501010000 "$(fnd_set_file)"
    [[ "$sa" != "$sb" && "$ka" != "$kb" ]] || { echo "one throttle name for two accounts"; return 1; }

    # Account A's prompt: its stamp is written and, by a detached decision, its lock.
    out="$(_claude_prompt claude-refresh-a "$PROD_URL" "$PROD_KEY" 600)"
    [[ "$(_ctx "$out")" == *"$PROD_DIRECTIVE"* ]] || { echo "control: A did not deliver: ${out:0:300}"; return 1; }
    [[ -f "$sa" ]] || { echo "A's stamp was not written at $sa; files: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    for (( i = 0; i < 300; i++ )); do [[ -f "$ka" ]] && break; sleep 0.2; done
    [[ -f "$ka" ]] || { echo "A's refresh was not decided (no lock at $ka)"; return 1; }

    # Account B's prompt, at once, while A's stamp is well inside the 300 s window. An unkeyed stamp
    # would throttle B here: B's refresh would wait for A's window to pass.
    last="$(<"$sa")"; now="$(date +%s)"
    (( now - last < 300 )) || { echo "control: A's stamp is already $(( now - last )) s old, so this proves nothing about the throttle"; return 1; }
    out="$(_claude_prompt claude-refresh-b "$INT_URL" "$INT_KEY" 600)"
    [[ "$(_ctx "$out")" == *"$INT_DIRECTIVE"* ]] || { echo "control: B did not deliver: ${out:0:300}"; return 1; }
    [[ -f "$sb" ]] || { echo "B's stamp was not written: A's stamp throttled B"; return 1; }
    for (( i = 0; i < 300; i++ )); do [[ -f "$kb" ]] && break; sleep 0.2; done
    [[ -f "$kb" ]] || { echo "B's refresh was not decided inside A's window: one account's throttle delayed the other's refresh"; return 1; }

    [[ ! -e "$TEST_TMPDIR/.mmry-foundation-refresh-checked" && ! -e "$TEST_TMPDIR/.mmry-foundation-refresh" ]] \
        || { echo "the shared, unkeyed throttle files were written"; return 1; }
}

# A set too large to show in six parts, written as the plugin writes it, for the account the
# environment names: twelve directives of about 5,100 bytes, over the 57,000-character capacity. A
# few large entries rather than hundreds of small ones, as handlers/foundation-31597-edges.bats
# builds its by-reference set: the cutter's cost grows with the lines, and on a loaded Windows
# machine 650 lines put the prompt past the hook's deadline. The response goes through a file
# because a body this size cannot travel in an environment variable on Windows.
_write_large_set() {
    local resp="$TEST_TMPDIR/large-$1.json" i w=""
    for (( i = 0; i < 100; i++ )); do w+="$1 directive text: keep every claim backed by a run. "; done
    { printf '['
      for (( i = 1; i <= 12; i++ )); do
          (( i > 1 )) && printf ','
          printf '{"memoryTier":"Foundation","topic":"R%02d","content":"%s directive %02d. %s"}' "$i" "$1" "$i" "$w"
      done
      printf ']'
    } > "$resp"
    bash -c 'source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1; mmry_write_foundation_cache "$(cat "$2")" "$3"' \
        _ "$PLUGIN_ROOT" "$resp" "$(fnd_set_file)"
}

@test "startup: the by-reference copy made with NO session id and NO marker is each account's own, never the shared mmry-foundation.byref.md" {
    local out ctx ca cb
    # Cutting a 60,000-character set runs past the hook's 10 s deadline on a loaded Windows machine
    # (seen twice on this PC); the deadline is not what this test is about, so it is widened the way
    # the README documents. The name of the copy is what is under test.
    export MMRY_FOUNDATION_DEADLINE_SECS=60
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; _write_large_set PRODUCTION || { echo "the writer failed for A"; return 1; }; ca="$(fnd_byref_file)"
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY";  _write_large_set INTEGRATION || { echo "the writer failed for B"; return 1; }; cb="$(fnd_byref_file)"
    [[ "$ca" != "$cb" ]] || { echo "one by-reference name for two accounts: $ca"; return 1; }

    out="$(_claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"too large to show here"* ]] || { echo "control: A was not delivered by reference: ${ctx:0:300}"; return 1; }
    [[ -f "$ca" ]] || { echo "no copy for A at $ca; files: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    [[ "$ctx" == *"${ca##*/}"* ]] || { echo "A's prompt points at a file other than its own copy: ${ctx:0:400}"; return 1; }

    out="$(_claude_prompt_nosid "$INT_URL" "$INT_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"too large to show here"* ]] || { echo "control: B was not delivered by reference: ${ctx:0:300}"; return 1; }
    [[ -f "$cb" ]] || { echo "no copy for B at $cb"; return 1; }
    [[ "$ctx" == *"${cb##*/}"* ]] || { echo "B's prompt points at a file other than its own copy: ${ctx:0:400}"; return 1; }
    grep -q 'PRODUCTION directive 12\.' "$ca" || { echo "A's copy does not hold A's set"; return 1; }
    grep -q 'INTEGRATION directive 12\.' "$cb" || { echo "B's copy does not hold B's set"; return 1; }
    (( $(grep -c 'INTEGRATION directive' "$ca" || true) == 0 )) || { echo "A's copy holds B's directives"; return 1; }
    [[ ! -e "$TEST_TMPDIR/mmry-foundation.byref.md" ]] || { echo "the shared, unkeyed by-reference copy was written"; return 1; }
}

@test "startup: the by-reference copy made WITH a session id carries the account as well as the session" {
    local out ctx c
    export MMRY_FOUNDATION_DEADLINE_SECS=60
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; _write_large_set PRODUCTION || return 1
    c="$(fnd_byref_file claude-byref-sid)"
    out="$(_claude_prompt claude-byref-sid "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"too large to show here"* ]] || { echo "control: not delivered by reference: ${ctx:0:300}"; return 1; }
    [[ -f "$c" ]] || { echo "no copy at $c; files: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    [[ "$ctx" == *"${c##*/}"* ]] || { echo "the prompt points elsewhere: ${ctx:0:400}"; return 1; }
}

# Found by independent QA of round 1 (probe2, requirement 2). With no session id on either session,
# the per-prompt hook named its prepared copy, claim, result and stored markers by the token
# SessionStart leaves for an id-less session, the literal "unknown": one name for both accounts, and
# the prepared copy holds the directive text, so account B's prompt overwrote account A's copy.
@test "startup: the per-session markers made with NO session id are each account's own - two accounts never share the prepared copy, result, stored marker or delivery record" {
    local out ctx pa pb ra rb ma mb sa sb
    _claude_start_nosid "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE" >/dev/null
    _claude_start_nosid "$INT_URL"  "$INT_KEY"  "$INT_DIRECTIVE"  "$INT_NOTE"  >/dev/null
    # The names each account's markers must have: the token is "unknown" for both, so the account
    # key is what keeps them apart.
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"
    pa="$(fnd_prepared_file unknown)"; ra="$(fnd_result_file unknown)"; ma="$(fnd_stored_file unknown)"; sa="$(fnd_status_file)"
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY"
    pb="$(fnd_prepared_file unknown)"; rb="$(fnd_result_file unknown)"; mb="$(fnd_stored_file unknown)"; sb="$(fnd_status_file)"
    [[ "$pa" != "$pb" && "$ra" != "$rb" && "$ma" != "$mb" && "$sa" != "$sb" ]] || { echo "one marker name for two accounts: ${pa##*/}"; return 1; }
    # SessionStart stored a set for each, and said so under each account's own marker.
    [[ -f "$ma" && -f "$mb" ]] || { echo "stored markers missing: $(ls -a "$TEST_TMPDIR" | grep stored | tr '\n' ' ')"; return 1; }

    out="$(_claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* ]] || { echo "control: A did not deliver: ${ctx:0:300}"; return 1; }
    [[ -f "$pa" ]] || { echo "no prepared copy for A at ${pa##*/}; files: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    grep -q "$PROD_DIRECTIVE" "$pa" || { echo "A's prepared copy does not hold A's directive"; return 1; }
    [[ -f "$ra" ]] || { echo "no result marker for A at ${ra##*/}"; return 1; }
    [[ -f "$sa" ]] || { echo "no delivery record for A at ${sa##*/}; files: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }

    out="$(_claude_prompt_nosid "$INT_URL" "$INT_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* ]] || { echo "control: B did not deliver: ${ctx:0:300}"; return 1; }
    [[ -f "$pb" ]] || { echo "no prepared copy for B at ${pb##*/}"; return 1; }
    grep -q "$INT_DIRECTIVE" "$pb" || { echo "B's prepared copy does not hold B's directive"; return 1; }
    [[ -f "$rb" && -f "$sb" ]] || { echo "B's result or delivery record missing"; return 1; }
    # The overwrite QA saw: after B's prompt, A's prepared copy must still be A's.
    grep -q "$PROD_DIRECTIVE" "$pa" || { echo "A's prepared copy was overwritten by B's prompt"; return 1; }
    (( $(grep -c "$INT_DIRECTIVE" "$pa" || true) == 0 )) || { echo "A's prepared copy holds B's directive"; return 1; }
    (( $(grep -c "$PROD_DIRECTIVE" "$pb" || true) == 0 )) || { echo "B's prepared copy holds A's directive"; return 1; }
    # And the shared names are never used.
    local f
    for f in .mmry-foundation-prepared.unknown .mmry-foundation-claim.unknown .mmry-foundation-result.unknown \
             mmry-foundation.stored.unknown mmry-foundation.status mmry-foundation.outcome; do
        [[ ! -e "$TEST_TMPDIR/$f" ]] || { echo "the shared marker $f was written"; return 1; }
    done
}

# THE CODEX WRITER'S QUICK PATH (#32915, QA round 2, F-A). On Codex the set writer spells the stored
# marker itself, without the shared function, to keep Codex's start inside its budget (#33062). It
# spelled it from the session token alone, and the token for a session with no id is "unknown", so
# two Codex accounts starting with no session id wrote ONE bare mmry-foundation.stored.unknown and
# neither wrote the keyed marker the per-prompt hook looks for (QA probe5). The test above drives
# Claude Code starts only; this one drives two Codex starts through codex-hook.sh.
@test "startup: two Codex sessions starting with NO session id each get their own stored marker - the Codex writer's quick path names it by the account too, never the shared mmry-foundation.stored.unknown" {
    local ha hb ma mb out
    ha="$(_codex_home nosid-a "$PROD_URL" "$PROD_KEY")"
    hb="$(_codex_home nosid-b "$INT_URL"  "$INT_KEY")"
    ma="$(FND_CONFIG_OVERRIDE="$ha/mmry-config.json" fnd_stored_file unknown)"
    mb="$(FND_CONFIG_OVERRIDE="$hb/mmry-config.json" fnd_stored_file unknown)"
    [[ "$ma" != "$mb" && "${ma##*/}" == mmry-foundation.stored.*.unknown ]] || { echo "unexpected marker names: ${ma##*/} ${mb##*/}"; return 1; }

    out="$(_codex_start_nosid "$ha" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    _told_path "$out" >/dev/null || { echo "control: Codex session A loaded nothing: ${out:0:300}"; return 1; }
    [[ -f "$ma" ]] || { echo "no stored marker for A at ${ma##*/}; stored files: $(ls -a "$TEST_TMPDIR" | grep stored | tr '\n' ' ')"; return 1; }
    [[ "$(_file "$ma")" == "1" ]] || { echo "A's marker does not hold A's count: $(_file "$ma")"; return 1; }

    out="$(_codex_start_nosid "$hb" "$INT_DIRECTIVE" "$INT_NOTE")"
    _told_path "$out" >/dev/null || { echo "control: Codex session B loaded nothing: ${out:0:300}"; return 1; }
    [[ -f "$mb" ]] || { echo "no stored marker for B at ${mb##*/}; stored files: $(ls -a "$TEST_TMPDIR" | grep stored | tr '\n' ' ')"; return 1; }
    [[ -f "$ma" ]] || { echo "A's stored marker went when B started"; return 1; }
    # The shared name is never written, by either start.
    [[ ! -e "$TEST_TMPDIR/mmry-foundation.stored.unknown" ]] || { echo "the shared marker mmry-foundation.stored.unknown was written"; return 1; }
}

# THE NOTICE MARKERS (#32915, QA round 2, F-B). The by-reference told marker, the in-flight marker and
# the cut-short marker were bare names with no session id, so two accounts in that state shared each
# of them. QA's privacy probe: account B's user was never told its set goes by reference (A's marker
# stood for B's), B's assistant was told B's previous turn ran without directives (A's killed turn),
# and A's own lost turn was never reported (B's prompt consumed the marker). Two accounts, no session
# id, each set too large to show so each goes by reference.
@test "startup: the by-reference, in-flight and cut-short markers made with NO session id are each account's own - one account's user is always told, and never told of the other account's lost turn" {
    local out ia ib ca cb ta tb f
    _claude_start_nosid "$PROD_URL" "$PROD_KEY" "$(_big_directive "$PROD_DIRECTIVE")" "$PROD_NOTE" >/dev/null
    _claude_start_nosid "$INT_URL"  "$INT_KEY"  "$(_big_directive "$INT_DIRECTIVE")"  "$INT_NOTE"  >/dev/null
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"
    ia="$(fnd_inflight_file)"; ca="$(fnd_cutshort_file)"; ta="$(fnd_byref_told_file)"
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY"
    ib="$(fnd_inflight_file)"; cb="$(fnd_cutshort_file)"; tb="$(fnd_byref_told_file)"
    unset MMRY_API_URL MMRY_API_KEY
    [[ "$ia" != "$ib" && "$ca" != "$cb" && "$ta" != "$tb" ]] || { echo "one marker name for two accounts: ${ia##*/}"; return 1; }

    # A's first prompt: its user is told once that the set goes by reference, under A's own marker.
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"
    [[ "$(_umsg "$out")" == *"larger than"* ]] || { echo "control: A's user was not told of A's by-reference set: ${out:0:300}"; return 1; }
    [[ -f "$ta" ]] || { echo "A's told marker is not at ${ta##*/}; files: $(ls -a "$TEST_TMPDIR" | grep told | tr '\n' ' ')"; return 1; }
    # B's first prompt: B's user is told too. With one shared marker, A's telling stood for B's.
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$INT_URL" "$INT_KEY")"
    [[ "$(_umsg "$out")" == *"larger than"* ]] || { echo "B's user was NOT told of B's by-reference set: A's marker stood for B's"; return 1; }
    [[ -f "$tb" ]] || { echo "B's told marker is not at ${tb##*/}"; return 1; }
    # A's second prompt: said once a session, so not again.
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"
    [[ "$(_umsg "$out")" != *"larger than"* ]] || { echo "A's user was told twice"; return 1; }

    # A's turn killed by the harness: the in-flight marker it leaves behind, at A's own name. B's
    # next turn must not report it; A's must, once.
    : > "$ia"
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$INT_URL" "$INT_KEY")"
    [[ "$(_ctx "$out")" != *"PREVIOUS turn"* ]] || { echo "B's assistant was told of A's lost turn"; return 1; }
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"
    [[ "$(_ctx "$out")" == *"PREVIOUS turn"* ]] || { echo "A's own lost turn was never reported to A"; return 1; }
    [[ ! -e "$ia" ]] || { echo "A's in-flight marker was not consumed by A's turn"; return 1; }
    # A turn stopped at the deadline leaves the cut-short marker, reported the same way.
    : > "$ca"
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$INT_URL" "$INT_KEY")"
    [[ "$(_ctx "$out")" != *"PREVIOUS turn"* ]] || { echo "B's assistant was told of A's cut-short turn"; return 1; }
    out="$(MMRY_FOUNDATION_PARTS_MAX=1 _claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"
    [[ "$(_ctx "$out")" == *"PREVIOUS turn"* ]] || { echo "A's own cut-short turn was never reported to A"; return 1; }
    [[ ! -e "$ca" ]] || { echo "A's cut-short marker was not consumed by A's turn"; return 1; }
    # And the shared names are never used.
    for f in .mmry-foundation-inflight .mmry-foundation-cutshort .mmry-foundation-byref-told .mmry-foundation-empty-told; do
        [[ ! -e "$TEST_TMPDIR/$f" ]] || { echo "the shared marker $f was written"; return 1; }
    done
}

# The empty-set notice is said once a session, and the marker that records it was the bare
# .mmry-foundation-empty-told with no session id, written by SessionStart (even with an id) and read
# by the per-prompt hook: one Foundation working file for every id-less session on the machine. It is
# the account's own now, and SessionStart writes no shared one.
@test "startup: the empty-set told marker made with NO session id is each account's own, and SessionStart never writes the shared one" {
    local out ea eb
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; ea="$(fnd_empty_told_file)"
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY";  eb="$(fnd_empty_told_file)"
    unset MMRY_API_URL MMRY_API_KEY
    [[ "$ea" != "$eb" ]] || { echo "one told marker name for two accounts: ${ea##*/}"; return 1; }
    out="$(_claude_start_nosid_empty "$PROD_URL" "$PROD_KEY")"
    [[ "$(_umsg "$out")" == *"no Foundation directives"* ]] || { echo "control: A's user was not told the set is empty: ${out:0:300}"; return 1; }
    [[ -f "$ea" ]] || { echo "A's told marker is not at ${ea##*/}; files: $(ls -a "$TEST_TMPDIR" | grep told | tr '\n' ' ')"; return 1; }
    out="$(_claude_start_nosid_empty "$INT_URL" "$INT_KEY")"
    [[ "$(_umsg "$out")" == *"no Foundation directives"* ]] || { echo "control: B's user was not told the set is empty"; return 1; }
    [[ -f "$eb" && -f "$ea" ]] || { echo "B's start did not leave B's marker, or took A's"; return 1; }
    # Told once: neither account's prompt says it again, each reading its own marker.
    out="$(_claude_prompt_nosid "$PROD_URL" "$PROD_KEY")"
    [[ "$(_umsg "$out")" != *"no Foundation directives"* ]] || { echo "A's user was told twice"; return 1; }
    out="$(_claude_prompt_nosid "$INT_URL" "$INT_KEY")"
    [[ "$(_umsg "$out")" != *"no Foundation directives"* ]] || { echo "B's user was told twice"; return 1; }
    [[ ! -e "$TEST_TMPDIR/.mmry-foundation-empty-told" ]] || { echo "the shared marker .mmry-foundation-empty-told was written"; return 1; }
    # With a session id the marker is the account's own as well (#33363: a real id can be shared by
    # two accounts), under the keyed name the hook reads, and still no shared one.
    _claude_start claude-empty-01 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE" >/dev/null
    printf '{"session_id":"claude-empty-02","hook_event_name":"SessionStart","cwd":"/w"}' \
        | env MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE='[{"id":2,"topic":"Note","content":"an ordinary memory","memoryTier":"Experience","scope":"global","category":"Fact"}]' \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" >/dev/null 2>&1
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; ea="$(fnd_empty_told_file claude-empty-02)"; unset MMRY_API_URL MMRY_API_KEY
    [[ "${ea##*/}" == .mmry-foundation-empty-told.*.claude-empty-02 ]] || { echo "the id-form name is not keyed: ${ea##*/}"; return 1; }
    [[ -f "$ea" ]] || { echo "the id-named told marker was not written at ${ea##*/}: $(ls -a "$TEST_TMPDIR" | grep told | tr '\n' ' ')"; return 1; }
    [[ ! -e "$TEST_TMPDIR/.mmry-foundation-empty-told.claude-empty-02" ]] || { echo "the bare id-named told marker was written"; return 1; }
    [[ ! -e "$TEST_TMPDIR/.mmry-foundation-empty-told" ]] || { echo "the shared marker .mmry-foundation-empty-told was written by a start WITH an id"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 3, requirement 3. A session that cannot identify its account and server delivers nothing:
# no API key, an authentication method that is not an API key, or an empty server address. A shared
# file standing at the old name is not read and not named, and the positive control proves the same
# harness sees a delivery when the identity is whole.
# ---------------------------------------------------------------------------------------------
_plant_shared() {
    printf '# MMRY AI - Loaded Memories\n\nPLANTED-SHARED-MEMORY: a directive left at the machine-wide name.\n---\n' > "$TEST_TMPDIR/mmry-memories.md"
    _PLANTED="$(_file "$TEST_TMPDIR/mmry-memories.md")"
}
_cfg() {  # _cfg <file> <url> <auth> <key>
    printf '{\n  "apiUrl": "%s",\n  "authMethod": "%s",\n  "apiKey": "%s"\n}\n' "$2" "$3" "$4" > "$1"
}
# Requests for the account's memories: the startup set, and since #33480 the Foundation memories of a
# moment (/api/memories/foundation?moment=...), which SessionStart and the daily refresh now ask for
# the per-prompt set. Counting /startup alone stopped seeing the refresh worker's fetch, so a
# fail-closed check that counted only it could no longer fail. With no log at all counting as none:
# grep -c on a missing file prints nothing, not 0.
_memory_fetches() { grep -cE 'api/memories/(startup|foundation)' "$TEST_TMPDIR/curl-log.txt" 2>/dev/null || true; }

# Nothing delivered: no instruction to read, no file with this account's memories, the planted file
# untouched, and the Foundation set not stored either.
_assert_nothing_delivered() {
    local out="$1" what="$2" ctx
    ctx="$(_ctx "$out")"
    [[ "$ctx" != *"Read them now"* ]] || { echo "$what: the session was told to read a file: ${ctx:0:300}"; return 1; }
    [[ "$ctx" != *"PLANTED-SHARED-MEMORY"* && "$out" != *"PLANTED-SHARED-MEMORY"* ]] || { echo "$what: the planted file's content was injected"; return 1; }
    [[ "$(_memories_files)" == "mmry-memories.md" ]] || { echo "$what: a memories file was written: $(_memories_files | tr '\n' ' ')"; return 1; }
    [[ "$(_file "$TEST_TMPDIR/mmry-memories.md")" == "$_PLANTED" ]] || { echo "$what: the planted shared file was rewritten"; return 1; }
    ! ls "$TEST_TMPDIR"/mmry-foundation-set.*.md >/dev/null 2>&1 || { echo "$what: a Foundation set was stored: $(ls "$TEST_TMPDIR"/mmry-foundation-set.*.md)"; return 1; }
    # No request for them was even made. Counted, with no log at all counting as none: grep -c on a
    # missing file prints nothing, not 0.
    local fetched; fetched="$(_memory_fetches)"
    [[ "${fetched:-0}" == "0" ]] || { echo "$what: memories were fetched ($fetched requests for the startup set or a Foundation moment)"; return 1; }
    [[ -n "$ctx" ]] || { echo "$what: the session was told nothing at all"; return 1; }
}
# THE PROMPTS AFTER A REFUSED START (QA round 1, probe3). SessionStart refused and stored nothing; the
# per-prompt hook's refresh worker, with the daily refresh on, then fetched from the default server,
# stored the set, and the second prompt delivered it. Two prompts, the refresh on, the service ready
# to answer: nothing delivered on either, no request made, no set stored. The worker runs detached,
# so each prompt is given time to do its worst before the files are checked.
#   _assert_prompts_deliver_nothing <sid> <config-file> <what>
_assert_prompts_deliver_nothing() {
    local sid="$1" cfg="$2" what="$3" out ctx i fetched
    for i in 1 2; do
        out="$(_claude_prompt_cfg "$sid" "$cfg" 60)"; ctx="$(_ctx "$out")"
        [[ "$ctx" != *"$PROD_DIRECTIVE"* && "$ctx" != *"FOUNDATION memories"* ]] || { echo "$what: prompt $i delivered directives: ${ctx:0:300}"; return 1; }
        sleep 6
        ! ls "$TEST_TMPDIR"/mmry-foundation-set.*.md >/dev/null 2>&1 || { echo "$what: a Foundation set was stored by prompt $i: $(ls "$TEST_TMPDIR"/mmry-foundation-set.*.md)"; return 1; }
        fetched="$(_memory_fetches)"
        [[ "${fetched:-0}" == "0" ]] || { echo "$what: prompt $i fetched memories ($fetched requests for the startup set or a Foundation moment)"; return 1; }
    done
    [[ "$(_memories_files)" == "mmry-memories.md" ]] || { echo "$what: a memories file was written by a prompt: $(_memories_files | tr '\n' ' ')"; return 1; }
}

@test "startup: positive control - with a whole identity the same harness sees the delivery, so the fail-closed checks below can see one too" {
    local out p
    _plant_shared
    _cfg "$TEST_TMPDIR/cfg-whole.json" "$PROD_URL" apikey "$PROD_KEY"
    out="$(_claude_start_cfg claude-control-01 "$TEST_TMPDIR/cfg-whole.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    p="$(_told_path "$out")" || { echo "control: no delivery: ${out:0:300}"; return 1; }
    [[ "$(_file "$p")" == *"$PROD_DIRECTIVE"* ]] || { echo "control: the file lacks the directive"; return 1; }
    [[ "$p" != "$TEST_TMPDIR/mmry-memories.md" ]] || { echo "control: the session was told to read the shared file"; return 1; }
    [[ "$(_file "$TEST_TMPDIR/mmry-memories.md")" == "$_PLANTED" ]] || { echo "control: the planted shared file was rewritten"; return 1; }
}

@test "startup: fail closed - with NO API key nothing is delivered and the shared file is not read" {
    local out
    _plant_shared
    _cfg "$TEST_TMPDIR/cfg-nokey.json" "$PROD_URL" apikey ""
    out="$(_claude_start_cfg claude-nokey-01 "$TEST_TMPDIR/cfg-nokey.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    _assert_nothing_delivered "$out" "no key"
}

@test "startup: fail closed - with an authentication method that is not an API key (oauth) nothing is delivered and the shared file is not read" {
    local out
    _plant_shared
    _cfg "$TEST_TMPDIR/cfg-oauth.json" "$PROD_URL" oauth "an-oauth-access-token-0000000000000000001"
    out="$(_claude_start_cfg claude-oauth-01 "$TEST_TMPDIR/cfg-oauth.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    _assert_nothing_delivered "$out" "oauth"
    _assert_prompts_deliver_nothing claude-oauth-01 "$TEST_TMPDIR/cfg-oauth.json" "oauth"
}

@test "startup: fail closed - with an EMPTY server address nothing is delivered and the shared file is not read" {
    local out
    _plant_shared
    _cfg "$TEST_TMPDIR/cfg-nourl.json" "" apikey "$PROD_KEY"
    out="$(_claude_start_cfg claude-nourl-01 "$TEST_TMPDIR/cfg-nourl.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    _assert_nothing_delivered "$out" "empty server address"
    _assert_prompts_deliver_nothing claude-nourl-01 "$TEST_TMPDIR/cfg-nourl.json" "empty server address"
    # And the same with the address absent from the config altogether: the case QA's probe3 ran.
    printf '{\n  "authMethod": "apikey",\n  "apiKey": "%s"\n}\n' "$PROD_KEY" > "$TEST_TMPDIR/cfg-absenturl.json"
    out="$(_claude_start_cfg claude-nourl-02 "$TEST_TMPDIR/cfg-absenturl.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    _assert_nothing_delivered "$out" "absent server address"
    _assert_prompts_deliver_nothing claude-nourl-02 "$TEST_TMPDIR/cfg-absenturl.json" "absent server address"
}

# A set ALREADY STANDING at the name an unidentified session computes (an older plugin's refresh left
# it, or something planted it) is not served either. The per-prompt hook's prepared path reads the set
# file straight from disk, without the worker, so the gate has to hold there too, and the test above
# cannot see it: it never has a set on disk. The control proves the same planted set IS delivered
# once the server is named, so the refusal is the gate and not the harness.
@test "startup: fail closed - a Foundation set left at the name an unidentified session would compute is not delivered by a prompt, and is once the server is named" {
    local out ctx acct set body
    _plant_shared
    body="$TEST_TMPDIR/staged-unidentified.md"
    printf -- '- %s\n' "$PROD_DIRECTIVE" > "$body"
    printf '{\n  "authMethod": "apikey",\n  "apiKey": "%s"\n}\n' "$PROD_KEY" > "$TEST_TMPDIR/cfg-absenturl2.json"
    acct="$(FND_CONFIG_OVERRIDE="$TEST_TMPDIR/cfg-absenturl2.json" fnd_acct)"
    set="$TEST_TMPDIR/mmry-foundation-set.${acct}.md"
    fnd_seal "$body" 1 "$set" "$acct"
    out="$(_claude_prompt_cfg claude-nourl-03 "$TEST_TMPDIR/cfg-absenturl2.json" 0)"; ctx="$(_ctx "$out")"
    [[ "$ctx" != *"$PROD_DIRECTIVE"* && "$ctx" != *"FOUNDATION memories"* ]] || { echo "a set at the unidentified name was delivered: ${ctx:0:300}"; return 1; }
    [[ -z "$ctx" ]] || { echo "the prompt said something for an unidentified session: ${ctx:0:300}"; return 1; }
    [[ "$(_file "$TEST_TMPDIR/mmry-memories.md")" == "$_PLANTED" ]] || { echo "the planted shared file was rewritten"; return 1; }
    # Control: the same set, sealed for the identity that names the server, is delivered by the same harness.
    _cfg "$TEST_TMPDIR/cfg-whole2.json" "$PROD_URL" apikey "$PROD_KEY"
    acct="$(FND_CONFIG_OVERRIDE="$TEST_TMPDIR/cfg-whole2.json" fnd_acct)"
    set="$TEST_TMPDIR/mmry-foundation-set.${acct}.md"
    fnd_seal "$body" 1 "$set" "$acct"
    out="$(_claude_prompt_cfg claude-whole-03 "$TEST_TMPDIR/cfg-whole2.json" 0)"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* ]] || { echo "control: the set was not delivered once the server was named: ${ctx:0:300}"; return 1; }
}

# THE WORKER'S OWN GATE, SEEN DIRECTLY (#32915, QA round 1, requirement 3). Through a prompt the
# supervisor refuses an unidentified session before it defines, let alone starts, any worker, so the
# two-prompt tests above cannot tell a worker with its gate from one without it: the worker-gate-off
# mutation survived them (r2 scoring, 2026-11-03). Here the refresh-only worker is started exactly as
# the supervisor's _mmry_fnd_refresh_check starts it, with the refresh due, a key, no server address,
# and a service that would answer with a directive: it must fetch nothing and store nothing. The
# control starts the same worker with the server named and sees the fetch and the stored set, so the
# refusal is the gate and not the harness.
#   _refresh_worker <config-file>
_refresh_worker() {
    env MMRY_CONFIG_FILE="$1" MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_FOUNDATION_REFRESH_SECONDS=60 \
        MMRY_FOUNDATION_WORKER=1 MMRY_FND_REFRESH_ONLY=1 MOCK_CURL_RESPONSE="$(_startup_body "$PROD_DIRECTIVE" "$PROD_NOTE")" \
        bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 </dev/null >/dev/null 2>&1 || true
    # The fetch the worker starts is detached from it; give it the time the two-prompt tests give.
    sleep 6
}
@test "startup: fail closed - the refresh-only worker, started as the supervisor starts it for a session with no server address, fetches nothing and stores nothing" {
    local fetched
    _cfg "$TEST_TMPDIR/cfg-nourl-w.json" "" apikey "$PROD_KEY"
    _refresh_worker "$TEST_TMPDIR/cfg-nourl-w.json"
    ! ls "$TEST_TMPDIR"/mmry-foundation-set.*.md >/dev/null 2>&1 || { echo "the worker stored a Foundation set for an unidentified session: $(ls "$TEST_TMPDIR"/mmry-foundation-set.*.md)"; return 1; }
    fetched="$(_memory_fetches)"
    [[ "${fetched:-0}" == "0" ]] || { echo "the worker fetched memories for an unidentified session ($fetched requests for the startup set or a Foundation moment)"; return 1; }
    # Control: the same worker, the server named, fetches and stores.
    _cfg "$TEST_TMPDIR/cfg-whole-w.json" "$PROD_URL" apikey "$PROD_KEY"
    _refresh_worker "$TEST_TMPDIR/cfg-whole-w.json"
    ls "$TEST_TMPDIR"/mmry-foundation-set.*.md >/dev/null 2>&1 || { echo "control: the worker stored no set once the server was named"; return 1; }
    fetched="$(_memory_fetches)"
    [[ "${fetched:-0}" != "0" ]] || { echo "control: the worker fetched nothing once the server was named"; return 1; }
}

# THE AUTH-METHOD HALF OF THE GATE (#32915, QA round 2, F-C). SessionStart refuses a credential that is
# not an API key. The set's name hashes the server address and the credential STRING, whatever the
# method, so an API-key session stores a set at the very name an OAuth session with that string
# computes, and the supervisor's gate asked only whether the server was given: the OAuth session was
# told nothing was loaded and its prompts then served that set from disk (QA probe4). The supervisor
# now asks the auth method too, from the environment or a scan of the config, with no process.
@test "startup: fail closed - a set an API-key session stored is not served to an OAuth session on the same server and credential string: SessionStart refuses it and prompts deliver nothing, while the API-key session's own prompt delivers" {
    local out ctx i fetched
    _plant_shared
    _cfg "$TEST_TMPDIR/cfg-apikey5.json" "$PROD_URL" apikey "$PROD_KEY"
    _cfg "$TEST_TMPDIR/cfg-oauth5.json"  "$PROD_URL" oauth  "$PROD_KEY"
    [[ "$(FND_CONFIG_OVERRIDE="$TEST_TMPDIR/cfg-apikey5.json" fnd_acct)" == "$(FND_CONFIG_OVERRIDE="$TEST_TMPDIR/cfg-oauth5.json" fnd_acct)" ]] \
        || { echo "the two configs do not compute one key, so the test proves nothing"; return 1; }
    # The API-key session stores its set, and its own prompt delivers it (the control).
    out="$(_claude_start_cfg claude-apikey-05 "$TEST_TMPDIR/cfg-apikey5.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    _told_path "$out" >/dev/null || { echo "control: the API-key session loaded nothing: ${out:0:300}"; return 1; }
    ls "$TEST_TMPDIR"/mmry-foundation-set.*.md >/dev/null 2>&1 || { echo "control: the API-key session stored no set"; return 1; }
    out="$(_claude_prompt_cfg claude-apikey-05 "$TEST_TMPDIR/cfg-apikey5.json" 0)"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* ]] || { echo "control: the API-key session's prompt delivered nothing: ${ctx:0:300}"; return 1; }
    # Every request so far is the API-key session's own (its start asks the startup set and, since
    # #33480, the every-message set). The OAuth session below must add none.
    local before; before="$(_memory_fetches)"
    # The OAuth session on the same server and credential string: refused at SessionStart, and
    # nothing on any prompt or part after it, with the refresh on and the service ready to answer.
    out="$(_claude_start_cfg claude-oauth-05 "$TEST_TMPDIR/cfg-oauth5.json" "$PROD_DIRECTIVE" "$PROD_NOTE")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"did not load memories"* && "$ctx" != *"Read them now"* ]] || { echo "the OAuth session was not refused at SessionStart: ${ctx:0:300}"; return 1; }
    for i in 1 2; do
        out="$(_claude_prompt_cfg claude-oauth-05 "$TEST_TMPDIR/cfg-oauth5.json" 60)"; ctx="$(_ctx "$out")"
        [[ "$ctx" != *"$PROD_DIRECTIVE"* && "$ctx" != *"FOUNDATION memories"* ]] || { echo "prompt $i served the API-key session's set to the OAuth session: ${ctx:0:300}"; return 1; }
        [[ -z "$ctx" ]] || { echo "prompt $i said something for the refused session: ${ctx:0:300}"; return 1; }
    done
    out="$(_claude_prompt_cfg claude-oauth-05 "$TEST_TMPDIR/cfg-oauth5.json" 60 2)"; ctx="$(_ctx "$out")"
    [[ -z "$ctx" ]] || { echo "part 2 said something for the refused session: ${ctx:0:300}"; return 1; }
    # The only request for startup memories was the API-key session's own start.
    fetched="$(grep -c 'api/memories/startup' "$TEST_TMPDIR/curl-log.txt" 2>/dev/null || true)"
    [[ "${fetched:-0}" == "1" ]] || { echo "startup memories were fetched $fetched times; the API-key start's one was expected"; return 1; }
    fetched="$(_memory_fetches)"
    [[ "${fetched:-0}" == "${before:-0}" ]] || { echo "the OAuth session fetched memories: $before requests before it, $fetched after"; return 1; }
    [[ "$(_file "$TEST_TMPDIR/mmry-memories.md")" == "$_PLANTED" ]] || { echo "the planted shared file was rewritten"; return 1; }
}

# THE WORKER'S OWN AUTH-METHOD CLAUSE, SEEN DIRECTLY. Through a prompt the supervisor refuses an OAuth
# session before any worker is started, so the test above cannot tell a worker with the clause from
# one without it (QA round 2's qa-worker-auth-dropped mutant survived the two-prompt oauth test for
# this reason). Here the delivery worker is started as the supervisor starts it, with the OAuth
# config and a set standing at its key: it must hand back nothing. The control starts the same worker
# with the API-key config and sees the set, so the refusal is the clause and not the harness.
#   _delivery_worker <config-file> <sid>
_delivery_worker() {
    env MMRY_CONFIG_FILE="$1" MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_FOUNDATION_REFRESH_SECONDS=0 \
        MMRY_FOUNDATION_WORKER=1 MMRY_FND_SID="$2" MMRY_FOUNDATION_PENDING="$TEST_TMPDIR/mmry-foundation.status.pending.test" \
        bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 </dev/null 2>/dev/null
}
@test "startup: fail closed - the delivery worker, started as the supervisor starts it for an OAuth session with a set standing at its key, hands back nothing, and hands the set to the API-key session" {
    local out body acct set
    body="$TEST_TMPDIR/staged-oauth.md"
    printf -- '- %s\n' "$PROD_DIRECTIVE" > "$body"
    _cfg "$TEST_TMPDIR/cfg-oauth6.json"  "$PROD_URL" oauth  "$PROD_KEY"
    _cfg "$TEST_TMPDIR/cfg-apikey6.json" "$PROD_URL" apikey "$PROD_KEY"
    acct="$(FND_CONFIG_OVERRIDE="$TEST_TMPDIR/cfg-oauth6.json" fnd_acct)"
    set="$TEST_TMPDIR/mmry-foundation-set.${acct}.md"
    fnd_seal "$body" 1 "$set" "$acct"
    out="$(_delivery_worker "$TEST_TMPDIR/cfg-oauth6.json" claude-oauth-06)"
    [[ "$out" != *"$PROD_DIRECTIVE"* ]] || { echo "the worker handed the set to an OAuth session: ${out:0:300}"; return 1; }
    [[ "$out" == "@@MMRY-NONE 1 0@@" ]] || { echo "the worker did not say it has nothing for the OAuth session: ${out:0:200}"; return 1; }
    out="$(_delivery_worker "$TEST_TMPDIR/cfg-apikey6.json" claude-apikey-06)"
    [[ "$out" == *"$PROD_DIRECTIVE"* ]] || { echo "control: the worker handed nothing to the API-key session: ${out:0:300}"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 4, requirement 4. A machine-wide, unkeyed mmry-memories.md left by an older plugin is
# never read, never named to the model, and never injected. It is left alone unless nothing has
# touched it for a week, when SessionStart's sweep takes it with the other week-old leftovers.
# ---------------------------------------------------------------------------------------------
@test "startup: a planted legacy unkeyed mmry-memories.md is never read, never named and never injected - the session gets its own file" {
    local out p f
    _plant_shared
    out="$(_claude_start claude-legacy-01 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    p="$(_told_path "$out")" || { echo "no delivery: ${out:0:300}"; return 1; }
    [[ "$p" != "$TEST_TMPDIR/mmry-memories.md" ]] || { echo "the session was told to read the legacy file"; return 1; }
    f="$(_file "$p")"
    [[ "$f" == *"$PROD_DIRECTIVE"* && "$f" != *"PLANTED-SHARED-MEMORY"* ]] || { echo "the file is not the session's own: ${f:0:300}"; return 1; }
    [[ "$out" != *"PLANTED-SHARED-MEMORY"* ]] || { echo "the legacy content reached the model"; return 1; }
    # Left alone: an older plugin in another session may still be using it.
    [[ -f "$TEST_TMPDIR/mmry-memories.md" && "$(_file "$TEST_TMPDIR/mmry-memories.md")" == "$_PLANTED" ]] || { echo "the legacy file was removed or rewritten on sight"; return 1; }
}

@test "startup: the legacy file and week-old keyed files are swept by SessionStart only once they are a week old" {
    _plant_shared
    printf 'old keyed file\n' > "$TEST_TMPDIR/mmry-memories.0123456789abcdef.old-session.md"
    touch -t 202001010000 "$TEST_TMPDIR/mmry-memories.md" "$TEST_TMPDIR/mmry-memories.0123456789abcdef.old-session.md"
    local out p
    out="$(_claude_start claude-sweep-01 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    p="$(_told_path "$out")" || { echo "no delivery: ${out:0:300}"; return 1; }
    [[ ! -e "$TEST_TMPDIR/mmry-memories.md" ]] || { echo "the week-old legacy file was kept"; return 1; }
    [[ ! -e "$TEST_TMPDIR/mmry-memories.0123456789abcdef.old-session.md" ]] || { echo "a week-old keyed file was kept"; return 1; }
    [[ -f "$p" ]] || { echo "this session's own file, just written, is missing"; return 1; }
}
