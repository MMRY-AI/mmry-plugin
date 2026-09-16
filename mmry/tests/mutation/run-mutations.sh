#!/usr/bin/env bash
# run-mutations.sh — #31434. A mutation harness for the Foundation re-injection hook.
#
# WHY THIS FILE IS IN THE REPOSITORY.
#
# During #31434 I claimed in a report that a mutation harness had found two coverage holes,
# and that the harness itself had contained the very defect it was hunting. Neither claim was
# checkable: nothing was committed. A claim about one's own verification that nobody can
# inspect is worth less than nothing, so the harness is now here, with its self-check included
# rather than described.
#
# WHAT IT DOES.
#
# For each mutation below: copy the plugin into a scratch directory, break one specific thing,
# and run the test files that are supposed to notice. A mutation that the suite still passes
# SURVIVED - the assertion protecting that behaviour does not exist, or does not bite. A
# mutation the suite fails REFUSED.
#
# THE DEFECT THE HARNESS ITSELF HAD, now guarded against in three places:
#
#   1. A mutation whose sed matched nothing is a no-op. It runs a green suite against
#      UNMODIFIED code and reports "SURVIVED", which reads as a coverage hole that is not
#      there - or, worse, lets a real hole hide behind a typo in the mutation. Every mutation
#      is now diffed against the original and the run ABORTS if it changed nothing.
#   2. The copy must itself be able to pass. hook-budgets.bats, for instance, asserts that a
#      marketplace.json sits above the plugin root, so a scratch copy missing it would fail
#      for a reason that has nothing to do with any mutation - and every mutation would be
#      scored REFUSED for free. A BASELINE run of the untouched copy must pass before any
#      mutation is scored.
#   3. Results are printed with the failing assertion line, so "REFUSED" can be checked
#      against the reason it was refused rather than taken on trust.
#
# USAGE
#   bash mmry/tests/mutation/run-mutations.sh            # every mutation
#   bash mmry/tests/mutation/run-mutations.sh m04 m05    # named mutations only
#   bash mmry/tests/mutation/run-mutations.sh --self-check   # prove the no-op guard bites
#
# Exit status is 0 only if the baseline passed and every mutation REFUSED.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"          # .../mmry
REPO_ROOT="$(cd "$PLUGIN_SRC/.." && pwd)"
HANDLER_REL="hooks-handlers/userpromptsubmit-foundation.sh"
HANDLER_TESTS="handlers/userpromptsubmit-foundation.bats"
BUDGET_TESTS="structural/hook-budgets.bats"
CONFIG_TESTS="unit/config-loading.bats"
CLIENT_REL="hooks-handlers/mmry-client.sh"

WORK_BASE="${TMPDIR:-/tmp}/mmry-mutation-$$"
mkdir -p "$WORK_BASE"
trap 'rm -rf "$WORK_BASE" 2>/dev/null' EXIT

# PORTABLE IN-PLACE EDIT (#31434 QA round 2). Every mutation below used `sed -i SCRIPT FILE`,
# which is a GNU extension: BSD sed, the sed macOS actually ships, reads the token after -i as
# the backup SUFFIX and would consume the script. The harness therefore could not run on half
# the platforms this plugin supports - and a mutation harness that cannot run on macOS cannot
# vouch for the macOS behaviour it scores. This does the edit with a temp file and a move, which
# both seds do identically.
_sedi() {
    # $1 = sed script, $2 = file
    local _t="$2.sedi.$$"
    sed "$1" "$2" > "$_t" && mv "$_t" "$2"
}

# ---------------------------------------------------------------------------
# The mutations. Each is a function taking the scratch plugin root. Keep every
# sed script anchored on text unique to the line it targets: a mutation that
# silently hits two places is a mutation nobody can reason about.
#
# A mutation that breaks a file OTHER than the handler declares file_mNN. The no-op guard
# diffs THAT file, so a mutation pointed at the wrong file is caught as a no-op rather than
# scored against a file it never touched.
# ---------------------------------------------------------------------------

# Point the customer at a command that does not exist. This is the #31434 QA finding: the
# string said /mmry:reload-memories, which this plugin has never shipped, and the assertion
# guarding it named the same non-existent command - so the suite defended the defect.
mutate_m01() { _sedi 's|/mmry:load-memories to rebuild|/mmry:reload-memories to rebuild|g' "$1/$HANDLER_REL"; }
targets_m01="$HANDLER_TESTS"
desc_m01="deadline notice names a command the plugin does not ship"

# Report every worker failure as a timeout, which is what the supervisor did before this pass:
# a crash got a false cause, a false duration and a remedy that cannot work.
mutate_m02() { _sedi 's|if (( HIT_DEADLINE == 1 )); then|if true; then|' "$1/$HANDLER_REL"; }
targets_m02="$HANDLER_TESTS"
desc_m02="crash reported as a deadline (single-branch supervisor)"

# Remove the watchdog's marker write. The supervisor can then no longer tell that IT was the
# one who killed the worker, so the deadline path degrades into the crash path.
mutate_m03() { _sedi '/: > "\$DEADLINE_MARK" 2>\/dev\/null || true/d' "$1/$HANDLER_REL"; }
targets_m03="$HANDLER_TESTS"
desc_m03="watchdog stops recording that it caused the kill"

# Raise the SHIPPED default deadline above the registered hook budget. This disables the
# self-imposed guard entirely and reinstates the silent-loss defect the ticket exists to
# close. It survived the whole suite until #31434's fix round, because every deadline test
# injects MMRY_FOUNDATION_DEADLINE_SECS and so never touches the shipped number.
#
# ITS SEDS MATCH THE NUMBER BY SHAPE, NOT BY VALUE (#31434 QA round 2). They were written as
# `:-15` and `DEADLINE=15` against the deadline that shipped to QA. THIS PR changed that number
# to 10, so both seds matched nothing, the no-op guard correctly aborted the whole run at m04 -
# and m05 through m09 were never scored at all. The evidence vehicle for this PR's central claim
# was broken by the very commit it vouches for, and the guard doing its job is what surfaced it.
# Pinning a literal that the code under test is expected to change is a self-defeating mutation,
# so these match `[0-9][0-9]*` and the harness survives the next time the deadline moves.
mutate_m04() {
    _sedi 's|MMRY_FOUNDATION_DEADLINE_SECS:-[0-9][0-9]*|MMRY_FOUNDATION_DEADLINE_SECS:-900|' "$1/$HANDLER_REL"
    _sedi 's%|| DEADLINE=[0-9][0-9]*%|| DEADLINE=900%' "$1/$HANDLER_REL"
}
targets_m04="$BUDGET_TESTS"
desc_m04="shipped default deadline raised above the hook budget (guard disabled)"

# Stop reaping orphaned per-firing files. Every harness timeout then leaves litter in the
# customer's temp directory forever. Also survived until #31434's fix round.
mutate_m05() { _sedi 's|kill -0 "\$_stale_pid" 2>/dev/null .*|true|' "$1/$HANDLER_REL"; }
targets_m05="$HANDLER_TESTS"
desc_m05="orphaned out-file sweep disabled"

# Stop recording that a firing began. A handler that never records a firing can never report
# a lost one, which is the entire feature. Kept as a regression: this one was found by
# mutation during the build and closed then.
mutate_m06() { _sedi '/: > "\$_INFLIGHT" 2>\/dev\/null || true/d' "$1/$HANDLER_REL"; }
targets_m06="$HANDLER_TESTS"
desc_m06="in-flight marker is never written"

# Hard-wire stderr back to /dev/null, so MMRY_DEBUG captures nothing and the next
# unreproducible customer report stays unreproducible.
mutate_m07() { _sedi '/_FOUND_ERR="\${_FOUND_TMPDIR}\/mmry-foundation-debug.log"/d' "$1/$HANDLER_REL"; }
targets_m07="$HANDLER_TESTS"
desc_m07="MMRY_DEBUG no longer redirects the discarded stderr"

# Drop the failure log line, so a turn that loses the customer's directives leaves no trace.
mutate_m08() { _sedi "/foundation reinjection FAILED/d" "$1/$HANDLER_REL"; }
targets_m08="$HANDLER_TESTS"
desc_m08="abnormal exits stop writing to the log"

# Put the config parse back on NEWLINE-delimited fields - the regression #31434 shipped in
# its own first cut and which this pass removed. A config value containing a newline then
# emits more lines than there are fields, every later field shears up one, and
# foundationRefreshSeconds inherits a wrong-but-numeric value that passes its `^[0-9]+$`
# guard. Silent, plausible and wrong, which is the failure shape the whole ticket is about.
#
# Three seds because the line-based form is three separate decisions: `-r` instead of `-j`,
# no NUL terminator, and reads without `-d ''`. Reverting only one of them would not compile
# into a working line parser and the mutation would prove nothing.
mutate_m09() {
    _sedi 's/"\$MMRY_JQ" -j/"$MMRY_JQ" -r/' "$1/$CLIENT_REL"
    _sedi '/u0000/d' "$1/$CLIENT_REL"   # the only occurrence in that file
    _sedi "s/read -r -d '' _cfg_/read -r _cfg_/g" "$1/$CLIENT_REL"
}
file_m09="$CLIENT_REL"
targets_m09="$CONFIG_TESTS"
desc_m09="config parse back to newline-delimited fields (values can shear the parse)"

ALL_MUTATIONS="m01 m02 m03 m04 m05 m06 m07 m08 m09"

# NOT in ALL_MUTATIONS. Exists only so `--self-check` can prove the no-op guard actually
# aborts, instead of the comment at the top of this file merely asserting that it does. Its
# sed cannot match anything in the handler, so running it must abort the harness.
mutate_m99() { _sedi 's|IMPOSSIBLE-SENTINEL-31434-NEVER-PRESENT|x|' "$1/$HANDLER_REL"; }
targets_m99="$HANDLER_TESTS"
desc_m99="deliberately matches nothing; exercises the harness's own guard"

# A mutation this harness deliberately does NOT claim to cover, stated rather than omitted:
# the config-loading teardown (#31434 QA). Removing it leaks a file into the working tree
# instead of failing an assertion, so no mutation of it can go red. It is verified by
# inspecting the tree after a deliberately failing run, not here.

# ---------------------------------------------------------------------------

_make_copy() {
    # $1 = destination directory. Produces $1/mmry plus the marketplace.json that
    # hook-budgets.bats requires to sit above the plugin root.
    mkdir -p "$1/.claude-plugin"
    cp -R "$PLUGIN_SRC" "$1/mmry"
    cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$1/.claude-plugin/" 2>/dev/null || true
    chmod +x "$1/mmry/tests/libs/bats-core/bin/bats" 2>/dev/null || true
}

_run_suite() {
    # $1 = plugin root of the copy, $2 = log file, rest = bats targets. Returns bats' status.
    local root="$1" log="$2"; shift 2
    ( cd "$root/tests" && PLUGIN_ROOT="$root" CLAUDE_PLUGIN_ROOT="$root" \
        ./libs/bats-core/bin/bats "$@" ) > "$log" 2>&1
}

_show_failures() {
    # The assertion that bit, so a REFUSED verdict can be checked rather than believed.
    #
    # ALL of them, not the first eight (#31434 QA). A mutation that breaks a shared code
    # path fails several tests at once, and the one that proves the mutation was understood
    # is not reliably among the first few - m09 fails four alphabetically-earlier tests
    # before it reaches the shearing assertion it exists to exercise. Truncating the list
    # hid exactly the line a reader needs to check the verdict against.
    grep -E '^not ok|in test file|^# *\(' "$1" | sed 's/^/        /'
}

# --- Self-check. Proves the guard rather than describing it. ---------------------------
if [[ "${1:-}" == "--self-check" ]]; then
    printf '=== SELF-CHECK: a mutation that changes nothing must ABORT, not be scored ===\n'
    _sc_out="$("$0" m99 2>&1)"; _sc_rc=$?
    if (( _sc_rc != 0 )) && [[ "$_sc_out" == *'NO-OP MUTATION'* ]]; then
        # Print what the guard actually SAID, and the status it exited with. A self-check
        # that reports only its own verdict asks to be trusted on exactly the point it
        # exists to prove (#31434 QA).
        printf 'self-check: the guard said, verbatim:\n'
        printf '%s\n' "$_sc_out" | sed 's/^/    | /'
        printf 'self-check: exit status was %s (non-zero, as it must be).\n' "$_sc_rc"
        printf 'self-check: PASS - the no-op guard aborted the run instead of scoring it.\n'
        exit 0
    fi
    printf 'self-check: FAIL — a mutation that modified nothing was SCORED. Every verdict this\n'
    printf '            harness produces is therefore untrustworthy. Output was:\n%s\n' "$_sc_out"
    exit 1
fi

# --- Baseline. If this does not pass, nothing below means anything. -------------------
printf '=== BASELINE: an unmutated copy must pass, or every verdict below is free ===\n'
BASE="$WORK_BASE/baseline"
mkdir -p "$BASE"
_make_copy "$BASE"
BASE_LOG="$WORK_BASE/baseline.log"
if _run_suite "$BASE/mmry" "$BASE_LOG" $HANDLER_TESTS $BUDGET_TESTS $CONFIG_TESTS; then
    printf 'baseline: PASS (%s tests)\n\n' "$(grep -c '^ok ' "$BASE_LOG")"
else
    printf 'baseline: FAIL — the harness is broken, not the code. Aborting.\n'
    _show_failures "$BASE_LOG"
    exit 1
fi

# --- Mutations ------------------------------------------------------------------------
SELECTED="${*:-$ALL_MUTATIONS}"
SURVIVED_COUNT=0
REFUSED_COUNT=0

for m in $SELECTED; do
    eval "desc=\${desc_$m:-}"
    eval "targets=\${targets_$m:-}"
    if [[ -z "$desc" || -z "$targets" ]]; then
        printf '%s: UNKNOWN MUTATION. Aborting.\n' "$m"; exit 1
    fi

    DIR="$WORK_BASE/$m"
    mkdir -p "$DIR"
    _make_copy "$DIR"

    eval "mfile=\${file_$m:-$HANDLER_REL}"
    before="$WORK_BASE/$m.before"
    cp "$DIR/mmry/$mfile" "$before"
    "mutate_$m" "$DIR/mmry"

    # GUARD 1: a mutation that changed nothing would run a green suite against untouched
    # code and score it as a coverage hole. This is the defect the harness itself had.
    if cmp -s "$before" "$DIR/mmry/$mfile"; then
        printf '%s: NO-OP MUTATION - the sed matched nothing in %s. Aborting rather than\n' "$m" "$mfile"
        printf '     reporting a verdict about code that was never modified.\n'
        exit 1
    fi

    LOG="$WORK_BASE/$m.log"
    if _run_suite "$DIR/mmry" "$LOG" $targets; then
        printf '%s  SURVIVED  %s\n' "$m" "$desc"
        printf '        nothing in %s objected.\n' "$targets"
        SURVIVED_COUNT=$(( SURVIVED_COUNT + 1 ))
    else
        printf '%s  REFUSED   %s\n' "$m" "$desc"
        _show_failures "$LOG"
        REFUSED_COUNT=$(( REFUSED_COUNT + 1 ))
    fi
done

printf '\n=== %s refused, %s survived ===\n' "$REFUSED_COUNT" "$SURVIVED_COUNT"
(( SURVIVED_COUNT == 0 ))
