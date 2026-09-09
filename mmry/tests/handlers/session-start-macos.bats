#!/usr/bin/env bats
# session-start.sh on a machine with no GNU `timeout` (#31385).
#
# The SessionStart handler reads the hook payload for one thing above all: the session id, which it
# then REGISTERS server-side. The shipped read was `timeout 2 cat`, and `timeout` is not on a stock
# macOS. With the payload gone the id fell through to CLAUDE_SESSION_ID and finally to the literal
# string "unknown", and that is the id the session was registered under.
#
# That is the mechanism behind the observation the ticket carries as a hypothesis: a second session
# register entry with no real identifier against the same workspace. These tests reproduce the
# CLIENT-SIDE cause. They do not, and cannot from here, confirm what the production rows actually
# hold - that needs the database, which is outside this task.
#
# Absence is simulated by SHADOWING timeout and gtimeout with shims that behave exactly as a missing
# command does: "command not found" on stderr, exit 127, argument never run. Removing /usr/bin from
# PATH instead would take date, stat, sed and tr with it and the handler would fail for reasons that
# have nothing to do with the defect.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/mmry/hooks-handlers" "$HOME/.claude/mmry/setup"
    # Deliberately NOT set. The whole point is what happens when the payload is the only source of
    # the id, which is the hook runtime's actual situation.
    unset CLAUDE_SESSION_ID || true
    unset CLAUDE_CODE_SESSION_ID || true
    MACOS_BIN="$(_macos_shim_dir)"
    FAULT_LOG="${TEST_TMPDIR}/mmry-hook-read-faults.log"
    rm -f "$FAULT_LOG"
}

_macos_shim_dir() {
    local dir="${TEST_TMPDIR}/macos-bin" c
    mkdir -p "$dir"
    for c in timeout gtimeout; do
        {
            echo '#!/usr/bin/env bash'
            echo "echo \"bash: ${c}: command not found\" >&2"
            echo 'exit 127'
        } > "${dir}/${c}"
        chmod +x "${dir}/${c}"
    done
    printf '%s' "$dir"
}

# A whole copy of the plugin with the shipped read put back in session-start.sh. The handler resolves
# its plugin root from its own path and sources siblings from it, so a directory of loose scripts is
# not enough - it has to be the tree.
_mutant_plugin() {
    local dir="${TEST_TMPDIR}/mutant-plugin"
    rm -rf "$dir"
    cp -r "$PLUGIN_ROOT" "$dir"
    local f="${dir}/hooks-handlers/session-start.sh"

    perl -0777 -pi -e 's{mmry_read_hook_payload[^\n]*\n[^\n]*HOOK_READ_STATUS="\$\{MMRY_HOOK_READ_STATUS:-empty\}"\n[^\n]*HOOK_PAYLOAD="\$\{MMRY_HOOK_PAYLOAD:-\}"}{HOOK_PAYLOAD="\$( { timeout 2 cat 2>/dev/null || true; } )"}' "$f"

    grep -q 'timeout 2 cat 2' "$f" || {
        echo "the mutation did not apply; the control that uses it would prove nothing" >&2
        return 1
    }
    bash -n "$f" || { echo "the mutation produced invalid bash" >&2; return 1; }
    printf '%s' "$dir"
}

# Run session-start.sh with a payload on stdin and the given plugin root, on a machine with no
# timeout. Leaves the mock curl log in place for inspection.
_run_session_start() {
    local root="$1" payload="$2"
    : > "${TEST_TMPDIR}/curl-log.txt"
    printf '%s' "$payload" > "${TEST_TMPDIR}/payload.json"
    run bash -c "env PATH='${MACOS_BIN}:${PATH}' HOME='${HOME}' \
            TEST_TMPDIR='${TEST_TMPDIR}' TMPDIR='${TEST_TMPDIR}' MMRY_TMPDIR='${TEST_TMPDIR}' \
            MMRY_CONFIG_FILE='${MMRY_CONFIG_FILE}' CLAUDE_PLUGIN_ROOT='${root}' \
            bash '${root}/hooks-handlers/session-start.sh' \
            < '${TEST_TMPDIR}/payload.json'"
}

_registered_session_id() {
    sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "${TEST_TMPDIR}/curl-log.txt" | head -1
}

# ---------------------------------------------------------------------------------------------

@test "harness: the shim shadows timeout, and this host really has one to shadow" {
    # Not via bats' `run`: an expected 127 triggers a BW01 warning that dumps the entire PATH into
    # the suite output.
    local out="${TEST_TMPDIR}/shim-probe.txt" st=0
    env PATH="${MACOS_BIN}:${PATH}" bash -c 'timeout 2 echo SHOULD-NOT-RUN' > "$out" 2>&1 || st=$?
    [ "$st" -eq 127 ] || { echo "the shim did not shadow timeout: ${st} $(cat "$out")"; return 1; }
    grep -q 'SHOULD-NOT-RUN' "$out" && { echo "the shim ran its argument"; return 1; }

    st=0
    bash -c 'timeout 2 echo PRESENT' > "$out" 2>&1 || st=$?
    [ "$st" -eq 0 ] || { echo "this host has no GNU timeout, so there is no contrast to draw"; return 1; }
    grep -q 'PRESENT' "$out"
}

@test "macos: the session id is read from the payload even with timeout absent" {
    _run_session_start "$PLUGIN_ROOT" '{"session_id":"REAL-UUID-1234","hook_event_name":"SessionStart"}'
    [ "$status" -eq 0 ]
    [ "$(_registered_session_id)" = "REAL-UUID-1234" ] || {
        echo "registered under '$(_registered_session_id)' instead of the id on stdin: $(cat "${TEST_TMPDIR}/curl-log.txt")"
        return 1
    }
}

@test "control: with the shipped read and timeout absent, the session registers as 'unknown'" {
    # POSITIVE CONTROL for the test above, and the reproduction of the ticket's carried observation.
    # With no payload the id chain ends at the literal string "unknown", and THAT is what is sent to
    # /api/sessions against this workspace - a register entry with no real identifier, alongside
    # whatever genuine rows the account already has.
    local mutant; mutant="$(_mutant_plugin)"
    _run_session_start "$mutant" '{"session_id":"REAL-UUID-1234","hook_event_name":"SessionStart"}'

    [ "$status" -eq 0 ]
    [ "$(_registered_session_id)" = "unknown" ] || {
        echo "the mutant did not produce the 'unknown' registration, so the test above proves nothing: $(cat "${TEST_TMPDIR}/curl-log.txt")"
        return 1
    }
}

@test "control: the shipped read is fine when timeout IS present, which is why this shipped" {
    local mutant; mutant="$(_mutant_plugin)"
    : > "${TEST_TMPDIR}/curl-log.txt"
    printf '%s' '{"session_id":"REAL-UUID-1234","hook_event_name":"SessionStart"}' > "${TEST_TMPDIR}/payload.json"
    # Note: no MACOS_BIN on PATH here.
    run bash -c "env HOME='${HOME}' \
            TEST_TMPDIR='${TEST_TMPDIR}' TMPDIR='${TEST_TMPDIR}' MMRY_TMPDIR='${TEST_TMPDIR}' \
            MMRY_CONFIG_FILE='${MMRY_CONFIG_FILE}' CLAUDE_PLUGIN_ROOT='${mutant}' \
            bash '${mutant}/hooks-handlers/session-start.sh' \
            < '${TEST_TMPDIR}/payload.json'"

    [ "$status" -eq 0 ]
    [ "$(_registered_session_id)" = "REAL-UUID-1234" ] || {
        echo "the mutant is simply broken rather than platform-specific: $(cat "${TEST_TMPDIR}/curl-log.txt")"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 4: a missing dependency must be a VISIBLE fault. This handler is the one place in the
# plugin that always has a channel to the model, so this is where an unreadable payload gets said
# out loud rather than passing for healthy.
# ---------------------------------------------------------------------------------------------

@test "req4: an unreadable payload is stated to the model, not swallowed" {
    _run_session_start "$PLUGIN_ROOT" ''
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING FROM MMRY AI"* ]] || {
        echo "an empty payload produced no warning at all: ${output}"
        return 1
    }
    [[ "$output" == *"could not be read from stdin"* ]]
    # Still valid hook JSON: a warning that breaks the contract is a second defect, not a fix.
    [[ "$output" == *'"hookEventName":"SessionStart"'* ]]
    run bash -c "printf '%s' '${output}' | jq -e '.hookSpecificOutput.additionalContext' >/dev/null"
    [ "$status" -eq 0 ]
}

@test "req4: a healthy read says nothing, so the warning means something when it appears" {
    # POSITIVE CONTROL, inverted. A warning printed on every session is a warning nobody reads.
    _run_session_start "$PLUGIN_ROOT" '{"session_id":"S1","hook_event_name":"SessionStart"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING FROM MMRY AI"* ]] || {
        echo "a healthy session was warned, so the warning cannot distinguish the two: ${output}"
        return 1
    }
    [[ "$output" == *"loaded"* ]]
}

@test "req4: the warning is FIRST in the context, not appended after the instructions" {
    # Appended to the end of a long instruction block it would be read after the model had already
    # decided what to do with the turn.
    _run_session_start "$PLUGIN_ROOT" ''
    local ctx
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == "WARNING FROM MMRY AI"* ]] || {
        echo "the warning is not at the front of the context: ${ctx}"
        return 1
    }
}

@test "req4: the fault is also left as a breadcrumb for support to find" {
    _run_session_start "$PLUGIN_ROOT" ''
    [ -s "$FAULT_LOG" ] || { echo "no breadcrumb at ${FAULT_LOG}"; return 1; }
    run grep -c 'session-start' "$FAULT_LOG"
    [ "$output" -ge 1 ]
}

@test "control: with the shipped read, the same total failure is reported as a healthy session" {
    # THE DEFECT ITSELF, stated as a test. The mutant loses the payload completely and its output is
    # indistinguishable from a session that worked - which is why nobody found this for as long as
    # they did, and what requirement 4 exists to end.
    local mutant; mutant="$(_mutant_plugin)"
    _run_session_start "$mutant" '{"session_id":"REAL-UUID-1234","hook_event_name":"SessionStart"}'

    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]] || {
        echo "the mutant warned about its own failure, so req4's tests prove nothing: ${output}"
        return 1
    }
    [[ "$output" == *"loaded"* ]]
    [ ! -s "$FAULT_LOG" ] || {
        echo "the mutant left a breadcrumb it has no code to write: $(cat "$FAULT_LOG")"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------

@test "absence: session-start.sh no longer calls GNU timeout in its code" {
    local code="${TEST_TMPDIR}/ss-code.sh"
    # CODE ONLY. The file explains the defect in a comment that quotes the bad call by name, so a
    # raw grep would match the explanation and report the defect present forever after the fix.
    grep -v '^[[:space:]]*#' "${PLUGIN_ROOT}/hooks-handlers/session-start.sh" > "$code"

    run grep -nE '(^|[^-[:alnum:]])timeout[[:space:]]+[0-9]' "$code"
    [ -z "$output" ] || { echo "GNU timeout is back: ${output}"; return 1; }

    # Control for the stripper and for the pattern: the explanatory comment IS still in the raw file.
    run grep -cE 'timeout[[:space:]]+2[[:space:]]+cat' "${PLUGIN_ROOT}/hooks-handlers/session-start.sh"
    [ "$output" -ge 1 ]

    run grep -c 'mmry_read_hook_payload' "$code"
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------------------------
# THE PAYLOAD MUST SURVIVE THE REGISTRATION, not just the handler.
#
# Claude Code does not run session-start.sh. It runs session-init.sh, which discovers the plugin
# root, copies the handler tree into ~/.claude/mmry, and only then delegates. Two processes and a
# recursive copy stand between the runtime's stdin and the read. Every other test in this file runs
# session-start.sh directly, so none of them would notice if that path dropped stdin - or if the
# copy missed the new library and left the delegate sourcing a file that is not there.
# ---------------------------------------------------------------------------------------------

@test "wiring: the payload survives session-init.sh, the hook Claude Code actually registers" {
    local fake_home="${TEST_TMPDIR}/inithome"
    mkdir -p "${fake_home}/.claude"
    : > "${TEST_TMPDIR}/curl-log.txt"
    printf '%s' '{"session_id":"INIT-UUID-99","hook_event_name":"SessionStart"}' \
        > "${TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${MACOS_BIN}:${PATH}' HOME='${fake_home}' \
            TEST_TMPDIR='${TEST_TMPDIR}' TMPDIR='${TEST_TMPDIR}' MMRY_TMPDIR='${TEST_TMPDIR}' \
            MMRY_CONFIG_FILE='${MMRY_CONFIG_FILE}' CLAUDE_PLUGIN_ROOT='${PLUGIN_ROOT}' \
            bash '${PLUGIN_ROOT}/hooks-handlers/session-init.sh' \
            < '${TEST_TMPDIR}/payload.json'"

    [ "$status" -eq 0 ] || { echo "session-init.sh failed: ${output}"; return 1; }
    [ "$(_registered_session_id)" = "INIT-UUID-99" ] || {
        echo "the id did not survive session-init.sh; registered '$(_registered_session_id)': $(cat "${TEST_TMPDIR}/curl-log.txt")"
        return 1
    }
}

@test "wiring: session-init.sh copies the new reader alongside the handlers that need it" {
    # session-init.sh copies with a *.sh glob today, so this holds by construction - but the two
    # handlers now `source` a sibling that did not exist before, and a copy step that ever became a
    # named list would leave formation-check.sh sourcing a missing file in ~/.claude and exiting
    # silently on every event. That failure would look exactly like the defect being fixed here.
    local fake_home="${TEST_TMPDIR}/copyhome"
    mkdir -p "${fake_home}/.claude"
    printf '%s' '{"session_id":"COPY-1","hook_event_name":"SessionStart"}' \
        > "${TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${MACOS_BIN}:${PATH}' HOME='${fake_home}' \
            TEST_TMPDIR='${TEST_TMPDIR}' TMPDIR='${TEST_TMPDIR}' MMRY_TMPDIR='${TEST_TMPDIR}' \
            MMRY_CONFIG_FILE='${MMRY_CONFIG_FILE}' CLAUDE_PLUGIN_ROOT='${PLUGIN_ROOT}' \
            bash '${PLUGIN_ROOT}/hooks-handlers/session-init.sh' \
            < '${TEST_TMPDIR}/payload.json'"

    [ -f "${fake_home}/.claude/mmry/hooks-handlers/lib-hookread.sh" ] || {
        echo "lib-hookread.sh was not copied into ~/.claude/mmry/hooks-handlers, which is where hooks.json runs the handlers from"
        return 1
    }

    # Control: a file that is definitely copied, so a missing directory cannot make this pass.
    [ -f "${fake_home}/.claude/mmry/hooks-handlers/formation-check.sh" ]

    # And the copied tree must actually work when driven from there, which is how hooks.json runs it.
    run bash -c "env PATH='${MACOS_BIN}:${PATH}' HOME='${fake_home}' \
            TEST_TMPDIR='${TEST_TMPDIR}' TMPDIR='${TEST_TMPDIR}' MMRY_TMPDIR='${TEST_TMPDIR}' \
            MMRY_CONFIG_FILE='${MMRY_CONFIG_FILE}' \
            bash '${fake_home}/.claude/mmry/hooks-handlers/formation-check.sh' \
            < '${TEST_TMPDIR}/payload.json' 2>&1"
    [ "$status" -eq 0 ]
}
