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
WRITER_TESTS="unit/foundation-cache-write.bats"
STATUS_TESTS="handlers/foundation-status.bats"
STATUS_REL="hooks-handlers/foundation-status.sh"
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

# Move the re-injection OFF-SWITCH to after the worker is spawned. The opt-out then costs an
# opted-out customer the entire ~3 s of process spawns it exists to avoid, and the crash
# notice's own remedy ("set foundationReinject to false") stops working, because the thing
# that crashes is spawned before the setting is consulted.
#
# This mutation exists because the check guarding that ordering was INERT (#31434 QA round 2):
# it took the first line naming the function, which is its DEFINITION near the top of the file,
# so the comparison held wherever the call actually sat. A reviewer proved it by making exactly
# this move. A one-off proof is not a guard, so the move is a mutation now.
#
# awk rather than sed: this is a MOVE across lines, and a multi-line move is not something BRE
# sed does the same way on GNU and BSD.
mutate_m10() {
    local f="$1/$HANDLER_REL" t="$1/$HANDLER_REL.m10"
    awk '
        /^    if _mmry_reinject_is_off_here; then$/ { skip = 3 }
        skip > 0 { skip--; next }
        { print }
        /^    WORKER_PID=\$!$/ {
            print ""
            print "    if _mmry_reinject_is_off_here; then"
            print "        exit 0"
            print "    fi"
        }
    ' "$f" > "$t" && mv "$t" "$f"
}
targets_m10="$BUDGET_TESTS"
desc_m10="re-injection off-switch moved to after the worker spawn (opt-out pays for the spawn)"


# ===========================================================================
# #31411 and #31583 mutations. Each one reinstates a specific defect that
# actually shipped, so a REFUSED verdict is evidence that the assertion added
# for it bites, rather than a count of tests that happened to pass.
# ===========================================================================

# Put the cut back. This is #31411 exactly as it shipped: a raw substring at the token cap
# times four, applied to the account's standing directives, with a note appended to the
# framing. On the account that surfaced it the cut landed mid-sentence inside a list of
# corporate values and four of the eight had never reached any assistant.
#
# awk, not sed: this inserts a multi-line block, and multi-line insertion is not something
# BRE sed does identically on GNU and BSD.
mutate_m11() {
    local f="$1/$HANDLER_REL" t="$1/$HANDLER_REL.m11"
    awk '
        { print }
        /^content="\$\(<"\$CACHE"\)"$/ {
            print "cap_chars=$(( ${MMRY_FOUNDATION_TOKEN_CAP:-1500} * 4 ))"
            print "if (( ${#content} > cap_chars )); then"
            print "    content=\"${content:0:cap_chars}\""
            print "fi"
        }
    ' "$f" > "$t" && mv "$t" "$f"
}
targets_m11="$HANDLER_TESTS"
desc_m11="#31411 the token-cap cut reinstated (the set is silently truncated again)"

# Replace the whole verification with the precondition it replaced: "the file is not empty".
# This IS #31583. Four bytes is not empty, so a stub passes and is forwarded to the assistant
# framed as the account's authoritative guidance.
#
# The mutation deletes the verification block by replacing the manifest read with an
# unconditional pass, which is the smallest edit that restores the old behaviour.
mutate_m12() {
    local f="$1/$HANDLER_REL" t="$1/$HANDLER_REL.m12"
    awk '
        /^MANIFEST=/ { print "MANIFEST=\"${CACHE}.manifest\""
                       print "[[ -s \"$CACHE\" ]] || exit 0"
                       print "content=\"$(<\"$CACHE\")\""
                       print "printf '\''%s'\'' \"The following are the account'\''s FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive."
                       print ""
                       print "${content}\""
                       print "exit 0"
                       next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
targets_m12="$HANDLER_TESTS"
desc_m12="#31583 verification replaced by the old 'file is not empty' precondition"

# Keep the manifest, keep the byte-count check, DROP the checksum comparison. This is the
# specific trap #31583 test case 2 names: "Length alone is not validity, and a check that
# only measures length would pass this while failing the customer." A harness that scored
# m12 alone would not distinguish a real content check from a length check.
mutate_m13() {
    local f="$1/$HANDLER_REL" t="$1/$HANDLER_REL.m13"
    awk '
        /^if \[\[ "\$_act_cksum" != "\$_exp_cksum" \]\]; then$/ { print "if false; then"; next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
targets_m13="$HANDLER_TESTS"
desc_m13="#31583 checksum comparison dropped, leaving a length-only check"

# Refuse the cache but tell only the assistant, not the customer. The directives are still
# withheld correctly; the person who could rebuild the cache simply never hears. #31583
# requirement 3 is explicit that the report has to reach "the person who can act on it".
mutate_m14() {
    _sedi 's|^        USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn - \${REASON}.*|        USERMSG=""|' "$1/$HANDLER_REL"
}
targets_m14="$HANDLER_TESTS"
desc_m14="#31583 the refusal is reported to the assistant but never to the customer"

# Warn on EVERY firing, including a healthy one. This passes any test that only checks
# "a damaged cache is refused" and fails the customer continuously. #31583 test case 4 exists
# precisely so the new check cannot be satisfied by warning all the time.
mutate_m15() {
    _sedi 's|^if \[\[ ! -r "\$CACHE" \]\]; then$|if true; then|' "$1/$HANDLER_REL"
}
targets_m15="$HANDLER_TESTS"
desc_m15="#31583 every firing reports a failure, healthy ones included"

# Put the writer back to the non-atomic clobber: redirect straight at the cache, hide the
# error, claim success. The shell sets up the redirect before jq runs, so any jq failure
# destroys the customer's good cache and the caller is told it worked.
mutate_m16() {
    local f="$1/$CLIENT_REL" t="$1/$CLIENT_REL.m16"
    awk '
        /^    tmp="\$\{cache\}\.new\.\$\$"$/ { print "    tmp=\"$cache\""; next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
file_m16="$CLIENT_REL"
targets_m16="$WRITER_TESTS"
desc_m16="#31583 writer redirects straight at the cache again (a jq failure destroys it)"

# Count entries by grepping the file instead of asking jq about the response. A single
# memory whose content is a bulleted list then counts as several, and the manifest records a
# number that is not the number of the customer's directives.
mutate_m17() {
    # Anchored on the START of the assignment only. The first cut of this pattern required a
    # trailing backslash, matching a line-continuation form this file does not use, so the
    # mutation changed nothing and the harness aborted the run on its own no-op guard. That
    # is the guard doing its job, and it is why m17 had never produced a verdict.
    local f="$1/$CLIENT_REL" t="$1/$CLIENT_REL.m17"
    awk '
        /^    entries="\$\(printf/ { print "    entries=\"$(grep -c '\''^- '\'' \"$tmp\" 2>/dev/null || true)\""; next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
file_m17="$CLIENT_REL"
targets_m17="$WRITER_TESTS"
desc_m17="#31583 manifest entry count taken from a line count rather than the response"

# Drop the check that an "empty set" manifest agrees with the cache beside it. entries is
# the one manifest field the bytes+cksum gate does not compare, and zero short-circuits the
# gate altogether, so without this guard a manifest reading entries=0 next to a cache full
# of directives makes the handler withhold the whole set and say NOTHING. Measured at 914
# bytes before the guard existed. A mutation that survives here means the product can go
# silent on a live account and no test notices.
mutate_m18() {
    _sedi 's|^    if \[\[ -s "\$CACHE" \]\]; then$|    if false; then|' "$1/$HANDLER_REL"
}
targets_m18="$HANDLER_TESTS"
desc_m18="#31583 the entries=0 claim is believed without checking the cache (silent withholding)"

# The same guard in the status command. This one is nastier than m18 because nothing breaks:
# the handler still refuses the cache, and /mmry:foundation-status cheerfully reports "VALID
# and EMPTY - nothing is being withheld" for the state it is refusing. A customer checking
# the one command built for asking would be sent away from a live fault.
mutate_m19() {
    _sedi 's|^    if \[\[ -s "\$CACHE" \]\]; then$|    if false; then|' "$1/$STATUS_REL"
}
file_m19="$STATUS_REL"
targets_m19="$STATUS_TESTS"
desc_m19="#31583 the status command reports health for a cache the handler is refusing"

ALL_MUTATIONS="m01 m02 m03 m04 m05 m06 m07 m08 m09 m10 m11 m12 m13 m14 m15 m16 m17 m18 m19"

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
if _run_suite "$BASE/mmry" "$BASE_LOG" $HANDLER_TESTS $BUDGET_TESTS $CONFIG_TESTS $WRITER_TESTS $STATUS_TESTS; then
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
