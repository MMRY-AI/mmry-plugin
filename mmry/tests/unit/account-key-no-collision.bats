#!/usr/bin/env bats
# account-key-no-collision.bats - two different server-and-sign-in pairs never give one account key,
# and every valid pair keeps the key it has today (#33620).
#
# THE DEFECT, finding S3 (security reviewer, replacement) of the independent QA of #33363, 2026-11-09.
# Since #32889 the account key is hashed over "<url>\n<key>". A line break inside either part moves
# the boundary: ("https://a.test", "x\ny") and ("https://a.test\nx", "y") are two different pairs that
# hash the same bytes. Using it needs control of the person's own settings, so the risk is low, but the
# separation #32915 and #33363 rely on (every Foundation file and the Codex hand-off are named by this
# key) should not depend on it.
#
# THE RULE: a server address or a sign-in that holds a control character (bytes 0x00 to 0x1F, or 0x7F)
# is refused before the key is made. A refused identity has NO key and is not "known", so every
# handler that asks (SessionStart, the per-prompt hook, PreCompact, the Codex hand-off) delivers nothing
# and writes nothing, the path #32915 built. No valid pair holds a control character (setup writes the
# key the service issued, hex, and a plain URL), so no existing account's key changes: the two fixed
# keys below were computed from develop c19e378 before this change and must never move.

load '../helpers/test-helper'

# The library in a fresh bash, so each case starts with no cached key.
#   _key <url> <sign-in>   -> prints the key, exits with the library's verdict (0 key, 1 refused)
_key() {
    MMRY_API_URL="$1" MMRY_API_KEY="$2" MMRY_AUTH_METHOD=apikey MMRY_CONFIG_FILE="" \
        bash -c 'source "$1/hooks-handlers/lib-foundation-key.sh"; mmry_foundation_account_key_v; rc=$?; printf "%s" "$_MMRY_FND_ACCT"; exit $rc' _ "$PLUGIN_ROOT"
}
_known() {
    MMRY_API_URL="$1" MMRY_API_KEY="$2" MMRY_AUTH_METHOD=apikey MMRY_CONFIG_FILE="" \
        bash -c 'source "$1/hooks-handlers/lib-foundation-key.sh"; mmry_foundation_identity_known_v' _ "$PLUGIN_ROOT"
}

@test "#33620: the key for a normal pair is unchanged from today's value (fixed expected key)" {
    run _key "https://mmryai.com" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    assert_success
    assert_output "a8ed9c829400d263"
    run _key "https://mmryai.com" "abc"
    assert_success
    assert_output "9976976648e449e4"
    # Two spellings of one server are one key, as before.
    run _key "https://MMRYAI.com/" "abc"
    assert_success
    assert_output "9976976648e449e4"
}

@test "#33620: the two pairs of the 33363 probe (a line break moving the boundary) never give one key: both are refused" {
    local a b
    # Pair A: address "https://a.test", sign-in "x<LF>y". Pair B: address "https://a.test<LF>x", sign-in "y".
    # Joined with a line break, both are the bytes "https://a.test<LF>x<LF>y".
    run _key "https://a.test" $'x\ny'
    a="$status:$output"
    run _key $'https://a.test\nx' "y"
    b="$status:$output"
    [[ "$a" == "1:" ]] || { echo "pair A was not refused: status:key = $a"; return 1; }
    [[ "$b" == "1:" ]] || { echo "pair B was not refused: status:key = $b"; return 1; }
}

@test "#33620: a pair with a line break in the sign-in is refused, and the identity is not known" {
    run _key "https://mmryai.com" $'abc\ndef'
    assert_failure
    assert_output ""
    run _known "https://mmryai.com" $'abc\ndef'
    assert_failure
}

@test "#33620: a pair with a line break in the server address is refused, and the identity is not known" {
    run _key $'https://mmryai.com\n' "abc"
    assert_failure
    assert_output ""
    run _known $'https://mmryai.com\n' "abc"
    assert_failure
}

@test "#33620: every other control character is refused too (tab, carriage return, NUL-adjacent 0x01, DEL)" {
    local c
    for c in $'\t' $'\r' $'\x01' $'\x7f'; do
        run _key "https://mmryai.com" "ab${c}c"
        [[ "$status" == 1 && -z "$output" ]] || { echo "a sign-in holding byte $(printf '%02x' "'$c") was not refused: $status:$output"; return 1; }
        run _key "https://mmryai${c}.com" "abc"
        [[ "$status" == 1 && -z "$output" ]] || { echo "an address holding byte $(printf '%02x' "'$c") was not refused: $status:$output"; return 1; }
    done
}

@test "#33620 control: a sign-in or address with no control character is never refused, printable punctuation and a multibyte character included" {
    run _key "https://mmryai.com" 'a!b"c#d$e%f&g'"'"'h(i)j*k+l,m-n.o/p:q;r<s=t>u?v@w[x\y]z^_`{|}~'
    assert_success
    [[ "$output" =~ ^[0-9a-f]{16}$ ]] || { echo "no key for a printable sign-in: $output"; return 1; }
    run _key "https://mmryai.com" "abcé"
    assert_success
    [[ "$output" =~ ^[0-9a-f]{16}$ ]] || { echo "no key for a multibyte sign-in: $output"; return 1; }
    run _known "https://mmryai.com" "abcé"
    assert_success
}

@test "#33620: a refused identity from the config file (a line break scanned between the quotes) has no key and is not known" {
    # The scan takes the bytes between the quotes after "apiKey"; a hand-edited file can put a line
    # break there. The environment names nothing, so the file decides.
    printf '{\n  "apiUrl": "https://mmryai.com",\n  "authMethod": "apikey",\n  "apiKey": "abc\ndef"\n}\n' > "$TEST_TMPDIR/cfg.json"
    run env MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_CONFIG_FILE="$TEST_TMPDIR/cfg.json" \
        bash -c 'source "$1/hooks-handlers/lib-foundation-key.sh"; mmry_foundation_account_key_v; rc=$?; printf "%s" "$_MMRY_FND_ACCT"; exit $rc' _ "$PLUGIN_ROOT"
    assert_failure
    assert_output ""
    run env MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_CONFIG_FILE="$TEST_TMPDIR/cfg.json" \
        bash -c 'source "$1/hooks-handlers/lib-foundation-key.sh"; mmry_foundation_identity_known_v' _ "$PLUGIN_ROOT"
    assert_failure
}

@test "#33620: the Codex early helper arms nothing for a refused identity (no session part, no key)" {
    printf '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"abc\ndef"}' > "$TEST_TMPDIR/cfg.json"
    run env MMRY_API_URL="" MMRY_API_KEY="" MMRY_AUTH_METHOD="" MMRY_CONFIG_FILE="$TEST_TMPDIR/cfg.json" \
        bash -c 'source "$1/hooks-handlers/lib-codex-key.sh"; mmry_codex_session_part_v sid-1; rc=$?; printf "%s|%s" "$_MMRY_CODEX_SESSION_PART" "$_MMRY_CODEX_KEY"; exit $rc' _ "$PLUGIN_ROOT"
    assert_failure
    assert_output "|"
}

@test "#33620: the name functions never build a name from an empty key (a refused identity names no file)" {
    run env MMRY_API_URL="https://mmryai.com" MMRY_API_KEY=$'abc\ndef' MMRY_AUTH_METHOD=apikey MMRY_CONFIG_FILE="" \
        bash -c 'source "$1/hooks-handlers/lib-foundation-key.sh"; mmry_foundation_set_name_v /d; mmry_foundation_session_part_v s1; mmry_foundation_memories_name_v /d s1; printf "%s|%s|%s" "$_MMRY_FND_SET_NAME" "$_MMRY_FND_SESSION_PART" "$_MMRY_FND_MEMORIES_NAME"' _ "$PLUGIN_ROOT"
    assert_success
    assert_output "||"
}
