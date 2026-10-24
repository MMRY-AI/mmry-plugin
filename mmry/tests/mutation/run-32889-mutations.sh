#!/usr/bin/env bash
# run-32889-mutations.sh - does each #32889 check bite? (#32889)
#
# For each mutation: copy the plugin to a scratch directory, break one thing #32889 built, run
# tests/structural/foundation-isolation.bats against the copy, and report REFUSED (the suite failed, as
# it must) or SURVIVED (nothing noticed). A mutation whose text is not found aborts the run rather than
# scoring a no-op, the same guard tests/mutation/run-mutations.sh has. The untouched copy must pass first.
#
# The first mutation is the one the ticket's test case 1 names: the account-and-server key dropped from
# the file name, which is exactly the develop behaviour the ticket was filed against.
#
# usage: bash mmry/tests/mutation/run-32889-mutations.sh [name ...]     exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
K="hooks-handlers/lib-foundation-key.sh"
C="hooks-handlers/mmry-client.sh"
H="hooks-handlers/userpromptsubmit-foundation.sh"
SUITE="tests/structural/foundation-isolation.bats"
WORK="${TMPDIR:-/tmp}/mmry-32889-mut-$$"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

# Replace the first occurrence of $2 with $3 in file $1; fail if $2 is not there.
_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

declare -a NAMES=() OLDS=() NEWS=() DESCS=() FILES=()
# add <name> <description> <old text> <new text> <file>
add() { NAMES+=("$1"); DESCS+=("$2"); OLDS+=("$3"); NEWS+=("$4"); FILES+=("$5"); }

add name-unkeyed "the account-and-server key is dropped from the set's file name (the develop defect)" \
    '_MMRY_FND_SET_NAME="${1}/mmry-foundation-set.${_MMRY_FND_ACCT}.md"' \
    '_MMRY_FND_SET_NAME="${1}/mmry-foundation-set.md"' "$K"
add marker-unkeyed "the key is dropped from the session marker's file name" \
    '_MMRY_FND_SESSION_NAME="${1}/mmry-foundation.session.${_MMRY_FND_ACCT}"' \
    '_MMRY_FND_SESSION_NAME="${1}/mmry-foundation.session"' "$K"
add server-not-in-key "the key is hashed from the API key alone, so one key on two servers is one set" \
    'local id="${_MMRY_FND_ID_URL}"$'"'"'\n'"'"'"${_MMRY_FND_ID_KEY}"' \
    'local id="${_MMRY_FND_ID_KEY}"' "$K"
add account-not-in-key "the key is hashed from the server alone, so two accounts on one server are one set" \
    'local id="${_MMRY_FND_ID_URL}"$'"'"'\n'"'"'"${_MMRY_FND_ID_KEY}"' \
    'local id="${_MMRY_FND_ID_URL}"' "$K"
add reader-accepts-any-account "the reader believes a record stamped for another account" \
    '    if [[ "$exp_acct" != "$_MMRY_FND_ACCT" ]]; then' \
    '    if false; then' "$C"
add env-ignored "MMRY_API_URL and MMRY_API_KEY from the environment are not part of the identity, only the config file is" \
    '    local url="${MMRY_API_URL:-}" key="${MMRY_API_KEY:-}" txt=""' \
    '    local url="" key="" txt=""' "$K"
add config-ignored "the config file is not part of the identity, only the environment is" \
    '        if [[ -n "$_MMRY_FND_CFG" && -r "$_MMRY_FND_CFG" ]]; then' \
    '        if false; then' "$K"
add hook-reads-unkeyed "the per-prompt hook verifies the unkeyed machine-wide file" \
    'MMRY_FND_CKSUM_SECS="$left" mmry_read_foundation_set "$_FND_SETF"' \
    'MMRY_FND_CKSUM_SECS="$left" mmry_read_foundation_set "${_FOUND_TMPDIR}/mmry-foundation-set.md"' "$H"

run_suite() { ( cd "$1/tests" && PLUGIN_ROOT="$1" ./libs/bats-core/bin/bats "${SUITE#tests/}" ) > "$2" 2>&1; }

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
    if ! _rep "$WORK/m/${FILES[$i]}" "${OLDS[$i]}" "${NEWS[$i]}"; then
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
