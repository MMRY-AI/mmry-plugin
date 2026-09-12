#!/usr/bin/env bats
# Formation delivery on a machine with no GNU `timeout` (#31385).
#
# THE DEFECT, IN ONE LINE. formation-check.sh read the hook payload with `timeout 2 cat`. GNU
# `timeout` is not on a stock macOS, and the Homebrew coreutils build installs it as `gtimeout`, so
# on any Mac without coreutils that ran a command which does not exist. `2>/dev/null` hid the
# "command not found", `|| true` discarded exit 127, and the payload came back empty with nothing
# reporting a fault. The payload carries hook_event_name, so with it gone EVERY registration fell
# through the handler's case statement to the PostToolUse contract:
#
#   Stop             one un-looped pass instead of a poll, so an idle session was never reached.
#   UserPromptSubmit exit 2 with the block on stderr, which BLOCKS the human's prompt.
#   SessionStart     exit 2 into a runtime that records that as an error and discards the text.
#
# HOW ABSENCE IS MADE THE CONDITION UNDER TEST, RATHER THAN HOPED FOR
# --------------------------------------------------------------------
# Stripping /usr/bin off PATH is not a substitute, because the handler legitimately needs date,
# stat, mkdir, rmdir and tr from the same directory, so the test would fail for reasons that have
# nothing to do with the defect and prove nothing about it.
#
# So `timeout` and `gtimeout` are SHADOWED by shims that behave exactly as a missing command does:
# "command not found" on stderr and exit 127, without running their argument. That is precisely what
# bash presents to the caller on a machine that lacks the binary, and it is the input the old line
# could not survive. The shims also record every invocation, so a control can prove the mutant
# really did reach for the missing binary rather than failing for some other reason.
#
# THIS RUNS ON A MAC, AND HERE IS WHAT THE MAC SAID
# --------------------------------------------------
# For a while this file carried "there is no Mac here" as a standing caveat. That was wrong. The
# repository has had a macos-latest leg in .github/workflows/test.yml since the workflow was
# written; the triggers just never named a branch anybody works on, so it had never fired for code
# under review. `develop` is on the triggers now, and the first run reported:
#
#   which bash     = /Users/runner/stockbash/bash      (pinned to the stock shell by the workflow)
#   bash --version = GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
#   /bin/bash      = GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
#   timeout        = ABSENT
#   gtimeout       = ABSENT
#
# So the two things this file used to record as unproven - real Darwin, and bash 3.2 - are now
# executed results rather than caveats, on the shell macOS actually ships and on a host that
# genuinely lacks the binary. The whole file is green there.
#
# The shims below are kept, and are not redundant. They make absence the condition under test on
# Linux and Windows too, so a regression is caught by whichever host runs first rather than only by
# the Mac. On the Mac they shadow a command that was not there anyway.
#
# WHAT IS STILL NOT PROVEN, recorded rather than glossed: that Claude Code's hook runtime on Darwin
# pipes stdin the way these fixtures do, and the two-machine leg of ticket test cases 3 and 4. Those
# need BETA, not CI.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-macos-$$"
    export MMRY_TEST_TIMEOUT_LOG="${BATS_TEST_TMPDIR}/timeout-invocations.log"
    : > "$MMRY_TEST_TIMEOUT_LOG"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true

    VALID_TRANSMISSION='[{"senderRole":"lead","senderSessionID":"other-session","content":"Heads up: I am touching FormationService.cs","sentDate":"2026-08-30T12:00:00"}]'
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

_safe_sid_for_test() {
    printf '%s' "$CLAUDE_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_'
}

_reset_locks() {
    rm -rf "${TMPDIR}/.mmry-formation-cs-$(_safe_sid_for_test)" \
           "${TMPDIR}/.mmry-formation-poll-$(_safe_sid_for_test)"
}

# A curl that answers from FAKE_BODY / FAKE_CODE, in bash, with no port and no network. Copied
# deliberately from formation-delivery.bats rather than shared: these tests must keep working if
# that file's fixture is changed for its own reasons.
#
# It COUNTS its invocations when MMRY_TEST_CALL_COUNTER is set. That is how the idle tests below
# tell a poll from a single pass. They used to time the handler instead, and a stopwatch cannot make
# that distinction on a slow host: QA deleted the polling behaviour outright and the timing
# assertion still passed, because one non-polling pass on a loaded Windows runner already took
# longer than the two seconds the test demanded. Counting the requests measures the thing the claim
# is actually about - "it kept asking" - and does not vary with how busy the machine is.
_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
if [ -n "${MMRY_TEST_CALL_COUNTER:-}" ]; then
    n=0
    [ -f "$MMRY_TEST_CALL_COUNTER" ] && n="$(cat "$MMRY_TEST_CALL_COUNTER")"
    printf '%s' "$(( n + 1 ))" > "$MMRY_TEST_CALL_COUNTER"
fi
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

# The machine without GNU coreutils. Shims that answer exactly as bash does for a command it cannot
# find, and that record the attempt so a control can show the attempt was actually made.
_macos_shim_dir() {
    local dir="${BATS_TEST_TMPDIR}/macos-bin" c
    mkdir -p "$dir"
    for c in timeout gtimeout; do
        cat > "${dir}/${c}" <<SHIM
#!/usr/bin/env bash
[ -n "\${MMRY_TEST_TIMEOUT_LOG:-}" ] && printf '${c}\n' >> "\$MMRY_TEST_TIMEOUT_LOG"
echo "bash: ${c}: command not found" >&2
exit 127
SHIM
        chmod +x "${dir}/${c}"
    done
    printf '%s' "$dir"
}

# THE CONTROL MACHINE: a host on which `timeout` WORKS.
#
# Every "with the binary present" control needs one, and on the platform this ticket is about there
# isn't one - which is the point. The macOS CI runner reports `timeout ABSENT` and `gtimeout ABSENT`,
# so these controls used to FAIL there, on the very machine that best demonstrates the defect. That
# is the wrong answer twice over: a control failing because its premise holds is not a finding, and
# a red suite on macOS is how the Mac leg gets ignored again.
#
# So the control machine is the host's own GNU timeout where there is one, and a working bash
# stand-in where there is not. Which one was used is reported by _control_timeout_kind and
# asserted, so a control can never quietly run with no timeout at all.
_control_timeout_dir() {
    local dir="${BATS_TEST_TMPDIR}/control-bin"
    mkdir -p "$dir"
    # The kind goes to a FILE, not a variable: this function is called through $(...), so anything
    # it assigns dies with the subshell. A marker that silently never gets set is exactly the dead
    # control this suite keeps having to close.
    if command -v timeout >/dev/null 2>&1; then
        printf 'host' > "${BATS_TEST_TMPDIR}/control-timeout-kind"
        printf '%s' ""
        return 0
    fi
    cat > "${dir}/timeout" <<'STANDIN'
#!/usr/bin/env bash
# A working `timeout DURATION COMMAND...`, in bash, for hosts that have no GNU coreutils.
# stdin is duplicated to fd 3 first: a shell redirects an asynchronous command's stdin from
# /dev/null unless it is given one explicitly, and `timeout 2 cat` is nothing BUT its stdin.
dur="$1"; shift
exec 3<&0
"$@" <&3 &
pid=$!
( sleep "$dur" 2>/dev/null; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watcher=$!
rc=0
wait "$pid" || rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
exit "$rc"
STANDIN
    chmod +x "${dir}/timeout"
    printf 'standin' > "${BATS_TEST_TMPDIR}/control-timeout-kind"
    printf '%s' "${dir}:"
}

# What the control machine's timeout actually was, for the assertions that require one to exist.
_control_timeout_kind() {
    cat "${BATS_TEST_TMPDIR}/control-timeout-kind" 2>/dev/null || printf ''
}

# A copy of the handler directory with the shipped defect deliberately put back: the payload read
# via `timeout 2 cat`. This is the positive control for every behavioural test below. A test that
# only ever asserts correct behaviour has never been watched fail and cannot yet be trusted to
# notice a regression.
_mutant_handler_dir() {
    local dir="${BATS_TEST_TMPDIR}/handlers-mutant"
    rm -rf "$dir"; mkdir -p "$dir"
    cp "${HANDLERS}"/*.sh "$dir"/
    local f="${dir}/formation-check.sh"

    perl -0777 -pi -e 's{^\s*mmry_read_hook_payload[^\n]*\n\s*payload="\$\{MMRY_HOOK_PAYLOAD:-\}"[^\n]*\n\s*hook_read_status="[^\n]*\n}{    payload="\$(timeout 2 cat 2>/dev/null || true)"\n    hook_read_status="ok"\n}m' "$f"

    grep -q 'timeout 2 cat' "$f" || {
        echo "the mutation did not apply, so the control that uses it would prove nothing" >&2
        return 1
    }
    grep -q 'mmry_read_hook_payload' "$f" && {
        echo "the mutation left the fixed read in place as well, so the mutant is not the shipped defect" >&2
        return 1
    }
    bash -n "$f" || { echo "the mutation produced invalid bash" >&2; return 1; }
    printf '%s' "$dir"
}

# Drive a handler directory exactly the way Claude Code does: a real payload on stdin naming the
# event, and NO MMRY_FORMATION_MODE. The override is the seam that hid this class of defect once
# already (#31196 QA round 2), so it is never set here.
#   $1 handler dir   $2 event name   $3 "macos" | "control"
_run_hook() {
    local hdir="$1" event="$2" machine="$3"
    local bin; bin="$(_fake_curl_dir)"
    local shim; shim="$(_macos_shim_dir)"
    local path

    if [[ "$machine" == "macos" ]]; then
        path="${shim}:${bin}:${PATH}"
    else
        local ctl; ctl="$(_control_timeout_dir)"
        path="${bin}:${ctl}${PATH}"
    fi

    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"${event}\"}" \
        > "${BATS_TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${path}' MMRY_TEST_TIMEOUT_LOG='${MMRY_TEST_TIMEOUT_LOG}' \
            FAKE_CODE=200 FAKE_BODY='${VALID_TRANSMISSION}' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
            bash '${hdir}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"
}

# ---------------------------------------------------------------------------------------------
# TICKET TEST CASE 1: the payload is read in full where the binary is absent, and on a machine
# where it is present as a control. Both must report a non-zero length.
# ---------------------------------------------------------------------------------------------

@test "harness: the shim really does shadow timeout, and the real one really is there to shadow" {
    # Neither half of test case 1 means anything unless this holds. Asserted first and separately so
    # a harness fault reports itself rather than being reported as a defect in the handler.
    local shim; shim="$(_macos_shim_dir)"

    # Run WITHOUT bats' `run`: an expected 127 makes it emit a BW01 warning that dumps the whole
    # PATH into the suite output, and a suite nobody can read is a suite nobody checks.
    local out="${BATS_TEST_TMPDIR}/shim-probe.txt" st=0
    env PATH="${shim}:${PATH}" bash -c 'timeout 2 echo SHOULD-NOT-RUN' > "$out" 2>&1 || st=$?
    [ "$st" -eq 127 ] || { echo "the shim did not shadow timeout: ${st} $(cat "$out")"; return 1; }
    grep -q 'SHOULD-NOT-RUN' "$out" && {
        echo "the shim ran its argument, so it is not behaving as a missing command"
        return 1
    }
    grep -q 'command not found' "$out" || {
        echo "the shim did not report itself as missing: $(cat "$out")"
        return 1
    }

    # And the control machine must genuinely have a WORKING timeout, or "with it present" is not a
    # control. On the macOS runner the host has none - `timeout ABSENT`, `gtimeout ABSENT`, which is
    # the ticket's premise confirmed rather than a fault - so a bash stand-in supplies one there.
    local ctl; ctl="$(_control_timeout_dir)"
    [ -n "$(_control_timeout_kind)" ] || { echo "the control machine did not report what it used"; return 1; }
    st=0
    env PATH="${ctl}${PATH}" bash -c 'timeout 2 echo PRESENT' > "$out" 2>&1 || st=$?
    [ "$st" -eq 0 ] || {
        echo "the control machine ($(_control_timeout_kind)) has no working timeout, so the control half of test case 1 is meaningless: $(cat "$out")"
        return 1
    }
    grep -q 'PRESENT' "$out"

    # ...and it must really pass a payload through, which is the only thing the control uses it for.
    st=0
    printf '%s' 'PAYLOAD-THROUGH' | env PATH="${ctl}${PATH}" \
        bash -c 'p="$(timeout 2 cat)"; printf "%s" "$p"' > "$out" 2>&1 || st=$?
    [ "$st" -eq 0 ] && grep -q 'PAYLOAD-THROUGH' "$out" || {
        echo "the control machine's timeout did not pass stdin through ($(_control_timeout_kind), exit ${st}): $(cat "$out")"
        return 1
    }
}

@test "tc1: with timeout ABSENT, the payload is read in full - both fields reach the handler" {
    # "Read in full" is asserted through the only two things the payload is for. The event resolving
    # to SessionStart's contract is only possible if hook_event_name was read, and the delivery
    # happening at all is only possible if session_id was read, because the handler exits at the id
    # check without one and the state was keyed under it.
    _run_hook "$HANDLERS" SessionStart macos

    [ "$status" -eq 0 ] || { echo "expected exit 0 for SessionStart, got ${status}: ${output}"; return 1; }
    [[ "$output" == *'"hookEventName": "SessionStart"'* ]] || {
        echo "hook_event_name did not survive the read: ${output}"
        return 1
    }
    [[ "$output" == *"FormationService.cs"* ]] || {
        echo "nothing was delivered, so session_id did not survive the read: ${output}"
        return 1
    }
    # And it got there without touching the binary that is not on a Mac.
    [ ! -s "$MMRY_TEST_TIMEOUT_LOG" ] || {
        echo "the handler invoked timeout $(wc -l < "$MMRY_TEST_TIMEOUT_LOG") time(s) despite the fix"
        return 1
    }
}

@test "tc1: with timeout PRESENT, the same payload produces the same result - the control machine" {
    _run_hook "$HANDLERS" SessionStart control

    [ "$status" -eq 0 ]
    [[ "$output" == *'"hookEventName": "SessionStart"'* ]]
    [[ "$output" == *"FormationService.cs"* ]]
}

@test "control: with timeout ABSENT the shipped read loses the payload and the event collapses" {
    # POSITIVE CONTROL for both halves above. Same scenario, same shims, the shipped code. The
    # correct answer for SessionStart is exit 0 with additionalContext on stdout; the mutant instead
    # exits 2 with the raw block on stderr, into a runtime that discards it.
    local mutant; mutant="$(_mutant_handler_dir)"
    : > "$MMRY_TEST_TIMEOUT_LOG"

    _run_hook "$mutant" SessionStart macos

    [ "$status" -eq 2 ] || {
        echo "expected the mutant to misread SessionStart as a tool call and exit 2, got ${status}: ${output}"
        return 1
    }
    [[ "$output" != *"hookEventName"* ]] || {
        echo "the mutant honoured the SessionStart contract, so tc1 proves nothing: ${output}"
        return 1
    }
    # And it must have failed for THE REASON UNDER TEST: it reached for the absent binary.
    [ -s "$MMRY_TEST_TIMEOUT_LOG" ] || {
        echo "the mutant never invoked timeout, so it failed for some other reason and this control is not measuring the defect"
        return 1
    }
}

@test "control: the shipped read works fine when timeout IS present, which is why this shipped" {
    # The other half of the control, and the reason the defect reached customers: on every machine
    # the team develops on, the shipped code is correct. A control that only showed the mutant
    # failing would leave open that the mutant is simply broken.
    local mutant; mutant="$(_mutant_handler_dir)"
    _run_hook "$mutant" SessionStart control

    [ "$status" -eq 0 ] || {
        echo "the mutant failed even with timeout present, so it is broken rather than platform-specific: ${status} ${output}"
        return 1
    }
    [[ "$output" == *'"hookEventName": "SessionStart"'* ]]
}

# ---------------------------------------------------------------------------------------------
# TICKET TEST CASE 2: each hook event resolves to its own handling. Named in the ticket: the two
# that end a turn (Stop, SubagentStop), the one that starts a session (SessionStart), and the one
# that submits a prompt (UserPromptSubmit). PostToolUse is included because it is registered too.
# ---------------------------------------------------------------------------------------------

@test "tc2: every registered event resolves to its own contract with timeout absent" {
    local event expect_status
    for event in SessionStart UserPromptSubmit PostToolUse Stop SubagentStop; do
        case "$event" in
            SessionStart|UserPromptSubmit) expect_status=0 ;;
            *)                             expect_status=2 ;;
        esac

        : > "$MMRY_TEST_TIMEOUT_LOG"
        _run_hook "$HANDLERS" "$event" macos

        [ "$status" -eq "$expect_status" ] || {
            echo "event ${event}: expected exit ${expect_status}, got ${status}: ${output}"
            return 1
        }
        [[ "$output" == *"FormationService.cs"* ]] || {
            echo "event ${event}: nothing was delivered: ${output}"
            return 1
        }
        # The two additionalContext events must NAME THEMSELVES. That is the part which silently
        # fell back to the PostToolUse contract, and naming the wrong event is how a SessionStart
        # sweep gets discarded without a word.
        if [ "$expect_status" -eq 0 ]; then
            [[ "$output" == *"\"hookEventName\": \"${event}\""* ]] || {
                echo "event ${event}: wrong or missing hookEventName: ${output}"
                return 1
            }
        else
            [[ "$output" != *"hookEventName"* ]] || {
                echo "event ${event}: emitted additionalContext into a runtime that wants exit 2: ${output}"
                return 1
            }
        fi
        [ ! -s "$MMRY_TEST_TIMEOUT_LOG" ] || {
            echo "event ${event}: the handler invoked the absent binary"
            return 1
        }
    done
}

@test "control: with the shipped read, all five events collapse into one behaviour" {
    # POSITIVE CONTROL for tc2, and the clearest statement of the defect there is. Five distinct
    # registrations, five distinct contracts, and on a Mac the shipped code answered all five the
    # same way. If this ever stops being true the test above has lost its meaning.
    local mutant; mutant="$(_mutant_handler_dir)"
    local event
    for event in SessionStart UserPromptSubmit PostToolUse Stop SubagentStop; do
        _run_hook "$mutant" "$event" macos
        [ "$status" -eq 2 ] || {
            echo "event ${event}: the mutant did NOT collapse to the tool contract (exit ${status}), so tc2's control is not measuring the defect: ${output}"
            return 1
        }
        [[ "$output" != *"hookEventName"* ]] || {
            echo "event ${event}: the mutant honoured a per-event contract: ${output}"
            return 1
        }
    done
}

# ---------------------------------------------------------------------------------------------
# TICKET TEST CASE 4: a message arriving while the customer is typing is handed over WITHOUT
# blocking their prompt.
# ---------------------------------------------------------------------------------------------

@test "tc4: a message arriving at a prompt is handed over quietly, not blocked onto stderr" {
    # UserPromptSubmit is the event that fires as the human submits. The distinction is not
    # cosmetic: exit 2 on that event is a BLOCK, so before the fix a Mac user with a pending
    # formation message had their prompt refused and the message shown as an error.
    _run_hook "$HANDLERS" UserPromptSubmit macos

    [ "$status" -eq 0 ] || {
        echo "a pending message blocked the prompt (exit ${status}): ${output}"
        return 1
    }
    [[ "$output" == *'"hookEventName": "UserPromptSubmit"'* ]]
    [[ "$output" == *"additionalContext"* ]]
    [[ "$output" == *"FormationService.cs"* ]]
}

@test "control: with the shipped read, that same message blocks the prompt" {
    local mutant; mutant="$(_mutant_handler_dir)"
    _run_hook "$mutant" UserPromptSubmit macos
    [ "$status" -eq 2 ] || {
        echo "the mutant did not block the prompt, so tc4 proves nothing: ${status} ${output}"
        return 1
    }
    [[ "$output" != *"additionalContext"* ]]
}

# ---------------------------------------------------------------------------------------------
# TICKET TEST CASE 3, in the part that can be reached without two machines: an idle session is
# reached automatically. Stop with asyncRewake is the only path that can wake a session nobody is
# touching, and it is the path the defect turned into a single un-looped pass.
# ---------------------------------------------------------------------------------------------

# A curl whose FIRST call answers with nothing and whose SECOND answers with the transmission. This
# is the only fixture that can tell an idle POLL from a single pass, and it exists because a
# mutation run showed the obvious version of the test below - one call, message already waiting -
# passing against a handler that had collapsed to the single-pass tool contract. Both behaviours
# deliver on the first call, so the first call cannot be the evidence.
_late_message_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/late-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'LATECURL'
#!/usr/bin/env bash
counter="${MMRY_TEST_CALL_COUNTER:?}"
n=0
[ -f "$counter" ] && n="$(cat "$counter")"
n=$(( n + 1 ))
printf '%s' "$n" > "$counter"

out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
if [ "$n" -ge 2 ]; then
    body="${FAKE_BODY:-[]}"
else
    body='[]'
fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '200'
exit 0
LATECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

@test "tc3: with timeout absent, Stop POLLS - it delivers a message that arrives after it started" {
    # The full ticket test case needs two machines on one account and a real Mac. This is the half
    # that is provable here, and it asserts the mechanism the other half depends on: Stop resolving
    # to the idle contract, which keeps asking, rather than to a single tool-call pass.
    #
    # The message is NOT waiting when the hook starts. It appears on the second request. A single
    # pass therefore cannot deliver it and a poll can, which is the distinction the whole ticket
    # turns on: "coordination messages never reach an IDLE session".
    local shim; shim="$(_macos_shim_dir)"
    local late; late="$(_late_message_curl_dir)"
    local counter="${BATS_TEST_TMPDIR}/call-count"
    rm -f "$counter"

    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"Stop\"}"         > "${BATS_TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${shim}:${late}:${PATH}' MMRY_TEST_CALL_COUNTER='${counter}'             FAKE_BODY='${VALID_TRANSMISSION}'             MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid'             MMRY_IDLE_POLL_SECONDS=6 MMRY_IDLE_POLL_INTERVAL=1             bash '${HANDLERS}/formation-check.sh'             < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"

    [ "$status" -eq 2 ] || {
        echo "Stop did not wake the session for a message that arrived while it was watching (exit ${status}): ${output}"
        return 1
    }
    [[ "$output" == *"FORMATION TRANSMISSION"* ]]
    [[ "$output" == *"FormationService.cs"* ]]

    # Control for the fixture: it must genuinely have been asked more than once, or "it polled" is
    # an inference rather than an observation.
    local calls; calls="$(cat "$counter")"
    [ "$calls" -ge 2 ] || {
        echo "the handler made ${calls} request(s), so it did not poll and the delivery came from somewhere else"
        return 1
    }
}

@test "control: with the shipped read, a message that arrives late is never delivered at all" {
    # POSITIVE CONTROL for the test above, and the literal headline of the ticket. The mutant
    # collapses Stop to a single pass, so it asks once, finds nothing, and exits silently. The
    # message that landed a second later reaches nobody.
    local mutant; mutant="$(_mutant_handler_dir)"
    local shim; shim="$(_macos_shim_dir)"
    local late; late="$(_late_message_curl_dir)"
    local counter="${BATS_TEST_TMPDIR}/call-count-mutant"
    rm -f "$counter"

    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"Stop\"}"         > "${BATS_TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${shim}:${late}:${PATH}' MMRY_TEST_CALL_COUNTER='${counter}'             CLAUDE_SESSION_ID='${CLAUDE_SESSION_ID}'             FAKE_BODY='${VALID_TRANSMISSION}'             MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid'             MMRY_IDLE_POLL_SECONDS=6 MMRY_IDLE_POLL_INTERVAL=1             bash '${mutant}/formation-check.sh'             < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"

    [ "$status" -eq 0 ] || {
        echo "the mutant delivered the late message, so the test above proves nothing: ${status} ${output}"
        return 1
    }
    [[ "$output" != *"FormationService.cs"* ]]

    local calls; calls="$(cat "$counter" 2>/dev/null || printf '0')"
    [ "$calls" -eq 1 ] || {
        echo "the mutant made ${calls} request(s); it was expected to ask exactly once and give up"
        return 1
    }
}

@test "tc3: with timeout absent and nothing pending, Stop polls and then gives up in silence" {
    # The other half of the idle contract, and the "worse defect" guard: a Stop hook that exited 2
    # with nothing to say would wake the model for no reason. Also the assertion that distinguishes
    # a poll from a single pass - with an empty response the handler must keep ASKING.
    #
    # WHY THIS COUNTS REQUESTS RATHER THAN SECONDS. It used to assert the handler took at least 2s
    # against a 3s budget. QA deleted the polling behaviour outright and this test still passed on
    # Windows, because a single non-polling pass on a slow host already exceeds two seconds - the
    # stopwatch was measuring host load, not looping. The same mutant died on Linux, so the reading
    # was a host artifact rather than a wrong idea, but an assertion that only discriminates on the
    # faster of two supported platforms is not an assertion. The request count is the evidence the
    # claim is actually made of, it is what the late-message test above already uses, and it does
    # not move with the weather.
    local bin; bin="$(_fake_curl_dir)"
    local shim; shim="$(_macos_shim_dir)"
    local counter="${BATS_TEST_TMPDIR}/idle-call-count"
    rm -f "$counter"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"Stop\"}" \
        > "${BATS_TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${shim}:${bin}:${PATH}' MMRY_TEST_CALL_COUNTER='${counter}' \
            FAKE_CODE=200 FAKE_BODY='[]' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            MMRY_IDLE_POLL_SECONDS=3 MMRY_IDLE_POLL_INTERVAL=1 \
            bash '${HANDLERS}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"

    [ "$status" -eq 0 ] || { echo "the poller woke the model with nothing to say: ${status} ${output}"; return 1; }
    [ -z "$output" ]

    # It must have LOOPED. A single un-looped pass - the shipped behaviour on a Mac - asks once and
    # returns. Anything that asked more than once against an always-empty server was polling.
    local calls; calls="$(cat "$counter" 2>/dev/null || printf '0')"
    [ "$calls" -ge 2 ] || {
        echo "Stop made ${calls} request(s) against a 3s budget at a 1s interval, so it did not poll"
        return 1
    }
}

@test "control: with the shipped read, Stop asks once instead of polling" {
    # POSITIVE CONTROL for the test above. This is the headline symptom of the ticket - "coordination
    # messages never reach an idle session" - reproduced. Counted, not timed, for the reason given
    # above: the stopwatch version of this pair could not reliably tell the mutant from the fix on a
    # slow host, which is precisely the pair it exists to separate.
    local mutant; mutant="$(_mutant_handler_dir)"
    local bin; bin="$(_fake_curl_dir)"
    local shim; shim="$(_macos_shim_dir)"
    local mutant_counter="${BATS_TEST_TMPDIR}/idle-mutant-count"
    local fixed_counter="${BATS_TEST_TMPDIR}/idle-fixed-count"
    rm -f "$mutant_counter" "$fixed_counter"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    printf '%s' "{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"Stop\"}" \
        > "${BATS_TEST_TMPDIR}/payload.json"

    run bash -c "env PATH='${shim}:${bin}:${PATH}' CLAUDE_SESSION_ID='${CLAUDE_SESSION_ID}' \
            MMRY_TEST_CALL_COUNTER='${mutant_counter}' \
            FAKE_CODE=200 FAKE_BODY='[]' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            MMRY_IDLE_POLL_SECONDS=8 MMRY_IDLE_POLL_INTERVAL=1 \
            bash '${mutant}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"

    local mutant_calls; mutant_calls="$(cat "$mutant_counter" 2>/dev/null || printf '0')"
    [ "$mutant_calls" -eq 1 ] || {
        echo "the mutant made ${mutant_calls} request(s) against an 8s budget; it was expected to ask exactly once and give up, so this control proves nothing"
        return 1
    }

    # A/B, not a single reading. "Asked once" on its own is also what a handler that died on line one
    # looks like, and the mutant differs from the real handler in exactly one line, so the comparison
    # has to be against the real handler in the IDENTICAL setup.
    _reset_locks
    run bash -c "env PATH='${shim}:${bin}:${PATH}' CLAUDE_SESSION_ID='${CLAUDE_SESSION_ID}' \
            MMRY_TEST_CALL_COUNTER='${fixed_counter}' \
            FAKE_CODE=200 FAKE_BODY='[]' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            MMRY_IDLE_POLL_SECONDS=8 MMRY_IDLE_POLL_INTERVAL=1 \
            bash '${HANDLERS}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/payload.json' 2>&1"

    local fixed_calls; fixed_calls="$(cat "$fixed_counter" 2>/dev/null || printf '0')"
    [ "$fixed_calls" -gt "$mutant_calls" ] || {
        echo "the FIXED handler made ${fixed_calls} request(s) too, so the mutant asking ${mutant_calls} time(s) is not evidence of anything"
        return 1
    }
    [ "$fixed_calls" -ge 2 ]
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 4: a missing dependency must be a VISIBLE fault, not something that passes as healthy.
# formation-check.sh is forbidden from telling the model (it runs in every session and its governing
# rule is to fail open and silent), so it leaves a breadcrumb instead. Silence is not the same as
# untraceability, and conflating the two is what let this defect live.
# ---------------------------------------------------------------------------------------------

@test "req4: an empty payload from a live pipe is recorded as a fault" {
    local bin; bin="$(_fake_curl_dir)"
    local shim; shim="$(_macos_shim_dir)"
    local log="${TMPDIR}/mmry-hook-read-faults.log"
    rm -f "$log"

    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    _reset_locks
    : > "${BATS_TEST_TMPDIR}/empty.json"

    run bash -c "env PATH='${shim}:${bin}:${PATH}' TMPDIR='${TMPDIR}' \
            CLAUDE_SESSION_ID='${CLAUDE_SESSION_ID}' \
            FAKE_CODE=200 FAKE_BODY='[]' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            bash '${HANDLERS}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/empty.json' 2>&1"

    [ -s "$log" ] || {
        echo "an empty payload left no trace at all, which is the fault this ticket exists to end"
        return 1
    }

    # THE EXACT CALLER, not a prefix. A mutation run showed the loose version of this passing
    # against a handler whose read-fault breadcrumb had been deleted outright, because the separate
    # "event unresolved" breadcrumb written further down also contains the string "formation-check"
    # and satisfied the grep. A check that any one of several writers can satisfy is not a check on
    # the one it is named after.
    run awk -F'	' '$2 == "formation-check" { n++ } END { print n+0 }' "$log"
    [ "$output" -ge 1 ] || {
        echo "the read fault itself was not recorded; the log holds only: $(cat "$log")"
        return 1
    }
}

@test "req4: a payload that DID arrive records nothing, so the breadcrumb means something" {
    # POSITIVE CONTROL, inverted: a log that is written on every run is not evidence of anything.
    local log="${TMPDIR}/mmry-hook-read-faults.log"
    rm -f "$log"

    _run_hook "$HANDLERS" SessionStart macos

    [ ! -s "$log" ] || {
        echo "a healthy run recorded a fault, so the breadcrumb cannot distinguish the two: $(cat "$log")"
        return 1
    }
}

@test "req4: the hook still fails open - a fault never breaks the session" {
    # The governing rule of this handler outranks the reporting. Whatever else an empty payload
    # does, it must not make the hook non-zero on a path Claude Code treats as blocking.
    local bin; bin="$(_fake_curl_dir)"
    local shim; shim="$(_macos_shim_dir)"
    : > "${BATS_TEST_TMPDIR}/empty.json"
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID"

    run bash -c "env PATH='${shim}:${bin}:${PATH}' \
            FAKE_CODE=200 FAKE_BODY='[]' \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL='http://fake.invalid' \
            bash '${HANDLERS}/formation-check.sh' \
            < '${BATS_TEST_TMPDIR}/empty.json' 2>&1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 2, as an absence check. Read from CODE ONLY: the handler explains this defect in a
# comment that quotes the bad call by name, so a raw grep matches the explanation and reports the
# defect present forever after it was fixed.
# ---------------------------------------------------------------------------------------------

_code_only() {
    grep -v '^[[:space:]]*#' "$1"
}

@test "req2: every registered hook event is matched by name, not absorbed by the catch-all" {
    # PostToolUse used to arrive through the catch-all, which made that branch both the right answer
    # for one event and the failure mode for all the others - indistinguishable from outside, which
    # is exactly how this passed for healthy.
    local code="${BATS_TEST_TMPDIR}/check-code.sh"
    _code_only "${HANDLERS}/formation-check.sh" > "$code"

    local ev
    for ev in Stop SubagentStop SessionStart UserPromptSubmit PostToolUse; do
        run grep -c "$ev" "$code"
        [ "$output" -ge 1 ] || { echo "${ev} is not named in the handler's code"; return 1; }
    done

    # Control for the stripper: it must not have eaten the case statement wholesale.
    run grep -c 'mode="tool"' "$code"
    [ "$output" -ge 1 ]
}

@test "req2: the handler no longer calls GNU timeout anywhere in its code" {
    local code="${BATS_TEST_TMPDIR}/check-code2.sh"
    _code_only "${HANDLERS}/formation-check.sh" > "$code"

    run grep -nE '(^|[^-[:alnum:]])timeout[[:space:]]+[0-9]' "$code"
    [ -z "$output" ] || { echo "GNU timeout is back: ${output}"; return 1; }

    # Control for the stripper AND the pattern: the comment that explains the defect is still in the
    # raw file, so a check reading the raw file would match it and could never pass.
    run grep -cE 'timeout[[:space:]]+2[[:space:]]+cat' "${HANDLERS}/formation-check.sh"
    [ "$output" -ge 1 ] || {
        echo "the explanatory comment is gone, so this control no longer demonstrates why _code_only is needed"
        return 1
    }
}

@test "req2: the handler sources the shared reader rather than rolling its own" {
    local code="${BATS_TEST_TMPDIR}/check-code3.sh"
    _code_only "${HANDLERS}/formation-check.sh" > "$code"
    run grep -c 'lib-hookread.sh' "$code"
    [ "$output" -ge 1 ]
    run grep -c 'mmry_read_hook_payload' "$code"
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 5: correct the customer guidance that sends a Mac user down a dead end.
#
# The reporter was on a client version well above the documented floor. The guidance named exactly
# one cause for a member not receiving while idle - Claude Code older than 2.1.64 - so anyone
# following it checked their version, found nothing wrong, and stopped. The plugin version, which
# was the actual cause, was never mentioned as a thing to check.
# ---------------------------------------------------------------------------------------------

@test "req5: the formation page names the plugin version floor, not only the client version" {
    local doc="${BATS_TEST_DIRNAME}/../../commands/formation.md"
    run grep -c '2\.9\.1' "$doc"
    [ "$output" -ge 1 ] || {
        echo "the plugin version that fixes macOS delivery is not stated where support will look"
        return 1
    }
    run grep -ci 'mac' "$doc"
    [ "$output" -ge 1 ]

    # Control for the assertion above: the CLIENT floor must still be there. Replacing one dead end
    # with another would pass a naive version check.
    run grep -c '2\.1\.64' "$doc"
    [ "$output" -ge 1 ] || {
        echo "the Claude Code floor was removed, which trades one incomplete answer for another"
        return 1
    }
}

@test "req5: the help page tells a Mac user to check both versions" {
    local doc="${BATS_TEST_DIRNAME}/../../commands/help.md"
    run grep -c '2\.9\.1' "$doc"
    [ "$output" -ge 1 ] || { echo "help.md still names only the client version"; return 1; }
    run grep -c '2\.1\.64' "$doc"
    [ "$output" -ge 1 ]
}

@test "req5: the stated floor is a version that has actually been released" {
    # WHAT THIS IS FOR. A documented floor that names a version nobody can install is worse than
    # none: it sends support to check for something that was never released.
    #
    # WHAT IT MUST NOT DO, learned the hard way in #31460. This previously demanded the floor equal
    # the CURRENT manifest version. That held for exactly one release - the one that shipped the
    # macOS payload fix - and then broke the moment any later work bumped the version, which is
    # every release forever. Worse, the only way to satisfy it was to rewrite a true statement
    # ("fixed in plugin 2.9.1") into a false one, telling users already holding the fix to go and
    # update for it. A test that can only be satisfied by making the documentation lie is a test
    # that will be edited under release pressure, so it is fixed here instead.
    #
    # The real requirement is that the floor is RELEASED: at or below the version being shipped.
    local plugin_json="${BATS_TEST_DIRNAME}/../../.claude-plugin/plugin.json"
    local doc="${BATS_TEST_DIRNAME}/../../commands/formation.md"
    local ver floor
    ver="$(grep -o '"version"[^"]*"[^"]*"' "$plugin_json" | head -1 | grep -o '[0-9][^"]*')"
    [ -n "$ver" ]

    # The floor formation.md actually states for the macOS payload fix.
    floor="$(grep -o 'Fixed in plugin [0-9][0-9.]*' "$doc" | head -1 | grep -o '[0-9][0-9.]*')"
    [ -n "$floor" ] || {
        echo "formation.md no longer states a plugin floor for the macOS payload fix at all"
        return 1
    }

    # Released means: not newer than what is shipping. sort -V puts the lower version first.
    [ "$(printf '%s
%s
' "$floor" "$ver" | sort -V | head -1)" = "$floor" ] || {
        echo "formation.md names floor ${floor}, which is NEWER than the shipped version ${ver} - nobody can install it"
        return 1
    }

    # And the page must still tell a Mac user to check that floor.
    run grep -c "$floor" "$doc"
    [ "$output" -ge 1 ]
}

@test "req5: the shipped version is newer than the last released one, or nobody gets this fix" {
    # THE TRAP THIS PRODUCT HAS HIT BEFORE. The marketplace decides whether to update by comparing
    # version numbers, so a fix committed at a version that has already shipped reaches nobody. Both
    # manifests must move, and they must move together - marketplace-sync.bats owns the "together"
    # half; this owns the "moved at all" half, against the value that was on the trunk before it.
    local plugin_json="${BATS_TEST_DIRNAME}/../../.claude-plugin/plugin.json"
    local ver
    ver="$(grep -o '"version"[^"]*"[^"]*"' "$plugin_json" | head -1 | grep -o '[0-9][^"]*')"
    [ "$ver" != "2.9.0" ] || {
        echo "the version is still 2.9.0, which is already released, so auto-update would skip this fix entirely"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# THE PAYLOAD HAS TO SURVIVE THE WHOLE REGISTRATION, not just the handler.
#
# Every test above runs formation-check.sh directly. Claude Code does not: it runs the command
# string in hooks.json, which is a `bash -c` that tests for a file and then runs hook-guard.sh,
# which runs the handler. Three processes stand between the runtime's stdin and the read. If any of
# them consumed or dropped it, every assertion above would still pass and the product would still
# be broken - which is the same shape of gap as testing only through MMRY_FORMATION_MODE.
# ---------------------------------------------------------------------------------------------

@test "wiring: the payload reaches the handler through the real registration chain" {
    # A fake ~/.claude tree holding the guard and a probe standing in for the handler, driven by the
    # EXACT command string lifted out of hooks.json rather than a reconstruction of it.
    local fake_home="${BATS_TEST_TMPDIR}/fakehome"
    local hh="${fake_home}/.claude/mmry/hooks-handlers"
    mkdir -p "$hh"
    cp "${HANDLERS}/hook-guard.sh" "$hh/"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo "source \"${HANDLERS}/lib-hookread.sh\""
        echo 'mmry_read_hook_payload 2 || true'
        echo 'printf "STATUS=%s LEN=%s\n" "$MMRY_HOOK_READ_STATUS" "${#MMRY_HOOK_PAYLOAD}"'
    } > "${hh}/formation-check.sh"
    chmod +x "${hh}/formation-check.sh" "${hh}/hook-guard.sh"

    # The registration, taken from hooks.json so it cannot drift away from what actually ships.
    local cmd
    cmd="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.Stop||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));process.stdout.write(s[0].command);' \
        "${BATS_TEST_DIRNAME}/../../hooks/hooks.json")"
    [ -n "$cmd" ] || { echo "could not read the Stop registration out of hooks.json"; return 1; }

    local payload='{"session_id":"WIRE-1","hook_event_name":"Stop"}'
    printf '%s' "$payload" > "${BATS_TEST_TMPDIR}/wire.json"

    local shim; shim="$(_macos_shim_dir)"
    run bash -c "env HOME='${fake_home}' PATH='${shim}:${PATH}' bash -c \"${cmd//\"/\\\"}\" < '${BATS_TEST_TMPDIR}/wire.json' 2>&1"

    [[ "$output" == *"STATUS=ok"* ]] || {
        echo "the payload did not survive the registration chain: ${output}"
        return 1
    }
    [[ "$output" == *"LEN=${#payload}"* ]] || {
        echo "the payload arrived truncated through the registration chain: ${output} (expected LEN=${#payload})"
        return 1
    }
}

@test "control: the wiring test notices when the chain swallows stdin" {
    # POSITIVE CONTROL. The test above passes if the chain is intact; this shows it fails when it is
    # not, by replacing the guard with one that reads stdin itself before handing over - the exact
    # mistake it exists to catch.
    local fake_home="${BATS_TEST_TMPDIR}/fakehome-bad"
    local hh="${fake_home}/.claude/mmry/hooks-handlers"
    mkdir -p "$hh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'while IFS= read -r _; do :; done   # swallow stdin'
        echo 'exec bash "${HOME}/.claude/mmry/hooks-handlers/${1}.sh"'
    } > "${hh}/hook-guard.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo "source \"${HANDLERS}/lib-hookread.sh\""
        echo 'mmry_read_hook_payload 1 || true'
        echo 'printf "STATUS=%s LEN=%s\n" "$MMRY_HOOK_READ_STATUS" "${#MMRY_HOOK_PAYLOAD}"'
    } > "${hh}/formation-check.sh"
    chmod +x "${hh}/formation-check.sh" "${hh}/hook-guard.sh"

    local cmd
    cmd="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const s=(d.hooks.Stop||[]).flatMap(g=>g.hooks).filter(h=>h.command.includes("formation-check"));process.stdout.write(s[0].command);' \
        "${BATS_TEST_DIRNAME}/../../hooks/hooks.json")"
    printf '%s' '{"session_id":"WIRE-1","hook_event_name":"Stop"}' > "${BATS_TEST_TMPDIR}/wire.json"

    run bash -c "env HOME='${fake_home}' bash -c \"${cmd//\"/\\\"}\" < '${BATS_TEST_TMPDIR}/wire.json' 2>&1"

    [[ "$output" != *"STATUS=ok"* ]] || {
        echo "a guard that eats stdin still reported a good read, so the wiring test proves nothing: ${output}"
        return 1
    }
}
