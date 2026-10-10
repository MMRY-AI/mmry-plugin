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
VERIFY_TESTS="unit/foundation-verify.bats"
# The two-paths comparison (#31411 TC5): session-start's bytes on disk against the per-prompt
# hook's decoded output. Added to the harness at QA's request, so that its bite is proven by
# the committed run rather than by a reviewer re-deriving it.
BOTH_PATHS_TESTS="handlers/foundation-both-paths.bats"
# Both surfaces against one config in one temp directory (#31583 QA round 4 and 5).
CROSS_TESTS="handlers/foundation-cross-surface.bats"
# The split delivery: parts, versions, by reference (#31411, #31583 QA round 2, #31597). QA found it
# was in no target list, so nothing the split added could be scored.
PARTS_TESTS="handlers/foundation-parts.bats"
CUT_REL="hooks-handlers/foundation-cut.awk"
SESSION_START_REL="hooks-handlers/session-start.sh"
STATUS_CMD_TESTS="structural/foundation-status-command.bats"
HELP_REL="commands/help.md"
CLIENT_REL="hooks-handlers/mmry-client.sh"
# #31597 round 2: R3, TC4, TC5 end to end, and the TC6 checks that no test could see broken.
EDGES_TESTS="handlers/foundation-31597-edges.bats"
SWITCH_REL="hooks-handlers/lib-foundation-switch.sh"

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

# Exact-text replacement, for a target that is awkward to anchor in sed (#31411 QA round 2): code
# full of $, brackets and quotes. Replaces the first occurrence; text that is not there changes
# nothing, and the no-op guard below reports that.
_mrep() {
    local f="$1" old="$2" new="$3" t
    t="$(cat "$f"; printf x)"; t="${t%x}"
    [[ "$t" == *"$old"* ]] || return 0
    printf '%s' "${t/"$old"/"$new"}" > "$f"
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
# REPOINTED (#31411 QA round 2): the marker is written by temp and rename now, _mmry_fnd_write.
# REPOINTED (#31893): an empty marker on a free path is made with a redirect, no process; both writes go.
mutate_m06() {
    _mrep "$1/$HANDLER_REL" '        _mmry_fnd_write "$_INFLIGHT" "" || true' '        :'
    _mrep "$1/$HANDLER_REL" '        : > "$_INFLIGHT" 2>/dev/null || true' '        :'
}
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
        /^content="\$MMRY_FND_SET"$/ {
            print "cap_chars=$(( ${MMRY_FOUNDATION_TOKEN_CAP:-1500} * 4 ))"
            print "if (( ${#content} > cap_chars )); then"
            print "    content=\"${content:0:cap_chars}\""
            print "fi"
        }
    ' "$f" > "$t" && mv "$t" "$f"
}
targets_m11="$HANDLER_TESTS $BOTH_PATHS_TESTS $PARTS_TESTS"
desc_m11="#31411 the token-cap cut reinstated (the set is silently truncated again)"

# Replace the whole verification with the precondition it replaced: "the file is not empty".
# This IS #31583. Four bytes is not empty, so a stub passes and is forwarded to the assistant
# framed as the account's authoritative guidance.
#
# The mutation deletes the verification by replacing the single read of the set (#31597) with an
# unconditional pass, which is the smallest edit that restores the old behaviour.
mutate_m12() {
    local f="$1/$HANDLER_REL" t="$1/$HANDLER_REL.m12"
    awk '
        # REPOINTED (#31411 QA round 2, then #31597): it replaces the verification call itself, which
        # is now the single read of the set.
        /^mmry_read_foundation_set "\$CACHE"$/ {
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
# REPOINTED (#31583 QA r3). This matched nothing from the moment the two duplicate
# verification blocks were merged into one routine: _act_cksum stopped existing in the
# handler and became act_cksum inside mmry_verify_foundation_cache. The harness aborts on
# the first no-op, so m13 matching nothing is also why m14 through m20 were never scored.
mutate_m13() {
    local f="$1/$CLIENT_REL" t="$1/$CLIENT_REL.m13"
    awk '
        /^    if \[\[ "\$act_cksum" != "\$exp_cksum" \]\]; then$/ { print "    if false; then"; next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
file_m13="$CLIENT_REL"
targets_m13="$VERIFY_TESTS $HANDLER_TESTS"
desc_m13="#31583 checksum comparison dropped, leaving a length-only check"

# Refuse the cache but tell only the assistant, not the customer. The directives are still
# withheld correctly; the person who could rebuild the cache simply never hears. #31583
# requirement 3 is explicit that the report has to reach "the person who can act on it".
# REPOINTED (#31583 QA r5 tweaks). The refusal message moved inside an if/else, which re-indented
# the line this anchored on, and the no-op guard aborted the run on it. Indentation is now matched
# rather than assumed, and preserved, so the next re-indent cannot silence this mutation.
mutate_m14() {
    _sedi 's|^\( *\)USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn - \${REASON}.*|\1USERMSG=""|' "$1/$HANDLER_REL"
}
targets_m14="$HANDLER_TESTS"
desc_m14="#31583 the refusal is reported to the assistant but never to the customer"

# Warn on EVERY firing, including a healthy one. This passes any test that only checks
# "a damaged cache is refused" and fails the customer continuously. #31583 test case 4 exists
# precisely so the new check cannot be satisfied by warning all the time.
# REPOINTED (#31583 QA r3), same cause as m13: the readability branch moved into the shared
# routine and the cache variable is lowercase there. Forcing it true makes every cache, healthy
# ones included, report as missing, which is what test case 4 exists to catch.
mutate_m15() {
    _sedi 's|^    if (( _got == 0 )); then$|    if true; then|' "$1/$CLIENT_REL"
}
file_m15="$CLIENT_REL"
targets_m15="$VERIFY_TESTS $HANDLER_TESTS"
desc_m15="#31583 every firing reports a failure, healthy ones included"

# Put the writer back to the non-atomic clobber: redirect straight at the cache, hide the
# error, claim success. The shell sets up the redirect before jq runs, so any jq failure
# destroys the customer's good cache and the caller is told it worked.
mutate_m16() {
    local f="$1/$CLIENT_REL" t="$1/$CLIENT_REL.m16"
    awk '
        /^    body="\$\{cache\}\.body\.\$\$"$/ { print "    body=\"$cache\""; next }
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
        /^    entries="\$\(printf/ { print "    entries=\"$(grep -c '\''^- '\'' \"$body\" 2>/dev/null || true)\""; next }
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
# REPOINTED (#31583 QA r3), same cause again.
mutate_m18() {
    _sedi 's|^        if \[\[ -n "\$body" \]\]; then$|        if false; then|' "$1/$CLIENT_REL"
}
file_m18="$CLIENT_REL"
targets_m18="$VERIFY_TESTS $HANDLER_TESTS"
desc_m18="#31583 the entries=0 claim is believed without checking the cache (silent withholding)"

# REWRITTEN (#31583 QA r3). This used to mutate the status command's OWN copy of the
# entries=0 guard. That copy is gone: merging the two duplicate verification blocks into one
# routine is precisely the fix that removed it, so the mutation matched nothing and the
# no-op guard aborted the run, which is the guard working correctly on a mutation that had
# outlived its target.
#
# The risk it was written for has not gone away, it has moved. With one routine the two
# callers cannot disagree about what verifies, but the status command still decides for
# itself what to DO with the verdict, and that decision is the whole of requirement 4. This
# mutation makes it ignore a refusal and fall through to the healthy report, which is the
# same customer-visible harm as before: the hook refuses the cache while the one command
# built for asking says everything is fine. Nothing crashes, which is what makes it nasty.
mutate_m19() {
    _sedi 's|^if (( _verdict != 0 )); then$|if false; then|' "$1/$STATUS_REL"
}
file_m19="$STATUS_REL"
targets_m19="$STATUS_TESTS $STATUS_CMD_TESTS"
desc_m19="#31583 the status command ignores a refusal and reports health anyway"

# Take the command back out of the help page. The handler still works perfectly and every
# test of its OUTPUT still passes; the customer simply has no way to learn the command
# exists. Requirement 4 of #31583 is that the customer can ASK, so a command nobody can
# find satisfies the handler tests and fails the requirement.
mutate_m20() {
    _sedi 's|/mmry:foundation-status|/mmry:removed-from-help|' "$1/$HELP_REL"
}
file_m20="$HELP_REL"
targets_m20="$STATUS_CMD_TESTS"
desc_m20="#31583 the status command is no longer advertised anywhere a customer would look"

# The status command stops saying when the set was last sent. The one line that answers "are my
# directives reaching my assistant RIGHT NOW" was, at QA round 4, guarded by nothing: deleting
# it left every status test green. Its guard used to prove itself by excising the line from a
# copy and checking the copy lacked it, which could not fail (#31583 QA round 5).
mutate_m21() {
    local f="$1/$STATUS_REL" t="$1/$STATUS_REL.m21"
    # Each "Last sent" line becomes a no-op rather than being deleted (#31583 QA round 6). Deleting
    # them left if-branches with nothing in them, which bash refuses to parse, so the mutant failed
    # every test for a syntax error and its REFUSED verdict said nothing about the line it removed.
    awk '/echo "Last sent:/ { sub(/echo "Last sent:.*/, ":") } { print }' "$f" > "$t" && mv "$t" "$f"
    bash -n "$f" || { echo "m21: the mutant does not parse; fix the mutation, not the code" >&2; return 1; }
}
file_m21="$STATUS_REL"
targets_m21="$CROSS_TESTS"
desc_m21="#31583 the status command no longer says when the set was last sent"

# The status command says Delivered IN FULL without reading the hook's failure evidence, which is
# what it did until QA round 5 (4e): IN FULL straight after a prompt the log recorded as FAILED.
mutate_m22() {
    _sedi 's|^if \[\[ -n "\$_failed_why" \]\]; then$|if false; then|' "$1/$STATUS_REL"
}
file_m22="$STATUS_REL"
targets_m22="$CROSS_TESTS"
desc_m22="#31583 the status command reports delivery without reading the failure evidence"

# ---------------------------------------------------------------------------
# #31411 and #31583 QA round 2. Each new check, broken on its own; foundation-parts.bats holds the
# tests that must refuse them.
# ---------------------------------------------------------------------------

mutate_m23() { _mrep "$1/$HANDLER_REL" '    _mmry_fnd_cut_bytes "$s" fill' '    :'; }
targets_m23="$PARTS_TESTS"
desc_m23="#31411 R1 the fuller cut is never tried, so sets that fit in six parts go by reference"

mutate_m24() { _mrep "$1/$HANDLER_REL" '    [[ "$s" =~ $nonascii ]] || return 0' '    return 0'; }
targets_m24="$PARTS_TESTS"
desc_m24="#31411 R1 sets are counted in bytes only, so a non-ASCII set that fits goes by reference"

mutate_m25() { _mrep "$1/$CUT_REL" '        w = (c in ISCONT) ? 0 : ((c in ISASTRAL) ? 2 : 1)' '        w = (c in ISCONT) ? 0 : 1'; }
file_m25="$CUT_REL"
targets_m25="$PARTS_TESTS"
desc_m25="#31411 R1 a character outside the BMP counts as one, so a part of emoji overruns the limit"

mutate_m26() { _mrep "$1/$HANDLER_REL" '                t="${w%[.!?][ $'"'"'\t'"'"']*}"' '                t="$w"'; }
targets_m26="$PARTS_TESTS"
desc_m26="#31411 TC3 a memory longer than a part is cut mid-sentence again"

mutate_m27() { _mrep "$1/$HANDLER_REL" '    _fnd_path="$_fnd_snap"' '    _fnd_path="$CACHE"'; }
targets_m27="$PARTS_TESTS"
desc_m27="#31411 R1, #31583 R3 by reference points at the live shared cache again"

# REPOINTED (#31597): the copy is written from the set this turn verified, so the check that a file
# copy matched it is gone. The mutation takes the copy from the file again, which hands the assistant
# the record line and trailer as well, and bytes a refresh may have replaced since the check.
# RE-ANCHORED (#31597 QA round 3): round 2 rewrote the line to restore NULs, so the old anchor
# matched nothing and the no-op guard aborted a full run here.
mutate_m28() { _mrep "$1/$HANDLER_REL" '        && { mmry_foundation_restore_nul "$content" && printf '"'"'\n\n%s\n'"'"' "$_fnd_end"; } > "$_fnd_snaptmp" 2>/dev/null \' '        && { cp -f "$CACHE" "$_fnd_snaptmp" && printf '"'"'\n%s\n'"'"' "$_fnd_end" >> "$_fnd_snaptmp"; } 2>/dev/null \'; }
targets_m28="$PARTS_TESTS"
desc_m28="#31583 R3, #31597 the by-reference copy is taken from the file again, not from the set this turn verified"

mutate_m29() { _mrep "$1/$HANDLER_REL" '            _mmry_fnd_write "${_FOUND_TMPDIR}/mmry-foundation.outcome${MMRY_FND_SID:+.$MMRY_FND_SID}${_SFX}" "${_fnd_qtok} ${_FND_T0} none"' '            :'; }
targets_m29="$PARTS_TESTS"
desc_m29="#31583 R4 a part that leaves early records nothing, so an earlier prompt's record counts"

mutate_m30() { _mrep "$1/$STATUS_REL" '        elif [[ -n "$_set1" && "$_ok" == "ok part ${_k} of ${_n} set ${_set1}" ]]; then' '        elif [[ "$_ok" == "ok part ${_k} of ${_n}"* ]]; then'; }
file_m30="$STATUS_REL"
targets_m30="$PARTS_TESTS"
desc_m30="#31583 R4 parts from two versions of the set read as IN FULL"

mutate_m31() { _mrep "$1/$STATUS_REL" '    _unknown=1' '    _n=1'; }
file_m31="$STATUS_REL"
targets_m31="$PARTS_TESTS"
desc_m31="#31583 an unrecognised record reads as IN FULL (fails open)"

mutate_m32() { _mrep "$1/$STATUS_REL" '(( BASH_REMATCH[1] <= 6 && BASH_REMATCH[1] <= _parts_max ))' 'true'; }
file_m32="$STATUS_REL"
targets_m32="$PARTS_TESTS"
desc_m32="#31583 a part count above six is believed"

mutate_m33() { _mrep "$1/$STATUS_REL" '    [[ -f "$f" ]] || return 0' '    [[ -f "$f" ]] || return 1'; }
file_m33="$STATUS_REL"
targets_m33="$PARTS_TESTS"
desc_m33="#31583 a marker that is not a regular file is not read as a part cut short"

mutate_m34() { _mrep "$1/$STATUS_REL" '    echo "Action:       ${_partly_action}"' '    echo "Action:       re-send the prompt. If it keeps happening, run /mmry:load-memories."'; }
file_m34="$STATUS_REL"
targets_m34="$PARTS_TESTS"
desc_m34="#31583 the PARTLY advice no longer follows the cause of the missing part"

mutate_m35() { _mrep "$1/$HANDLER_REL" '            NOTICE="MMRY AI could not load PART ${MMRY_FND_PART} of this account' '            NOTICE="[Foundation part ${MMRY_FND_PART}] ${NOTICE}"; : "'; }
targets_m35="$PARTS_TESTS"
desc_m35="#31411 a failing part tells the assistant the whole turn went without the directives"

mutate_m36() { _mrep "$1/$HANDLER_REL" '        _told="${_FOUND_TMPDIR}/.mmry-foundation-byref-told${MMRY_FND_SID:+.$MMRY_FND_SID}" _tok="" _told_tok=""' '        _told="${_FOUND_TMPDIR}/.mmry-foundation-byref-told" _tok="" _told_tok=""'; }
targets_m36="$PARTS_TESTS"
desc_m36="#31411 the told marker is shared, so a session is told again after another session"

# QA #2's four survivors at 0961a90 (handback 3 of 4), each kept here so it is seen to be refused.

# H6, bash: every cut made hard, never at a line or sentence end.
mutate_m37() { _mrep "$1/$HANDLER_REL" '        if [[ "$mode" == "fill" ]]; then' '        if true; then :; elif [[ "$mode" == "fill" ]]; then'; }
targets_m37="$PARTS_TESTS"
desc_m37="#31411 QA H6 every cut in the hook is hard, never at a line or sentence end"

# H6, awk: the same in foundation-cut.awk, by making the second half impossible to reach.
mutate_m38() { _mrep "$1/$CUT_REL" '            half = int(wb / 2); a = -1' '            half = wb + 1; a = -1'; }
file_m38="$CUT_REL"
targets_m38="$PARTS_TESTS"
desc_m38="#31411 QA H6 every cut in foundation-cut.awk is hard, never at a line or sentence end"

# H7: the early-exit bound doubled. A part cut at a line end can be little over half the cap, so
# the last parts of such a set leave early and are dropped without a word.
mutate_m39() { _mrep "$1/$HANDLER_REL" '(MMRY_FND_PART - 1) * (MMRY_FND_PART_CAP / 2 - 8)' '(MMRY_FND_PART - 1) * (MMRY_FND_PART_CAP - 8)'; }
targets_m39="$PARTS_TESTS"
desc_m39="#31411 QA H7 the early exit assumes full parts, so a set of half-full parts loses its last parts"

# H9: parts 2 to 6 stop recording their failures.
# Retargeted in #31893 QA round 2: the outcome is written by _mmry_fnd_finish, and a part 2-6 now
# finishes with no outcome at all, which is the same defect.
mutate_m40() { _mrep "$1/$HANDLER_REL" '        _mmry_fnd_finish "failed ${_FOUND_OUTCOME}" "$_fnd_cut"' '        (( MMRY_FND_PART > 1 )) && _mmry_fnd_finish "" "$_fnd_cut"
        _mmry_fnd_finish "failed ${_FOUND_OUTCOME}" "$_fnd_cut"'; }
targets_m40="$PARTS_TESTS"
desc_m40="#31583 QA H9 a part 2-6 that fails records nothing, so the status cannot say which or why"

# S3: a part with no record counted as arrived.
mutate_m41() { _mrep "$1/$STATUS_REL" '            _missing="${_missing}; part ${_k} has no record of arriving"' '            _got=$(( _got + 1 ))'; }
file_m41="$STATUS_REL"
targets_m41="$PARTS_TESTS"
desc_m41="#31583 QA S3 a part with no record of arriving is counted as arrived"

# ---- #31583 / #31411 QA round 3 (DEV 02 round 4) ----------------------------------------------------

# R4(a): the status counts a record whatever prompt it came from.
mutate_m42() { _mrep "$1/$STATUS_REL" '    [[ "${_rs[k]}" == ok && -n "$_floor" ]] && (( 10#${_rt[k]} >= _floor )) || return 1' '    [[ "${_rs[k]}" == ok ]] || return 1'; }
file_m42="$STATUS_REL"
targets_m42="$PARTS_TESTS"
desc_m42="#31583 QA r3 R4(a) a part that never ran on the latest prompt is counted from an earlier one"

# R4(b): no record written when a firing starts, so an exit that writes none leaves the last prompt's.
mutate_m43() { _mrep "$1/$HANDLER_REL" '    _mmry_outcome "failed unfinished"' '    :'; }
targets_m43="$PARTS_TESTS"
desc_m43="#31583 QA r3 R4(b) no pessimistic record, so a silent exit leaves the previous prompt's record"

# R3 / P4: a part 2-6 that refuses is silent on the turn again.
mutate_m44() { _mrep "$1/$HANDLER_REL" '        _mmry_fnd_log "$(date +%FT%T 2>/dev/null || echo now) foundation reinjection REFUSED${MMRY_FND_PART:+ (part ${MMRY_FND_PART})}: ${REASON}"
        _mmry_emit "$NOTICE" "$USERMSG"' '        (( MMRY_FND_PART > 1 )) || _mmry_emit "$NOTICE" "$USERMSG"'; }
targets_m44="$PARTS_TESTS"
desc_m44="#31583 QA r3 R3 a part 2-6 that refuses tells nobody on the turn"

# A directory at the by-reference copy path: both checks for it removed, before the rename and after.
# (#31597 carried a mutant removing only the first, m48 as e8bc0bf numbered it; with the second check
# in place it could not bite, so it is folded in here.)
mutate_m45() {
    _mrep "$1/$HANDLER_REL" '    if [[ ! -d "$_fnd_snap" ]] \' '    if true \'
    _mrep "$1/$HANDLER_REL" '        && [[ -f "$_fnd_snap" ]]; then' '        ; then'
}
targets_m45="$PARTS_TESTS"
desc_m45="#31411 QA r3, #31597 a directory at the copy path takes the copy, and the assistant is pointed at the directory"

# A copy that cannot be written reported as damage to the set, with a rebuild as the remedy.
mutate_m46() { _mrep "$1/$HANDLER_REL" "        printf '%s' 'unwritable|the copy of" "        printf '%s' 'contents|the copy of"; }
targets_m46="$PARTS_TESTS"
desc_m46="#31411 QA r3, #31597 a copy that cannot be written is reported as damage, not in its own state"

# P8: the hook reads only the first 160 bytes for the session id.
mutate_m47() { _mrep "$1/$HANDLER_REL" '        while (( _fnd_rc == 0 && ${#_fnd_head} < 4096 )) && [[ ! "$_fnd_head" =~ $_fnd_re ]]; do' '        while false; do'; }
targets_m47="$PARTS_TESTS"
desc_m47="#31583 QA r3 P8 a session id past byte 160 is not read"

# P8: the status never reads the token-named records the hook falls back to.
mutate_m48() { _mrep "$1/$STATUS_REL" '    _sid=""
fi
STATUS=' '    :
fi
STATUS='; }
file_m48="$STATUS_REL"
targets_m48="$PARTS_TESTS"
desc_m48="#31583 QA r3 P8 the status looks only under the session id and says nothing yet after a delivery"

# R4(b): a failed emit records nothing of its own.
# Retargeted in #31893 QA round 2: the failed emit's outcome is handed to _mmry_fnd_finish.
mutate_m49() { _mrep "$1/$HANDLER_REL" '        _fnd_o="failed emit"' '        :'; }
targets_m49="$PARTS_TESTS"
desc_m49="#31583 QA r3 R4(b) a failed emit is not recorded as one"

# R4(b): a client that will not load is a quiet exit again.
mutate_m50() { _mrep "$1/$HANDLER_REL" 'mmry-client.sh" 2>/dev/null || exit 4' 'mmry-client.sh" 2>/dev/null || exit 0'; }
targets_m50="$PARTS_TESTS"
desc_m50="#31583 QA r3 R4(b) a loader that cannot load the client leaves in silence"

# R4(b): a part whose loader finds an empty set leaves without saying so.
# RE-ANCHORED (#31597 QA round 3): round 2 replaced the _mmry_fnd_nothing call with an "empty"
# NONE answer, so the old anchor matched nothing. The mutant now drops that answer and just exits.
mutate_m51() { _mrep "$1/$HANDLER_REL" "    printf '@@MMRY-NONE %s 0 empty@@' \"\$MMRY_FND_PART\"
    exit 0" "    exit 0"; }
targets_m51="$PARTS_TESTS"
desc_m51="#31583 QA r3 R4(b) a part whose loader finds an empty set records nothing"

# Item 6: the last-sent line gives the full size under PARTLY again.
mutate_m52() { _mrep "$1/$STATUS_REL" '    if [[ -n "$_partly" ]]; then
        _what=", in part (see above)"
    elif' '    if false; then :
    elif'; }
file_m52="$STATUS_REL"
targets_m52="$PARTS_TESTS"
desc_m52="#31411 QA r3 the last-sent line gives the full size of a set that arrived only in part"

# #31597: one file, one read. Each check the format change added, broken on its own.
# ---------------------------------------------------------------------------

# The hook verifies one copy and delivers another: a second read of the file after the check.
# This is the gap the ticket found beside the two-file one. With the record and trailer in the
# file, a second raw read also hands the assistant the record line, so the byte-for-byte tests see
# it at once; in production it would also deliver bytes a refresh had replaced since the check.
mutate_m53() {
    _sedi 's|^content="\$MMRY_FND_SET"$|content="$(<"$CACHE")"|' "$1/$HANDLER_REL"
}
targets_m53="$HANDLER_TESTS $BOTH_PATHS_TESTS"
desc_m53="#31597 the hook delivers a second read of the file, not the copy it verified"

# The writer stops ending the file with the trailer. The single read uses $(<file), which drops
# trailing newlines, so the set's own last newline is lost and every set fails on length.
mutate_m54() {
    local f="$1/$CLIENT_REL" t="$1/$CLIENT_REL.m54"
    awk '
        /^           && printf .%s. "\$MMRY_FND_TRAILER"; } > "\$tmp" 2>\/dev\/null$/ { print "           ; } > \"$tmp\" 2>/dev/null"; next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
file_m54="$CLIENT_REL"
targets_m54="$WRITER_TESTS"
desc_m54="#31597 the writer drops the trailer, so the set's last newline is lost to the read"

# The part label stops naming the version, so the assistant cannot see the parts disagree.
# REPOINTED (#31893): the framing is written once, in _mmry_fnd_payload, for both paths.
mutate_m55() {
    _sedi 's|of the set, version \$3\. The parts arrive|of the set. The parts arrive|' "$1/$HANDLER_REL"
}
targets_m55="$PARTS_TESTS"
desc_m55="#31597 the part label no longer names the version of the set"

# A set stored in this session and removed before its first delivery goes silent again: the hook
# no longer looks at the marker SessionStart leaves.
mutate_m56() {
    _sedi 's|^        if _fnd_stored="\$(mmry_foundation_stored_entries "\$MMRY_TMPDIR" "\${MMRY_FND_SID:-}")" \&\& (( _fnd_stored > 0 )); then$|        if false; then|' "$1/$HANDLER_REL"
}
targets_m56="$HANDLER_TESTS $BOTH_PATHS_TESTS"
desc_m56="#31597 a set removed before its first delivery is not reported missing (marker ignored)"

# The writer stops leaving the marker. Same customer-visible effect as m56, from the other end.
# REPOINTED (#31597 r2, R3): SessionStart used to leave the marker itself, so a set stored by the
# per-prompt refresh left none. The writer leaves it now, for every writer, so that is what breaks.
mutate_m57() {
    _mrep "$1/$CLIENT_REL" '    mmry_foundation_mark_stored "${cache%/*}" "$sid" "$entries" || true' '    :'
}
file_m57="$CLIENT_REL"
targets_m57="$BOTH_PATHS_TESTS $EDGES_TESTS"
desc_m57="#31597 the writer no longer records that a set was stored"

# WINDOWS ONLY. The writer stops probing for a jq that turns newlines into CR LF, so on Windows the
# stored set gains a carriage return on every line and the assistant is handed bytes the service
# never sent. On macOS and Linux jq does no such translation and this mutant cannot be told apart
# from the code, so it is run only where it can bite; see WINDOWS_ONLY_MUTATIONS below.
mutate_m58() {
    local f="$1/$CLIENT_REL" t="$1/$CLIENT_REL.m58"
    awk '
        /^    \[\[ "\$probe" == \*\$.\\r.\* \]\] && jqb="-b"$/ { print "    :"; next }
        { print }
    ' "$f" > "$t" && mv "$t" "$f"
}
file_m58="$CLIENT_REL"
targets_m58="$BOTH_PATHS_TESTS"
desc_m58="#31597 (Windows) the writer no longer stops jq adding CR to every line"

ALL_MUTATIONS="m01 m02 m03 m04 m05 m06 m07 m08 m09 m10 m11 m12 m13 m14 m15 m16 m17 m18 m19 m20 m21 m22 m23 m24 m25 m26 m27 m28 m29 m30 m31 m32 m33 m34 m35 m36 m37 m38 m39 m40 m41 m42 m43 m44 m45 m46 m47 m48 m49 m50 m51 m52 m53 m54 m55 m56 m57"
# m58 can only bite where jq rewrites newlines, which is a native Windows jq. Elsewhere it is run by
# name if wanted and is expected to survive there.
WINDOWS_ONLY_MUTATIONS="m58"
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ALL_MUTATIONS="$ALL_MUTATIONS $WINDOWS_ONLY_MUTATIONS" ;; esac

# NOT in ALL_MUTATIONS. Exists only so `--self-check` can prove the no-op guard actually
# aborts, instead of the comment at the top of this file merely asserting that it does. Its
# sed cannot match anything in the handler, so running it must abort the harness.
mutate_m99() { _sedi 's|IMPOSSIBLE-SENTINEL-31434-NEVER-PRESENT|x|' "$1/$HANDLER_REL"; }
targets_m99="$HANDLER_TESTS"
desc_m99="deliberately matches nothing; exercises the harness's own guard"

# P4 (Lead/PM decision, 2026-10-05): parts 2-6 stop asking what part 1 recorded, so whole-set damage
# shows a banner per part again. Numbered m59 so the same commit carries onto #31597's branch, where
# m53-m58 are taken, and added to the list here for the same reason.
# Retargeted in #31893 QA round 2: part 1's answer comes back in _FND_P1, not through "$( )".
mutate_m59() { _mrep "$1/$HANDLER_REL" '            _mmry_fnd_part1_said 8 && _fnd_p1="$_FND_P1"' '            :'; }
targets_m59="$PARTS_TESTS"
desc_m59="#31583 P4 whole-set damage shows one banner per part again"
ALL_MUTATIONS="$ALL_MUTATIONS m59"

# ---------------------------------------------------------------------------
# #31597 round 2. QA's TC6 named seven checks round 1 added with no mutant (its X5-X11); each is broken
# here on its own. Then every check round 2 added for R3, TC4 and TC5.
# ---------------------------------------------------------------------------

# X5. The status command's MISSING answer, from the stored marker, is never given.
mutate_m60() {
    _mrep "$1/$STATUS_REL" '        elif _stored="$(mmry_foundation_stored_entries "$MMRY_TMPDIR" "$_sid")" && (( _stored > 0 )); then' '        elif false; then'
}
file_m60="$STATUS_REL"
targets_m60="$STATUS_TESTS"
desc_m60="#31597 X5 the status command never answers MISSING from the stored marker"

# X6. The record pattern loses its end anchor, so anything after the checksum is believed.
mutate_m61() {
    _mrep "$1/$CLIENT_REL" "bytes=([0-9]+) cksum=([0-9]+)\$'" "bytes=([0-9]+) cksum=([0-9]+)'"
}
file_m61="$CLIENT_REL"
targets_m61="$VERIFY_TESTS"
desc_m61="#31597 X6 the record pattern is not anchored at its end"

# X7. Parts 2-6 stop requiring a version 2 record before they believe its bytes=.
mutate_m62() {
    _mrep "$1/$HANDLER_REL" '    if [[ "$_fnd_mb" =~ ^mmry-foundation\ v2\ .*bytes=([0-9]+) ]]' '    if [[ "$_fnd_mb" =~ bytes=([0-9]+) ]]'
}
targets_m62="$EDGES_TESTS"
desc_m62="#31597 X7 parts 2-6 believe any first line that says bytes="

# X8. The open is tried once, not three times.
mutate_m63() { _mrep "$1/$CLIENT_REL" '    for _try in 1 2 3; do' '    for _try in 1; do'; }
file_m63="$CLIENT_REL"
targets_m63="$VERIFY_TESTS"
desc_m63="#31597 X8 a failed open is not retried"

# X9. A lone record line with no newline is no longer refused as having no set.
mutate_m64() {
    _mrep "$1/$CLIENT_REL" '    if [[ "$header" == "$raw" || ! "$header" =~ $re ]]; then' '    if [[ ! "$header" =~ $re ]]; then'
}
file_m64="$CLIENT_REL"
targets_m64="$VERIFY_TESTS"
desc_m64="#31597 X9 a file that is only a record line is read as a record and a set"

# X10. The stored marker is believed whatever it holds.
mutate_m65() { _mrep "$1/$CLIENT_REL" '    [[ "$n" =~ ^[0-9]{1,9}$ ]] || return 1' '    :'; }
file_m65="$CLIENT_REL"
targets_m65="$VERIFY_TESTS $EDGES_TESTS"
desc_m65="#31597 X10 the stored marker is not checked to be digits"

# X11. The record line is not required at all.
mutate_m66() {
    _mrep "$1/$CLIENT_REL" '    if [[ "$header" == "$raw" || ! "$header" =~ $re ]]; then' '    if false; then'
}
file_m66="$CLIENT_REL"
targets_m66="$VERIFY_TESTS"
desc_m66="#31597 X11 a set file with no record line is not refused for it"

# R3. The per-prompt refresh stops passing its session to the writer, so the marker is filed under the
# shared token, which names whichever session started last.
mutate_m67() {
    _mrep "$1/$HANDLER_REL" 'mmry_refresh_foundation_cache "$PWD" "$CACHE" "${MMRY_FND_SID:-}"' 'mmry_refresh_foundation_cache "$PWD" "$CACHE"'
}
targets_m67="$EDGES_TESTS"
desc_m67="#31597 r2 R3 the refresh files its marker under the shared token, not its session"

# R3. The refresh function drops the session on its way to the writer.
mutate_m68() {
    _mrep "$1/$CLIENT_REL" '        mmry_write_foundation_cache "$MMRY_RESPONSE" "$cache" "$sid" || return 1' '        mmry_write_foundation_cache "$MMRY_RESPONSE" "$cache" || return 1'
}
file_m68="$CLIENT_REL"
targets_m68="$WRITER_TESTS $EDGES_TESTS"
desc_m68="#31597 r2 R3 the refresh function does not pass its session to the writer"

# TC4. SessionStart stores an empty set and says nothing.
mutate_m69() {
    _mrep "$1/$SESSION_START_REL" '    EMPTY_SYSMSG=",\"systemMessage\":\"$(_mmry_json_escape "$MMRY_FND_EMPTY_NOTICE")\""' '    :'
}
file_m69="$SESSION_START_REL"
targets_m69="$EDGES_TESTS"
desc_m69="#31597 r2 TC4 SessionStart does not tell the customer the set is empty"

# TC4. SessionStart tells, but does not record it, so the first prompt says it again.
mutate_m70() {
    _mrep "$1/$SESSION_START_REL" '    [[ -n "$_fnd_esid" ]] && { printf' '    false && { printf'
}
file_m70="$SESSION_START_REL"
targets_m70="$EDGES_TESTS"
desc_m70="#31597 r2 TC4 SessionStart does not record that it told, so the first prompt repeats it"

# TC4. The per-prompt notice is given on every prompt, the nagging #31583 removed.
mutate_m71() { _mrep "$1/$HANDLER_REL" '            if [[ "$_etok" != "$_etold_tok" ]]; then' '            if true; then'; }
targets_m71="$EDGES_TESTS"
desc_m71="#31597 r2 TC4 the empty notice is repeated on every prompt"

# TC4. The per-prompt notice is never given.
mutate_m72() { _mrep "$1/$HANDLER_REL" '[[ "$_FND_KIND" == *" empty" ]]; then' 'false; then'; }
targets_m72="$EDGES_TESTS"
desc_m72="#31597 r2 TC4 the first prompt never tells the customer the set is empty"

# TC4. The worker reports an empty set as plain nothing, so the supervisor cannot tell.
mutate_m73() { _mrep "$1/$HANDLER_REL" "    printf '@@MMRY-NONE %s 0 empty@@'" "    printf '@@MMRY-NONE %s 0@@'"; }
targets_m73="$EDGES_TESTS"
desc_m73="#31597 r2 TC4 the worker does not say the set was empty"

# TC4. The words themselves: an empty notice that does not say what it is about.
mutate_m74() { _mrep "$1/$SWITCH_REL" 'this account has no Foundation directives, so' 'nothing to apply, so'; }
file_m74="$SWITCH_REL"
targets_m74="$EDGES_TESTS"
desc_m74="#31597 r2 TC4 the empty notice no longer says the account has no Foundation directives"

# TC5. The reader removes every trailing newline again, as round 1 did.
mutate_m75() {
    _mrep "$1/$CLIENT_REL" "    body=\"\${body%\$'\\n'}\"" "    while [[ \"\$body\" == *\$'\\n' ]]; do body=\"\${body%\$'\\n'}\"; done"
}
file_m75="$CLIENT_REL"
targets_m75="$VERIFY_TESTS $EDGES_TESTS"
desc_m75="#31597 r2 TC5 the reader removes all trailing newlines, the directive's own with the writer's"

# TC5. The reader removes none, so the assistant gets a newline the service never sent.
mutate_m76() { _mrep "$1/$CLIENT_REL" "    body=\"\${body%\$'\\n'}\"" "    :"; }
file_m76="$CLIENT_REL"
targets_m76="$VERIFY_TESTS $EDGES_TESTS"
desc_m76="#31597 r2 TC5 the reader keeps the writer's own last newline"

# TC5. The writer drops NULs, as round 1 did.
mutate_m77() { _mrep "$1/$CLIENT_REL" "        | LC_ALL=C tr '\\000' '\\377' \\" "        | LC_ALL=C tr -d '\\000' \\"; }
file_m77="$CLIENT_REL"
targets_m77="$WRITER_TESTS $EDGES_TESTS"
desc_m77="#31597 r2 TC5 the writer drops a NUL instead of storing it"

# TC5. The writer stores the NUL raw, which the single read cannot hold.
mutate_m78() { _mrep "$1/$CLIENT_REL" "        | LC_ALL=C tr '\\000' '\\377' \\" "        | cat \\"; }
file_m78="$CLIENT_REL"
targets_m78="$WRITER_TESTS $EDGES_TESTS"
desc_m78="#31597 r2 TC5 the writer stores a NUL as a NUL, and the set is refused"

# TC5. The JSON escape stops turning the stored 0xFF back into a NUL.
mutate_m79() { _mrep "$1/$HANDLER_REL" '        (( _needff )) && p="${p//"$_ff"/\\u0000}"' '        :'; }
targets_m79="$EDGES_TESTS"
desc_m79="#31597 r2 TC5 an inline part delivers byte 0xFF where the service sent a NUL"

# TC5. The by-reference copy is written without turning 0xFF back into a NUL.
mutate_m80() { _mrep "$1/$HANDLER_REL" '{ mmry_foundation_restore_nul "$content" && printf' "{ printf '%s' \"\$content\" && printf"; }
targets_m80="$EDGES_TESTS"
desc_m80="#31597 r2 TC5 the by-reference copy holds byte 0xFF where the service sent a NUL"

# TC4. A part other than part 1 tells the customer too, so one prompt can say it more than once.
mutate_m81() { _mrep "$1/$HANDLER_REL" '        if (( MMRY_FND_PART == 1 )) && [[ "$_FND_KIND" == *" empty" ]]; then' '        if [[ "$_FND_KIND" == *" empty" ]]; then'; }
targets_m81="$EDGES_TESTS"
desc_m81="#31597 r2 TC4 parts 2-6 give the empty notice as well as part 1"

# TC4 (#31597 QA round 3, Q4). SessionStart does not write the token-form told-marker, so a session with
# no session id is told about the empty set at SessionStart and again on its first prompt.
mutate_m82() {
    _mrep "$1/$SESSION_START_REL" '    printf '"'"'%s'"'"' "$(mmry_foundation_session_token "$MMRY_TMPDIR" || true)" > "${MMRY_TMPDIR}/.mmry-foundation-empty-told" 2>/dev/null || true' '    :'
}
file_m82="$SESSION_START_REL"
targets_m82="$EDGES_TESTS"
desc_m82="#31597 r3 TC4 SessionStart leaves no token-form told-marker, so a session with no id is told twice"

ALL_MUTATIONS="$ALL_MUTATIONS m60 m61 m62 m63 m64 m65 m66 m67 m68 m69 m70 m71 m72 m73 m74 m75 m76 m77 m78 m79 m80 m81 m82"

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
# THE FILES THE SELECTED MUTATIONS ARE SCORED AGAINST (#31597 r2). A named run baselines exactly
# those files, so a verdict never rests on a file the baseline skipped, and a run of a few mutants does
# not wait an hour for files none of them uses. Every file, when no mutation is named.
BASE_TARGETS="$HANDLER_TESTS $BUDGET_TESTS $CONFIG_TESTS $WRITER_TESTS $STATUS_TESTS $STATUS_CMD_TESTS $VERIFY_TESTS $BOTH_PATHS_TESTS $CROSS_TESTS $PARTS_TESTS $EDGES_TESTS"
if (( $# > 0 )); then
    BASE_TARGETS=""
    for _bm in "$@"; do
        eval "_bt=\${targets_$_bm:-}"
        for _bf in $_bt; do [[ " $BASE_TARGETS " == *" $_bf "* ]] || BASE_TARGETS="$BASE_TARGETS $_bf"; done
    done
fi
printf 'baseline files:%s\n' "$BASE_TARGETS"
if _run_suite "$BASE/mmry" "$BASE_LOG" $BASE_TARGETS; then
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
    # A MUTATION THAT FAILED TO APPLY IS NOT SCORED (#31411 QA round 2). The harness used to ignore the
    # mutate function's exit status, so a mutation that errored half way was scored against a copy
    # nobody had looked at. And one that leaves a script bash cannot parse would be REFUSED for the
    # syntax error, a verdict that says nothing about the line it changed.
    if ! "mutate_$m" "$DIR/mmry"; then
        printf '%s: THE MUTATION FAILED TO APPLY. Aborting rather than scoring a copy in an unknown state.\n' "$m"
        exit 1
    fi
    if [[ "$mfile" == *.sh ]] && ! bash -n "$DIR/mmry/$mfile" 2>/dev/null; then
        printf '%s: THE MUTANT DOES NOT PARSE. Fix the mutation; a syntax error proves nothing about the code.\n' "$m"
        exit 1
    fi

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
