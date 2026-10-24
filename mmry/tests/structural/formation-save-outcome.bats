#!/usr/bin/env bats
# Every formation member is prompted to save its own outcome to MMRY when it leaves, or records
# Done or Abandoned (#32682, DD-156).
#
# WHY THIS FILE EXISTS. On 2026-10-22, in the formation running the 1.30.1 release, a member
# recorded Done, sent its handover and left without saving anything, and the person running the
# work had to ask whether its progress was saved. Only the lead's close-out saved anything, and
# that is the formation's account, not each member's own outcome.
#
# WHAT IS PINNED, by the ticket's own test cases:
#   req1  leaving prints the prompt, the leave still completes and the exit code is unchanged.
#   req2  reporting Done, then Abandoned, prints the prompt each time; Accepted and Blocked do not.
#         A lead reporting for ANOTHER member is not prompted: it is not that member's outcome.
#   req3  the prompt names tasks and their final states, what shipped, what was handed to whom,
#         and where the notes are.
#   req4  one text: the leave and progress output on Claude Code and Codex carry it byte for byte,
#         each followed by the save route that host has; the command page and the Codex skill
#         carry it; and so does the connector, when MMRY_SERVICE_REPO names a checkout of
#         MMRY-AI/mmry.
#   req5  the existing leave and progress suites are untouched and still pass beside this one.
#
# DD-156: a member that has already saved since its last report is still prompted. The prompt is
# not a gate and keeps no state; its last sentence lets a member that has saved everything skip it.

# THE PROMPT, as one literal. If a surface drifts from this, the surface is wrong.
SAVE_ASK="Save what you did before you go: tasks and their status, what shipped, handoffs, and where your notes are."
SAVE_SKIP="Skip this if you already saved it."
# The order on every surface: the outcome sentence, the save route, then the skip sentence.
SAVE_PROMPT="${SAVE_ASK} ${SAVE_SKIP}"

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    PLUGIN_DIR="${BATS_TEST_DIRNAME}/../.."
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_CODE_SESSION_ID="bats-save-outcome-$$"
    export CLAUDE_SESSION_ID="$CLAUDE_CODE_SESSION_ID"
    # A config that does not exist, so the client falls back to the environment given per test.
    # HOME is isolated by structural/setup_suite.bash, so no developer config is read either.
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    # A Codex home that is not the default, as codex-customer-strings.bats uses.
    CODEX_DIR="${BATS_TEST_TMPDIR}/codexhome"
    mkdir -p "${CODEX_DIR}/mmry"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_CODE_SESSION_ID" || true
}

# The save route each host names after the prompt.
_route_line() {
    case "$1" in
        codex) printf '%s Use the memory_save tool. %s' "$SAVE_ASK" "$SAVE_SKIP" ;;
        *)     printf '%s Use /mmry:save. %s' "$SAVE_ASK" "$SAVE_SKIP" ;;
    esac
}

# A fake curl that answers the roster read and the progress write differently, as
# formation-progress.bats does; the leave call is answered like the write.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
body="${FAKE_BODY:-}"
code="${FAKE_CODE:-200}"
if [[ "$url" != *"/progress"* && "$url" != *"/leave"* ]]; then
    body="${FAKE_BODY_GET:-$body}"
    code="${FAKE_CODE_GET:-200}"
fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# Run a handler on the given host ("claude" or "codex") with the fake transport.
_on() {
    local host="$1"; shift
    local bin; bin="$(_fake_curl_dir)"
    if [[ "$host" == "codex" ]]; then
        PATH="${bin}:${PATH}" MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "$@"
    else
        PATH="${bin}:${PATH}" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "$@"
    fi
}

_leave() {
    local host="$1"
    bash "${HANDLERS}/formation-state.sh" set 77 "$CLAUDE_CODE_SESSION_ID"
    local released
    released="$(printf '{"formationId":77,"sessionId":"%s","leftDate":"2026-10-23T12:00:00Z","formationStatus":"Active","memberCount":2,"activeMemberCount":1}' "$CLAUDE_CODE_SESSION_ID")"
    export FAKE_CODE="${LEAVE_CODE:-200}"
    export FAKE_BODY="${LEAVE_BODY:-$released}"
    _on "$host" "${HANDLERS}/formation-leave.sh"
}

# The roster with THIS session as member 7 and somebody else as member 3.
_roster_body() {
    printf '{"formation":{"id":42,"objective":"o"},"members":[{"id":3,"sessionId":"somebody-else","role":"Lead","progress":"Accepted","leftDate":null},{"id":7,"sessionId":"%s","role":"Wingman","progress":"Accepted","leftDate":null}]}' "$CLAUDE_CODE_SESSION_ID"
}

# The roster entry the server reads back after a write: member $1, session $2, state $3.
_entry_body() {
    printf '{"id":%s,"sessionId":"%s","userId":3,"email":"a@b.c","userIsActive":true,"role":"Wingman","assignment":"the validator","progress":"%s","progressUpdatedDate":"2026-10-23T13:00:00","joinedDate":"2026-10-23T12:00:00","leftDate":null}' "$1" "$2" "$3"
}

# Report $2 for this session on host $1; the server reads back the same state.
_progress() {
    local host="$1" state="$2"
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=200 FAKE_BODY_GET; FAKE_BODY_GET="$(_roster_body)"
    export FAKE_BODY; FAKE_BODY="$(_entry_body 7 "$CLAUDE_CODE_SESSION_ID" "$state")"
    _on "$host" "${HANDLERS}/formation-progress.sh" "$state"
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

_no_prompt() {
    [[ "$output" != *"Save what you did before you go"* ]] || { echo "the prompt was printed:"; echo "$output"; return 1; }
}

# ---- Requirement 1: leaving --------------------------------------------------------------------

@test "req1: leaving on Claude Code prints the save prompt, and the leave still completes with exit 0" {
    _leave claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"Left formation 77."* ]] || return 1     # the control: the leave happened
    _has_line "$(_route_line claude)"
    [ -z "$(bash "${HANDLERS}/formation-state.sh" get "$CLAUDE_CODE_SESSION_ID")" ]
}

@test "req1: leaving on Codex prints the same prompt with the save route Codex has" {
    _leave codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"Left formation 77."* ]] || return 1
    _has_line "$(_route_line codex)"
    [[ "$output" != *"/mmry:"* ]] || return 1
}

@test "req1: the prompt comes after the confirmation, so it cannot be read as the leave waiting on it" {
    _leave claude
    local left at
    left="$(printf '%s\n' "$output" | grep -n "Left formation" | head -1 | cut -d: -f1)"
    at="$(printf '%s\n' "$output" | grep -n "Save what you did before you go" | head -1 | cut -d: -f1)"
    [ -n "$left" ] && [ -n "$at" ]
    [ "$at" -gt "$left" ]
}

@test "req1: a session the service had no record of is prompted too; exit code unchanged at 0" {
    LEAVE_CODE=404 LEAVE_BODY="{}" _leave claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to release"* ]] || return 1
    _has_line "$(_route_line claude)"
}

@test "req1 control: a refused leave is not prompted and still exits 1, as before" {
    # The session is still a member; it is told to resolve that first. It sees the prompt when the
    # leave that releases it succeeds.
    LEAVE_CODE=403 LEAVE_BODY="{\"error\":\"no\"}" _leave claude
    [ "$status" -eq 1 ]
    [[ "$output" == *"refused to release"* ]] || return 1
    _no_prompt
}

# ---- Requirement 2: Done and Abandoned, and not Accepted or Blocked ------------------------------

@test "req2: reporting Done prints the save prompt" {
    _progress claude Done
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded as Done"* ]] || return 1
    _has_line "$(_route_line claude)"
}

@test "req2: and then reporting Abandoned prints it again" {
    _progress claude Done
    _has_line "$(_route_line claude)"
    _progress claude Abandoned
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded as Abandoned"* ]] || return 1
    _has_line "$(_route_line claude)"
}

@test "req2: Accepted prints no prompt" {
    _progress claude Accepted
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded as Accepted"* ]] || return 1    # the control: it was recorded
    _no_prompt
}

@test "req2: Blocked prints no prompt" {
    _progress claude Blocked
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded as Blocked"* ]] || return 1
    _no_prompt
}

@test "req2: on Codex, Done and Abandoned print the prompt with the Codex route, and Blocked does not" {
    _progress codex Done
    [ "$status" -eq 0 ]
    _has_line "$(_route_line codex)"
    _progress codex Abandoned
    _has_line "$(_route_line codex)"
    _progress codex Blocked
    [[ "$output" == *"recorded as Blocked"* ]] || return 1
    _no_prompt
}

@test "req2: the state the server read back decides, not the one asked for" {
    # Asked for Done, the server answers Blocked: no prompt. The #31192 rule, applied here too.
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=200 FAKE_BODY_GET; FAKE_BODY_GET="$(_roster_body)"
    export FAKE_BODY; FAKE_BODY="$(_entry_body 7 "$CLAUDE_CODE_SESSION_ID" Blocked)"
    _on claude "${HANDLERS}/formation-progress.sh" Done
    [[ "$output" == *"recorded as Blocked"* ]] || return 1
    _no_prompt
}

@test "req2: a lead reporting Done for ANOTHER member is not prompted; it is not the lead's outcome" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=200 FAKE_BODY; FAKE_BODY="$(_entry_body 3 somebody-else Done)"
    _on claude "${HANDLERS}/formation-progress.sh" 3 Done
    [ "$status" -eq 0 ]
    [[ "$output" == *"Member 3 in formation 42 is now recorded as Done"* ]] || return 1
    _no_prompt
}

@test "req2: a member naming its OWN member id is still prompted" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=200 FAKE_BODY; FAKE_BODY="$(_entry_body 7 "$CLAUDE_CODE_SESSION_ID" Done)"
    _on claude "${HANDLERS}/formation-progress.sh" 7 Done
    [ "$status" -eq 0 ]
    _has_line "$(_route_line claude)"
}

@test "req2 control: a refused report is not prompted and still exits 1" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_CODE_SESSION_ID"
    export FAKE_CODE=400 FAKE_BODY='{"error":"The formation is closed out."}' FAKE_BODY_GET; FAKE_BODY_GET="$(_roster_body)"
    _on claude "${HANDLERS}/formation-progress.sh" Done
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing was recorded"* ]] || return 1
    _no_prompt
}

# ---- Requirement 3: what the prompt names ------------------------------------------------------

@test "req3: the prompt names tasks and final states, what shipped, what was handed over, and the notes" {
    [[ "$SAVE_PROMPT" == "Save what you did before you go"* ]] || return 1
    [[ "$SAVE_PROMPT" == *"tasks and their status"* ]] || return 1
    [[ "$SAVE_PROMPT" == *"what shipped"* ]] || return 1
    [[ "$SAVE_PROMPT" == *"handoffs"* ]] || return 1
    [[ "$SAVE_PROMPT" == *"where your notes are"* ]] || return 1
    # And the handler holds exactly this text, so the assertions above are about what is printed.
    grep -q -F -- "MMRY_FORMATION_SAVE_OUTCOME_ASK=\"${SAVE_ASK}\"" "${HANDLERS}/lib-formation-prompts.sh"
    grep -q -F -- "MMRY_FORMATION_SAVE_OUTCOME_SKIP=\"${SAVE_SKIP}\"" "${HANDLERS}/lib-formation-prompts.sh"
}

@test "req3: the prompt is plain ASCII with no apostrophe, so it needs no escaping on any surface" {
    [[ "$SAVE_PROMPT" != *"'"* ]] || return 1
    LC_ALL=C bash -c '[[ "$1" =~ ^[\ -~]+$ ]]' _ "$SAVE_PROMPT"
}

# ---- Requirement 4: one text on every surface -----------------------------------------------------

# The prompt line from the last run, carriage returns removed.
_prompt_line() {
    printf '%s\n' "$output" | tr -d '\r' | grep "^Save what you did before you go"
}

@test "req4: the prompt is byte-identical in leave and progress, with only the save route differing by host" {
    local got
    _leave claude;             got="$(_prompt_line)"
    [ "$got" = "$(_route_line claude)" ] || { echo "drifted: $got"; return 1; }
    _progress claude Done;     got="$(_prompt_line)"
    [ "$got" = "$(_route_line claude)" ] || { echo "drifted: $got"; return 1; }
    _leave codex;              got="$(_prompt_line)"
    [ "$got" = "$(_route_line codex)" ] || { echo "drifted: $got"; return 1; }
    _progress codex Abandoned; got="$(_prompt_line)"
    [ "$got" = "$(_route_line codex)" ] || { echo "drifted: $got"; return 1; }
}

@test "req4: on every host the save route comes between the ask and the skip sentence, and the skip sentence is last" {
    local host line
    for host in claude codex; do
        _leave "$host"
        line="$(_prompt_line)"
        [[ "$line" == "$SAVE_ASK Use "* ]] || { echo "route does not follow the outcome sentence: $line"; return 1; }
        [[ "$line" == *" $SAVE_SKIP" ]] || { echo "the skip sentence is not last: $line"; return 1; }
        [[ "$line" != *"Skip this if you already saved it. Use"* ]] || return 1
    done
}

@test "req4: the command page and the Codex skill each say once to act on the prompt, with their own save route" {
    # One sentence each (#32682 follow-up), not a quotation of the prompt: a quotation is a copy to drift.
    grep -q -F -- "prints a short prompt to save what you did; act on it with \`/mmry:save\`" "${PLUGIN_DIR}/commands/formation.md"
    grep -q -F -- "act on it with \`memory_save\`" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md"
    [ "$(grep -c -F -- "prints a short prompt to save what you did" "${PLUGIN_DIR}/commands/formation.md")" -eq 1 ]
    [[ "$(cat "${PLUGIN_DIR}/commands/formation.md" "${PLUGIN_DIR}/skills-codex/memory-system/SKILL.md")" != *"nothing more to save"* ]] || return 1
}

@test "req4: the connector in the service carries the same prompt" {
    if [[ -z "${MMRY_SERVICE_REPO:-}" ]]; then
        skip "MMRY_SERVICE_REPO is not set; set it to a checkout of MMRY-AI/mmry to compare the connector"
    fi
    local cs="${MMRY_SERVICE_REPO}/src/Mnemo.Api/Services/FormationMemberPrompts.cs"
    [ -f "$cs" ]
    grep -q -F -- "\"${SAVE_ASK}\"" "$cs"
    grep -q -F -- "\"${SAVE_SKIP}\"" "$cs"
    grep -q -F -- 'SaveOutcomeAsk + " Use mmry_save. " + SaveOutcomeSkip' "$cs"
}
