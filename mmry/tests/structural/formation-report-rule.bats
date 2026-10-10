#!/usr/bin/env bats
# Every formation member reports to the lead at each stopping point (#31744).
#
# WHY THIS FILE EXISTS. On 2026-10-04 a member held finished work for about 40 minutes behind a
# slow check, and the sponsor had to ask whether the lead had been told. Nothing in the product told
# a member to report back: joining said only that messages would arrive, and the text printed with
# every delivered batch ended "Do not reply to the formation unless you have something worth
# transmitting", which a member reasonably read as "stay quiet".
#
# WHAT IS PINNED, by the ticket's own test cases:
#   req1  joining prints the report rule, on Claude Code and on Codex.
#   req3  the delivery text says a report to the lead is always worth sending, and no longer
#         carries the sentence that discouraged it.
#   req4  the rule is one text: the join output on both hosts, the command page and the Codex skill
#         carry it byte for byte, and so do the service's copies when the service repository is
#         given in MMRY_SERVICE_REPO (the connector join response and the assignment notice).
#   req5  joining asks for an acknowledgement of substance on assignments, briefs and questions
#         only, and the command page carries the same wording.
#
# Requirement 2 (the assignment notice) is written by the service, not by this plugin, and is
# pinned in MMRY-AI/mmry. The req4 test below reads it from there.

# THE RULES, as one literal each. If a surface drifts from these, the surface is wrong.
REPORT_RULE="Report to the lead at every stopping point, with a message directed to the lead: when you finish, when you are blocked, when you are waiting, and when you stop with work still running, saying what is still running. Never hold finished work back for a slow check; report it and say the check is still running."
ACK_RULE="When you receive an assignment, a brief or a question, acknowledge it before you start, with substance: what you understood, anything you cannot do, and when to expect the result. If the job is short, fold that into your first update. Findings and status updates need no acknowledgement."

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    PLUGIN_DIR="${BATS_TEST_DIRNAME}/../.."
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_CODE_SESSION_ID="bats-report-rule-$$"
    export CLAUDE_SESSION_ID="$CLAUDE_CODE_SESSION_ID"
    # A config that does not exist, so the client falls back to the environment given per test.
    # HOME is isolated by structural/setup_suite.bash, so no developer config is read either.
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true

    JOIN_BODY='{"formation":{"id":4242,"objective":"TEST DATA 31744 ship the validator"},"members":[]}'
    TRANSMISSION='[{"senderRole":"lead","senderSessionID":"other-session","content":"Heads up: I am touching FormationService.cs","sentDate":"2026-10-10T12:00:00"}]'
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
}

# The fake transport formation-leave.bats and formation-delivery.bats use: no network, no port, the
# body and status are whatever the test says.
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

# Join through the published handler on the given host ("claude" or "codex").
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

# One line of output, exactly, with any CR a Windows tool may have added removed.
_has_line() {
    local want="$1" line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" == "$want" ]] && return 0
    done <<< "$output"
    echo "expected this exact line in the output:"
    echo "  $want"
    echo "output was:"
    echo "$output"
    return 1
}

# The delivered block, from the PostToolUse path, on the given host.
_deliver() {
    local host="$1" bin; bin="$(_fake_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_CODE_SESSION_ID"
    if [[ "$host" == "codex" ]]; then
        # Codex is given the block as PostToolUse additionalContext JSON. Unwrap it, so the same
        # sentence checks apply to the text the model actually reads.
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$TRANSMISSION" MMRY_HOST=codex \
            MMRY_FORMATION_MODE=tool \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-check.sh"
        [ "$status" -eq 0 ] || return 1
        output="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    else
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$TRANSMISSION" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "${HANDLERS}/formation-check.sh"
    fi
}

# Collapse the block's hard line wraps so a sentence can be matched whole.
_flat() { printf '%s' "$output" | tr -d '\r' | tr '\n' ' ' | tr -s ' '; }

# ---- Requirement 1: the join confirmation carries the rule --------------------------------------

@test "req1: joining on Claude Code prints the report rule" {
    _join claude
    [ "$status" -eq 0 ]
    _has_line "$REPORT_RULE"
}

@test "req1: joining on Codex prints the report rule" {
    _join codex
    [ "$status" -eq 0 ]
    _has_line "$REPORT_RULE"
}

@test "req1 control: the join really happened in that harness, so the rule is not printed by accident" {
    # The rule is printed after a join the service granted, and only then. A refused join must not
    # print it: the session is not a member and there is no lead to report to.
    _join claude
    [[ "$output" == *"Joined formation 4242: TEST DATA 31744 ship the validator."* ]]

    local bin; bin="$(_fake_curl_dir)"
    PATH="${bin}:${PATH}" FAKE_CODE=403 FAKE_BODY='{}' \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-join.sh" 4242
    [ "$status" -ne 0 ]
    [[ "$output" != *"Report to the lead"* ]]
}

# ---- Requirement 3: the delivery text --------------------------------------------------------------

@test "req3: the delivery text says a report to the lead is always worth sending (Claude Code)" {
    _deliver claude
    [ "$status" -eq 2 ]
    local flat; flat="$(_flat)"
    [[ "$flat" == *"A report to the lead is always worth sending: tell the lead when you finish, are blocked, are waiting, or stop with work still running."* ]]
}

@test "req3: and on Codex the delivered text is the same" {
    _deliver codex
    local flat; flat="$(_flat)"
    [[ "$flat" == *"A report to the lead is always worth sending: tell the lead when you finish, are blocked, are waiting, or stop with work still running."* ]]
}

@test "req3: no wording that discourages a report to the lead is left in the delivery text" {
    _deliver claude
    local flat; flat="$(_flat)"
    [[ "$flat" == *"FormationService.cs"* ]]    # the control: this IS the delivered block
    [[ "$flat" != *"Do not reply"* ]]
    [[ "$flat" != *"unless you have something worth"* ]]
    [[ "$flat" != *"say nothing"* ]]
    # And in the source, so a branch of the block not reached by this fixture cannot carry it.
    # Comment lines are excluded: the comment above the block quotes the old sentence on purpose.
    run bash -c 'grep -v -E "^[[:space:]]*#" "$1" | grep -c -E "Do not reply to the formation|unless you have something worth"' _ "${HANDLERS}/formation-check.sh"
    [ "$output" = "0" ]
}

@test "req3: the prompt path still delivers the reworded block whole, as valid JSON" {
    # The prompt path strips exactly one trailing newline and depends on the block ending in
    # "transmitting." with no newline of its own. The rewording keeps that.
    local bin; bin="$(_fake_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_CODE_SESSION_ID"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$TRANSMISSION" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        MMRY_FORMATION_MODE=prompt \
        run bash "${HANDLERS}/formation-check.sh"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "${BATS_TEST_TMPDIR}/ups.json"
    run node -e '
        const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const t = o.hookSpecificOutput.additionalContext.replace(/\s+/g, " ");
        if (!t.includes("A report to the lead is always worth sending")) process.exit(1);
        if (!t.endsWith("worth transmitting.")) process.exit(2);
        console.log("ok");' "${BATS_TEST_TMPDIR}/ups.json"
    [ "$status" -eq 0 ]
}

# ---- Requirement 5: the acknowledgement ---------------------------------------------------------

@test "req5: joining on Claude Code asks for an acknowledgement of substance" {
    _join claude
    _has_line "$ACK_RULE"
}

@test "req5: joining on Codex asks for the same acknowledgement" {
    _join codex
    _has_line "$ACK_RULE"
}

@test "req5: the acknowledgement is asked for on assignments, briefs and questions only" {
    # Each part the ticket names, present; and the exclusion, present, so it is never read as a
    # duty to acknowledge everything.
    [[ "$ACK_RULE" == *"an assignment, a brief or a question"* ]]
    [[ "$ACK_RULE" == *"what you understood"* ]]
    [[ "$ACK_RULE" == *"anything you cannot do"* ]]
    [[ "$ACK_RULE" == *"when to expect the result"* ]]
    [[ "$ACK_RULE" == *"fold that into your first update"* ]]
    [[ "$ACK_RULE" == *"Findings and status updates need no acknowledgement."* ]]
    _join claude
    _has_line "$ACK_RULE"
}

@test "req5 docs: the formation command page carries the same acknowledgement wording" {
    grep -q -F -- "> ${ACK_RULE}" "${PLUGIN_DIR}/commands/formation.md"
}

# ---- Requirement 4: one rule on every surface ----------------------------------------------------

@test "req4: the join output is byte-identical on Claude Code and Codex" {
    _join claude
    local cc; cc="$(printf '%s' "$output" | tr -d '\r' | grep -E "^(Report to the lead|When you receive)")"
    _join codex
    local cx; cx="$(printf '%s' "$output" | tr -d '\r' | grep -E "^(Report to the lead|When you receive)")"
    [ -n "$cc" ]
    [ "$cc" = "$cx" ]
}

@test "req4: the command page and the Codex skill carry both rules byte for byte" {
    grep -q -F -- "> ${REPORT_RULE}" "${PLUGIN_DIR}/commands/formation.md"
    grep -q -F -- "> ${ACK_RULE}" "${PLUGIN_DIR}/commands/formation.md"
    grep -q -F -- "> ${REPORT_RULE}" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md"
    grep -q -F -- "> ${ACK_RULE}" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md"
}

@test "req4: the connector and the assignment notice in the service carry the same two rules" {
    # The third surface is the service: the connector's join response and the assignment notice
    # each hold the rules as a literal. Given the service repository, compare against it.
    if [[ -z "${MMRY_SERVICE_REPO:-}" ]]; then
        skip "MMRY_SERVICE_REPO is not set; set it to a checkout of MMRY-AI/mmry to compare the third surface"
    fi
    local cs="${MMRY_SERVICE_REPO}/src/Mnemo.Api/Services/FormationReportRule.cs"
    local mig="${MMRY_SERVICE_REPO}/sql/lib/Migration066.ps1"
    [ -f "$cs" ]
    [ -f "$mig" ]
    grep -q -F -- "\"${REPORT_RULE}\"" "$cs"
    grep -q -F -- "\"${ACK_RULE}\"" "$cs"
    grep -q -F -- "N'${REPORT_RULE}'" "$mig"
    grep -q -F -- "N'${ACK_RULE}'" "$mig"
}
