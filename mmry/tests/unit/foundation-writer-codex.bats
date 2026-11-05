#!/usr/bin/env bats
# foundation-writer-codex.bats - the Codex path of mmry_write_foundation_cache writes the same bytes
# (#33062 fix round 7).
#
# On Codex the writer runs inside the session start, before the memories are handed over, and on
# Windows its twenty-odd processes cost 3 to 5 s of Codex's limit. So on Codex it takes a shorter
# road: one jq for the entry count, the response's length and the set, the set read back with the
# read builtin, and the temp file reused (no cat, no second jq, no rm). The Foundation set is what
# every later prompt is checked against, so the shorter road is only acceptable if it writes the
# same file. This proves it does, byte for byte, against the road Claude Code still takes, for the
# responses most likely to tell them apart: a NUL, carriage returns, non-ASCII, backslashes, an empty
# set, no Foundation entries, a large set, and a response jq cannot use.

load '../helpers/test-helper'
load '../helpers/foundation-set'

setup() {
    export MMRY_API_KEY="test-key"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    mkdir -p "$TEST_TMPDIR/classic" "$TEST_TMPDIR/codex"
    A="$(mmry_foundation_set_path "$TEST_TMPDIR/classic")"
    B="$(mmry_foundation_set_path "$TEST_TMPDIR/codex")"
}

# _both RESPONSE [SID] - write RESPONSE with the classic road into A and the Codex road into B.
# Sets RC_A and RC_B.
_both() {
    local sid="${2:-sess-1}"
    _MMRY_HOST_V="claude"; RC_A=0
    mmry_write_foundation_cache "$1" "$A" "$sid" || RC_A=$?
    _MMRY_HOST_V="codex"; RC_B=0
    mmry_write_foundation_cache "$1" "$B" "$sid" || RC_B=$?
    _MMRY_HOST_V="claude"
}

_same_files() {
    [ "$RC_A" = "$RC_B" ] || { echo "classic returned $RC_A, Codex returned $RC_B"; return 1; }
    cmp "$A" "$B" || { echo "the set files differ"; od -c "$A" | head -5; od -c "$B" | head -5; return 1; }
    cmp "$TEST_TMPDIR/classic/mmry-foundation.stored.${1:-sess-1}" "$TEST_TMPDIR/codex/mmry-foundation.stored.${1:-sess-1}" \
        || { echo "the stored markers differ"; return 1; }
}

@test "codex writer: two Foundation memories and one of another tier, the same bytes" {
    _both '[{"memoryTier":"Foundation","topic":"Identity","content":"Eric builds MMRY."},{"memoryTier":"Strategic","topic":"Ignored","content":"x"},{"memoryTier":"Foundation","topic":"Value","content":"Clarity."}]'
    [ "$RC_B" = "0" ]
    _same_files
    [[ "$(fnd_set_record "$B")" == 'mmry-foundation v3 entries=2 '* ]]
}

@test "codex writer: a NUL, carriage returns, newlines, backslashes and non-ASCII inside memories, the same bytes" {
    _both '[{"memoryTier":"Foundation","topic":"Nul","content":"a\u0000b"},{"memoryTier":"Foundation","topic":"Crlf","content":"one\r\ntwo\rthree\n\nfour"},{"memoryTier":"Foundation","topic":"Esc","content":"back\\slash \"quoted\" tab\there"},{"memoryTier":"Foundation","topic":"Uni","content":"café — 日本 😀"}]'
    [ "$RC_B" = "0" ]
    _same_files
}

@test "codex writer: a memory whose content ends in newlines and one that starts with a dash, the same bytes" {
    _both '[{"memoryTier":"Foundation","topic":"T","content":"ends\n\n\n"},{"memoryTier":"Foundation","topic":"- dash","content":"- not a new entry"}]'
    [ "$RC_B" = "0" ]
    _same_files
}

@test "codex writer: no Foundation memories at all is the same valid empty set" {
    _both '[{"memoryTier":"Strategic","topic":"x","content":"y"}]'
    [ "$RC_B" = "0" ]
    _same_files
    [[ "$(fnd_set_record "$B")" == 'mmry-foundation v3 entries=0 bytes=0 '* ]]
}

@test "codex writer: an empty response is the same valid empty set" {
    _both '[]'
    [ "$RC_B" = "0" ]
    _same_files
}

@test "codex writer: a large set (300 memories) is the same bytes" {
    local resp
    resp="$(jq -cn '[range(300) | {memoryTier:"Foundation", topic:("T" + tostring), content:("content " * 40 + tostring)}]')"
    _both "$resp"
    [ "$RC_B" = "0" ]
    _same_files
}

@test "codex writer: a response jq cannot use fails the same way and leaves the existing set and no temp file" {
    _both '[{"memoryTier":"Foundation","topic":"Keep","content":"kept"}]'
    cp "$A" "$TEST_TMPDIR/a.before"; cp "$B" "$TEST_TMPDIR/b.before"
    _both 'this is not json'
    [ "$RC_A" != "0" ] && [ "$RC_B" != "0" ]
    cmp "$A" "$TEST_TMPDIR/a.before"
    cmp "$B" "$TEST_TMPDIR/b.before"
    run ls -a "$TEST_TMPDIR/codex"
    [[ "$output" != *".new."* && "$output" != *".body."* ]] || { echo "a temp file was left: $output"; return 1; }
}

@test "codex writer: with no valid session id the stored marker is named as the shared function names it" {
    printf 'tok-9' > "$(mmry_foundation_session_path "$TEST_TMPDIR/classic")"
    printf 'tok-9' > "$(mmry_foundation_session_path "$TEST_TMPDIR/codex")"
    _both '[{"memoryTier":"Foundation","topic":"T","content":"c"}]' 'bad.id'
    [ "$RC_B" = "0" ]
    _same_files tok-9
}

# The token "unknown" is what SessionStart leaves for a session with no id, and it passes the plain-id
# regex the quick path keys on. The shared function puts the account key in front of it (#32915), so
# the quick path must too, or two Codex accounts with no session id share one bare marker (QA round 2, F-A).
@test "codex writer: with the token unknown (a session with no id) the stored marker carries the account key, as the shared function names it, and the bare mmry-foundation.stored.unknown is never written" {
    local part
    part="$(fnd_session_part unknown)"
    [[ "$part" == *.unknown && "$part" != unknown ]] || { echo "the session part for the token is $part"; return 1; }
    _both '[{"memoryTier":"Foundation","topic":"T","content":"c"}]' 'unknown'
    [ "$RC_B" = "0" ]
    _same_files "$part"
    [ ! -e "$TEST_TMPDIR/codex/mmry-foundation.stored.unknown" ] || { echo "the Codex road wrote the bare shared marker"; return 1; }
    [ ! -e "$TEST_TMPDIR/classic/mmry-foundation.stored.unknown" ] || { echo "the classic road wrote the bare shared marker"; return 1; }
}

@test "codex writer: reports the response's own length, as jq length counts it" {
    local resp='[{"memoryTier":"Foundation","topic":"a","content":"b"},{"memoryTier":"Fact","topic":"c","content":"d"},{"memoryTier":"Strategic","topic":"e","content":"f"}]'
    _MMRY_HOST_V="codex"
    mmry_write_foundation_cache "$resp" "$B" "sess-1"
    _MMRY_HOST_V="claude"
    [ "$MMRY_FND_RESPONSE_LENGTH" = "$(printf '%s' "$resp" | jq length | tr -d '\r')" ]
    [ "$MMRY_FND_RESPONSE_LENGTH" = "3" ]
}

@test "codex jq choice: the probe that chooses jq records whether it writes carriage returns, and the writer uses it" {
    unset MMRY_JQ _MMRY_JQ_VERIFIED _MMRY_JQ_CR_FOR _MMRY_JQ_CR
    _MMRY_HOST_V="codex"
    _mmry_jq_codex_probe
    [ -n "$MMRY_JQ" ]
    [ "$_MMRY_JQ_CR_FOR" = "$MMRY_JQ" ]
    local real; real="$(printf '%s' '"x\ny"' | "$MMRY_JQ" -j .)"
    if [[ "$real" == *$'\r'* ]]; then [ "$_MMRY_JQ_CR" = "1" ]; else [ "$_MMRY_JQ_CR" = "0" ]; fi
    _MMRY_HOST_V="claude"
    _both '[{"memoryTier":"Foundation","topic":"Crlf","content":"one\ntwo"}]'
    _same_files
}

@test "codex jq choice: a jq that does not answer the probe is not chosen by it" {
    printf '#!/bin/sh\nexit 3\n' > "$TEST_TMPDIR/badjq"; chmod +x "$TEST_TMPDIR/badjq"
    MMRY_JQ="$TEST_TMPDIR/badjq"; unset _MMRY_JQ_VERIFIED _MMRY_JQ_CR_FOR
    run _mmry_jq_codex_probe
    [ "$status" -ne 0 ]
}
