#!/usr/bin/env bash
# run-33617-mutations.sh - does each #33617 check bite? (#33617, DD-179)
#
# For each mutation: copy the plugin to a scratch directory, break one thing #33617 built, run
# tests/structural/codex-late-handoff-isolation.bats against the copy, and report REFUSED (the suite
# failed, as it must) or SURVIVED (nothing noticed). A mutation whose text is not found aborts the run
# rather than scoring a no-op, the same guard tests/mutation/run-33363-mutations.sh has. The untouched
# copy must pass first.
#
# The first two mutations are the ones the plan names: the account key dropped from the late marker's
# name in the writer (codex-hook.sh), and separately from the reader (codex-first-prompt.sh). The third
# drops it from both names in both files at once, which is exactly the develop 2818e45b behaviour the
# ticket was filed against (the 33363 QA S1 probe). The fourth removes the reader's second guard.
#
# TEMP SAFETY (the 2026-11-08 temp-folder incident, and finding 2 of the 33363 QA): TMPDIR must be set
# and must exist, or the run refuses to start; every rm is on a path guarded with ${WORK:?}.
#
# usage: bash mmry/tests/mutation/run-33617-mutations.sh [name ...]     exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="hooks-handlers/codex-hook.sh"
FIRST="hooks-handlers/codex-first-prompt.sh"
SUITE="tests/structural/codex-late-handoff-isolation.bats"

if [[ -z "${TMPDIR:-}" || ! -d "${TMPDIR:-}" ]]; then
    echo "REFUSED TO START: TMPDIR must be set to an existing directory (it is '${TMPDIR:-}')" >&2
    exit 2
fi
WORK="${TMPDIR%/}/mmry-33617-mut-$$"
mkdir -p "${WORK:?}" || exit 2
trap 'rm -rf "${WORK:?}"' EXIT

# Replace the first occurrence of $2 with $3 in file $1; fail if $2 is not there.
_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || return 1
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

# Each mutation is a function that edits the copy in $1.
# The writer names the late marker by the bare id again: the reader, looking for its keyed name, finds
# nothing, and the account's own late memories never arrive.
m_writer_late_unkeyed() {
    _rep "$1/$HOOK" '_mmry_late_file="${TMPDIR:-/tmp}/.mmry-codex-late.${_mmry_part}"' \
                    '_mmry_late_file="${TMPDIR:-/tmp}/.mmry-codex-late.${BASH_REMATCH[1]}"'
}
# The reader looks for the late marker by the bare id again.
m_reader_late_unkeyed() {
    _rep "$1/$FIRST" '_late="${_T}/.mmry-codex-late.${_part}"' \
                     '_late="${_T}/.mmry-codex-late.${_sid}"'
}
# Both names, both files, by the bare id: the develop 2818e45b defect itself (S1).
m_both_unkeyed() {
    _rep "$1/$HOOK" '_mmry_late_file="${TMPDIR:-/tmp}/.mmry-codex-late.${_mmry_part}"' \
                    '_mmry_late_file="${TMPDIR:-/tmp}/.mmry-codex-late.${BASH_REMATCH[1]}"' &&
    _rep "$1/$HOOK" '_mmry_hand="${TMPDIR:-/tmp}/.mmry-codex-start.${_mmry_part}.$$"' \
                    '_mmry_hand="${TMPDIR:-/tmp}/.mmry-codex-start.${BASH_REMATCH[1]}.$$"' &&
    _rep "$1/$FIRST" '_late="${_T}/.mmry-codex-late.${_part}"' \
                     '_late="${_T}/.mmry-codex-late.${_sid}"' &&
    _rep "$1/$FIRST" '_hand="${_T}/.mmry-codex-start.${_part}.${_pid}"' \
                     '_hand="${_T}/.mmry-codex-start.${_sid}.${_pid}"'
}
# The reader's second guard gone: an answer naming another account's memories file is delivered.
m_guard_removed() {
    _rep "$1/$FIRST" 'if [[ "$_ans" == *"$_mark"* && "$_ans" != *"mmry-memories.${_key}."* ]]; then' \
                     'if false; then'
}

declare -a NAMES=() DESCS=()
add() { NAMES+=("$1"); DESCS+=("$2"); }
add writer_late_unkeyed "the writer (codex-hook.sh) names the late marker by the bare session id"
add reader_late_unkeyed "the reader (codex-first-prompt.sh) looks for the late marker by the bare session id"
add both_unkeyed "both files spell both names by the bare session id: the develop 2818e45b defect (S1)"
add guard_removed "the reader's second guard is gone: another account's memories file is delivered"

run_suite() { ( cd "$1/tests" && PLUGIN_ROOT="$1" ./libs/bats-core/bin/bats "${SUITE#tests/}" ) > "$2" 2>&1; }

copy() { rm -rf "${WORK:?}/${1:?}"; mkdir -p "$WORK/$1"; cp -R "$PLUGIN_SRC/." "$WORK/$1/"; }

echo "baseline: the untouched copy"
copy base
if ! run_suite "$WORK/base" "$WORK/base.log"; then
    echo "BASELINE FAILED: the untouched copy does not pass $SUITE"; tail -40 "$WORK/base.log"; exit 2
fi
echo "baseline: passed ($(grep -c '^ok' "$WORK/base.log") ok)"

rc=0
for (( i = 0; i < ${#NAMES[@]}; i++ )); do
    n="${NAMES[i]}"
    if (( $# > 0 )); then
        keep=0; for want in "$@"; do [[ "$want" == "$n" ]] && keep=1; done
        (( keep )) || continue
    fi
    copy "$n"
    if ! "m_$n" "$WORK/$n"; then
        echo "ABORT: mutation $n: its text is not in the handlers; the runner is out of date"; exit 2
    fi
    if run_suite "$WORK/$n" "$WORK/$n.log"; then
        echo "SURVIVED  $n: ${DESCS[i]}"; rc=1
    else
        echo "REFUSED   $n: ${DESCS[i]} ($(grep -c '^not ok' "$WORK/$n.log") test(s) failed: $(grep '^not ok' "$WORK/$n.log" | sed 's/^not ok \([0-9]*\).*/\1/' | tr '\n' ' '))"
    fi
done
exit $rc
