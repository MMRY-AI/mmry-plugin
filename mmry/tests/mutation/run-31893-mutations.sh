#!/usr/bin/env bash
# run-31893-mutations.sh - does each #31893 check bite? (#31893)
#
# For each mutation: copy the plugin to a scratch directory, break one thing #31893 built, run
# tests/handlers/foundation-in-time.bats against the copy, and report REFUSED (the suite failed, as it
# must) or SURVIVED (nothing noticed). A mutation whose text is not found aborts the run rather than
# scoring a no-op, the same guard tests/mutation/run-mutations.sh has. The untouched copy must pass first.
#
# usage: bash mmry/tests/mutation/run-31893-mutations.sh [name ...]     exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
H="hooks-handlers/userpromptsubmit-foundation.sh"
SUITE="tests/handlers/foundation-in-time.bats"
WORK="${TMPDIR:-/tmp}/mmry-31893-mut-$$"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

# Replace the first occurrence of $2 with $3 in file $1; fail if $2 is not there.
_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

declare -a NAMES=() OLDS=() NEWS=() DESCS=()
add() { NAMES+=("$1"); DESCS+=("$2"); OLDS+=("$3"); NEWS+=("$4"); }

add serve-no-compare "a part is served from the prepared copy without checking the set still reads the same" \
    '[[ -n "$raw" && "${p#*$'"'"'\n'"'"'}" == "$raw" ]] || return 1' '[[ -n "$raw" ]] || return 1'
add serve-no-version "the prepared record's version, entries and bytes are not checked against the set's" \
    '[[ "$_FND_HDR_C" == "$setid" && "$_FND_HDR_E" == "$entries" && "$_FND_HDR_B" == "$bytes" ]] || return 1' ':'
add serve-no-cap "the cut ends are not checked against the cap" \
    '(( e > prev && e - prev <= cap * (big ? 4 : 1) )) || return 1' '(( e > prev )) || return 1'
add claim-always "every part prepares, none waits" \
    '        if _mmry_fnd_claim; then' '        if _mmry_fnd_claim || true; then'
add live-claim-ignored "a claim held by a live firing does not make a part wait" \
    '            _FND_HELD="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            return 1' '            _FND_HELD="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            return 0'
add dead-claim-kept "a claim left by a firing that died is waited out, not taken over" \
    '        if kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then' '        if true; then'
add any-result "a waiting part believes a result whichever firing left it" \
    'if [[ "$l" =~ $rre && "${BASH_REMATCH[1]}" == "$seen" ]]; then' 'if [[ "$l" =~ $rre ]]; then'
add cksum-unbounded "the supervisor's cksum is not bounded by the time left" \
    'MMRY_FND_CKSUM_SECS="$left" mmry_read_foundation_set' 'mmry_read_foundation_set'
add loser-no-deadline "a waiting part never stops at its deadline" \
    '        if (( SECONDS >= DEADLINE )); then
            WORKER_RC=124 HIT_DEADLINE=1 _FND_ROUTE=done' '        if false; then
            WORKER_RC=124 HIT_DEADLINE=1 _FND_ROUTE=done'
add deadline-banner "a prompt cut short shows the person a banner again" \
    '            USERMSG=""
            _FOUND_EVENT="deadline exceeded (${DEADLINE}s)"' '            USERMSG="MMRY AI: your Foundation directives were NOT applied to this turn."
            _FOUND_EVENT="deadline exceeded (${DEADLINE}s)"'
add no-cut-marker "a turn cut short leaves nothing for the next turn" \
    '    [[ -e "$_CUTSHORT" && ! -f "$_CUTSHORT" ]] && return 0' '    return 0'
add next-not-told "the next turn does not read the cut-short marker" \
    '[[ -f "$_INFLIGHT" || -f "$_CUTSHORT" ]] && MISSED_PREVIOUS=1' '[[ -f "$_INFLIGHT" ]] && MISSED_PREVIOUS=1'
add one-key "every session shares one prepared copy" \
    '    _FND_KEY="$_FND_STAMP"' '    _FND_KEY="shared"'
add refresh-unthrottled "the refresh decision is started on every prompt" \
    '[[ "$last" =~ ^[0-9]+$ ]] && (( _FND_NOW > 0 && _FND_NOW - last < every && _FND_NOW >= last )) && return 0' ':'
add refresh-never "the refresh is never decided" \
    '        (( MMRY_FND_PART == 1 )) || return 0
        local every=300' '        return 0
        local every=300'
add no-store "the preparation is never stored, so every prompt prepares again" \
    '    _mmry_fnd_store_prepared "$_c" "$_e" "$_b" "$MMRY_FND_SET" || true' '    :'

run_suite() { ( cd "$1/tests" && ./libs/bats-core/bin/bats "${SUITE#tests/}" ) > "$2" 2>&1; }

copy() { rm -rf "$1"; mkdir -p "$1"; cp -R "$PLUGIN_SRC/." "$1/"; }

echo "baseline: the untouched copy"
copy "$WORK/base"
if ! run_suite "$WORK/base" "$WORK/base.out"; then
    echo "BASELINE FAILED; nothing can be scored"; grep '^not ok' "$WORK/base.out"; exit 2
fi
echo "baseline passed: $(grep -c '^ok' "$WORK/base.out") checks"

want=("$@"); refused=0; survived=0
for i in "${!NAMES[@]}"; do
    n="${NAMES[$i]}"
    if (( ${#want[@]} )); then
        hit=0; for w in "${want[@]}"; do [[ "$w" == "$n" ]] && hit=1; done
        (( hit )) || continue
    fi
    copy "$WORK/m"
    if ! _rep "$WORK/m/$H" "${OLDS[$i]}" "${NEWS[$i]}"; then
        echo "ABORT: mutation $n found nothing to change"; exit 3
    fi
    if run_suite "$WORK/m" "$WORK/m.out"; then
        echo "SURVIVED  $n: ${DESCS[$i]}"; survived=$(( survived + 1 ))
    else
        echo "REFUSED   $n: ${DESCS[$i]} -- $(grep '^not ok' "$WORK/m.out" | sed 's/^not ok [0-9]* //' | head -3 | paste -sd'|' -)"
        refused=$(( refused + 1 ))
    fi
done
echo "RESULT: $refused refused, $survived survived"
(( survived == 0 ))
