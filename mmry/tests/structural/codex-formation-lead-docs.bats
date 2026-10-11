#!/usr/bin/env bats
# codex-formation-lead-docs.bats - the Codex page claims only formation operations proven on Codex,
# and says plainly that a Claude Code session should lead (#31789).
#
# Requirement 4: the Codex customer documentation states only formation capabilities proven on
# Codex. Test case 5: every formation claim on the Codex page names a case proven by test cases 1
# to 4, and no unproven operation is claimed. The page used to say "Formations work, all of them",
# listing eleven operations, when Version 1.25 had proven only joining and receiving a message.
#
# THE PROVEN SET IS WRITTEN DOWN HERE WITH THE TEST CASE THAT PROVES EACH ONE, so a claim added to
# the page without a case fails, and so does a case removed from the page's claim. The live runs of
# test cases 1 to 4 are docs/evidence/31789/README.md (procedure) and live-integration.sh (the
# automated run in the real codex app-server).
#
# Requirement 0: when an idle Codex lead cannot hear its members, the docs state the limit and
# recommend Claude Code as lead. The page, the skill and the README are each checked for it.

load '../helpers/test-helper'

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    PAGE="$REPO_ROOT/docs/codex.md"
    SKILL="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    README="$REPO_ROOT/README.md"
    PLUGIN_README="$PLUGIN_ROOT/README.md"
    SERVER="$PLUGIN_ROOT/hooks-handlers/mcp-server.sh"
}

# Each claimed operation, as the page words it, and the test case of #31789 that proves it on Codex.
PROVEN='Start a formation and share its id|TC1
join one by its id|TC1
message the formation or one member|TC3
see the roster|TC3
assign work to a member|TC2
report progress|TC3
read the close-out record|TC4
close the formation out with a debrief|TC4
and leave|TC4'

# The formation bullet under "What is the same", joined into one line.
_bullet() {
    tr -d '\r' < "$PAGE" | awk '/^## What is the same/{on=1; next} on && /^## /{exit} on' \
        | awk '/^- \*\*Formations work/{on=1} on && /^- \*\*/ && !/Formations work/{exit} on' | tr '\n' ' '
}

# The part of the bullet that claims something: everything before the not-yet-tested sentence,
# which begins "Listing the formations". If that sentence is missing, the whole bullet is a claim.
_claims() {
    local b; b="$(_bullet)"
    printf '%s' "${b%%Listing the formations*}"
}

@test "TC5: the page has a formation claim, and it is the one this test reads" {
    [ -n "$(_bullet)" ] || { echo "no 'Formations work' bullet under What is the same"; return 1; }
    [[ "$(_bullet)" == *"Formations work, for the operations tested on Codex"* ]] || { _bullet; return 1; }
}

@test "TC5: every proven operation is claimed, and each names its test case" {
    local claims line phrase tc missing=""
    claims="$(_claims)"
    while IFS= read -r line; do
        phrase="${line%%|*}"; tc="${line##*|}"
        [[ "$tc" =~ ^TC[1-4]$ ]] || { echo "$phrase is not mapped to a test case 1 to 4: $tc"; return 1; }
        [[ "$claims" == *"$phrase"* ]] || missing="${missing}
  ${phrase} (${tc})"
    done <<< "$PROVEN"
    [ -z "$missing" ] || { echo "proven operations the page does not claim:${missing}"; return 1; }
}

@test "TC5: nothing unproven is claimed: listing and claiming an area appear only as not yet tested" {
    local claims; claims="$(_claims | tr 'A-Z' 'a-z')"
    [[ "$claims" != *"claim an area"* && "$claims" != *"claiming"* ]] || { echo "claiming an area is claimed: $claims"; return 1; }
    [[ "$claims" != *"list the formations"* && "$claims" != *"listing"* && "$claims" != *" list,"* ]] || { echo "listing is claimed: $claims"; return 1; }
    # And the bullet says so, rather than leaving them out silently.
    [[ "$(_bullet)" == *"Listing the formations on your account and claiming an area of the work have not been tested"* ]] || { _bullet; return 1; }
}

@test "TC5: the claim names nothing beyond the proven set" {
    # Strip each proven phrase from the claim; what is left may not name a formation operation.
    local rest line
    rest="$(_claims)"
    while IFS= read -r line; do rest="${rest//${line%%|*}/}"; done <<< "$PROVEN"
    rest="$(printf '%s' "$rest" | tr 'A-Z' 'a-z')"
    local op
    for op in "claim" "list" "debrief" "assign" "roster" "progress" "start" "join" "leave" "close-out" "speak"; do
        [[ "$rest" != *"$op"* ]] || { echo "the claim names '$op' outside the proven phrases: $rest"; return 1; }
    done
}

@test "TC5: no sentence anywhere on the page claims every formation operation" {
    local page; page="$(tr -d '\r' < "$PAGE" | tr 'A-Z' 'a-z')"
    [[ "$page" != *"formations work, all of them"* ]] || return 1
    [[ "$page" != *"every formation operation"* ]] || return 1
    [[ "$page" != *"every operation is usable here"* ]]
}

# The Codex skill names the same proven set, in its own words (tool operations, not page phrases).
SKILL_PROVEN='start|TC1
join|TC1
say (to the formation or to one member)|TC3
assign|TC2
progress|TC3
roster|TC3
report|TC4
debrief|TC4
and leave|TC4'

# The skill's sentence that states what is tested on Codex, joined into one line.
_skill_claim() {
    tr -d '\r' < "$SKILL" | tr '\n' ' ' | grep -o 'The formation operations tested on Codex are: [^.]*\.'
}

@test "TC5: the Codex skill claims exactly the proven operations, each mapped to a test case" {
    local claim line op tc rest
    claim="$(_skill_claim)"
    [ -n "$claim" ] || { echo "the skill has no 'The formation operations tested on Codex are:' sentence"; return 1; }
    rest="${claim#The formation operations tested on Codex are: }"
    while IFS= read -r line; do
        op="${line%%|*}"; tc="${line##*|}"
        [[ "$tc" =~ ^TC[1-4]$ ]] || { echo "$op is not mapped to a test case 1 to 4: $tc"; return 1; }
        [[ "$rest" == *"$op"* ]] || { echo "the skill does not claim the proven '$op' ($tc): $claim"; return 1; }
        rest="${rest//"$op"/}"
    done <<< "$SKILL_PROVEN"
    rest="$(printf '%s' "$rest" | tr 'A-Z' 'a-z')"
    for op in "list" "claim" "speak" "close-out" "script"; do
        [[ "$rest" != *"$op"* ]] || { echo "the skill's tested sentence names '$op' outside the proven set: $claim"; return 1; }
    done
}

@test "TC5: the Codex skill claims no unproven operation and states listing and claiming as not yet tested" {
    local skill; skill="$(tr -d '\r' < "$SKILL" | tr '\n' ' ')"
    local low; low="$(printf '%s' "$skill" | tr 'A-Z' 'a-z')"
    [[ "$low" != *"every formation operation"* ]] || { echo "the skill claims every formation operation"; return 1; }
    [[ "$low" != *"list and claim as scripts"* ]] || { echo "the skill offers list and claim as available"; return 1; }
    [[ "$low" != *"formations work, all of them"* ]] || return 1
    [[ "$skill" == *"Listing the formations and claiming an area have not been tested from Codex yet"* ]] \
        || { echo "the skill does not state listing and claiming as not yet tested"; return 1; }
    [[ "$skill" == *"never tell a customer they are proven here"* ]] || { echo "no instruction to the model"; return 1; }
    # Where the skill shows the two scripts, it says the same thing.
    [[ "$skill" == *"claiming an area have no tool, and neither has been tested from Codex yet"* ]] \
        || { echo "the scripts section does not say they are untested"; return 1; }
}

@test "TC5: neither plugin README claims an unproven formation operation on Codex" {
    local f low line
    for f in "$README" "$PLUGIN_README"; do
        low="$(tr -d '\r' < "$f" | tr 'A-Z' 'a-z')"
        [[ "$low" != *"every formation operation"* ]] || { echo "$f claims every formation operation"; return 1; }
        [[ "$low" != *"formations work, all of them"* ]] || { echo "$f claims all formations work"; return 1; }
        # A line that names formations and listing or claiming must say they are untested.
        while IFS= read -r line; do
            [[ "$line" == *"formation"* ]] || continue
            [[ "$line" == *"list"* || "$line" == *"claim"* ]] || continue
            [[ "$line" == *"not been tested"* ]] || { echo "$f claims listing or claiming: $line"; return 1; }
        done <<< "$low"
    done
}

@test "R0: the page states the lead limit and recommends a Claude Code lead" {
    local page; page="$(tr -d '\r' < "$PAGE" | tr '\n' ' ')"
    [[ "$page" == *"we recommend you lead a formation from Claude Code"* ]] || { echo "no recommendation"; return 1; }
    [[ "$page" == *"A Codex lead hears its members only on its next action"* ]] || { echo "no limit"; return 1; }
    [[ "$page" == *"start the formation from a Claude Code session"* ]] || { echo "no instruction"; return 1; }
    # And the customer is told what to do if they lead from Codex anyway.
    [[ "$page" == *"Check in while the work runs"* ]] || { echo "no instead"; return 1; }
}

@test "R0: the skill tells the model the limit and to recommend a Claude Code lead" {
    local skill; skill="$(tr -d '\r' < "$SKILL" | tr '\n' ' ')"
    grep -q '^### Leading a formation on Codex' "$SKILL"
    [[ "$skill" == *"hears its members only on its next action"* ]] || return 1
    [[ "$skill" == *"we recommend it does not lead one"* ]] || return 1
    [[ "$skill" == *"start the formation from Claude Code and join it from Codex"* ]] || return 1
    [[ "$skill" == *"Never tell a customer a member's message will reach an idle Codex lead on its own"* ]] || return 1
}

@test "R0: the README's idle row recommends a Claude Code lead" {
    local row; row="$(grep -i '^| *A message that arrives while your assistant is idle' "$README" | tr -d '\r')"
    [[ "$row" == *"we recommend a Claude Code session lead a formation"* ]] || { echo "$row"; return 1; }
}

@test "the page's count of tools that ask once matches the server's destructive tools" {
    # Derived from the server, so a destructive tool added there without the page saying so fails.
    local n words
    n="$(printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        | env MMRY_HOST=codex CODEX_HOME="$BATS_TEST_TMPDIR" MMRY_API_KEY=k MMRY_API_URL=http://fake.invalid MMRY_AUTH_METHOD=apikey bash "$SERVER" 2>/dev/null \
        | jq '[.result.tools[] | select(.annotations.destructiveHint)] | length')"
    case "$n" in 1) words="One of them asks once" ;; 2) words="Two of them ask once" ;; *) words="(unexpected: $n)" ;; esac
    grep -q "$words" "$PAGE" || { echo "the server has $n destructive tools; the page does not say '$words'"; return 1; }
    grep -q 'closing' "$PAGE"
}
