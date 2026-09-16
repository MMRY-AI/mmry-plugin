#!/usr/bin/env bats
# hook-budgets.bats — #31434.
#
# The defect: the UserPromptSubmit Foundation hook was registered with a 5 second budget
# while its handler routinely cost 1 to 2 seconds on a loaded Windows machine. When it
# overran, Claude Code killed it and DISCARDED its output, so the turn silently ran with
# none of the account's standing directives. Three customer reports, one account, three
# plugin versions.
#
# What this file asserts, from the ticket's third test case: no hook the plugin registers
# carries a budget below the measured cost of its own handler, checked against the SHIPPED
# configuration rather than a copy edited by hand.
#
# Two things this file is deliberately careful about, because both have bitten this repo:
#
#  1. It reads the repo's hooks.json, and REFUSES to run against an installed plugin cache
#     or marketplace clone. The machine this was developed on had a hand-edited copy of
#     hooks.json in the marketplace clone carrying a different timeout, so a check that
#     happened to read the installed copy would have passed for the wrong reason.
#
#  2. Every loop asserts its own sample size first. A check that examined zero hooks and
#     reported no problem is a failed check reporting success.

load '../helpers/test-helper'

HOOKS_FILE=""

setup() {
    HOOKS_FILE="$PLUGIN_ROOT/hooks/hooks.json"
}

# Wall-clock cost of a command in MILLISECONDS, averaged over N runs.
# `date +%s%3N` is a GNU extension and macOS does not have it, so this times a BATCH with
# whole seconds and divides. Coarse on purpose: it is portable to the bash 3.2 / BSD date
# that macOS actually ships, and the margins being asserted here are large.
_avg_ms() {
    local runs="$1"; shift
    local start finish i
    start="$(date +%s)"
    for (( i = 0; i < runs; i++ )); do
        "$@" >/dev/null 2>&1 </dev/null || true
    done
    finish="$(date +%s)"
    # +1 second before dividing. Whole-second timing truncates by up to a second, and an
    # UNDER-stated cost would overstate the headroom - which is the error that lets this
    # whole file pass for the wrong reason. Round against ourselves.
    echo $(( ( (finish - start + 1) * 1000 ) / runs ))
}

_write_config() {
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

@test "hook-budgets: the file under test is the repo's shipped hooks.json, not an installed copy" {
    [[ -f "$HOOKS_FILE" ]]
    # An installed plugin lives under .../plugins/cache/... or .../plugins/marketplaces/...
    # Reading either would make every assertion below meaningless.
    [[ "$HOOKS_FILE" != */plugins/cache/* ]]
    [[ "$HOOKS_FILE" != */plugins/marketplaces/* ]]
    # And it must be the copy git tracks, in a repository that contains this test.
    [[ -f "$PLUGIN_ROOT/../.claude-plugin/marketplace.json" ]]
    [[ -d "$PLUGIN_ROOT/tests" ]]
}

@test "hook-budgets: every registered hook declares a positive integer timeout" {
    local timeouts count t
    timeouts="$(jq -r '[.hooks[][].hooks[].timeout] | .[]' "$HOOKS_FILE" | tr -d '\r')"
    count="$(printf '%s\n' "$timeouts" | grep -c '[0-9]')"
    # SAMPLE SIZE. The plugin registers nine hooks today; if a refactor drops them all,
    # every "no hook is below its cost" assertion below would pass vacuously.
    (( count >= 9 ))
    for t in $timeouts; do
        [[ "$t" =~ ^[0-9]+$ ]]
        (( t > 0 ))
    done
}

@test "hook-budgets: the Foundation hook's budget is not the outlier it was" {
    local mine others min_other
    mine="$(jq -r '.hooks.UserPromptSubmit[].hooks[]
                   | select(.command | test("userpromptsubmit-foundation")) | .timeout' "$HOOKS_FILE" | tr -d '\r')"
    [[ "$mine" =~ ^[0-9]+$ ]]

    others="$(jq -r '[.hooks[][].hooks[] | select((.command | test("userpromptsubmit-foundation")) | not) | .timeout]
                     | .[]' "$HOOKS_FILE" | tr -d '\r')"
    # SAMPLE SIZE: there must be other hooks to be an outlier against.
    (( $(printf '%s\n' "$others" | grep -c '[0-9]') >= 8 ))

    min_other="$(printf '%s\n' "$others" | sort -n | head -1)"
    # The whole complaint in the ticket: this handler alone was budgeted below every other.
    (( mine >= min_other ))
}

@test "hook-budgets: the Foundation hook's budget is a large multiple of its MEASURED cost" {
    _write_config
    printf -- '- Truthfulness: never overstate evidence.\n' > "$TEST_TMPDIR/mmry-foundation.md"

    local handler cost budget
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    cost="$(_avg_ms 5 bash "$handler")"
    budget="$(jq -r '.hooks.UserPromptSubmit[].hooks[]
                     | select(.command | test("userpromptsubmit-foundation")) | .timeout' "$HOOKS_FILE" | tr -d '\r')"

    echo "measured cost: ${cost} ms over 5 runs; registered budget: ${budget} s" >&3

    # The measurement must be real. A handler that cost 0 ms did not run.
    (( cost > 0 ))
    # Headroom of at least 5x. At the 5 s budget this refuses for any cost above 1000 ms,
    # which is exactly the range that was measured in the field.
    #
    # This bar was NOT moved to make it pass (#31434 QA). It went red on Windows at 4800 ms
    # against its 4000 ms limit, four consecutive runs, and the bar was right: the handler was
    # spending ~2 s per firing on process spawns that a hook running on every prompt has no
    # business paying. Removing them (`$(<file)` for two `cat`s, parameter expansion for a
    # `tr` pipeline, and the opt-out answered before the worker is spawned at all) brought the
    # same measurement to 2600-3200 ms on the same machine.
    (( budget * 1000 >= cost * 5 ))

    # AND against the number that now actually stops this handler (#31434 QA). The registered
    # budget is the HARNESS's limit; since the supervisor landed, the plugin's own deadline is
    # reached first by design, so a cost that is comfortable against the budget can still be
    # one slow turn away from the handler killing itself. Asserting only the budget would
    # leave the operative limit unmeasured.
    local deadline
    deadline="$(grep -o 'MMRY_FOUNDATION_DEADLINE_SECS:-[0-9][0-9]*'         "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" | head -1 | sed 's/.*:-//')"
    [[ "$deadline" =~ ^[0-9]+$ ]]
    echo "measured cost: ${cost} ms; shipped deadline: ${deadline} s" >&3
    # 3x. Stated rather than assumed, and it is not a comfortable multiple: on Windows Git
    # Bash every process spawn costs ~300 ms, this handler cannot get below about half a dozen
    # of them, and a machine three times slower than an idle developer box would trip the
    # handler's own guard. That is a real residual exposure and it is recorded here rather
    # than rounded off - see the QA notes on this ticket. It degrades honestly (the customer
    # is told the directives were dropped) rather than silently, which is what the ticket
    # exists to guarantee; making it comfortable means cutting the spawn count further, which
    # is its own change.
    (( deadline * 1000 >= cost * 3 ))
}

@test "hook-budgets: the SHIPPED default deadline sits below the registered budget (#31434)" {
    # THE INVARIANT THE WHOLE SUPERVISOR DESIGN RESTS ON, and until now nothing asserted it.
    #
    # Found by mutation, and found by a reviewer rather than by me. Raising the handler's
    # default DEADLINE from 15 to 900 disables the self-imposed guard completely: the harness
    # reaches its own 20 s budget first, kills the hook and DISCARDS its output, which is
    # precisely the silent-loss defect this ticket exists to close. Every handler test and
    # every budget test stayed green, because every deadline test injects
    # MMRY_FOUNDATION_DEADLINE_SECS explicitly and therefore never exercises the number
    # customers actually run.
    #
    # So this reads the SHIPPED source - the same discipline the rest of this file applies to
    # hooks.json, for the same reason: a value the test supplied proves nothing about what
    # ships.
    local handler default fallback budget documented
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [[ -f "$handler" ]]

    # The `:-N` default, and the N the handler falls back to when the env override is not a
    # positive integer. Both are shipped constants and a disagreement between them is its own
    # bug, so both are extracted and compared rather than trusting either alone.
    default="$(grep -o 'MMRY_FOUNDATION_DEADLINE_SECS:-[0-9][0-9]*' "$handler" | head -1 | sed 's/.*:-//')"
    fallback="$(grep -o '^[[:space:]]*.*|| DEADLINE=[0-9][0-9]*' "$handler" | head -1 | sed 's/.*DEADLINE=//')"
    budget="$(jq -r '.hooks.UserPromptSubmit[].hooks[]
                     | select(.command | test("userpromptsubmit-foundation")) | .timeout' "$HOOKS_FILE" | tr -d '\r')"

    echo "shipped default deadline: ${default}s (fallback ${fallback}s); registered budget: ${budget}s" >&3

    # SAMPLE SIZE, in the form this file uses everywhere else: an extraction that found
    # nothing must fail loudly, not silently pass a comparison against an empty string.
    [[ "$default" =~ ^[0-9]+$ ]]
    [[ "$fallback" =~ ^[0-9]+$ ]]
    [[ "$budget" =~ ^[0-9]+$ ]]
    (( default > 0 ))
    [[ "$default" == "$fallback" ]]

    # The plugin must stop ITSELF before the harness stops it, with room left over to write
    # the JSON that tells the customer what happened. Without that margin the whole supervisor
    # is decoration: the harness wins the race and the output is discarded regardless.
    (( default < budget ))
    (( default + 3 <= budget ))

    # And the number the customer is told in the README is the number that ships. A doc
    # promising a 15 s stop against a handler that waits 900 is the same defect wearing
    # a different hat.
    documented="$(grep -o 'stops itself after [0-9][0-9]* seconds' "$PLUGIN_ROOT/README.md" | head -1 | sed 's/[^0-9]//g')"
    [[ "$documented" =~ ^[0-9]+$ ]]
    [[ "$documented" == "$default" ]]
}

@test "hook-budgets: no hook is budgeted below the startup cost every handler pays" {
    _write_config

    # Every entry-point handler sources mmry-client.sh, which resolves jq and loads the
    # config. That is the floor under all of them, so no registered budget may sit near it.
    local floor t timeouts count
    floor="$(_avg_ms 5 bash -c "source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'")"
    echo "shared startup floor: ${floor} ms over 5 runs" >&3
    (( floor > 0 ))

    timeouts="$(jq -r '[.hooks[][].hooks[].timeout] | .[]' "$HOOKS_FILE" | tr -d '\r')"
    count=0
    for t in $timeouts; do
        (( t * 1000 >= floor * 5 ))
        count=$(( count + 1 ))
    done
    # SAMPLE SIZE, stated beside the verdict.
    echo "hooks checked against the floor: ${count}" >&3
    (( count >= 9 ))
}

@test "hook-budgets: the ENFORCED wall clock stays under the registered budget (#31434 QA)" {
    # THE INVARIANT THAT ACTUALLY FAILED QA, and nothing measured it before.
    #
    # Every other check here reads CONFIGURED numbers - the deadline constant, the registered
    # timeout - and compares them. That is exactly how the defect survived: the configured
    # deadline was 15 and the configured budget was 20, so every declarative check agreed the
    # plugin stopped itself first, while the handler really took 23-29 s and the harness
    # killed it and discarded its output. The watchdog counted `sleep 1` ITERATIONS rather
    # than elapsed time, so its effective deadline was DEADLINE x (1 s + the cost of spawning
    # `sleep`) - about 1.3 s per round on Windows Git Bash - and the supervisor's own startup
    # and reporting sat on top of that.
    #
    # So this asserts the ENFORCED figure: a stopwatch around a real firing that is made to
    # hang, using the SHIPPED default deadline with no environment override, because the
    # override is what let every other deadline test avoid the number customers run.
    _write_config
    printf -- '- Truthfulness: never overstate evidence.
' > "$TEST_TMPDIR/mmry-foundation.md"

    # A jq that never returns in time. --version stays fast because the resolver probes it.
    local shim="$TEST_TMPDIR/hang-jq.sh"
    cat > "$shim" <<'SHIMEOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done
sleep 60
exec jq "$@"
SHIMEOF
    chmod +x "$shim"

    local handler budget start elapsed_ms out margin_ms
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    budget="$(jq -r '.hooks.UserPromptSubmit[].hooks[]
                     | select(.command | test("userpromptsubmit-foundation")) | .timeout' "$HOOKS_FILE" )"
    # Trim anything that is not a digit, rather than naming a carriage return: jq.exe
    # opens stdout in text mode on Windows and appends one. An earlier form used
    # `tr -d` with a LITERAL CR in the source, which git's CRLF normalisation turned
    # into a line break on checkout and silently broke this extraction (#31434 QA).
    budget="${budget%%[![:digit:]]*}"
    [[ "$budget" =~ ^[0-9]+$ ]]

    start="$(date +%s)"
    out="$(MMRY_JQ="$shim" bash "$handler" 2>/dev/null)"
    elapsed_ms=$(( ( $(date +%s) - start ) * 1000 ))
    margin_ms=$(( budget * 1000 - elapsed_ms ))
    echo "ENFORCED wall clock: ${elapsed_ms} ms; registered budget: ${budget}s; margin: ${margin_ms} ms" >&3

    # The premise: it really did hang, so this measures the guard and not a fast path.
    (( elapsed_ms >= 9000 ))
    # THE ASSERTION. The plugin stopped itself before the harness could, with a stated margin.
    # 5 s, not "under the budget": finishing at 19.5 s would satisfy the letter of the
    # invariant on an idle box and still lose the race on a loaded one.
    (( elapsed_ms < budget * 1000 ))
    (( margin_ms >= 5000 ))
    # And the customer was told. A guard that wins the race and says nothing is the silent
    # loss wearing a different hat.
    [[ "$out" == *'NOT applied to this turn'* ]]
    [[ "$out" == *'exceeded'* ]]
    echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

@test "hook-budgets: the watchdog measures ELAPSED TIME, not sleep iterations (#31434 QA)" {
    # Isolates the DRIFT, which the wall-clock test above cannot always see.
    #
    # The shipped-to-QA watchdog counted `sleep 1` ROUNDS, so one configured second really
    # bought 1 s plus the cost of spawning `sleep`. That is how a 15 s deadline produced a
    # 23-29 s handler against a 20 s budget. The wall-clock test catches that combination -
    # measured here at 23 s, margin -3000 ms - but it cannot catch the drift ALONE, because
    # the size of the drift is the size of a process spawn, and that is a property of the
    # machine, not of the code. Measured on this Windows box: ~300 ms per spawn under load,
    # giving a 25% overrun, but under 100 ms when the box was quiet, giving almost none. A
    # timing assertion for drift would therefore pass or fail on how busy the machine was,
    # which is not evidence about the code. Two runs proved exactly that: the same iteration
    # counter measured 125% of real time once and 86% another time.
    #
    # So the drift is asserted where it is deterministic - in the source. This file already
    # reads shipped source for the deadline constant, for the same reason: some invariants are
    # not observable from the outside cheaply or reliably, and asserting them weakly is worse
    # than asserting them structurally and saying so.
    local handler block
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [[ -f "$handler" ]]

    # The watchdog subshell: from its `while` to the kill that ends it.
    block="$(sed -n '/^        while /,/kill -TERM/p' "$handler")"
    # SAMPLE SIZE, as everywhere else in this file: an extraction that found nothing must fail
    # loudly rather than pass a comparison against an empty string.
    (( $(printf '%s
' "$block" | grep -c .) >= 3 ))
    printf '%s
' "$block" | grep -q 'kill -TERM'

    # The loop bound must be a CLOCK. `SECONDS` is a bash builtin, so this also removes the
    # per-round spawn that caused the drift in the first place.
    printf '%s
' "$block" | grep -q 'while (( SECONDS < DEADLINE ))'
    # And nothing in it may be a per-iteration counter standing in for elapsed time.
    #
    # Counted rather than written as `! ... | grep -q` (#31434 QA). A `!`-negated command is
    # EXEMT from `set -e` by the shell standard, so `! grep -q x` never fails a bats test -
    # it just returns 1 and execution carries on to the next line. Demonstrated on this suite:
    # a test whose body was `! true` followed by `false` reported the failure at `false`. Every
    # negative assertion in this file is therefore written as a count compared to zero, which
    # `(( ))` does fail on.
    (( $(printf '%s
' "$block" | grep -cE '_waited|\+ 1 \)\)' || true) == 0 ))
    # The clock must be reset before the loop, or it counts from the supervisor's start and
    # fires early.
    grep -q '^        SECONDS=0$' "$handler"
}

@test "hook-budgets: the per-prompt path spawns no process it does not need (#31434 QA)" {
    # The complement to the MEASURED-cost test above, and the reason both exist.
    #
    # That test is a wall-clock bar, so it only bites when the machine is slow enough to make
    # the cost visible. It did bite - 4800 ms against its 4000 ms limit, four consecutive runs
    # on a loaded Windows box, which is what sent this ticket back. But re-running the same
    # regression on a QUIET box passes it: restoring every spawn this fix removed still came in
    # under the bar. A guard that only works when the machine is busy will let the regression
    # back in on the day CI happens to be idle, which is precisely how the original 5 s budget
    # survived a green suite.
    #
    # So the thing that actually matters is asserted directly: on Windows Git Bash a process
    # spawn measured ~300 ms, so for a hook that runs on EVERY PROMPT the spawn count is the
    # cost. These three idioms were the removable ones; each has a builtin equivalent that
    # this handler now uses.
    local handler body
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [[ -f "$handler" ]]

    # Comments in this file discuss the idioms by name, so strip them before matching or the
    # test fails on its own explanation.
    body="$(grep -v '^[[:space:]]*#' "$handler")"
    # SAMPLE SIZE: the strip must leave a handler behind, not an empty string.
    (( $(printf '%s
' "$body" | grep -c .) >= 100 ))

    # Counted, not `! ... grep -q`: see the note in the watchdog test above - a `!`-negated
    # command cannot fail a bats test. Written as `! grep`, both of these passed against a
    # handler with every removed spawn restored.
    #
    # `cat` to read a file into a variable - `$(<file)` is a builtin and costs no exec.
    (( $(printf '%s
' "$body" | grep -c 'cat "\$' || true) == 0 ))
    # A `tr` pipeline to case-fold a short string - _mmry_tolower does it in the shell.
    (( $(printf '%s
' "$body" | grep -c "tr '\[:upper:\]'" || true) == 0 ))
    # And the opt-out must be answered before the worker is spawned, not after: an opted-out
    # customer should pay nothing, and the crash notice's own remedy depends on it.
    printf '%s
' "$body" | grep -q '_mmry_reinject_is_off_here'
    local off_line worker_line
    off_line="$(printf '%s
' "$body" | grep -n '_mmry_reinject_is_off_here' | head -1 | cut -d: -f1)"
    worker_line="$(printf '%s
' "$body" | grep -n 'MMRY_FOUNDATION_WORKER=1 bash' | head -1 | cut -d: -f1)"
    [[ "$off_line" =~ ^[0-9]+$ ]]
    [[ "$worker_line" =~ ^[0-9]+$ ]]
    (( off_line < worker_line ))
}
