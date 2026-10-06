#!/usr/bin/env bats
# formation-check identity (#31245 QA round 8).
#
# A SEPARATE FILE ON PURPOSE. These belong beside the formation-state identity tests in
# formation-delivery.bats, and they were written there first. That pushed the file past 64 KiB, and
# on Windows Git Bash bats then hangs while gathering tests, with no CPU and no output, for every
# test in the file: byte-identical content hangs at 65544 bytes and runs at 65526.
# structural/test-file-size.bats now refuses any test file over that size.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    VALID_TRANSMISSION='[{"senderRole":"lead","senderSessionID":"other-session","content":"Heads up: I am touching FormationService.cs","sentDate":"2026-08-30T12:00:00"}]'
}

# A curl that records every call and answers with whatever the test asks for. Same shim as
# formation-delivery.bats, so the network is observed rather than inferred from timing.
_recording_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/curl-recorder"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'RECCURL'
#!/usr/bin/env bash
printf 'called\n' >> "${MMRY_TEST_CURL_LOG:?curl recorder needs MMRY_TEST_CURL_LOG}"
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
RECCURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# ---------------------------------------------------------------------------------------------
# #31245 QA round 8: the same identity, pinned in formation-check.sh itself
# ---------------------------------------------------------------------------------------------
#
# The two tests above exercise formation-state.sh only. Reverting the fix in formation-check.sh,
# its "session_id=${session_id:-$(mmry_session_id)}" line, survived a full structural and handlers
# run, so the headline of the confidentiality fix was unpinned. These run the delivery hook.
#
# The observable is the network. A session that resolves to its OWN id finds no formation state and
# makes no call; a session that adopts the inherited id finds the other session's state and polls as
# it. The payload is "{}", a readable hook payload with no session_id, which is the case the
# fallback exists for: with an id in the payload the env chain is never consulted at all.

_identity_codex_home() {
    local home="${BATS_TEST_TMPDIR}/codex-home"
    mkdir -p "$home"
    printf '{"apiUrl":"http://fake.invalid","authMethod":"apikey","apiKey":"fake-key"}' > "${home}/mmry-config.json"
    printf '%s' "$home"
}

@test "identity: formation-check on Codex polls as its own id, not an inherited Claude one" {
    local codex_sid="qa8-fc-codex-own-$$"
    local claude_sid="qa8-fc-inherited-claude-$$"
    local log="${BATS_TEST_TMPDIR}/curl-calls.log"
    local bin; bin="$(_recording_curl_dir)"
    local chome; chome="$(_identity_codex_home)"

    # The inherited Claude id is in a formation; the Codex session's own id is not.
    bash "${HANDLERS}/formation-state.sh" clear "$codex_sid" || true
    env -u MMRY_HOST -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$claude_sid" \
        bash "${HANDLERS}/formation-state.sh" set 4242
    [[ -f "${TMPDIR}/.mmry-formation-${claude_sid}" ]] || { echo "fixture: no state for the Claude id"; return 1; }

    : > "$log"
    run bash -c 'printf "{}" | env PATH="$1:$PATH" MMRY_TEST_CURL_LOG="$2" FAKE_CODE=200 FAKE_BODY="$3" \
        MMRY_HOST=codex CODEX_HOME="$4" CODEX_SESSION_ID="$5" CLAUDE_SESSION_ID="$6" CLAUDE_CODE_SESSION_ID="$6" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "$7/formation-check.sh"' _ "$bin" "$log" "$VALID_TRANSMISSION" "$chome" "$codex_sid" "$claude_sid" "$HANDLERS"
    bash "${HANDLERS}/formation-state.sh" clear "$claude_sid" || true
    [ "$status" -eq 0 ]
    [ ! -s "$log" ] || {
        echo "the Codex session polled as the INHERITED Claude id: it found that session's formation"
        echo "and reached the network $(wc -l < "$log") time(s), so it could consume its directed messages"
        return 1
    }
}

@test "identity: control, formation-check on Codex does poll when its own id is in a formation" {
    # Without this the test above is satisfied by a hook that never polls on Codex at all.
    local codex_sid="qa8-fc-codex-member-$$"
    local claude_sid="qa8-fc-other-claude-$$"
    local log="${BATS_TEST_TMPDIR}/curl-calls.log"
    local bin; bin="$(_recording_curl_dir)"
    local chome; chome="$(_identity_codex_home)"

    bash "${HANDLERS}/formation-state.sh" clear "$claude_sid" || true
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID MMRY_HOST=codex CODEX_HOME="$chome" CODEX_SESSION_ID="$codex_sid" \
        bash "${HANDLERS}/formation-state.sh" set 4242
    [[ -f "${TMPDIR}/.mmry-formation-${codex_sid}" ]] || { echo "fixture: no state for the Codex id"; return 1; }

    : > "$log"
    run bash -c 'printf "{}" | env PATH="$1:$PATH" MMRY_TEST_CURL_LOG="$2" FAKE_CODE=200 FAKE_BODY="$3" \
        MMRY_HOST=codex CODEX_HOME="$4" CODEX_SESSION_ID="$5" CLAUDE_SESSION_ID="$6" CLAUDE_CODE_SESSION_ID="$6" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "$7/formation-check.sh"' _ "$bin" "$log" "$VALID_TRANSMISSION" "$chome" "$codex_sid" "$claude_sid" "$HANDLERS"
    bash "${HANDLERS}/formation-state.sh" clear "$codex_sid" || true
    [ "$status" -eq 0 ]
    [ -s "$log" ] || { echo "a Codex session in a formation under its own id never polled"; return 1; }
}

@test "identity: formation-check on Claude Code is not displaced by a stray Codex id" {
    # The mirror image, so the fix cannot be "always prefer Codex".
    local claude_sid="qa8-fc-claude-own-$$"
    local codex_sid="qa8-fc-stray-codex-$$"
    local log="${BATS_TEST_TMPDIR}/curl-calls.log"
    local bin; bin="$(_recording_curl_dir)"

    bash "${HANDLERS}/formation-state.sh" clear "$codex_sid" || true
    env -u MMRY_HOST -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$claude_sid" \
        bash "${HANDLERS}/formation-state.sh" set 4242

    : > "$log"
    run bash -c 'printf "{}" | env -u MMRY_HOST -u CLAUDE_SESSION_ID PATH="$1:$PATH" MMRY_TEST_CURL_LOG="$2" FAKE_CODE=200 FAKE_BODY="$3" \
        CLAUDE_CODE_SESSION_ID="$4" CODEX_SESSION_ID="$5" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash "$6/formation-check.sh"' _ "$bin" "$log" "$VALID_TRANSMISSION" "$claude_sid" "$codex_sid" "$HANDLERS"
    bash "${HANDLERS}/formation-state.sh" clear "$claude_sid" || true
    # Exit 2 with the transmission on stderr is how Claude Code delivers on a tool event, so the
    # delivery itself is the assertion, not exit 0.
    [ -s "$log" ] || { echo "a stray CODEX_SESSION_ID displaced the Claude Code identity"; return 1; }
    [[ "$output" == *"formation 4242"* ]] || { echo "polled but did not deliver: exit $status: $output"; return 1; }
}
