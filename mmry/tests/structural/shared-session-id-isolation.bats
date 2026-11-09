#!/usr/bin/env bats
# shared-session-id-isolation.bats - two accounts that use ONE real session id never share or overwrite
# each other's per-session Foundation files (#33363).
#
# THE DEFECT, found by the independent QA of #32915 (round 2, security scenario G, B-r2-8). #32915
# named each session's working files by its session id and put the account key in front only when
# there was no id ("unknown" or none). A real id was taken to be unique to its session. It is not: a
# session resumed under a second account, or an id passed in by hand, gives two accounts the same id,
# and they then shared the prepared copy, claim, result, stored marker, delivery record and outcome
# records. QA showed account B's prompt overwriting account A's prepared copy with 60 of B's lines,
# directive text included. What each account RECEIVED stayed its own, because delivery checks the
# copy against the account's own set, but the copy itself held one account's directives in a file
# the other account writes.
#
# Since #33363 the account key is part of EVERY session part (lib-foundation-key.sh,
# mmry_foundation_session_part_v): <key>.<sid>, <key>.unknown or <key>.none. One function names
# every per-session file, so a shared id can never name a shared file. The old bare-id names are
# never read again (DD-176) and go with the existing seven-day sweep.
#
# Every test drives the real entry points - session-start.sh, codex-hook.sh for Codex, the
# UserPromptSubmit hook, foundation-status.sh - with a mock curl standing in for the service. The only
# thing the two sessions share is the temp directory and the session id, which is exactly what they
# share on a real machine. The first test was run against develop adf91431 before the fix and failed
# there: A's prepared copy held B's directive after B's prompt (the red run is in the handback).

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_HOST CODEX_HOME || true
    mkdir -p "$HOME/.claude/mmry/hooks-handlers"
    # Two accounts on two servers. Keys are throwaway strings, never real credentials.
    PROD_URL="https://prod.example.test"   PROD_KEY="prod-account-key-000000000000000000000001"
    INT_URL="https://integration.example.test" INT_KEY="integration-account-key-00000000000002"
    PROD_DIRECTIVE="PRODUCTION-DIRECTIVE: keep every claim backed by something you ran."
    PROD_NOTE="PRODUCTION-NOTE: the production account prefers short sentences."
    INT_DIRECTIVE="INTEGRATION-DIRECTIVE: always answer in plain English."
    INT_NOTE="INTEGRATION-NOTE: the integration account is a throwaway."
    # The ONE id both accounts use: a resumed session's id, or one passed in by hand.
    SID="shared-session-id-0001"
}

_startup_body() {
    printf '[{"id":1,"topic":"Rule","content":"%s","memoryTier":"Foundation","scope":"global","category":"Fact"},{"id":2,"topic":"Note","content":"%s","memoryTier":"Experience","scope":"global","category":"Fact"}]' "$1" "$2"
}
# No Foundation memory at all: an empty set.
_empty_body() {
    printf '[{"id":2,"topic":"Note","content":"an ordinary memory","memoryTier":"Experience","scope":"global","category":"Fact"}]'
}

# A Claude Code SessionStart for the account given by its URL and key, with the session id.
#   _claude_start <sid> <url> <key> <directive> <note>
_claude_start() {
    local sid="$1" url="$2" key="$3"; shift 3
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$sid" \
        | env MMRY_API_URL="$url" MMRY_API_KEY="$key" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE="$(_startup_body "$@")" \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}
#   _claude_start_empty <sid> <url> <key>
_claude_start_empty() {
    printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"/w"}' "$1" \
        | env MMRY_API_URL="$2" MMRY_API_KEY="$3" MMRY_AUTH_METHOD=apikey \
              MOCK_CURL_RESPONSE="$(_empty_body)" \
              bash "$PLUGIN_ROOT/hooks-handlers/session-start.sh" 2>/dev/null
}
# A Claude Code prompt for that session: part 1 of the UserPromptSubmit hook, as hooks.json registers it.
#   _claude_prompt <sid> <url> <key>
_claude_prompt() {
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" \
        | env MMRY_API_URL="$2" MMRY_API_KEY="$3" MMRY_AUTH_METHOD=apikey MMRY_FOUNDATION_REFRESH_SECONDS=0 \
              bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 2>/dev/null
}
# The status command for that session under that account.
#   _claude_status <sid> <url> <key>
_claude_status() {
    env CLAUDE_CODE_SESSION_ID="$1" MMRY_API_URL="$2" MMRY_API_KEY="$3" MMRY_AUTH_METHOD=apikey \
        bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh" 2>/dev/null
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
#   _codex_prompt <codex-home> <sid>
_codex_prompt() {
    printf '{"session_id":"%s","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"hi"}' "$2" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$1" \
              bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" userpromptsubmit-foundation --part 1 2>/dev/null
}

_ctx() { jq -j '.hookSpecificOutput.additionalContext // ""' <<<"$1" | tr -d '\r'; }
_umsg() { jq -j '.systemMessage // ""' <<<"$1" | tr -d '\r'; }
_file() { local t; t="$(cat "$1"; printf x)"; printf '%s' "${t%x}"; }
_has() { grep -q -- "$2" "$1" 2>/dev/null; }
_count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# The per-session names for the current identity and $SID, into P (prepared), C (claim), R (result),
# M (stored), S (status) and O (outcome).
_names() {
    P="$(fnd_prepared_file "$SID")"; C="$(fnd_claim_file "$SID")"; R="$(fnd_result_file "$SID")"
    M="$(fnd_stored_file "$SID")";   S="$(fnd_status_file "$SID")"; O="$(fnd_outcome_file "$SID")"
}
# Every bare-id name the old plugin would have used for $SID: none may ever be written.
_bare_names() {
    printf '%s\n' ".mmry-foundation-prepared.$SID" ".mmry-foundation-claim.$SID" ".mmry-foundation-result.$SID" \
        "mmry-foundation.stored.$SID" "mmry-foundation.status.$SID" "mmry-foundation.outcome.$SID" \
        ".mmry-foundation-inflight.$SID" ".mmry-foundation-cutshort.$SID" ".mmry-foundation-empty-told.$SID" \
        ".mmry-foundation-byref-told.$SID"
}
_no_bare_written() {
    local f
    while IFS= read -r f; do
        [[ ! -e "$TEST_TMPDIR/$f" ]] || { echo "the bare-id name $f was written: $(ls -a "$TEST_TMPDIR" | grep foundation | tr '\n' ' ')"; return 1; }
    done < <(_bare_names)
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 1, requirement 1 (QA round 2 scenario G as the model). Two accounts, one real session id,
# one temp directory, each prompting in turn. Each prepared copy, claim, result, stored marker, status
# record and outcome record is its own and holds only its own directive.
# ---------------------------------------------------------------------------------------------
@test "shared id: two Claude Code accounts with the SAME real session id never share or overwrite each other's prepared copy, claim, result, stored, status or outcome file" {
    local out ctx pa ca ra ma sa oa pb cb rb mb sb ob
    _claude_start "$SID" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE" >/dev/null
    _claude_start "$SID" "$INT_URL"  "$INT_KEY"  "$INT_DIRECTIVE"  "$INT_NOTE"  >/dev/null
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; _names; pa=$P ca=$C ra=$R ma=$M sa=$S oa=$O
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY";  _names; pb=$P cb=$C rb=$R mb=$M sb=$S ob=$O
    unset MMRY_API_URL MMRY_API_KEY

    # Scenario G: A prompts, then B prompts, then A's prepared copy is read.
    out="$(_claude_prompt "$SID" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* ]] || { echo "control: A did not deliver: ${ctx:0:300}"; return 1; }
    [[ -f "$pa" ]] || { echo "no prepared copy for A at ${pa##*/}; files: $(ls -a "$TEST_TMPDIR" | grep foundation | tr '\n' ' ')"; return 1; }
    _has "$pa" "$PROD_DIRECTIVE" || { echo "A's prepared copy does not hold A's directive"; return 1; }
    out="$(_claude_prompt "$SID" "$INT_URL" "$INT_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* ]] || { echo "control: B did not deliver: ${ctx:0:300}"; return 1; }
    [[ "$ctx" != *"$PROD_DIRECTIVE"* ]] || { echo "B was served A's directive"; return 1; }
    [[ -f "$pb" ]] || { echo "no prepared copy for B at ${pb##*/}"; return 1; }
    _has "$pb" "$INT_DIRECTIVE" || { echo "B's prepared copy does not hold B's directive"; return 1; }
    # The overwrite QA saw: after B's prompt, A's prepared copy must still be A's and only A's.
    _has "$pa" "$PROD_DIRECTIVE" || { echo "A's prepared copy was overwritten by B's prompt (scenario G)"; return 1; }
    (( $(_count "$pa" "$INT_DIRECTIVE") == 0 )) || { echo "A's prepared copy holds B's directive"; return 1; }
    (( $(_count "$pb" "$PROD_DIRECTIVE") == 0 )) || { echo "B's prepared copy holds A's directive"; return 1; }

    # Every per-session file is two files, one per account.
    [[ "$pa" != "$pb" && "$ca" != "$cb" && "$ra" != "$rb" && "$ma" != "$mb" && "$sa" != "$sb" && "$oa" != "$ob" ]] \
        || { echo "one name for two accounts: ${pa##*/}"; return 1; }
    [[ -f "$ma" && -f "$mb" ]] || { echo "stored markers missing: $(ls -a "$TEST_TMPDIR" | grep stored | tr '\n' ' ')"; return 1; }
    [[ -f "$ra" && -f "$rb" ]] || { echo "result markers missing"; return 1; }
    [[ -f "$sa" && -f "$sb" ]] || { echo "delivery records missing: $(ls -a "$TEST_TMPDIR" | grep status | tr '\n' ' ')"; return 1; }
    [[ -f "$oa" && -f "$ob" ]] || { echo "outcome records missing: $(ls -a "$TEST_TMPDIR" | grep outcome | tr '\n' ' ')"; return 1; }
    # A prompts again: still its own set, served from its own copy, and B's copy is untouched.
    out="$(_claude_prompt "$SID" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* && "$ctx" != *"$INT_DIRECTIVE"* ]] || { echo "A's second prompt: ${ctx:0:300}"; return 1; }
    _has "$pb" "$INT_DIRECTIVE" || { echo "B's prepared copy was overwritten by A's second prompt"; return 1; }
    # The status command, the reader, reads each account's own record under the shared id.
    out="$(_claude_status "$SID" "$PROD_URL" "$PROD_KEY")"
    [[ "$out" == *"Delivered:    IN FULL"* ]] || { echo "A's status: $out"; return 1; }
    out="$(_claude_status "$SID" "$INT_URL" "$INT_KEY")"
    [[ "$out" == *"Delivered:    IN FULL"* ]] || { echo "B's status: $out"; return 1; }
    # And the bare-id names are never used.
    _no_bare_written
}

@test "shared id: two Codex accounts with the SAME real session id never share or overwrite each other's prepared copy or stored marker (J-016@codex)" {
    local ha hb out ctx pa ma sa pb mb sb
    ha="$(_codex_home a "$PROD_URL" "$PROD_KEY")"
    hb="$(_codex_home b "$INT_URL"  "$INT_KEY")"
    pa="$(FND_CONFIG_OVERRIDE="$ha/mmry-config.json" fnd_prepared_file "$SID")"
    ma="$(FND_CONFIG_OVERRIDE="$ha/mmry-config.json" fnd_stored_file "$SID")"
    sa="$(FND_CONFIG_OVERRIDE="$ha/mmry-config.json" fnd_status_file "$SID")"
    pb="$(FND_CONFIG_OVERRIDE="$hb/mmry-config.json" fnd_prepared_file "$SID")"
    mb="$(FND_CONFIG_OVERRIDE="$hb/mmry-config.json" fnd_stored_file "$SID")"
    sb="$(FND_CONFIG_OVERRIDE="$hb/mmry-config.json" fnd_status_file "$SID")"

    _codex_start "$ha" "$SID" "$PROD_DIRECTIVE" "$PROD_NOTE" >/dev/null
    _codex_start "$hb" "$SID" "$INT_DIRECTIVE"  "$INT_NOTE"  >/dev/null
    # The Codex writer's quick path names the stored marker itself: both must be keyed and distinct.
    [[ "$ma" != "$mb" ]] || { echo "one stored marker name for two accounts: ${ma##*/}"; return 1; }
    [[ -f "$ma" && -f "$mb" ]] || { echo "stored markers missing: $(ls -a "$TEST_TMPDIR" | grep stored | tr '\n' ' ')"; return 1; }
    [[ "$(_file "$ma")" == "1" && "$(_file "$mb")" == "1" ]] || { echo "markers do not hold each count: $(_file "$ma") $(_file "$mb")"; return 1; }

    out="$(_codex_prompt "$ha" "$SID")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* ]] || { echo "control: Codex A did not deliver: ${out:0:300}"; return 1; }
    [[ -f "$pa" ]] || { echo "no prepared copy for A at ${pa##*/}; files: $(ls -a "$TEST_TMPDIR" | grep foundation | tr '\n' ' ')"; return 1; }
    out="$(_codex_prompt "$hb" "$SID")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$INT_DIRECTIVE"* && "$ctx" != *"$PROD_DIRECTIVE"* ]] || { echo "control: Codex B did not deliver its own: ${out:0:300}"; return 1; }
    [[ -f "$pb" ]] || { echo "no prepared copy for B at ${pb##*/}"; return 1; }
    _has "$pa" "$PROD_DIRECTIVE" || { echo "A's prepared copy was overwritten by B's prompt"; return 1; }
    (( $(_count "$pa" "$INT_DIRECTIVE") == 0 )) || { echo "A's prepared copy holds B's directive"; return 1; }
    (( $(_count "$pb" "$PROD_DIRECTIVE") == 0 )) || { echo "B's prepared copy holds A's directive"; return 1; }
    [[ "$pa" != "$pb" && "$sa" != "$sb" ]] || { echo "one name for two accounts: ${pa##*/}"; return 1; }
    [[ -f "$sa" && -f "$sb" ]] || { echo "delivery records missing: $(ls -a "$TEST_TMPDIR" | grep status | tr '\n' ' ')"; return 1; }
    _no_bare_written
}

# The empty-set told marker in its session-id form is written by SessionStart and read by the hook.
# Both must spell the keyed name, or the customer is told twice (and, shared, told for the other
# account): session-start.sh wrote .mmry-foundation-empty-told.<sid> bare before #33363.
@test "shared id: the empty-set notice is told once per account under a shared real session id, each reading its own told marker" {
    local out ea eb
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; ea="$(fnd_empty_told_file "$SID")"
    export MMRY_API_URL="$INT_URL"  MMRY_API_KEY="$INT_KEY";  eb="$(fnd_empty_told_file "$SID")"
    unset MMRY_API_URL MMRY_API_KEY
    [[ "$ea" != "$eb" ]] || { echo "one told marker name for two accounts: ${ea##*/}"; return 1; }
    out="$(_claude_start_empty "$SID" "$PROD_URL" "$PROD_KEY")"
    [[ "$(_umsg "$out")" == *"no Foundation directives"* ]] || { echo "control: A's user was not told the set is empty: ${out:0:300}"; return 1; }
    [[ -f "$ea" ]] || { echo "A's told marker is not at ${ea##*/}; files: $(ls -a "$TEST_TMPDIR" | grep told | tr '\n' ' ')"; return 1; }
    [[ "$(_file "$ea")" == "$SID" ]] || { echo "A's told marker is not stamped with the session: $(_file "$ea")"; return 1; }
    # B, a set with a directive, on the same id: B's start writes no told marker and takes nothing from A's.
    _claude_start "$SID" "$INT_URL" "$INT_KEY" "$INT_DIRECTIVE" "$INT_NOTE" >/dev/null
    [[ ! -e "$eb" ]] || { echo "B's start wrote a told marker for a set that is not empty"; return 1; }
    [[ -f "$ea" ]] || { echo "B's start removed A's told marker"; return 1; }
    # Told once: A's prompt does not say it again, reading its own keyed marker.
    out="$(_claude_prompt "$SID" "$PROD_URL" "$PROD_KEY")"
    [[ "$(_umsg "$out")" != *"no Foundation directives"* ]] || { echo "A's user was told twice: the hook did not find the marker SessionStart wrote"; return 1; }
    [[ ! -e "$TEST_TMPDIR/.mmry-foundation-empty-told.$SID" ]] || { echo "the bare-id told marker was written"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# DD-176: the first prompt after an upgrade. A session that began under the previous plugin has its
# per-session files under the bare id. They are NEVER read again, not even once for the same account:
# the stamp inside them is the session id, which a second account shares, so nothing in a bare-id
# file proves whose it is. The session's set is the account-keyed set file, which is unchanged; the
# first prompt prepares a fresh copy from it under the keyed name, exactly as the first prompt of any
# session does, and the customer sees their own directives on that prompt. The bare-id files are left
# untouched for the seven-day sweep.
# ---------------------------------------------------------------------------------------------
@test "shared id (DD-176): on the first prompt after upgrade a running session's bare-id files are never read, its directives arrive from its own set, and the bare files are left for the sweep" {
    local out ctx bare_p bare_s bare_m
    _claude_start "$SID" "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE" >/dev/null
    # What the previous plugin left for this session: a prepared copy (here holding another account's
    # directive, as QA's scenario G produced), a delivery record and a stored marker, all bare.
    bare_p="$TEST_TMPDIR/.mmry-foundation-prepared.$SID"
    bare_s="$TEST_TMPDIR/mmry-foundation.status.$SID"
    bare_m="$TEST_TMPDIR/mmry-foundation.stored.$SID"
    printf 'mmry-fnd-prepared v1 1 1 1 1 6 9500 1 1\n%s\n' "$INT_DIRECTIVE" > "$bare_p"
    printf '%s %s ok entries=1 bytes=99\n' "$SID" "$(date +%s)" > "$bare_s"
    printf '%s' '7' > "$bare_m"
    local p0 s0 m0; p0="$(_file "$bare_p")" s0="$(_file "$bare_s")" m0="$(_file "$bare_m")"

    out="$(_claude_prompt "$SID" "$PROD_URL" "$PROD_KEY")"; ctx="$(_ctx "$out")"
    [[ "$ctx" == *"$PROD_DIRECTIVE"* ]] || { echo "the first prompt after upgrade did not deliver the session's own set: ${ctx:0:300}"; return 1; }
    [[ "$ctx" != *"$INT_DIRECTIVE"* ]] || { echo "the bare-id prepared copy was served"; return 1; }
    [[ -z "$(_umsg "$out")" ]] || { echo "the customer was shown something on the first prompt after upgrade: $(_umsg "$out")"; return 1; }
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"; _names; unset MMRY_API_URL MMRY_API_KEY
    [[ -f "$P" && -f "$S" ]] || { echo "the keyed prepared copy or record was not written: $(ls -a "$TEST_TMPDIR" | grep foundation | tr '\n' ' ')"; return 1; }
    _has "$P" "$PROD_DIRECTIVE" || { echo "the keyed prepared copy does not hold the session's directive"; return 1; }
    # The bare files are neither read into anything nor touched: left for the sweep.
    [[ "$(_file "$bare_p")" == "$p0" && "$(_file "$bare_s")" == "$s0" && "$(_file "$bare_m")" == "$m0" ]] \
        || { echo "a bare-id file was rewritten on the first prompt after upgrade"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# TEST CASE 2, requirement 2: the old bare-id names clear through the existing seven-day sweep.
# Every per-session pattern, eight days old, is gone after one SessionStart; the same names touched
# today are kept, because a file touched this week may belong to a running older plugin.
# ---------------------------------------------------------------------------------------------
_plant_old_names() {
    local f
    while IFS= read -r f; do
        printf 'old\n' > "$TEST_TMPDIR/$f"
        printf 'fresh\n' > "$TEST_TMPDIR/$f.fresh"
        touch -t 202001010000 "$TEST_TMPDIR/$f"
    done < <(_bare_names)
    # The outcome records of parts 2 to 6 and the per-part in-flight marker take a part suffix.
    printf 'old\n' > "$TEST_TMPDIR/mmry-foundation.outcome.$SID.3"; touch -t 202001010000 "$TEST_TMPDIR/mmry-foundation.outcome.$SID.3"
    printf 'old\n' > "$TEST_TMPDIR/.mmry-foundation-inflight.$SID.2"; touch -t 202001010000 "$TEST_TMPDIR/.mmry-foundation-inflight.$SID.2"
}
_old_names_swept() {
    local f
    while IFS= read -r f; do
        [[ ! -e "$TEST_TMPDIR/$f" ]] || { echo "the week-old bare-id file $f was kept"; return 1; }
        [[ -f "$TEST_TMPDIR/$f.fresh" ]] || { echo "the fresh file $f.fresh was swept"; return 1; }
    done < <(_bare_names)
    [[ ! -e "$TEST_TMPDIR/mmry-foundation.outcome.$SID.3" ]] || { echo "the week-old part-3 outcome record was kept"; return 1; }
    [[ ! -e "$TEST_TMPDIR/.mmry-foundation-inflight.$SID.2" ]] || { echo "the week-old part-2 in-flight marker was kept"; return 1; }
}

@test "sweep: bare-id per-session files from the previous plugin are swept by a Claude Code SessionStart once a week old, and files touched this week are kept" {
    _plant_old_names
    local out
    out="$(_claude_start sweep-new-01 "$PROD_URL" "$PROD_KEY" "$PROD_DIRECTIVE" "$PROD_NOTE")"
    [[ "$(_ctx "$out")" == *"Read them now: "* ]] || { echo "control: no delivery: ${out:0:300}"; return 1; }
    _old_names_swept
    # This session's own files, just written, stand.
    export MMRY_API_URL="$PROD_URL" MMRY_API_KEY="$PROD_KEY"
    [[ -f "$(fnd_stored_file sweep-new-01)" ]] || { echo "this session's own stored marker is missing"; return 1; }
}

@test "sweep: the same bare-id files are swept by a Codex SessionStart too (the sweep runs as the hook ends)" {
    _plant_old_names
    local h out
    h="$(_codex_home sweep "$PROD_URL" "$PROD_KEY")"
    out="$(_codex_start "$h" sweep-new-02 "$PROD_DIRECTIVE" "$PROD_NOTE")"
    [[ "$(_ctx "$out")" == *"Read them now: "* ]] || { echo "control: Codex loaded nothing: ${out:0:300}"; return 1; }
    _old_names_swept
}
