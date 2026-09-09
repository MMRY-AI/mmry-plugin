#!/usr/bin/env bats
# lib-hookread.sh - reading the Claude Code hook payload without GNU coreutils (#31385).
#
# WHAT THESE TESTS CAN AND CANNOT PROVE, STATED UP FRONT
# ------------------------------------------------------
# The defect is "a command absent from macOS", and there is no Mac in this test environment. A test
# that ran on a Mac and passed would prove the fix; a test that hopes the reader has a Mac proves
# nothing at all. So absence is made the CONDITION UNDER TEST rather than a property of the host:
#
#   PATH="" is the strongest available form of "the binary is not there". With an empty PATH the
#   shell can execute NO external command whatsoever - not timeout, not gtimeout, not cat. Anything
#   that still works under it is provably built out of shell builtins and nothing else, which is the
#   exact property the fix claims and the exact property the old `timeout 2 cat` did not have.
#
# What that does NOT establish, and is recorded on the ticket rather than glossed here: that bash
# 3.2 (the bash macOS ships at /bin/bash) behaves identically to the bash running this suite, and
# that a real Darwin hook runtime pipes stdin the way the fixture does. Only a Mac settles those.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    LIB="${HANDLERS}/lib-hookread.sh"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    PROBE="${BATS_TEST_TMPDIR}/probe.sh"
    _write_probe
}

# One call of the reader in a clean shell, printing a machine-readable result. The shell is started
# with `set -euo pipefail` because every handler that calls this runs under those options, and a
# reader that only survived without them would be a reader that kills its callers.
#
# PATH is whatever the caller sets: the point of most tests below is to set it to nothing.
# The PATH is emptied INSIDE the probe, not around it. The first attempt at this file wrapped the
# probe in `env PATH='' bash ...`, which cannot work: with no PATH the shell cannot find `bash`
# itself, so every one of those runs exited 127 having never executed the code under test. They
# failed loudly, which is the only reason it was caught, and the lesson is kept here because a
# harness that cannot start its own subject is the exact shape of a test that proves nothing.
#
# Emptying it after the source is just as strict for this purpose: `source` needs no PATH, and the
# reader has not run yet. Every probe run therefore reports PATHCONTROL, and every test below
# asserts it, so no assertion can pass on a run where absence was never actually simulated.
_write_probe() {
    {
        echo 'set -euo pipefail'
        echo "source \"${LIB}\""
        echo 'PATH=""; export PATH'
        echo 'if command -v timeout >/dev/null 2>&1; then'
        echo '    printf "PATHCONTROL=timeout-STILL-REACHABLE\n"'
        echo 'else'
        echo '    printf "PATHCONTROL=clean\n"'
        echo 'fi'
        echo 'rc=0'
        echo 'mmry_read_hook_payload "${1:-2}" || rc=$?'
        echo 'printf "rc=%s\n" "$rc"'
        echo 'printf "status=%s\n" "$MMRY_HOOK_READ_STATUS"'
        echo 'printf "len=%s\n" "${#MMRY_HOOK_PAYLOAD}"'
        echo 'printf "payload=[%s]\n" "$MMRY_HOOK_PAYLOAD"'
        echo 'printf "elapsed=%s\n" "$SECONDS"'
    } > "$PROBE"
}

# Every probe run must confirm it really had no PATH. Asserted by every test that uses the probe.
_assert_path_was_empty() {
    [[ "$1" == *"PATHCONTROL=clean"* ]] || {
        echo "the probe ran with timeout still reachable, so this assertion proves nothing: $1"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# The headline: it works where no external command exists at all.
# ---------------------------------------------------------------------------------------------

@test "no-coreutils: a payload is read in full with an EMPTY PATH, where no external command exists" {
    # THE CENTRAL ASSERTION OF #31385. The shipped code read the payload with `timeout 2 cat`, two
    # external binaries, one of which is simply not present on a stock macOS. Under PATH="" neither
    # is reachable and neither is anything else, so passing this is proof by construction that the
    # read is built from builtins.
    local json='{"session_id":"abc-123","hook_event_name":"Stop"}'

    # Control for the harness itself: under an empty PATH an external command really is unreachable,
    # or this test is measuring nothing. Asked of the shell directly - `env PATH="" bash -c ...`
    # would answer 127 because it could not find BASH, which looks identical and proves the wrong
    # thing.
    run bash -c 'PATH=""; export PATH; command -v timeout'
    [ "$status" -ne 0 ] || {
        echo "timeout is still resolvable with an empty PATH (${output}), so absence was never simulated"
        return 1
    }
    [ -z "$output" ]
    # ... and the same question asked WITH a PATH must answer yes, or the check above is vacuous.
    run bash -c 'command -v timeout'
    [ "$status" -eq 0 ] || {
        echo "this host has no timeout at all, so the control-vs-stripped comparison is meaningless"
        return 1
    }

    run bash -c "printf '%s' '${json}' | bash '${PROBE}' 2"
    [ "$status" -eq 0 ]
    _assert_path_was_empty "$output"
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"status=ok"* ]]
    [[ "$output" == *"len=${#json}"* ]] || {
        echo "expected the whole ${#json}-byte payload, got: ${output}"
        return 1
    }
    [[ "$output" == *"payload=[${json}]"* ]]
}

@test "control: the same payload under an empty PATH is lost by the shipped timeout-based read" {
    # POSITIVE CONTROL for the test above. It asserts the payload survives; this shows the identical
    # scenario destroys the payload for the code that was actually shipped, so the assertion is
    # discriminating rather than vacuously true of any implementation.
    local old="${BATS_TEST_TMPDIR}/old-read.sh"
    {
        echo 'set -euo pipefail'
        echo 'PATH=""; export PATH'
        echo 'payload="$(timeout 2 cat 2>/dev/null || true)"'
        echo 'printf "len=%s\n" "${#payload}"'
    } > "$old"

    local json='{"session_id":"abc-123","hook_event_name":"Stop"}'
    run bash -c "printf '%s' '${json}' | bash '${old}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"len=0"* ]] || {
        echo "the shipped read did NOT lose the payload here, so the test above proves nothing: ${output}"
        return 1
    }
}

@test "no-coreutils: a payload with NO trailing newline is not truncated" {
    # The hook payload frequently arrives without one. `read` reports failure on a partial final
    # line while still filling the variable, so an implementation that inspects the return code
    # before the variable silently drops the entire payload.
    run bash -c "printf '%s' '{\"a\":1}' | bash '${PROBE}' 2"
    _assert_path_was_empty "$output"
    [[ "$output" == *"status=ok"* ]]
    [[ "$output" == *'payload=[{"a":1}]'* ]] || {
        echo "a payload with no trailing newline was mangled: ${output}"
        return 1
    }
}

@test "no-coreutils: a multi-line payload is read in full, not just its first line" {
    local f="${BATS_TEST_TMPDIR}/multi.json"
    printf '{\n  "session_id": "s1",\n  "hook_event_name": "SessionStart"\n}\n' > "$f"
    run bash -c "bash '${PROBE}' 2 < '${f}'"
    _assert_path_was_empty "$output"
    [[ "$output" == *"status=ok"* ]]
    [[ "$output" == *'"session_id": "s1"'* ]]
    [[ "$output" == *'"hook_event_name": "SessionStart"'* ]] || {
        echo "only the first line survived: ${output}"
        return 1
    }
}

@test "no-coreutils: what was read is still valid JSON to the project's own jq" {
    # Reading the bytes is necessary and not sufficient - they have to survive in a shape the parser
    # downstream accepts. A reader that dropped or reordered newlines would pass every length
    # assertion above and still break both call sites.
    local f="${BATS_TEST_TMPDIR}/multi2.json"
    printf '{\n  "session_id": "s9",\n  "hook_event_name": "Stop"\n}\n' > "$f"

    local rebuilt="${BATS_TEST_TMPDIR}/rebuilt.sh"
    {
        echo 'set -euo pipefail'
        echo "source \"${LIB}\""
        echo 'PATH=""; export PATH'
        echo 'mmry_read_hook_payload 2 || true'
        echo 'printf "%s" "$MMRY_HOOK_PAYLOAD"'
    } > "$rebuilt"

    # shellcheck source=/dev/null
    source "${HANDLERS}/lib-jq.sh"
    mmry_resolve_jq

    run bash -c "bash '${rebuilt}' < '${f}' | '${MMRY_JQ}' -r '.hook_event_name'"
    [ "$status" -eq 0 ]
    [ "$output" = "Stop" ] || {
        echo "the reconstructed payload did not parse back to its event name: ${output}"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# An empty read must SAY SO. This is the second half of the defect and the harder half: the missing
# binary was survivable; being unable to tell a total failure from a quiet hook was not.
# ---------------------------------------------------------------------------------------------

@test "empty read: zero bytes from a live pipe is its own status, not an ordinary quiet payload" {
    run bash -c "printf '' | bash '${PROBE}' 2"
    [ "$status" -eq 0 ]
    _assert_path_was_empty "$output"
    [[ "$output" == *"rc=2"* ]] || { echo "expected rc=2 for an empty read: ${output}"; return 1; }
    [[ "$output" == *"status=empty"* ]]
    [[ "$output" == *"len=0"* ]]
}

@test "empty read: 'empty' and 'ok' are distinguishable, which is the whole point" {
    # Stated as one test on purpose. The defect was not that the payload was empty; it was that
    # empty and present produced the SAME observable. If these two ever collapse to one value the
    # fault becomes invisible again, no matter how the read itself is implemented.
    run bash -c "printf '' | bash '${PROBE}' 2"
    _assert_path_was_empty "$output"
    local empty_out="$output"
    run bash -c "printf 'x' | bash '${PROBE}' 2"
    local ok_out="$output"

    [[ "$empty_out" == *"status=empty"* ]]
    [[ "$ok_out" == *"status=ok"* ]]
    [ "$empty_out" != "$ok_out" ]
}

@test "control: the shipped read cannot tell an empty pipe from a full one" {
    # POSITIVE CONTROL for the test above. `timeout 2 cat` on a machine without timeout returns the
    # same empty string as a genuinely empty pipe does on a machine with it, and both come back
    # through `|| true` as success. That indistinguishability is the defect, and here it is.
    local old="${BATS_TEST_TMPDIR}/old-read2.sh"
    {
        echo 'set -euo pipefail'
        echo '[ "${STRIP_PATH:-0}" = "1" ] && { PATH=""; export PATH; }'
        echo 'rc=0'
        echo 'payload="$(timeout 2 cat 2>/dev/null || true)" || rc=$?'
        echo 'printf "rc=%s len=%s\n" "$rc" "${#payload}"'
    } > "$old"

    # Machine WITHOUT timeout, payload present.
    run bash -c "printf '%s' '{\"a\":1}' | STRIP_PATH=1 bash '${old}'"
    local no_binary="$output"
    # Machine WITH timeout, pipe genuinely empty.
    run bash -c "printf '' | STRIP_PATH=0 bash '${old}'"
    local genuinely_empty="$output"

    [ "$no_binary" = "$genuinely_empty" ] || {
        echo "the shipped read distinguished the two cases ('${no_binary}' vs '${genuinely_empty}'), so there was nothing to fix"
        return 1
    }
}

@test "timeout: a stream that never closes ends the read rather than hanging the session" {
    # The 2s cap in the old line was there for a reason and the replacement must keep it. The budget
    # is a whole-payload deadline, not a per-line one: a stream emitting a line just inside a
    # per-line timeout forever would otherwise never expire.
    # The WRITER needs sleep, so it runs with a normal PATH. The READER still runs with none.
    #
    # ELAPSED TIME IS REPORTED BY THE PROBE, not by a stopwatch around the pipeline. A stopwatch
    # outside also times the writer's `sleep 6`, so it reads about six seconds however quickly the
    # reader gave up - a measurement that can only ever report failure. It was watched doing exactly
    # that before this was corrected.
    run bash -c "{ printf 'first
'; sleep 6; } | bash '${PROBE}' 1"

    [ "$status" -eq 0 ]
    _assert_path_was_empty "$output"
    [[ "$output" == *"rc=3"* ]] || { echo "expected rc=3 (timeout): ${output}"; return 1; }
    [[ "$output" == *"status=timeout"* ]]

    local elapsed
    elapsed="$(printf '%s' "$output" | sed -n 's/^elapsed=//p')"
    [ -n "$elapsed" ] || { echo "the probe reported no elapsed time: ${output}"; return 1; }
    [ "$elapsed" -lt 4 ] || {
        echo "the reader itself took ${elapsed}s against a 1s budget, so the budget was not enforced"
        return 1
    }
}

@test "timeout: the budget is a WHOLE-PAYLOAD deadline, not a fresh one for every line" {
    # A mutation run showed the test above surviving a reader whose deadline was recomputed on each
    # line - because a writer that sends one line and then stops still trips a per-line timeout at
    # the same moment. The distinction only shows against a stream that keeps DRIP-FEEDING: with a
    # per-line budget it never expires, and the hook hangs until Claude Code kills it. That is the
    # hang the original 2s cap existed to prevent, and this file claimed the whole-payload property
    # in a comment for a while before anything checked it.
    #
    # One line per second against a 3s budget. A correct reader gives up at about 3s.
    #
    # THE WRITER STOPS ITSELF AFTER 20 SECONDS, and that bound is not cosmetic. The first version of
    # this test used `while :;` - a genuinely endless stream - and against a reader with a per-line
    # budget the pipeline never terminated, so the mutation run HUNG here instead of reporting a
    # failure. A test that hangs on the defect it is named after is only marginally better than one
    # that misses it: CI reports an infrastructure timeout rather than a broken deadline, and
    # somebody reruns it. A correct reader still finishes in ~3s; a broken one finishes in ~20s and
    # the elapsed assertion below says so out loud.
    local writer="${BATS_TEST_TMPDIR}/dripfeed.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'end=$(( SECONDS + 20 ))'
        echo 'while [ "$SECONDS" -lt "$end" ]; do printf "drip
"; sleep 1; done'
    } > "$writer"
    chmod +x "$writer"

    run bash -c "bash '${writer}' 2>/dev/null | bash '${PROBE}' 3"

    [ "$status" -eq 0 ]
    _assert_path_was_empty "$output"
    [[ "$output" == *"rc=3"* ]] || {
        echo "the reader did not report a timeout against a stream that never ends: ${output}"
        return 1
    }

    local elapsed
    elapsed="$(printf '%s' "$output" | sed -n 's/^elapsed=//p')"
    [ -n "$elapsed" ]
    [ "$elapsed" -le 6 ] || {
        echo "the reader ran for ${elapsed}s against a 3s budget, so the budget is being restarted per line rather than held across the whole read"
        return 1
    }
}

@test "timeout: whatever DID arrive before the deadline is still handed back" {
    run bash -c "{ printf 'first\n'; sleep 6; } | bash '${PROBE}' 1"
    [[ "$output" == *"payload=[first]"* ]] || {
        echo "the partial payload was discarded on timeout: ${output}"
        return 1
    }
}

@test "caller safety: a non-zero outcome does not kill a caller running under set -e and trap ERR" {
    # Every handler that calls this runs `set -euo pipefail`, and formation-check.sh additionally
    # traps ERR and converts it to a silent exit. A reader whose ordinary end-of-input return killed
    # its caller would turn this fix into a worse defect than the one it replaces.
    local strict="${BATS_TEST_TMPDIR}/strict.sh"
    {
        echo 'set -euo pipefail'
        echo "trap 'echo TRAPPED_ERR; exit 9' ERR"
        echo "source \"${LIB}\""
        echo 'mmry_read_hook_payload 1 || true'
        echo 'printf "SURVIVED status=%s\n" "$MMRY_HOOK_READ_STATUS"'
    } > "$strict"

    run bash -c "printf '' | bash '${strict}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED status=empty"* ]]
    [[ "$output" != *"TRAPPED_ERR"* ]]
}

@test "budget: a nonsense budget falls back to the default rather than breaking the read" {
    # `read -t` rejects a non-numeric argument outright, which under set -e would take the caller
    # with it. Anything unparseable becomes the 2s default.
    run bash -c "printf 'x' | bash '${PROBE}' 'not-a-number'"
    [ "$status" -eq 0 ]
    _assert_path_was_empty "$output"
    [[ "$output" == *"status=ok"* ]]
}

# ---------------------------------------------------------------------------------------------
# The breadcrumb. formation-check.sh may not speak to the model, so this is how it leaves evidence.
# ---------------------------------------------------------------------------------------------

@test "breadcrumb: a recorded fault names who saw it and what happened" {
    local log="${BATS_TEST_TMPDIR}/mmry-hook-read-faults.log"
    rm -f "$log"
    run bash -c "set -euo pipefail; source '${LIB}'; TMPDIR='${BATS_TEST_TMPDIR}' mmry_note_hook_read_fault 'a-caller' 'empty'"
    [ "$status" -eq 0 ]
    [ -s "$log" ] || { echo "no breadcrumb was written to ${log}"; return 1; }
    run grep -c 'a-caller' "$log"
    [ "$output" -eq 1 ]
    run grep -c 'empty' "$log"
    [ "$output" -eq 1 ]
}

@test "breadcrumb: it never fails the caller, even when the log cannot be written" {
    run bash -c "set -euo pipefail; source '${LIB}'; TMPDIR='/nonexistent-dir-for-mmry-31385' mmry_note_hook_read_fault 'a-caller' 'empty'; echo SURVIVED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}

# ---------------------------------------------------------------------------------------------
# The absence checks. Read from CODE ONLY: both handlers explain this defect in a comment that
# quotes the bad call by name, so a raw grep matches the explanation and reports the defect present
# forever after it was fixed - a check that can never pass, which is as useless as one that can
# never fail.
# ---------------------------------------------------------------------------------------------

_code_only() {
    grep -v '^[[:space:]]*#' "$1"
}

@test "absence: no handler reads stdin through GNU timeout any more" {
    local f code base
    for f in "${HANDLERS}"/*.sh; do
        base="$(basename "$f")"
        code="${BATS_TEST_TMPDIR}/code-${base}"
        _code_only "$f" > "$code"

        run grep -nE '(^|[^-[:alnum:]])timeout[[:space:]]+[0-9]' "$code"
        [ -z "$output" ] || {
            echo "${base} still calls GNU timeout: ${output}"
            return 1
        }
        run grep -n 'gtimeout' "$code"
        [ -z "$output" ] || {
            echo "${base} reaches for the Homebrew gtimeout, which is not a fix: ${output}"
            return 1
        }
    done
}

@test "control: the absence check catches a handler that still calls timeout, and spares curl's flags" {
    # POSITIVE CONTROL for the check above. An absence assertion that has never been watched fail
    # cannot be trusted to notice a reintroduction, and this one greps a stripped file, which is one
    # more place for it to silently match nothing.
    local dir="${BATS_TEST_TMPDIR}/reintroduced"
    mkdir -p "$dir"
    local code="${BATS_TEST_TMPDIR}/code-control.sh"

    printf '%s\n' 'payload="$(timeout 2 cat 2>/dev/null || true)"' > "${dir}/bad.sh"
    _code_only "${dir}/bad.sh" > "$code"
    run grep -nE '(^|[^-[:alnum:]])timeout[[:space:]]+[0-9]' "$code"
    [ -n "$output" ] || {
        echo "the absence check did not match a line that plainly calls timeout, so it proves nothing"
        return 1
    }

    # And it must NOT match curl's --connect-timeout / --max-time, which are legitimate and are all
    # over this codebase. A check that flagged those would be switched off within a week.
    printf '%s\n' 'curl --connect-timeout 10 --max-time 25 "$url"' > "${dir}/ok.sh"
    _code_only "${dir}/ok.sh" > "$code"
    run grep -nE '(^|[^-[:alnum:]])timeout[[:space:]]+[0-9]' "$code"
    [ -z "$output" ] || {
        echo "the absence check false-positives on curl's own timeout flags: ${output}"
        return 1
    }
}
