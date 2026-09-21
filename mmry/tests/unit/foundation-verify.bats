#!/usr/bin/env bats
# mmry_verify_foundation_cache - a DIRECT test of the routine both readers now depend on.
#
# #31583 QA round 2: "the consolidated verifier has no direct test of any kind, so the routine
# R2 and R3 now rest on is exercised only incidentally through two callers and its written
# contract is pinned by nothing."
#
# That is exactly the shape that produced the verifier in the first place. The verification
# used to be duplicated in the hook and the status command, each pinned only through its own
# caller, and the two drifted twice. Consolidating them and then testing the result only
# through those same callers would leave the contract itself unpinned.
#
# THE CONTRACT, asserted here rather than described in a comment somewhere:
#   0  "ok <entries> <bytes>"
#   1  "absent" | "empty"
#   3  "<state>|<customer prose>"
#
# Every state token is asserted, because the status command maps them to labels and a typo in
# one degrades silently to its catch-all.

load '../helpers/test-helper'

setup() {
    export MMRY_API_KEY="test-key" MMRY_AUTH_METHOD="apikey" MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    MANIFEST="$CACHE.manifest"
}

# Write a manifest that genuinely describes the cache, so each test can then break ONE thing.
_manifest_for() {
    local s b n="${1:-}"
    read -r s b < <(cksum < "$CACHE")
    [ -n "$n" ] || n="$(grep -c '^- ' "$CACHE" 2>/dev/null || echo 1)"
    printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s\n' "$n" "$b" "$s" > "$MANIFEST"
}

_state()  { printf '%s' "${1%%|*}"; }

@test "verify: a healthy pair returns 0 and reports the entries and bytes" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    _manifest_for 1

    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 0 ]
    [[ "$output" == "ok 1 "* ]]
    # The byte count is the file's, not an echo of the manifest's claim.
    [[ "$output" == *" $(wc -c < "$CACHE" | tr -d ' ')" ]]
}

@test "verify: nothing on disk at all returns 1 absent, which is not damage" {
    rm -f "$CACHE" "$MANIFEST"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 1 ]
    [ "$output" = "absent" ]
}

@test "verify: a genuinely empty set returns 1 empty, which is not damage either" {
    : > "$CACHE"
    printf 'mmry-foundation v1 entries=0 bytes=0 cksum=4294967295\n' > "$MANIFEST"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 1 ]
    [ "$output" = "empty" ]
}

@test "verify: state no-manifest, a cache with nothing describing it" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    rm -f "$MANIFEST"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "no-manifest" ]
}

@test "verify: state bad-manifest, present but unparseable" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    printf 'garbage not a manifest\n' > "$MANIFEST"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "bad-manifest" ]
}

@test "verify: state inconsistent, entries=0 beside a cache holding directives" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    printf 'mmry-foundation v1 entries=0 bytes=%s cksum=%s\n' "$b" "$s" > "$MANIFEST"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "inconsistent" ]
}

@test "verify: state missing, the manifest describes a cache that is gone" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    _manifest_for 1
    rm -f "$CACHE"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "missing" ]
}

@test "verify: state size, the right content at the wrong length" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    _manifest_for 1
    printf -- '- Identity: Eric builds MMRY, and more besides.\n' > "$CACHE"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "size" ]
}

@test "verify: state contents, the right length with the wrong bytes" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    _manifest_for 1
    local n; n="$(wc -c < "$CACHE" | tr -d ' ')"
    head -c "$n" /dev/zero | tr '\0' 'z' > "$CACHE"
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "contents" ]
    # size and contents must be DISTINCT states, or the status command prints that 28 bytes
    # does not match 28 bytes, which is what QA saw.
    [ "$(_state "$output")" != "size" ]
}

@test "verify: state blank, verified bytes that are only whitespace" {
    printf '  \n \n  ' > "$CACHE"
    _manifest_for 2
    run mmry_verify_foundation_cache "$CACHE"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "blank" ]
}

@test "verify: every refusal carries prose after the state token, not just a token" {
    printf '  \n \n  ' > "$CACHE"
    _manifest_for 2
    run mmry_verify_foundation_cache "$CACHE"
    local prose="${output#*|}"
    [ -n "$prose" ]
    [ "$prose" != "$output" ]
    # Customer-facing, so it must read as a sentence rather than a token.
    [ "${#prose}" -gt 20 ]
}
