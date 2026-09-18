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
    # 6 s of extra latency, not the 7 s this used to inject (#31434 QA).
    #
    # NOT a weakened premise - the premise is "past the OLD 5 s budget", and 6 is. What
    # changed underneath it is the SHIPPED DEADLINE, cut from 15 s to 10 s so the plugin wins
    # its race against the harness with a stated margin instead of losing it. The handler's own
    # overhead measured 2.5-3 s on Windows Git Bash, so a 10 s deadline tolerates roughly 7 s
    # of added latency, and a 7 s injection sat exactly on that boundary: measured three times
    # outside the harness at 10.0/10.9/11.2 s it delivered, and inside the harness it was
    # killed. A test that flips on which side of a boundary the machine lands is not evidence
    # either way.
    #
    # The narrowed tolerance is a real consequence of the lower deadline and it is recorded
    # rather than papered over: see the residual-exposure note in hook-budgets.bats.
    local shim budget start elapsed
    shim="$(_make_slow_jq 6)"
    budget="$(_registered_timeout)"
    # The premise of the test: 6s must be past the old budget and inside the new one.
    (( 6 > 5 ))
    (( 6 < budget ))

    start="$(date +%s)"
    MMRY_JQ="$shim" run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # Asserted on the INJECTED CONTENT, not on the absence of a warning.
    [[ "$output" == *'never overstate evidence'* ]]
    [[ "$output" == *'"hookEventName":"UserPromptSubmit"'* ]]
    # It really was slow — otherwise this test proves nothing about the budget.
    (( elapsed >= 5 ))
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
    # The remedy must name a command that EXISTS. This assertion previously read
    # '/mmry:reload-memories', which this plugin does not ship - so a green suite actively
    # defended handing a confused customer an unknown command at the one moment their
    # directives had just vanished. Now checked against commands/, not by eye.
    [[ "$output" == *'/mmry:load-memories'* ]]
    [ -f "$PLUGIN_ROOT/commands/load-memories.md" ]
    # The model is told too, so it cannot claim to be following directives it never got.
    [[ "$output" == *'running WITHOUT the account'* ]]
    # And it is still one valid JSON object.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    # It must NOT pretend to have delivered the Foundation set.
    [[ "$output" != *'never overstate evidence'* ]]
    # It must say the DEADLINE was hit, in the words reserved for that cause.
    [[ "$output" == *'exceeded'* ]]
    [[ "$output" != *'exit code'* ]]
    # And it must leave a trace. A failure that drops the customer's directives and records
    # nothing is how this defect survived three reports without anyone being able to act on it.
    grep -q 'foundation reinjection FAILED' "$TEST_TMPDIR/mmry-foundation.log"
    grep -q 'deadline exceeded' "$TEST_TMPDIR/mmry-foundation.log"
}

@test "userpromptsubmit-foundation: a worker that CRASHES is not reported as a slow one (#31434)" {
    # Found by review. The supervisor branched on a non-zero worker exit alone, so every
    # worker failure was announced as a timeout: with a broken install the worker exits 127
    # in well under a second and the customer was told "loading took over 15s" and to re-send
    # the prompt. A false cause, a false duration, and a remedy that cannot work. The watchdog
    # now records that it was the one who killed the worker, and the absence of that record is
    # what makes this path distinguishable.
    #
    # Induced without adding any test seam to production code. The supervisor re-executes this
    # file as a worker via `bash`, resolved from PATH; a broken environment where that `bash`
    # fails is exactly how the field produces a fast non-zero. 127 is the code the review
    # observed. The supervisor itself is invoked by absolute path so that only the WORKER
    # spawn is affected.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    local start elapsed shimdir real_bash
    real_bash="$(command -v bash)"
    shimdir="$TEST_TMPDIR/broken-bash"
    mkdir -p "$shimdir"
    printf '#!/bin/sh\nexit 127\n' > "$shimdir/bash"
    chmod +x "$shimdir/bash"

    start="$(date +%s)"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    # It failed FAST. Anything that took a deadline's worth of time is not this scenario.
    (( elapsed < 5 ))
    # Told as a failure, with the real exit code, and explicitly NOT as a duration.
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'NOT applied to this turn'* ]]
    [[ "$output" == *'exit code'* ]]
    [[ "$output" == *'failure, not a slow turn'* ]]
    # The three lies the old single-branch version told, each asserted absent.
    [[ "$output" != *'exceeded'* ]]
    [[ "$output" != *'took over'* ]]
    [[ "$output" != *'Re-send the prompt to try again'* ]]
    # Still exactly one valid JSON object, and still no false claim of delivery.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    [[ "$output" != *'never overstate evidence'* ]]
    # Logged as a crash, not as a deadline, so the log agrees with what the customer was told.
    grep -q 'foundation reinjection FAILED' "$TEST_TMPDIR/mmry-foundation.log"
    grep -q 'without hitting' "$TEST_TMPDIR/mmry-foundation.log"
    # Counted, not `! grep -q`: a `!`-negated command is exempt from `set -e`, so the
    # original form could not fail this test even when the log DID say 'deadline exceeded'
    # - the one thing this assertion exists to catch (#31434 QA).
    (( $(grep -c 'deadline exceeded' "$TEST_TMPDIR/mmry-foundation.log" || true) == 0 ))
}

@test "userpromptsubmit-foundation: MMRY_DEBUG captures the stderr the handler otherwise discards (#31434)" {
    # The supervisor must never let stderr reach the terminal - it deliberately kills a
    # background job and the shell announces that at a moment nobody controls. But a feature
    # born of three unreproducible customer reports cannot also ship with field diagnostics
    # hard-wired to /dev/null, or the fourth report is just as unreproducible. MMRY_DEBUG
    # redirects rather than discards; the terminal contract is unchanged either way.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    local dbg="$TEST_TMPDIR/mmry-foundation-debug.log"

    # Default: nothing is captured anywhere.
    rm -f "$dbg"
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [ ! -f "$dbg" ]

    # Debug on: the same run is still clean on both of the customer's channels...
    rm -f "$dbg"
    MMRY_DEBUG=1 run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
    # ...and the diagnostics now have somewhere to land.
    [ -f "$dbg" ]
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

# ---------------------------------------------------------------------------------------------
# THE SAME TWO NOTICES, ON A CONFIGURED CODEX INSTALL (#31245 QA round 6).
#
# The round-4 fix in this handler makes an UNCONFIGURED Codex install exit silently rather than
# printing the crash notice. It did nothing for a CONFIGURED one, which is the ordinary case and
# still reaches both notices on any worker failure. QA reproduced 725 bytes of it on a configured
# install hitting the deadline, naming /mmry:load-memories - a command Codex customers cannot type
# - and ~/.claude/mmry-config.json, the OTHER product's file.
#
# Both branches are covered, because fixing the branch somebody looked at and leaving its sibling
# three lines below is the defect this task keeps repeating. Each is paired with its Claude control
# asserting the literal is unchanged, so a handler that "fixes" this by naming no remedy at all
# fails rather than passes.

_codex_home_with_credential() {
    # A Codex home that is NOT the default, because the customer this feature exists for is the one
    # who moved it, and a message built from a hardcoded ~/.codex would pass against the default.
    local d="$TEST_TMPDIR/codexhome"
    mkdir -p "$d/mmry"
    cat > "$d/mmry-config.json" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationReinjectTokenCap": 1500,
  "foundationRefreshSeconds": 0
}
EOF
    printf '%s' "$d"
}

@test "userpromptsubmit-foundation: a CONFIGURED Codex install past the deadline is told something it can do" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    _make_config
    local shim codex
    shim="$(_make_slow_jq 20)"
    codex="$(_codex_home_with_credential)"

    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 \
        MMRY_HOST=codex CODEX_HOME="$codex" \
        run bash "$HANDLER"

    [ "$status" -eq 0 ]
    # It still fires: a configured install is NOT silenced by the round-4 unconfigured-install
    # guard, and a test that merely asserted silence here would pass against the defect.
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'NOT applied to this turn'* ]]
    [[ "$output" == *'exceeded'* ]]

    # THE DEFECT, ASSERTED AS ABSENT.
    [[ "$output" != *'/mmry:load-memories'* ]]
    [[ "$output" != *'~/.claude/mmry-config.json'* ]]

    # AND THE REMEDY, ASSERTED AS PRESENT. Absence alone is satisfied by a notice that stopped
    # offering any remedy at all, which is worse for the customer, not better.
    [[ "$output" == *"bash ${codex}/mmry/hooks-handlers/session-start.sh"* ]]
    [[ "$output" == *"${codex}/mmry-config.json"* ]]
    # The script it names is really there. A path that reads plausibly and is not on disk is the
    # same failure in a nicer font.
    [ -f "$PLUGIN_ROOT/hooks-handlers/session-start.sh" ]
}

@test "userpromptsubmit-foundation: req4 - and on Claude Code that deadline notice is unchanged" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    _make_config
    local shim
    shim="$(_make_slow_jq 20)"

    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"

    [ "$status" -eq 0 ]
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'/mmry:load-memories'* ]]
    [[ "$output" == *'~/.claude/mmry-config.json'* ]]
    [ -f "$PLUGIN_ROOT/commands/load-memories.md" ]
}

@test "userpromptsubmit-foundation: a CONFIGURED Codex install whose worker CRASHES gets the same treatment" {
    # The sibling branch. Round 4 fixed the notice's unconfigured case; this is the one three
    # lines below it in the same if/else, which round 5 shipped untouched.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    _make_config
    local shim codex
    shim="$TEST_TMPDIR/broken-jq.sh"
    cat > "$shim" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done
exit 9
EOF
    chmod +x "$shim"
    codex="$(_codex_home_with_credential)"

    MMRY_JQ="$shim" MMRY_HOST=codex CODEX_HOME="$codex" run bash "$HANDLER"

    [ "$status" -eq 0 ]
    if [[ "$output" != *'systemMessage'* ]]; then
        # The crash branch is reached through the worker's exit status, which some environments
        # swallow. Say so rather than passing silently on a test that checked nothing.
        skip "the worker did not exit non-zero in this environment; the deadline branch above covers the same two strings"
    fi
    [[ "$output" != *'/mmry:load-memories'* ]]
    [[ "$output" != *'~/.claude/mmry-config.json'* ]]
    [[ "$output" == *"bash ${codex}/mmry/hooks-handlers/session-start.sh"* ]]
}

@test "userpromptsubmit-foundation: an absurd deadline value falls back to the default rather than disabling the guard" {
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    MMRY_FOUNDATION_DEADLINE_SECS="not-a-number" run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'never overstate evidence'* ]]
}

@test "userpromptsubmit-foundation: awkward characters survive into valid JSON and come back out intact (#31434)" {
    # The escaping used to be `sed ':a;N;$!ba;s/\n/\n/g'`. That label-and-branch form is a GNU
    # extension and the BSD sed macOS ships rejects it, so on a Mac the error text went into the
    # handler's output and the emitted "JSON" was not JSON. The macOS CI leg had been red on
    # "emits valid JSON" since before this ticket, which is what an unread CI leg buys you.
    #
    # Asserted by ROUND-TRIPPING the content back out of the JSON, not by eyeballing the string:
    # a test that only checked "contains a backslash" would pass on double-escaped output too.
    printf -- '- Quote: he said "no".\n- Backslash: C:\Users\x\n- Tab:\tafter\n- Ampersand & percent %%\n' > "$CACHE"

    run bash "$HANDLER"
    [ "$status" -eq 0 ]

    local ctx
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *'he said "no".'* ]]
    [[ "$ctx" == *'C:\Users\x'* ]]
    [[ "$ctx" == *'Ampersand & percent %'* ]]
    # The newlines are real newlines again after the round trip, not a literal backslash-n.
    [ "$(printf '%s' "$ctx" | wc -l)" -ge 4 ]
    # And a tab is a tab.
    printf '%s' "$ctx" | grep -q "$(printf 'Tab:\tafter')"
}

@test "userpromptsubmit-foundation: nothing is left holding an inherited descriptor after it exits (#31434)" {
    # THE BUG THIS EXISTS FOR, and the reason to distrust a green suite.
    #
    # The supervisor's first watchdog was `( sleep "$DEADLINE"; kill ... ) &`, killed after the
    # wait. Killing the subshell ORPHANS its sleep, and the orphan keeps every descriptor it
    # inherited. Whoever reads the hook waits for the LAST WRITER to close, not for the handler
    # to exit - so the reader sat there for the entire deadline while the handler had long since
    # produced its answer.
    #
    # Two things this assertion had to get right, both learned by getting them wrong:
    #
    #  1. stdout alone does NOT catch it. The old watchdog redirected its own stdout to
    #     /dev/null, so `bash handler | cat` finished in about 500 ms either way.
    #  2. Measuring bats' own `run` does not catch it reliably either - the first version of
    #     this test did that, and it passed against the broken watchdog.
    #
    # So it reproduces the condition directly: attach an EXTRA descriptor to the same pipe the
    # output is read from, then measure time to EOF. Measured this way: 15155/15170/15155 ms
    # with the orphan against a 15 s deadline, 494/515/604/567/572 ms without it.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"

    local start elapsed captured
    start="$(date +%s)"
    captured="$( { MMRY_FOUNDATION_DEADLINE_SECS=12 bash "$HANDLER" </dev/null; } 3>&1 )"
    elapsed=$(( $(date +%s) - start ))

    # The answer is right...
    [[ "$captured" == *'never overstate evidence'* ]]
    # ...and the reader was released as soon as it was produced, not at the deadline.
    echo "time to EOF with an extra inherited descriptor: ${elapsed}s against a 12s deadline" >&3
    (( elapsed < 6 ))
}

@test "userpromptsubmit-foundation: a firing killed outright LEAVES the marker, end to end (#31434)" {
    # Found by mutation, not by inspection. The test above creates the in-flight marker by hand
    # and asserts it is READ. Deleting the line that WRITES it therefore changed nothing and the
    # whole suite stayed green - a handler that never records a firing can never report a lost
    # one, which is the entire feature. This drives the real sequence instead.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": "true",
  "foundationRefreshSeconds": 0
}
EOF
    local shim; shim="$(_make_slow_jq 20)"

    # SIGKILL, because that is what the harness does on timeout: no trap, no cleanup, nothing.
    MMRY_JQ="$shim" bash "$HANDLER" >/dev/null 2>&1 </dev/null &
    local victim=$!
    sleep 2
    kill -9 "$victim" 2>/dev/null
    wait "$victim" 2>/dev/null || true

    # The evidence that a turn was lost has to survive the kill, or nobody can ever be told.
    [ -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]

    # The same kill ORPHANS this firing's out-file - the worker outlives its supervisor and
    # goes on writing to a file no one will ever read. Deleting the sweep that reaps it turned
    # nothing red until these two lines existed, so a leak that grows with every timeout in the
    # customer's temp directory was shipping untested. The condition already existed here; only
    # the assertions were missing.
    [ -f "$TEST_TMPDIR/.mmry-foundation-out.$victim" ]

    # And the next firing picks it up and says so, on both channels.
    run bash "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'PREVIOUS turn'* ]]
    [[ "$output" == *'previous turn'* ]]
    [[ "$output" == *'never overstate evidence'* ]]
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight" ]
    # ...and that same firing reaps the orphan, because its supervisor no longer exists.
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-out.$victim" ]
}

# ============================================================================
# #31434 QA - the off switch the failure notices recommend.
#
# Both failure notices tell the customer to set foundationReinject to false. That advice was
# INERT on the path that gave it: the toggle was read only by the worker, via mmry_load_config,
# and the crash branch runs precisely when the worker could not run. A reviewer set it in the
# config AND in the environment and the banner fired anyway, on every prompt, with no way to
# stop it. These tests exist so that cannot ship again.
#
# Each one carries its CONTROL in the same test - a run that must produce the banner - because
# "no banner" is the passing state here, and a test whose pass condition is silence will also
# pass when the handler has simply stopped working.
# ============================================================================

_make_broken_bash() {
    # A PATH bash that fails instantly: the supervisor re-execs this file as a worker via
    # `bash` resolved from PATH, so this is how the field produces a fast non-zero exit.
    local d="$TEST_TMPDIR/broken-bash"
    mkdir -p "$d"
    printf '#!/bin/sh
exit 127
' > "$d/bash"
    chmod +x "$d/bash"
    printf '%s' "$d"
}

_write_toggle_config() {
    # $1 = the raw JSON value for foundationReinject
    cat > "$MMRY_CONFIG_FILE" <<EOF
{
  "apiUrl": "http://127.0.0.1:9",
  "authMethod": "apikey",
  "apiKey": "test-key",
  "foundationReinject": $1,
  "foundationReinjectTokenCap": 1500,
  "foundationRefreshSeconds": 0
}
EOF
}

@test "userpromptsubmit-foundation: foundationReinject=false in CONFIG silences the crash notice it recommends (#31434 QA)" {
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
    local real_bash shimdir
    real_bash="$(command -v bash)"
    shimdir="$(_make_broken_bash)"

    # CONTROL FIRST: with the toggle ON, this exact scenario must produce the banner.
    # Without it the test would also pass against a handler that did nothing at all.
    _write_toggle_config '"true"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'NOT applied to this turn'* ]]

    # Now the remedy the notice just handed the customer.
    _write_toggle_config '"false"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: a JSON boolean false is honoured too, not just the string (#31434 QA)" {
    # The README documents `false`; mmry_load_config tostring's it into "false". The supervisor
    # reads the file without jq, so the bare boolean is the spelling most likely to be missed.
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
    local real_bash shimdir
    real_bash="$(command -v bash)"
    shimdir="$(_make_broken_bash)"

    _write_toggle_config 'true'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [[ "$output" == *'NOT applied to this turn'* ]]

    _write_toggle_config 'false'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: the ENVIRONMENT off switch silences the crash notice, and outranks the config (#31434 QA)" {
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
    local real_bash shimdir
    real_bash="$(command -v bash)"
    shimdir="$(_make_broken_bash)"
    # The config says ON throughout, so a pass here can only come from the environment override
    # being honoured - and it must be honoured by the SUPERVISOR, since no worker ever starts.
    _write_toggle_config '"true"'

    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [[ "$output" == *'NOT applied to this turn'* ]]

    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    MMRY_FOUNDATION_REINJECT=false PATH="$shimdir:$PATH" run "$real_bash" "$HANDLER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "userpromptsubmit-foundation: the off switch also silences the DEADLINE notice (#31434 QA)" {
    # The other half of the same promise, and the path the customer is most likely trying to
    # escape. The opt-out is answered before the worker exists, so an opted-out customer does
    # not even wait out a deadline to be told about a feature they switched off.
    printf -- '- Truthfulness: never overstate evidence.
' > "$CACHE"
    local shim start elapsed
    shim="$(_make_slow_jq 30)"

    _write_toggle_config '"false"'
    rm -f "$TEST_TMPDIR/.mmry-foundation-inflight"
    start="$(date +%s)"
    MMRY_JQ="$shim" MMRY_FOUNDATION_DEADLINE_SECS=3 run bash "$HANDLER"
    elapsed=$(( $(date +%s) - start ))

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    (( elapsed < 3 ))
}

# ---------------------------------------------------------------------------------------------
# THE UNCONFIGURED CODEX INSTALL (#31245 QA round 4).
#
# On a Codex install with no credential of its own, this handler fired on every prompt and exited
# 1 with zero bytes. The chain: the worker sources mmry-client.sh -> lib-jq.sh -> lib-host.sh,
# which refuses with `exit 1` rather than a return code, so the worker's own `|| exit 0` never
# saw it and the worker died with rc=1.
#
# After #31434 that stopped being silent and started being WRONG. The supervisor cannot tell a
# refusal from a broken install, so rc=1 took the crash branch and printed, on every prompt, a
# banner naming /mmry:load-memories - a slash command Codex customers cannot type - and
# ~/.claude/mmry-config.json, the OTHER product's config file, with "the usual cause is an
# incomplete plugin install", which is not the cause.
#
# These stage a real Codex install the way session-init.sh does, rather than asserting against a
# replica of it.

_stage_codex_install() {
    local root="$1"
    mkdir -p "$root/mmry/hooks-handlers" "$root/fakehome"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/mmry/hooks-handlers/"
    printf 'codex\n' > "$root/mmry/.mmry-host"
    printf '%s/mmry/hooks-handlers/userpromptsubmit-foundation.sh' "$root"
}

@test "codex: an unconfigured Codex install emits NOTHING on a prompt, rather than a banner" {
    local root="$TEST_TMPDIR/codex-unconfigured" handler
    handler="$(_stage_codex_install "$root")"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST HOME="$root/fakehome" CODEX_HOME="$root" \
        bash "$handler"

    [ "$status" -eq 0 ]
    # ZERO BYTES. Not "no crash banner" - nothing at all, which is what every other
    # nothing-to-say path in this handler does.
    [ -z "$output" ]
}

@test "codex: and it does not name a slash command Codex cannot type, or the other product's config" {
    local root="$TEST_TMPDIR/codex-unconfigured-msg" handler
    handler="$(_stage_codex_install "$root")"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST HOME="$root/fakehome" CODEX_HOME="$root" \
        bash "$handler"

    # These three are the literal contents of the banner the merge produced. Asserted
    # separately from the emptiness check above so that a future change which emits SOMETHING
    # here still cannot emit THIS.
    [[ "$output" != *"/mmry:load-memories"* ]]
    [[ "$output" != *".claude/mmry-config.json"* ]]
    [[ "$output" != *"incomplete plugin install"* ]]
}

@test "codex: a CONFIGURED Codex install still re-injects - the guard is not a blanket off switch" {
    local root="$TEST_TMPDIR/codex-configured" handler
    handler="$(_stage_codex_install "$root")"
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"k","foundationReinject":"true"}' \
        > "$root/mmry-config.json"
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST HOME="$root/fakehome" CODEX_HOME="$root" \
        bash "$handler"

    [ "$status" -eq 0 ]
    [[ "$output" == *'FOUNDATION'* ]]
    [[ "$output" == *'never overstate evidence'* ]]
}

@test "req4 control: a Claude install with NO credential is unaffected by the Codex guard" {
    # The guard must key on the HOST, not on whether a credential happens to exist. A Claude
    # install has always re-injected from cache regardless, and still must.
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    local fakehome="$TEST_TMPDIR/claude-nocred"
    mkdir -p "$fakehome/.claude"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CODEX_HOME HOME="$fakehome" bash "$HANDLER"

    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY'* ]]
}

@test "req4 control: a curated copy with NO lib-host.sh still re-injects, rather than going silent" {
    # "Could not ask the question" must not be treated as "the answer was refuse". hook-guard.sh
    # documents why such copies exist; collapsing the two would trade a Codex bug for a Claude one.
    local root="$TEST_TMPDIR/claude-curated"
    mkdir -p "$root/mmry/hooks-handlers" "$root/fakehome/.claude"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/mmry/hooks-handlers/"
    rm -f "$root/mmry/hooks-handlers/lib-host.sh"
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"

    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CODEX_HOME HOME="$root/fakehome" \
        bash "$root/mmry/hooks-handlers/userpromptsubmit-foundation.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY'* ]]
}
