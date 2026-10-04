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
load '../helpers/foundation-set'

HOOKS_FILE=""

setup() {
    HOOKS_FILE="$PLUGIN_ROOT/hooks/hooks.json"
}

# Wall-clock cost of a command in MILLISECONDS, averaged over N runs.
# `date +%s%3N` is a GNU extension and macOS does not have it, so this times a BATCH with
# whole seconds and divides. Coarse on purpose: it is portable to the bash 3.2 / BSD date
# that macOS actually ships, and the margins being asserted here are large.
# The CHEAPEST of $1 runs, in ms, rounded up (#31411 QA round 3, item 8). What these bars guard is the
# handler's own cost, and on a machine two other suites are loading, the average measured the other
# suites: the bars went red with them and passed alone. The cheapest run is the closest a busy machine
# gets to the handler's own cost, and a handler that really grew is no cheaper on any run. Needs
# bash 5's EPOCHREALTIME for per-run timing; without it (bash 3.2 on a Mac) it is the average below.
_min_ms() {
    if [[ -z "${EPOCHREALTIME:-}" || "${BASH_VERSINFO[0]}" -lt 5 ]]; then _avg_ms "$@"; return; fi
    local runs="$1"; shift
    local i t0 t1 us best=""
    for (( i = 0; i < runs; i++ )); do
        t0="${EPOCHREALTIME/[.,]/}"
        "$@" >/dev/null 2>&1 </dev/null || true
        t1="${EPOCHREALTIME/[.,]/}"
        us=$(( 10#$t1 - 10#$t0 ))
        [[ -z "$best" ]] || (( us < best )) && best=$us
    done
    echo $(( (best + 999) / 1000 ))
}

# Now in ms, for one firing: EPOCHREALTIME where bash has it, whole seconds otherwise.
_now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" && "${BASH_VERSINFO[0]}" -ge 5 ]]; then
        local t="${EPOCHREALTIME/[.,]/}"; echo $(( 10#$t / 1000 ))
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

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

# Seal a hand-written Foundation set into the file the hook reads (#31583, #31597).
#
# The re-injection handler no longer trusts a set merely for existing - it verifies the bytes
# against the record the writer put on the set file's first line. A fixture without one is
# refused, so a budget test using it would be timing the REFUSAL path rather than the injection
# path and would report a cost that has nothing to do with what a customer pays. The fixture is
# staged in the file named by $1 and sealed into mmry-foundation-set.md beside it.
_manifest_for() {
    fnd_seal "$1" "" "$(dirname "$1")/mmry-foundation-set.md"
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
    [[ -f "$HOOKS_FILE" ]] || return 1
    # An installed plugin lives under .../plugins/cache/... or .../plugins/marketplaces/...
    # Reading either would make every assertion below meaningless.
    [[ "$HOOKS_FILE" != */plugins/cache/* ]] || return 1
    [[ "$HOOKS_FILE" != */plugins/marketplaces/* ]] || return 1
    # And it must be the copy git tracks, in a repository that contains this test.
    [[ -f "$PLUGIN_ROOT/../.claude-plugin/marketplace.json" ]] || return 1
    [[ -d "$PLUGIN_ROOT/tests" ]]
}

@test "hook-budgets: every registered hook declares a positive integer timeout" {
    local timeouts count t
    timeouts="$(jq -r '[.hooks[][].hooks[].timeout] | .[]' "$HOOKS_FILE" | tr -d '\r')"
    count="$(printf '%s\n' "$timeouts" | grep -c '[0-9]')"
    # SAMPLE SIZE. The plugin registers nine hooks today; if a refactor drops them all,
    # every "no hook is below its cost" assertion below would pass vacuously.
    (( count >= 9 )) || return 1
    for t in $timeouts; do
        [[ "$t" =~ ^[0-9]+$ ]] || return 1
        (( t > 0 )) || return 1
    done
}

@test "hook-budgets: the Foundation hook's budget is not the outlier it was" {
    local mine others min_other
    mine="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | if length == 1 then .[0] else "DISAGREE" end' "$HOOKS_FILE" | tr -d '\r')"
    [[ "$mine" =~ ^[0-9]+$ ]] || return 1

    others="$(jq -r '[.hooks[][].hooks[] | select((.command | test("userpromptsubmit-foundation")) | not) | .timeout]
                     | .[]' "$HOOKS_FILE" | tr -d '\r')"
    # SAMPLE SIZE: there must be other hooks to be an outlier against.
    (( $(printf '%s\n' "$others" | grep -c '[0-9]') >= 8 )) || return 1

    min_other="$(printf '%s\n' "$others" | sort -n | head -1)"
    # The whole complaint in the ticket: this handler alone was budgeted below every other.
    (( mine >= min_other ))
}

@test "hook-budgets: the Foundation hook's budget is a large multiple of its MEASURED cost" {
    _write_config
    # A REALISTIC SET, NOT ONE LINE (#31411 QA, performance). This was a single 45-byte
    # directive, the smallest set possible, on the one change whose whole point is that there
    # is no largest size. The bar was sound and could not see a cost that grows with the set.
    # About 35 KB: the largest Foundation set on the platform is 34,343 characters (2026-10-02).
    awk -v n=400 'BEGIN { for (i = 0; i < n; i++) print "- Directive: keep every sentence short and every claim backed by something you ran." }' > "$TEST_TMPDIR/mmry-foundation.md"
    _manifest_for "$TEST_TMPDIR/mmry-foundation.md"

    local handler cost budget
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    cost="$(_min_ms 5 bash "$handler")"
    budget="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | if length == 1 then .[0] else "DISAGREE" end' "$HOOKS_FILE" | tr -d '\r')"

    echo "measured cost: ${cost} ms, the cheapest of 5 runs; registered budget: ${budget} s" >&3

    # THE PREMISE: the thing that was timed actually ran, and actually did the work.
    #
    # This was `(( cost > 0 ))`, and it could not fail (#31434 QA round 2). `_avg_ms` adds a
    # whole second before dividing, so its floor is 1000/runs = 200 ms; a reviewer pointed it
    # at a handler that DOES NOT EXIST and it reported 200 ms, cheerfully positive. A premise
    # check that cannot go red is not a premise check, and this file's whole subject is checks
    # that cannot fail.
    #
    # So the premise is checked by OBSERVATION rather than by the clock: run the handler once,
    # require exit 0, and require its stdout to be the hook JSON carrying the fixture directive
    # written above. A handler that is missing exits 127 with empty stdout; one that ran but
    # injected nothing emits nothing at all. Both go red here.
    local probe_rc=0 probe_out
    probe_out="$(bash "$handler" 2>/dev/null </dev/null)" || probe_rc=$?
    (( probe_rc == 0 )) || return 1
    [[ -n "$probe_out" ]] || return 1
    printf '%s' "$probe_out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    [[ "$probe_out" == *'every claim backed by something you ran'* ]] || return 1
    # Headroom of at least 5x. At the 5 s budget this refuses for any cost above 1000 ms,
    # which is exactly the range that was measured in the field.
    #
    # This bar was NOT moved to make it pass (#31434 QA). It went red on Windows at 4800 ms
    # against its 4000 ms limit, four consecutive runs, and the bar was right: the handler was
    # spending ~2 s per firing on process spawns that a hook running on every prompt has no
    # business paying. Removing them (`$(<file)` for two `cat`s, parameter expansion for a
    # `tr` pipeline, and the opt-out answered before the worker is spawned at all) brought the
    # same measurement to 2600-3200 ms on the same machine.
    (( budget * 1000 >= cost * 5 )) || return 1

    # AND against the number that now actually stops this handler (#31434 QA). The registered
    # budget is the HARNESS's limit; since the supervisor landed, the plugin's own deadline is
    # reached first by design, so a cost that is comfortable against the budget can still be
    # one slow turn away from the handler killing itself. Asserting only the budget would
    # leave the operative limit unmeasured.
    local deadline
    deadline="$(grep -o 'MMRY_FOUNDATION_DEADLINE_SECS:-[0-9][0-9]*'         "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" | head -1 | sed 's/.*:-//')"
    [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
    echo "measured cost: ${cost} ms; shipped deadline: ${deadline} s" >&3
    # A 3x BAR, WHICH IS NOT THE SAME THING AS A 3x MARGIN - and the difference was reported
    # the wrong way round, so it is stated correctly here (#31434 QA round 2).
    #
    # What this line asserts is a ratio of the shipped deadline to the measured handler cost:
    # 10 s against 2600-3200 ms. That is the bar, and it is a fair bar for the thing it guards
    # (a handler drifting back up toward its own deadline).
    #
    # What it is NOT is the margin on the failure customers actually suffer. That failure is
    # the HARNESS killing the hook and discarding its output, and it happens when the whole
    # firing exceeds the 20 s registered budget. Since the deadline is 10 s, the breach
    # condition is the SUPERVISOR'S OWN OVERHEAD - start-up, reaping the worker, deciding why
    # it failed, writing the JSON - exceeding the remaining 10 s. Measured under load that
    # overhead was 3.9-5.7 s, so the true margin on the customer-visible failure is about
    # 1.8x to 2.6x, not 3x.
    #
    # It is still a real residual exposure, recorded rather than rounded off: on Windows Git
    # Bash every process spawn costs ~300 ms and this handler cannot get below about half a
    # dozen of them, so a machine roughly twice as slow as a loaded developer box would trip
    # the handler's own guard. It degrades HONESTLY when it does - the customer is told the
    # directives were dropped, verified 5 of 5 - which is what the ticket exists to guarantee.
    # Making the margin comfortable means cutting the spawn count further, which is its own
    # change.
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
    [[ -f "$handler" ]] || return 1

    # The `:-N` default, and the N the handler falls back to when the env override is not a
    # positive integer. Both are shipped constants and a disagreement between them is its own
    # bug, so both are extracted and compared rather than trusting either alone.
    default="$(grep -o 'MMRY_FOUNDATION_DEADLINE_SECS:-[0-9][0-9]*' "$handler" | head -1 | sed 's/.*:-//')"
    fallback="$(grep -o '^[[:space:]]*.*|| DEADLINE=[0-9][0-9]*' "$handler" | head -1 | sed 's/.*DEADLINE=//')"
    budget="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | if length == 1 then .[0] else "DISAGREE" end' "$HOOKS_FILE" | tr -d '\r')"

    echo "shipped default deadline: ${default}s (fallback ${fallback}s); registered budget: ${budget}s" >&3

    # SAMPLE SIZE, in the form this file uses everywhere else: an extraction that found
    # nothing must fail loudly, not silently pass a comparison against an empty string.
    [[ "$default" =~ ^[0-9]+$ ]] || return 1
    [[ "$fallback" =~ ^[0-9]+$ ]] || return 1
    [[ "$budget" =~ ^[0-9]+$ ]] || return 1
    (( default > 0 )) || return 1
    [[ "$default" == "$fallback" ]] || return 1

    # The plugin must stop ITSELF before the harness stops it, with room left over to write
    # the JSON that tells the customer what happened. Without that margin the whole supervisor
    # is decoration: the harness wins the race and the output is discarded regardless.
    (( default < budget )) || return 1
    (( default + 3 <= budget )) || return 1

    # And the number the customer is told in the README is the number that ships. A doc
    # promising a 15 s stop against a handler that waits 900 is the same defect wearing
    # a different hat.
    documented="$(grep -o 'stops itself after [0-9][0-9]* seconds' "$PLUGIN_ROOT/README.md" | head -1 | sed 's/[^0-9]//g')"
    [[ "$documented" =~ ^[0-9]+$ ]] || return 1
    [[ "$documented" == "$default" ]]
}

@test "hook-budgets: no hook is budgeted below the startup cost every handler pays" {
    _write_config

    # Every entry-point handler sources mmry-client.sh, which resolves jq and loads the
    # config. That is the floor under all of them, so no registered budget may sit near it.
    local floor t timeouts count
    floor="$(_avg_ms 5 bash -c "source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'")"
    echo "shared startup floor: ${floor} ms over 5 runs" >&3

    # THE PREMISE, by observation rather than by the clock - same defect and same fix as the
    # measured-cost test above (#31434 QA round 2). `(( floor > 0 ))` cannot go red: _avg_ms
    # rounds up by a whole second before dividing, so sourcing a file that does not exist
    # still measures 200 ms. What matters is that the source SUCCEEDED and produced the
    # client's API, so that is what is asserted.
    local sourced
    sourced="$(bash -c "source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'         && declare -F mmry_load_config >/dev/null         && declare -F mmry_get_startup_memories >/dev/null         && printf SOURCED" 2>/dev/null)"
    [[ "$sourced" == "SOURCED" ]] || return 1

    timeouts="$(jq -r '[.hooks[][].hooks[].timeout] | .[]' "$HOOKS_FILE" | tr -d '\r')"
    count=0
    for t in $timeouts; do
        (( t * 1000 >= floor * 5 )) || return 1
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
    _manifest_for "$TEST_TMPDIR/mmry-foundation.md"

    # A jq that never returns in time. --version stays fast because the resolver probes it.
    local shim="$TEST_TMPDIR/hang-jq.sh"
    cat > "$shim" <<'SHIMEOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done
sleep 60
exec jq "$@"
SHIMEOF
    chmod +x "$shim"

    local handler budget start elapsed_ms out margin_ms control_ms own_ms real_bash broken
    handler="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    budget="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | if length == 1 then .[0] else "DISAGREE" end' "$HOOKS_FILE" )"
    # Trim anything that is not a digit, rather than naming a carriage return: jq.exe
    # opens stdout in text mode on Windows and appends one. An earlier form used
    # `tr -d` with a LITERAL CR in the source, which git's CRLF normalisation turned
    # into a line break on checkout and silently broke this extraction (#31434 QA).
    budget="${budget%%[![:digit:]]*}"
    [[ "$budget" =~ ^[0-9]+$ ]] || return 1

    # THE CONTROL, at the same moment on the same machine (#31411 QA round 3, item 8): the same
    # handler, whose loader fails at once, so it pays everything a firing pays - start-up, the
    # records, the report - except the wait. This assertion went red when two other suites shared the
    # machine and passed alone: what grew under load was that per-firing cost, not the deadline.
    real_bash="$(command -v bash)"
    broken="$TEST_TMPDIR/broken-bash"
    mkdir -p "$broken"
    printf '#!/bin/sh\nexit 127\n' > "$broken/bash"
    chmod +x "$broken/bash"
    start="$(_now_ms)"
    PATH="$broken:$PATH" "$real_bash" "$handler" >/dev/null 2>&1 </dev/null
    control_ms=$(( $(_now_ms) - start ))

    start="$(_now_ms)"
    out="$(MMRY_JQ="$shim" bash "$handler" 2>/dev/null)"
    elapsed_ms=$(( $(_now_ms) - start ))
    margin_ms=$(( budget * 1000 - elapsed_ms ))
    # What the plugin's own deadline cost, net of what this machine charges any firing right now.
    own_ms=$(( elapsed_ms - control_ms ))
    echo "ENFORCED wall clock: ${elapsed_ms} ms; a firing with no wait: ${control_ms} ms; the deadline's own share: ${own_ms} ms; registered budget: ${budget}s; margin: ${margin_ms} ms" >&3

    # The premise: it really did hang, so this measures the guard and not a fast path.
    (( elapsed_ms >= 9000 )) || return 1
    # THE ASSERTION. The plugin stopped itself before the harness could: under the budget, as
    # measured, whatever the load, because past it the harness discards the output.
    (( elapsed_ms < budget * 1000 )) || return 1
    # And with a stated margin. 5 s, not "under the budget": finishing at 19.5 s would satisfy the
    # letter of the invariant on an idle box and still lose the race on a loaded one. The margin is
    # what the plugin's own deadline leaves of the budget for that per-firing cost, so it is taken
    # net of the control: the shipped 15 s deadline that #31434 QA failed leaves under 5 s here on
    # any machine, while a busy machine no longer fails a 10 s one.
    (( budget * 1000 - own_ms >= 5000 )) || return 1
    # And the customer was told. A guard that wins the race and says nothing is the silent
    # loss wearing a different hat.
    [[ "$out" == *'NOT applied to this turn'* ]] || return 1
    [[ "$out" == *'exceeded'* ]] || return 1
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
    [[ -f "$handler" ]] || return 1

    # The watchdog subshell: from its `while` to the kill that ends it.
    # The FIRST such loop only, ending at its kill (#31411 QA round 2). A sed range reopens at every
    # later line that starts the same way, and the part cut added one below the watchdog, so the block
    # ran to the end of the file and took in the cut's own counters.
    block="$(awk '/^        while / { f = 1 } f { print } f && /kill -TERM/ { exit }' "$handler")"
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
    [[ -f "$handler" ]] || return 1

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
    # THE CALL, NOT THE DEFINITION (#31434 QA round 2). This took the FIRST line mentioning
    # _mmry_reinject_is_off_here - which is the function's own DEFINITION, and the definition
    # sits near the top of the file, so `off_line < worker_line` held no matter where the call
    # was. A reviewer proved it inert by moving the call to AFTER the worker spawn, which is
    # exactly the regression this check exists to catch, and the test still passed.
    #
    # So the definition line is excluded explicitly, and every line number is identified rather
    # than assumed: a definition that stopped matching, or a call that disappeared, fails here
    # instead of quietly leaving an empty string to be compared.
    # THE DEFINITION MOVED, THE PROPERTY DID NOT (#31583 QA round 4). The off-switch used to
    # be defined in this file and is now in lib-foundation-switch.sh, because the status
    # command has to reach the same answer and two derivations of it disagreed in front of a
    # customer. So the definition is asserted where it now lives, and this file is required to
    # SOURCE it before calling it, which is a third way this check can go red.
    #
    # The original lesson stands and is why every line number is still identified rather than
    # assumed: this once took the first line mentioning the function, which was its own
    # definition near the top, so the ordering held wherever the call was. A reviewer proved it
    # inert by moving the call after the worker spawn and the test still passed.
    local def_line src_line off_line worker_line
    def_line="$(grep -n '_mmry_reinject_is_off_here()' "$PLUGIN_ROOT/hooks-handlers/lib-foundation-switch.sh" | head -1 | cut -d: -f1)"
    src_line="$(printf '%s
' "$body" | grep -n 'source .*lib-foundation-switch.sh' | head -1 | cut -d: -f1)"
    off_line="$(printf '%s
' "$body" | grep -n '_mmry_reinject_is_off_here' | grep -v '_mmry_reinject_is_off_here()' | head -1 | cut -d: -f1)"
    worker_line="$(printf '%s
' "$body" | grep -n '^ *MMRY_FOUNDATION_WORKER=1 ' | head -1 | cut -d: -f1)"
    [[ "$def_line" =~ ^[0-9]+$ ]] || return 1
    [[ "$src_line" =~ ^[0-9]+$ ]] || return 1
    [[ "$off_line" =~ ^[0-9]+$ ]] || return 1
    [[ "$worker_line" =~ ^[0-9]+$ ]] || return 1
    # The supervisor must not carry its own copy of the definition any more; one answer only.
    #
    # Written as an if rather than `! cmd ...`, because a negated command is EXEMPT from
    # errexit in bats unless it is the final statement, so the short form here could never
    # fail. I wrote the short form first and proved it inert by reintroducing a definition and
    # watching the suite stay green. That is the same shape this repository has found sixteen
    # times, added by the person auditing for it.
    if printf '%s
' "$body" | grep -q '_mmry_reinject_is_off_here()'; then
        echo "the supervisor has its own copy of the off-switch definition again"
        return 1
    fi
    # The line this check is about must be a CALL.
    printf '%s
' "$body" | sed -n "${off_line}p" | grep -q 'if _mmry_reinject_is_off_here'
    # Sourced before it is called, and both before anything is spawned.
    (( src_line < off_line )) || return 1
    (( off_line < worker_line ))
}


# #31411 R6: there is no size at which the product SILENTLY withholds the set.
#
# Before this, the whole-set escape ran in the supervisor after the watchdog had released the
# worker, so nothing bounded it: measured at 17 s for 400 KB and 28 s for 2 MB, past the 20 s
# hook budget, where Claude Code discards the output and neither channel says anything. The
# escape now runs inside the worker's deadline.
#
# SINCE THE SPLIT (#31411 QA round 2). Claude Code shows a hook at most 10,000 characters, so the
# set now travels as up to six labelled parts, one per registered hook, and a set too large for six
# goes by reference. These three pin the budget for each shape: the most six parts can carry,
# delivered in full; a set thirty times the largest ever measured, by reference; and a part that
# runs out of time, reported with its number. The six firings run at the same time here, as Claude
# Code runs them, so the wall clock includes the contention between them.

# Fire all six parts at once with no payload; each writes $TEST_TMPDIR/budget-part<k>.json. Sets
# SECS to the whole seconds the six took together plus one, rounded against ourselves: date +%s%N
# is not portable to BSD date (#31411 QA round 2, on a real Mac).
_fire_six_concurrently() {
    local t0 t1 k
    t0="$(date +%s)"
    for k in 1 2 3 4 5 6; do
        bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part "$k" < /dev/null \
            > "$TEST_TMPDIR/budget-part$k.json" 2>/dev/null &
    done
    wait
    t1="$(date +%s)"
    [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]] || { echo "a clock reading was not a number: t0=[$t0] t1=[$t1]"; return 1; }
    SECS=$(( t1 - t0 + 1 ))
}

# The shipped budget of the six Foundation entries, or DISAGREE if they differ.
_foundation_budget() {
    jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | if length == 1 then .[0] else "DISAGREE" end' "$HOOKS_FILE" | tr -d '\r'
}

@test "hook-budgets: #31411 the most six parts can carry arrives in full, all six inside the budget" {
    _write_config
    # 600 directives of 89 bytes: 53,400 bytes, which cuts into exactly six parts.
    awk -v n=600 'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$TEST_TMPDIR/mmry-foundation.md"
    _manifest_for "$TEST_TMPDIR/mmry-foundation.md"
    local budget; budget="$(_foundation_budget)"
    [[ "$budget" =~ ^[0-9]+$ ]] || { echo "budget=[$budget]"; return 1; }

    _fire_six_concurrently || return 1
    echo "six parts of a 53,400-byte set in at most ${SECS} s against a ${budget} s budget" >&3

    local k ctx joined="" stored
    for k in 1 2 3 4 5 6; do
        # Trailing newlines kept: a part cut after a newline ends in one, and $( ) would drop it.
        ctx="$(jq -j '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/budget-part$k.json" | tr -d '\r' && printf '.')"
        ctx="${ctx%.}"
        [[ "$ctx" == *"This is PART $k OF 6 of the set, version "* ]] || { echo "part $k is missing or not labelled $k of 6"; return 1; }
        joined="${joined}${ctx#*$'\n\n'}"
        if grep -q systemMessage "$TEST_TMPDIR/budget-part$k.json"; then echo "part $k reported a problem"; return 1; fi
    done
    stored="$(<"$TEST_TMPDIR/mmry-foundation.md")"
    [ "$joined" = "$stored" ] || { echo "the six parts do not rejoin to the stored set"; return 1; }
    (( SECS < budget ))
}

@test "hook-budgets: #31411 a set thirty times the largest ever measured goes by reference, inside the budget, and says so" {
    _write_config
    awk -v n=12000 'BEGIN { for (i = 0; i < n; i++) print "- Directive: keep every sentence short and every claim backed by something you ran." }' > "$TEST_TMPDIR/mmry-foundation.md"
    _manifest_for "$TEST_TMPDIR/mmry-foundation.md"
    local bytes; bytes="$(wc -c < "$TEST_TMPDIR/mmry-foundation.md" | tr -d ' ')"
    # About 1 MB, as before the split, so the escape regression this file was written for would
    # still show here if it came back.
    (( bytes > 1000000 )) || return 1
    local budget; budget="$(_foundation_budget)"
    [[ "$budget" =~ ^[0-9]+$ ]] || { echo "budget=[$budget]"; return 1; }

    _fire_six_concurrently || return 1
    echo "${bytes} bytes referenced in at most ${SECS} s against a ${budget} s budget" >&3

    # The assistant is pointed at the verified file and told to read it before answering.
    local ctx; ctx="$(jq -j '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/budget-part1.json" | tr -d '\r')"
    [[ "$ctx" == *"BEFORE YOU ANSWER, read this file in full"* ]] || { echo "part 1: ${ctx:0:300}"; return 1; }
    [[ "$ctx" != *'every claim backed by something you ran'* ]] || { echo "part 1 passed off part of the set as the whole"; return 1; }
    # The customer is told, and is not told it failed.
    jq -e '.systemMessage | test("larger than Claude Code lets a plugin show")' "$TEST_TMPDIR/budget-part1.json" >/dev/null || { echo "the customer was not told"; return 1; }
    if grep -q 'NOT applied' "$TEST_TMPDIR/budget-part1.json"; then echo "a by-reference delivery was reported as a failure"; return 1; fi
    local k
    for k in 2 3 4 5 6; do
        [ ! -s "$TEST_TMPDIR/budget-part$k.json" ] || { echo "part $k spoke on a by-reference set"; return 1; }
    done
    (( SECS < budget ))
}

# A deadline is a deadline whatever caused it. Before the split the cause here was size: a 4 MB set
# could not be escaped inside one second. Each part now escapes at most 9,500 bytes and a large set
# goes by reference in well under a second, so size no longer reliably reaches the deadline. A jq
# that sleeps on every real parse does, on any machine, and is what a loaded machine looks like.
@test "hook-budgets: #31411 a part that runs out of time is REPORTED with its number, never dropped in silence" {
    _write_config
    awk -v n=380 'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$TEST_TMPDIR/mmry-foundation.md"
    _manifest_for "$TEST_TMPDIR/mmry-foundation.md"
    local slow="$TEST_TMPDIR/slow-jq.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done' 'sleep 20' 'exec jq "$@"' > "$slow"
    chmod +x "$slow"

    MMRY_JQ="$slow" MMRY_FOUNDATION_DEADLINE_SECS=1 run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" --part 3
    [ "$status" -eq 0 ]
    # Not silent: the customer channel carries a notice naming the part that was lost.
    [[ "$output" == *systemMessage* ]] || return 1
    [[ "$output" == *'part 3 of your Foundation directives was NOT applied'* ]] || return 1
    # The assistant is told as well, and which part.
    # And the assistant is told which part (#31411 QA round 2: a part names itself).
    [[ "$output" == *'could not load PART 3 of this account'* ]] || return 1
    # And no partial set was passed off as the account guidance.
    [[ "$output" != *'every claim backed by something you ran'* ]]
}
