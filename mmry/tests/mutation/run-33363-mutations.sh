#!/usr/bin/env bash
# run-33363-mutations.sh - does each #33363 check bite? (#33363)
#
# For each mutation: copy the plugin to a scratch directory, break one thing #33363 built, run
# tests/structural/shared-session-id-isolation.bats against the copy, and report REFUSED (the suite
# failed, as it must) or SURVIVED (nothing noticed). A mutation whose text is not found aborts the run
# rather than scoring a no-op, the same guard tests/mutation/run-mutations.sh has. The untouched copy
# must pass first.
#
# The first mutation is the one the ticket's test case names: the account key dropped from a REAL-ID
# session part, which is exactly the develop adf91431 behaviour the ticket was filed against.
#
# usage: bash mmry/tests/mutation/run-33363-mutations.sh [name ...]     exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
K="hooks-handlers/lib-foundation-key.sh"
S="hooks-handlers/session-start.sh"
C="hooks-handlers/mmry-client.sh"
SUITE="tests/structural/shared-session-id-isolation.bats"
# Work folder (#33618): made inside an existing TMPDIR by a checked mktemp, never in a fallback /tmp,
# and removed only through mmry_work_dir_remove, which refuses anything it did not make.
# shellcheck source=../helpers/work-dir.bash
. "$SCRIPT_DIR/../helpers/work-dir.bash" || { echo "REFUSED TO START: tests/helpers/work-dir.bash is missing" >&2; exit 2; }
mmry_work_dir_new 33363-mut || exit 2
WORK="$MMRY_WORK_DIR"
trap 'mmry_work_dir_remove "$WORK"' EXIT

# Replace the first occurrence of $2 with $3 in file $1; fail if $2 is not there.
_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

declare -a NAMES=() OLDS=() NEWS=() DESCS=() FILES=()
# add <name> <description> <old text> <new text> <file>
add() { NAMES+=("$1"); DESCS+=("$2"); OLDS+=("$3"); NEWS+=("$4"); FILES+=("$5"); }

add real-id-part-unkeyed "the account key is dropped from a real-id session part: a real id stands alone again (the develop adf91431 defect, the ticket's mutation)" \
    '    [[ "$v" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || v=""
    mmry_foundation_account_key_v
    _MMRY_FND_SESSION_PART="${_MMRY_FND_ACCT}.${v:-none}"' \
    '    [[ "$v" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || v=""
    if [[ -n "$v" && "$v" != "unknown" ]]; then
        _MMRY_FND_SESSION_PART="$v"
        return 0
    fi
    mmry_foundation_account_key_v
    _MMRY_FND_SESSION_PART="${_MMRY_FND_ACCT}.${v:-none}"' "$K"
add part-wholly-unkeyed "the account key is dropped from every session part" \
    '_MMRY_FND_SESSION_PART="${_MMRY_FND_ACCT}.${v:-none}"' \
    '_MMRY_FND_SESSION_PART="${v:-none}"' "$K"
add empty-told-id-bare "SessionStart writes the id-form empty-set told marker under the bare id, so the hook never finds it and the customer is told twice" \
    '        mmry_foundation_session_part_v "$_fnd_esid"
        printf '"'"'%s'"'"' "$_fnd_ekey" > "${MMRY_TMPDIR}/.mmry-foundation-empty-told.${_MMRY_FND_SESSION_PART}" 2>/dev/null || true' \
    '        printf '"'"'%s'"'"' "$_fnd_ekey" > "${MMRY_TMPDIR}/.mmry-foundation-empty-told.${_fnd_esid}" 2>/dev/null || true' "$S"
add codex-stored-quick-bare "the Codex writer's quick path spells the stored marker from the bare id or token, without the account key, so two Codex accounts share mmry-foundation.stored.<sid> on one id, or mmry-foundation.stored.unknown with none" \
    'printf '"'"'%s'"'"' "$entries" > "${cache%/*}/mmry-foundation.stored.${_MMRY_FND_SESSION_PART}" 2>/dev/null || true' \
    'printf '"'"'%s'"'"' "$entries" > "${cache%/*}/mmry-foundation.stored.${sid}" 2>/dev/null || true' "$C"

run_suite() { ( cd "$1/tests" && PLUGIN_ROOT="$1" ./libs/bats-core/bin/bats "${SUITE#tests/}" ) > "$2" 2>&1; }

copy() { mmry_work_reset "$1" || exit 2; cp -R "$PLUGIN_SRC/." "$1/"; }

echo "baseline: the untouched copy"
copy "$WORK/base"
if ! run_suite "$WORK/base" "$WORK/base.log"; then
    echo "BASELINE FAILED: the untouched copy does not pass $SUITE"; tail -40 "$WORK/base.log"; exit 2
fi
echo "baseline: passed"

rc=0
for (( i = 0; i < ${#NAMES[@]}; i++ )); do
    n="${NAMES[i]}"
    if (( $# > 0 )); then
        keep=0; for want in "$@"; do [[ "$want" == "$n" ]] && keep=1; done
        (( keep )) || continue
    fi
    copy "$WORK/$n"
    if ! _rep "$WORK/$n/${FILES[i]}" "${OLDS[i]}" "${NEWS[i]}"; then
        echo "ABORT: mutation $n: its text is not in ${FILES[i]}; the runner is out of date"; exit 2
    fi
    if run_suite "$WORK/$n" "$WORK/$n.log"; then
        echo "SURVIVED  $n: ${DESCS[i]}"; rc=1
    else
        echo "REFUSED   $n: ${DESCS[i]} ($(grep -c '^not ok' "$WORK/$n.log") test(s) failed)"
    fi
done
exit $rc
