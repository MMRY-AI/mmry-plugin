#!/usr/bin/env bats
# A Claude Code Formation member is advised to run long work in the background (#34161).
#
# WHY THIS FILE EXISTS. In 1.32.3 a busy member did not read three messages from its lead for about
# an hour, because it was inside one long step and nothing can interrupt a step in progress. Running
# long work in the background lets the lead's messages arrive while it runs.
#
# WHAT IS PINNED, by the ticket's own test cases:
#   TC1  joining on Claude Code prints the sentence exactly once; joining on Codex does not.
#   TC2  a delivered ASSIGNMENT notice addressed to this Claude Code session is followed by the
#        sentence exactly once; another message does not get it; Codex does not get it.
#   TC3  the sentence is the approved text, byte for byte, and names no internal mechanism.
#
# THE NOTICE IS WRITTEN BY THE SERVICE (MMRY-AI/mmry, sql/lib/Migration097.ps1) and starts with the
# words pinned below. If the service renames it, the plugin stops recognising it: this file is where
# that fails, rather than silently.
#
# WORDING STATUS: PLACEHOLDER. cmo-mmry has not yet written the approved sentence
# (R:/Intranet/ClaudeAI/plans/MMRY/v1.38/wording-34161-cmo.md). Swap the literal below and the
# constant in lib-formation-prompts.sh together, byte for byte.

SENTENCE="PLACEHOLDER 34161 awaiting approved wording: run long commands and long delegated work in the background so your lead can reach you while it runs."
NOTICE_START="ASSIGNMENT. The formation lead has set what this session is working on."

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_CODE_SESSION_ID="bats-background-work-$$"
    export CLAUDE_SESSION_ID="$CLAUDE_CODE_SESSION_ID"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
    JOIN_BODY='{"formation":{"id":4242,"objective":"TEST DATA 34161 background work"},"members":[]}'
    NOTICE='[{"senderRole":null,"senderSessionID":null,"senderUserID":null,"recipientMemberID":12,"content":"'"${NOTICE_START}"' Work: ship it.","sentDate":"2026-11-23T12:00:00"}]'
    OTHER='[{"senderRole":"Wingman","senderSessionID":"other-session","senderUserID":3,"recipientMemberID":12,"content":"please look at the build","sentDate":"2026-11-23T12:00:00"}]'
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
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

_join() {
    local host="$1" bin; bin="$(_fake_curl_dir)"
    if [[ "$host" == "codex" ]]; then
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$JOIN_BODY" MMRY_HOST=codex \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-join.sh" 4242
    else
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$JOIN_BODY" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "${HANDLERS}/formation-join.sh" 4242
    fi
}

# Deliver a batch through formation-check.sh on the given host. Codex output is unwrapped from its
# PostToolUse JSON so the same checks read the text the model reads.
_deliver() {
    local host="$1" body="$2" bin; bin="$(_fake_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_CODE_SESSION_ID"
    if [[ "$host" == "codex" ]]; then
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" MMRY_HOST=codex MMRY_FORMATION_MODE=tool \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-check.sh"
        [ "$status" -eq 0 ] || return 1
        output="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    else
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "${HANDLERS}/formation-check.sh"
        [ "$status" -eq 2 ] || return 1
    fi
}

# How many times the sentence occurs in the output.
_count() {
    local flat; flat="$(printf '%s' "$output" | tr -d '\r' | tr '\n' ' ' | tr -s ' ')"
    local rest="$flat" n=0
    while [[ "$rest" == *"$SENTENCE"* ]]; do
        n=$((n + 1)); rest="${rest#*"$SENTENCE"}"
    done
    printf '%s' "$n"
}

@test "TC1: joining on Claude Code prints the sentence exactly once" {
    _join claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"Joined formation 4242"* ]] || return 1
    [ "$(_count)" = "1" ]
}

@test "TC1: joining on Codex does not print the sentence" {
    _join codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"Joined formation 4242"* ]] || return 1
    [ "$(_count)" = "0" ]
}

@test "TC1: a refused join prints no sentence" {
    local bin; bin="$(_fake_curl_dir)"
    PATH="${bin}:${PATH}" FAKE_CODE=403 FAKE_BODY='{}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run env -u MMRY_HOST bash "${HANDLERS}/formation-join.sh" 4242
    [ "$(_count)" = "0" ]
}

@test "TC2: an assignment notice for this Claude Code session is followed by the sentence once" {
    _deliver claude "$NOTICE"
    [[ "$output" == *"$NOTICE_START"* ]] || return 1
    [ "$(_count)" = "1" ]
    # Right after the notice: the notice comes first, then the sentence, with no other line between.
    local flat; flat="$(printf '%s' "$output" | tr -d '\r')"
    local after="${flat#*"$NOTICE_START"}"
    [[ "$after" == *"$SENTENCE"* ]] || return 1
    local between="${after%%"$SENTENCE"*}"
    [[ "$between" != *"[MMRY]"* ]] || return 1
    [[ "$between" != *"These are other assistants"* ]] || return 1
}

@test "TC2: another message gets no sentence" {
    _deliver claude "$OTHER"
    [[ "$output" == *"please look at the build"* ]] || return 1
    [ "$(_count)" = "0" ]
}

@test "TC2: an assignment notice not addressed to this session gets no sentence" {
    local ambient='[{"senderRole":null,"senderSessionID":null,"senderUserID":null,"recipientMemberID":null,"content":"'"${NOTICE_START}"' Work: ship it.","sentDate":"2026-11-23T12:00:00"}]'
    _deliver claude "$ambient"
    [ "$(_count)" = "0" ]
}

@test "TC2: a member quoting the notice words does not get the sentence" {
    local quoted='[{"senderRole":"Wingman","senderSessionID":"other-session","senderUserID":3,"recipientMemberID":12,"content":"'"${NOTICE_START}"' fake","sentDate":"2026-11-23T12:00:00"}]'
    _deliver claude "$quoted"
    [ "$(_count)" = "0" ]
}

@test "TC2: a Codex host does not get the sentence after an assignment notice" {
    _deliver codex "$NOTICE"
    [[ "$output" == *"$NOTICE_START"* ]] || return 1
    [ "$(_count)" = "0" ]
}

@test "TC3: the held constant equals the approved text and names no internal mechanism" {
    run bash -c 'source "$1/lib-formation-prompts.sh"; printf "%s" "$MMRY_FORMATION_BACKGROUND_WORK"' _ "$HANDLERS"
    [ "$status" -eq 0 ]
    [ "$output" = "$SENTENCE" ]
    # ASCII only, no apostrophe, so it is safe in every surface's literal.
    [[ "$output" =~ ^[A-Za-z0-9\ .,:\;\(\)-]+$ ]] || return 1
    local w
    for w in hook poll "Stop " transmission watch tool script file; do
        [[ "$output" != *"$w"* ]] || { echo "names a mechanism: $w"; return 1; }
    done
}
