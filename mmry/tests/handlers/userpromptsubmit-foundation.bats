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

# ============================================================================
# #31434 — the hook budget, the self-imposed deadline, and telling the customer.
#
# These tests drive the failure deliberately by making the handler SLOW, using the
# MMRY_JQ seam that lib-jq.sh already honours. No production test seam was added: a
# slow jq is exactly what a loaded machine produces. The shim answers --version
# instantly (the resolver probes it) and sleeps only on a real parse.
#
# Note the config file: with no config, mmry_load_config never invokes jq at all and
# the shim would never fire — a delay test that silently delays nothing is precisely
# the kind of check that cannot fail.
# ============================================================================

_make_slow_jq() {
    # $1 = seconds to sleep on a real parse
    local shim="$TEST_TMPDIR/slow-jq.sh"
    cat > "$shim" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "--version" ]] && exec jq "\$@"; done
sleep $1
exec jq "\$@"
EOF
    chmod +x "$shim"
    printf '%s' "$shim"
}

_make_config() {
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationReinjectTokenCap": 1500,
  "foundationRefreshSeconds": 0
}
EOF
}

_registered_timeout() {
    # The SHIPPED budget for this hook, read from the repo's hooks.json — not from an
    # installed cache and not from a hand-edited copy.
    jq -r '.hooks.UserPromptSubmit[].hooks[]
           | select(.command | test("userpromptsubmit-foundation")) | .timeout' \
        "$PLUGIN_ROOT/hooks/hooks.json"
}

@test "userpromptsubmit-foundation: slowed past the OLD 5s budget, still delivers the directives inside the shipped one" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    _make_config
    local shim budget start elapsed
    shim="$(_make_slow_jq 7)"
    budget="$(_registered_timeout)"
    # The premise of the test: 7s must be past the old budget and inside the new one.
    (( 7 > 5 ))
    (( 7 < budget ))

    start="$(date +%s)"
    MMRY_JQ="$shim" run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # Asserted on the INJECTED CONTENT, not on the absence of a warning.
    [[ "$output" == *'never overstate evidence'* ]]
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]]
    # It really was slow — otherwise this test proves nothing about the budget.
    (( elapsed >= 6 ))
    # And it still finished inside the budget the plugin actually ships.
    (( elapsed < budget ))
}

@test "userpromptsubmit-foundation: slowed past the DEADLINE, the turn proceeds and the customer is told" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    _make_config
    local shim start elapsed budget
    shim="$(_make_slow_jq 20)"
    budget="$(_registered_timeout)"

    start="$(date +%s)"
    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    # Did not hang: stopped itself at its own deadline, well inside the hook budget.
    [ "$status" -eq 0 ]
    (( elapsed >= 3 ))
    (( elapsed < 12 ))
    (( elapsed < budget ))
    # The user is told, in terms they can act on.
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'NOT applied to this turn'* ]]
    [[ "$output" == *'/mmry:reload-memories'* ]]
    # The model is told too, so it cannot claim to be following directives it never got.
    [[ "$output" == *'running WITHOUT the account'* ]]
    # And it is still one valid JSON object.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    # It must NOT pretend to have delivered the Foundation set.
    [[ "$output" != *'never overstate evidence'* ]]
}

@test "userpromptsubmit-foundation: a firing cut short by the harness is reported on the NEXT firing" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    # The marker the supervisor leaves behind when it never reaches its own exit.
    : > "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'PREVIOUS turn'* ]]
    [[ "$output" == *'previous turn'* ]]          # the user-facing half
    # The miss is reported AND this turn's directives are still delivered.
    [[ "$output" == *'never overstate evidence'* ]]
    # The marker is consumed, so the report is not repeated forever.
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
}

@test "userpromptsubmit-foundation: a clean firing reports nothing and leaves no marker" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
    # No notice of any kind on a healthy turn — a nag on every prompt would be its own bug.
    [[ "$output" != *'systemMessage'* ]]
    [[ "$output" != *'PREVIOUS turn'* ]]
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
}

@test "userpromptsubmit-foundation: no false alarm when there were no directives to lose" {
    # Marker present, but nothing to inject. Reporting a loss here would be a lie.
    rm -f "$CACHE"
    : > "$TEST_TMPDIR/.mmry-foundation-inflight"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: an absurd deadline value falls back to the default rather than disabling the guard" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    MMRY_FOUNDATION_DEADLINE_SECS="not-a-number" run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
}
