#!/usr/bin/env bats
# foundation-status.bats - /mmry:foundation-status (#31583 requirement 4).
#
# The command exists so a customer can ASK whether their standing directives are reaching
# their assistants, rather than finding out hours later that they were not. It shipped on
# this branch with no tests of its own, so nothing held it to the one property that makes
# it worth having: its answer must agree with what the re-injection handler actually does.
# A status command that reports health while the handler refuses the cache is worse than
# no status command, because it is the thing a customer would check first.

load '../helpers/test-helper'

setup() {
    STATUS_CMD="$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    HANDLER="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
}

manifest_now() {
    local c="${1:-$CACHE}" n="${2:-}" s b
    read -r s b < <(cksum < "$c")
    if [[ -z "$n" ]]; then
        n="$(grep -c '^- ' "$c" 2>/dev/null || true)"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
    fi
    printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s\n' "$n" "$b" "$s" > "${c}.manifest"
}

@test "foundation-status: a verified cache is reported as verified, with the count and size" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'VERIFIED'* ]]
    [[ "$output" == *'2 directives'* ]]
    [[ "$output" == *'Re-injection: ON'* ]]
}

@test "foundation-status: a damaged cache is reported as refused, not as healthy" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    manifest_now
    local n
    n="$(wc -c < "$CACHE")"
    head -c "$n" /dev/zero | tr '\0' 'z' > "$CACHE"

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'DAMAGED'* ]]
    [[ "$output" == *'REFUSED'* ]]
    run grep -c 'VERIFIED' <<<"$output"
    [ "$output" = "0" ]
}

@test "foundation-status: a cache with no manifest is reported as unverifiable" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    rm -f "${CACHE}.manifest"

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'UNVERIFIABLE'* ]]
}

@test "foundation-status: an account with genuinely no Foundation memories is told nothing is withheld" {
    : > "$CACHE"
    printf 'mmry-foundation v1 entries=0 bytes=0 cksum=4294967295\n' > "${CACHE}.manifest"

    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'VALID and EMPTY'* ]]
}

@test "foundation-status: #31583 it never reports health for a cache the handler is refusing" {
    # The property that makes this command worth having. The two read the same manifest by
    # different paths, so they can drift; this pins them together on the case that drift
    # actually produced - a manifest claiming the set is empty beside a cache full of
    # directives. The handler refuses that. The status command must not call it fine.
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    printf 'mmry-foundation v1 entries=0 bytes=%s cksum=%s\n' "$b" "$s" > "${CACHE}.manifest"

    # What the handler does with it, measured here rather than assumed.
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'could not verify'* ]]

    # What the customer is told when they ask.
    run bash "$STATUS_CMD"
    [ "$status" -eq 0 ]
    run grep -c 'Nothing is being withheld' <<<"$output"
    [ "$output" = "0" ]
}
