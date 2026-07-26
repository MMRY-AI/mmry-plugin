#!/usr/bin/env bats
# userpromptsubmit-foundation.bats — UserPromptSubmit Foundation re-injection handler (#30579).
# The handler inlines the session-local Foundation cache on every prompt, framed as
# authoritative. It must NEVER block a prompt: any problem -> emit nothing, exit 0.

load '../helpers/test-helper'

setup() {
    HANDLER="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
}

@test "userpromptsubmit-foundation: reinjects cached Foundation memories inline with authoritative framing" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]]
    [[ "$output" == *'"additionalContext"'* ]]
    [[ "$output" == *'FOUNDATION'* ]]
    [[ "$output" == *'authoritative'* ]]
    [[ "$output" == *'clarity over cleverness'* ]]
}

@test "userpromptsubmit-foundation: emits valid JSON" {
    printf -- '- Foundation fact.\n' > "$CACHE"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # Validate with jq if present, else python3 — the emitted context must parse.
    if command -v jq >/dev/null; then
        echo "$output" | jq . >/dev/null
    else
        echo "$output" | python3 -c 'import sys,json; json.load(sys.stdin)'
    fi
}

@test "userpromptsubmit-foundation: refresh disabled (0) creates no refresh lock" {
    printf -- '- Foundation fact.\n' > "$CACHE"
    export MMRY_FOUNDATION_REFRESH_SECONDS=0
    export MMRY_API_KEY="test-key"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-refresh" ]
}

@test "userpromptsubmit-foundation: a stale cache triggers a gated background refresh (lock created)" {
    printf -- '- Foundation fact.\n' > "$CACHE"
    touch -t 202001010000 "$CACHE"   # force the cache to look stale
    export MMRY_FOUNDATION_REFRESH_SECONDS=1
    export MMRY_API_KEY="test-key"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    # The lock is touched synchronously before the background fetch is spawned.
    [ -f "$TEST_TMPDIR/.mmry-foundation-refresh" ]
    # Still emitted the current (pre-refresh) cache this turn — non-blocking.
    [[ "$output" == *'Foundation fact'* ]]
}

@test "userpromptsubmit-foundation: toggle off emits nothing and exits 0" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    export MMRY_FOUNDATION_REINJECT=false
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: missing cache emits nothing and never blocks (exit 0)" {
    rm -f "$CACHE"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: empty cache emits nothing and exits 0" {
    : > "$CACHE"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: token cap truncates an oversized set and logs the drop" {
    head -c 4000 /dev/zero | tr '\0' 'x' > "$CACHE"
    export MMRY_FOUNDATION_TOKEN_CAP=100
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'truncated'* ]]
    [ -f "$TEST_TMPDIR/mmry-foundation.log" ]
}
