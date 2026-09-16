#!/usr/bin/env bats
# codex-formation-delivery.bats — requirement 2 on Codex (#31245): a coordination-group message
# reaches the session as the customer works, without the customer asking.
#
# The mechanism is the same handler as on Claude Code; the delivery ROUTE differs, and getting that
# wrong is silent in both directions. A hook that returns additionalContext into a runtime that
# ignores it looks healthy and delivers nothing. A hook that exits 2 into a runtime that treats it
# as a block cancels the customer's tool call every time a colleague speaks.
#
# The Codex routes asserted here come from Codex's own generated schemas and event handlers:
#   post-tool-use.command.output.schema.json  PostToolUseHookSpecificOutputWire.additionalContext
#   session-start.command.output.schema.json  SessionStartHookSpecificOutputWire.additionalContext
#   stop.command.output.schema.json           no hookSpecificOutput at all
#   codex-rs/hooks/src/events/stop.rs L343    exit 2 + stderr becomes the continuation prompt
#
# EVERY ASSERTION HERE WAS SEEN TO REFUSE. See codex-mutation-log.md.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-codexform-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    VALID_TRANSMISSION='[{"senderRole":"lead","senderSessionID":"other-session","content":"Heads up: I am touching FormationService.cs","sentDate":"2026-08-30T12:00:00"}]'
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# ---------------------------------------------------------------------------------------------
# The control. Without it every "Codex delivered X" below proves nothing, because a typo in the
# shim, a missing key or a guard firing three steps earlier would produce the same output shape.
# ---------------------------------------------------------------------------------------------

@test "control: on Claude Code a tool-call message is still stderr with exit 2, unchanged" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=tool \
        run env -u MMRY_HOST bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"FormationService.cs"* ]]
    [[ "$output" != *"hookSpecificOutput"* ]]
}

# ---------------------------------------------------------------------------------------------
# Codex: PostToolUse
# ---------------------------------------------------------------------------------------------

@test "req2 codex: a tool-call message arrives as PostToolUse additionalContext" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=tool MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    run_ev="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
    [ "$run_ev" = "PostToolUse" ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("FormationService.cs")' >/dev/null
}

@test "req2 codex: the tool-call route exits 0, so a colleague's message never cancels a tool call" {
    # This is the reason for choosing additionalContext over exit 2 on Codex. Exit 2 works here
    # too - events/post_tool_use.rs turns stderr into Feedback - but it also sets should_block.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=tool MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -ne 2 ]
}

@test "req2 codex: the emitted JSON is well formed, so the message is not lost to an escaping bug" {
    # The block contains quotes and newlines. Hand-rolled escaping in a shell script eventually
    # always breaks on one of them, and a malformed payload is discarded with no error.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    local body='[{"senderRole":"lead","senderSessionID":"s2","content":"quote \" and newline\nand backslash \\ all at once","sentDate":"2026-08-30T12:00:00"}]'

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=tool MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | type == "string"' >/dev/null
}

@test "req2 codex: nothing pending means silence, on the new route as on the old one" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=tool MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "req2 codex: a session in no formation pays nothing and says nothing" {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=tool MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------------------------
# Codex: SessionStart and UserPromptSubmit keep the additionalContext route they already had
# ---------------------------------------------------------------------------------------------

@test "req2 codex: the session-start sweep still delivers as SessionStart additionalContext" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=start MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    # Parsed rather than string-matched: the handler pretty-prints on this route, so a literal
    # {"hookEventName":"SessionStart"} never appears even when the output is exactly right. A test
    # that matched the literal would fail for a formatting reason and be "fixed" by loosening it.
    run_ev="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
    [ "$run_ev" = "SessionStart" ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("FormationService.cs")' >/dev/null
}

@test "req2 codex: the prompt sweep still delivers as UserPromptSubmit additionalContext" {
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=prompt MMRY_HOST=codex \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 0 ]
    run_ev="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')"
    [ "$run_ev" = "UserPromptSubmit" ]
}

# ---------------------------------------------------------------------------------------------
# Codex: the idle poller must not run, and must not be silent about a message already waiting
# ---------------------------------------------------------------------------------------------

@test "codex: an idle registration does ONE pass and returns, it does not poll for minutes" {
    # A synchronous four-minute poller would hold the end of every turn open. The budget here is
    # 60 seconds of poll time on Claude Code; on Codex the handler must be back long before that.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    local started ended
    started="$(date +%s)"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_HOST=codex \
        MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5 \
        run bash "${HANDLERS}/formation-check.sh"
    ended="$(date +%s)"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Generous, because this runs on a loaded CI box; the point is "did not wait out the budget".
    [ "$(( ended - started ))" -lt 20 ]
}

@test "codex: a message ALREADY waiting at Stop is still delivered, on stderr with exit 2" {
    # Stop has no hookSpecificOutput on Codex, so this is the only route, and losing it would mean
    # a message that arrived during the turn is never mentioned.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$VALID_TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle MMRY_HOST=codex \
        MMRY_IDLE_POLL_SECONDS=60 MMRY_IDLE_POLL_INTERVAL=5 \
        run bash "${HANDLERS}/formation-check.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"FormationService.cs"* ]]
    [[ "$output" != *"hookSpecificOutput"* ]]
}

@test "control: on Claude Code the idle poller DOES wait, which is what makes the Codex test mean something" {
    # Without this the Codex timing assertion above is satisfied by any handler that returns fast
    # for any reason. This asserts the same inputs on the other host take materially longer.
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"

    local started ended
    started="$(date +%s)"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='[]' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=idle \
        MMRY_IDLE_POLL_SECONDS=6 MMRY_IDLE_POLL_INTERVAL=2 \
        run env -u MMRY_HOST bash "${HANDLERS}/formation-check.sh"
    ended="$(date +%s)"

    [ "$status" -eq 0 ]
    [ "$(( ended - started ))" -ge 2 ]
}
