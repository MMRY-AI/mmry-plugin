#!/usr/bin/env bats
# codex-formation-instructions.bats — the remedy a stuck customer is handed must be one they can
# run ON THE HOST THEY ARE USING (#31245 QA round 5).
#
# WHAT WENT WRONG. Four formation handlers are already on the Codex surface — say, roster, start
# and join are the four of the six exposed operations that print remedies — and every one of those
# remedies named "/mmry:formation ...". Codex gives plugins no typed slash commands at all: the
# manifest names an empty commands directory on purpose (commands-codex/README.md) and Codex
# customers reach this feature through skills. So twenty strings told a Codex customer to type
# something that does not exist on their machine.
#
# WHY IT IS WORSE THAN A COSMETIC BUG. Every one of these strings is printed at the moment the
# customer is ALREADY STUCK: a recipient id that is not a number, a session that is in no
# formation, an objective left off. An instruction that cannot be followed sends them hunting for
# a command rather than at the thing that is actually wrong. This is the same defect that failed
# #31434 — a customer-facing string naming a command that does not exist for them, discovered at
# the exact moment they are confused.
#
# HOW THIS FILE TESTS IT, AND WHY THAT SHAPE.
#
#   1. IT ASSERTS ON THE MESSAGE THE CUSTOMER WOULD SEE, NOT ON THE HELPER THAT BUILDS IT. Every
#      test below RUNS the handler and reads its stdout. A test that called
#      mmry_host_formation_ref directly would pass against a handler that never calls it — which
#      is exactly the hole that let twenty such strings ship in the first place. The helper has
#      its own unit coverage in unit/lib-host.bats; this file is about what comes out of the
#      handler.
#
#   2. EVERY CODEX ASSERTION IS PAIRED WITH A CLAUDE CONTROL. Without the control, the whole file
#      is satisfied by a handler that simply stops naming any command at all — delete the remedy
#      and "no /mmry: appears" is trivially true, while the customer is left with a complaint and
#      no way forward. The control pins the Claude string BYTE FOR BYTE to what it has always
#      been, which is also requirement 4 of this task: the existing Claude Code experience is
#      preserved unchanged.
#
#   3. THE DERIVED PATH IS CHECKED FOR BEING RUNNABLE, NOT MERELY DIFFERENT. _assert_targets_exist
#      resolves every formation-*.sh the message names back to a real file in hooks-handlers/. A
#      remedy that points at formation-rooster.sh is as useless as one naming a slash command, and
#      it would read perfectly plausibly in a diff.
#
# SCOPE, DELIBERATELY. Only the four handlers a Codex customer can already reach are covered. The
# other nine formation handlers have no Codex surface, so their strings are not yet wrong for
# anybody; making them reachable is a feature decision, not a QA fix, and it is not made here.
# The roster footer does name progress and report, which are NOT advertised on the Codex surface —
# that stays honest because session-init.sh copies hooks-handlers/*.sh wholesale (line 108), so
# those scripts are on disk at the derived path and do run.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-codexinstr-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true

    # A Codex home that exists but is NOT the default, because the customer this whole feature
    # exists for is the one who moved it. A message derived from a hardcoded "~/.codex" would pass
    # a test that used the default and fail this one.
    CODEX_DIR="${BATS_TEST_TMPDIR}/codexhome"
    mkdir -p "${CODEX_DIR}/mmry"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# Run a handler as Codex sees it.
#
# MMRY_API_KEY is supplied because lib-host.sh refuses outright on a Codex install with no
# credential (the round-2 fix that stops it borrowing the Claude account), and that refusal fires
# before any of these messages is reached. A credential in the environment is a credential, so
# this reaches the message under test rather than the credential guard.
_run_codex() {
    MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "$@"
}

_run_claude() {
    MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "$@"
}

# The literal a Codex customer can paste. Built here from the same two facts the handler has —
# the resolved home and the operation — so that a test cannot agree with the handler by sharing
# its mistake.
_codex_ref() {
    printf 'bash %s/mmry/hooks-handlers/formation-%s.sh' "$CODEX_DIR" "$1"
}

# A remedy naming a script that is not there is not a remedy. Resolve every formation-*.sh the
# message mentions back to a real file.
_assert_targets_exist() {
    local named
    named="$(printf '%s' "$output" | grep -o 'formation-[a-z]*\.sh' | sort -u)"
    [ -n "$named" ]
    local f
    while IFS= read -r f; do
        [ -f "${HANDLERS}/${f}" ] || {
            echo "message names ${f}, which is not a handler that exists" >&2
            return 1
        }
    done <<< "$named"
}

# No message may name a slash command on Codex. Kept as one helper so a new assertion cannot
# forget the half that matters.
_assert_no_slash_command() {
    [[ "$output" != *"/mmry:"* ]]
}

# ------------------------------------------------------------------ formation-join

@test "join: a Codex customer with no argument is given a command that exists on their machine" {
    _run_codex "${HANDLERS}/formation-join.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_codex_ref join)"* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "join: the same message on Claude Code still names the slash command, unchanged" {
    _run_claude "${HANDLERS}/formation-join.sh"
    [ "$status" -eq 1 ]
    # Byte for byte what it has always said. This is the control: a handler that "fixes" the
    # Codex message by naming no command at all fails here.
    [[ "$output" == *"Usage: /mmry:formation join <formationId>"* ]]
}

# ------------------------------------------------------------------ formation-start

@test "start: a Codex customer with no objective is given a runnable command" {
    _run_codex "${HANDLERS}/formation-start.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_codex_ref start)"* ]]
    # The quoted example argument survives the derivation; without it the customer is told to run
    # a script and not what to pass it.
    [[ "$output" == *'"what the formation is for"'* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "start: on Claude Code the usage line is the slash command it always was" {
    _run_claude "${HANDLERS}/formation-start.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'Usage: /mmry:formation start "what the formation is for"'* ]]
}

@test "start: a session already in a formation is told how to leave, in its own host's terms" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    _run_codex "${HANDLERS}/formation-start.sh" "coordinate the billing migration"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already in formation 42"* ]]
    [[ "$output" == *"$(_codex_ref leave)"* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "start: and on Claude Code that same remedy is still /mmry:formation leave" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    _run_claude "${HANDLERS}/formation-start.sh" "coordinate the billing migration"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run /mmry:formation leave first, or use that one."* ]]
}

# ------------------------------------------------------------------ formation-say

@test "say: a Codex customer with no message is given a runnable command" {
    _run_codex "${HANDLERS}/formation-say.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_codex_ref say)"* ]]
    [[ "$output" == *'"what you want the others to know" [recipientMemberId]'* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "say: on Claude Code the usage line is unchanged" {
    _run_claude "${HANDLERS}/formation-say.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'Usage: /mmry:formation say "what you want the others to know" [recipientMemberId]'* ]]
}

@test "say: a bad recipient points a Codex customer at the roster they can actually run" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    _run_codex "${HANDLERS}/formation-say.sh" "the validator is yours" "not-a-number"
    [ "$status" -eq 1 ]
    # The refusal itself must survive: nothing was sent, and that is the point of the message.
    [[ "$output" == *"Nothing was sent"* ]]
    [[ "$output" == *"$(_codex_ref roster)"* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "say: and on Claude Code the bad recipient still names /mmry:formation roster" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    _run_claude "${HANDLERS}/formation-say.sh" "the validator is yours" "not-a-number"
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive whole number from /mmry:formation roster"* ]]
}

@test "say: a session in no formation is told how to find and join one, runnably" {
    _run_codex "${HANDLERS}/formation-say.sh" "anyone there"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_codex_ref list)"* ]]
    [[ "$output" == *"$(_codex_ref join)"* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "say: and on Claude Code that pair is still the two slash commands" {
    _run_claude "${HANDLERS}/formation-say.sh" "anyone there"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run /mmry:formation list to see what is active, then /mmry:formation join <id>."* ]]
}

# ------------------------------------------------------------------ formation-roster

@test "roster: a session in no formation is given commands it can run" {
    _run_codex "${HANDLERS}/formation-roster.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_codex_ref list)"* ]]
    [[ "$output" == *"$(_codex_ref join)"* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

@test "roster: on Claude Code that message is unchanged" {
    _run_claude "${HANDLERS}/formation-roster.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run /mmry:formation list to see what is active, then /mmry:formation join <id>."* ]]
}

@test "roster: a malformed id points a Codex customer at a runnable list" {
    _run_codex "${HANDLERS}/formation-roster.sh" "not-an-id"
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive whole number"* ]]
    [[ "$output" == *"$(_codex_ref list)"* ]]
    _assert_no_slash_command
    _assert_targets_exist
}

# The footer below is the one a customer reads on the SUCCESS path — the busiest cluster of the
# twenty, and the only one that is not an error. The fake transport is the same one the other
# formation suites use.
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

_ROSTER_JSON='{"formation":{"id":42,"objective":"migrate the billing schema"},"members":[{"id":11,"sessionId":"s1","role":"Lead","email":"lead@example.com","assignment":"coordinate","leftDate":null}]}'

@test "roster: the success footer hands a Codex customer three commands that all exist" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$_ROSTER_JSON" \
        MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -eq 0 ]
    # It is still the roster it was.
    [[ "$output" == *"migrate the billing schema"* ]]
    [[ "$output" == *"lead@example.com"* ]]
    # And every instruction under it is runnable here.
    [[ "$output" == *"$(_codex_ref say)"* ]]
    [[ "$output" == *"$(_codex_ref progress)"* ]]
    [[ "$output" == *"$(_codex_ref report)"* ]]
    _assert_no_slash_command
    # progress and report have no advertised Codex surface, so this is the assertion that keeps
    # the footer honest rather than merely quiet: the scripts it names are really on disk.
    _assert_targets_exist
}

@test "roster: the same footer on Claude Code still names all three slash commands" {
    bash "${HANDLERS}/formation-state.sh" set 42 "$CLAUDE_SESSION_ID"
    local bin; bin="$(_fake_curl_dir)"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$_ROSTER_JSON" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run bash "${HANDLERS}/formation-roster.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *'/mmry:formation say "..." --to <id>'* ]]
    [[ "$output" == *"/mmry:formation progress <Accepted|Done|Blocked|Abandoned>"* ]]
    [[ "$output" == *"/mmry:formation report"* ]]
}

# ------------------------------------------------------------------ the boundary

@test "surface: none of the four exposed handlers names a slash command on Codex" {
    # A sweep rather than four separate assertions, so that a fifth message added to any of these
    # four handlers is caught without anyone remembering to add a test for it. Each invocation is
    # an argument-validation path, so none of them reaches the network.
    local failures=""
    _run_codex "${HANDLERS}/formation-join.sh";   [[ "$output" == *"/mmry:"* ]] && failures="${failures} join"
    _run_codex "${HANDLERS}/formation-start.sh";  [[ "$output" == *"/mmry:"* ]] && failures="${failures} start"
    _run_codex "${HANDLERS}/formation-say.sh";    [[ "$output" == *"/mmry:"* ]] && failures="${failures} say"
    _run_codex "${HANDLERS}/formation-roster.sh"; [[ "$output" == *"/mmry:"* ]] && failures="${failures} roster"
    [ -z "$failures" ] || {
        echo "these handlers still name a slash command on Codex:${failures}" >&2
        return 1
    }
}
