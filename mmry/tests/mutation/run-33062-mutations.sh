#!/usr/bin/env bash
# run-33062-mutations.sh - does each #33062 check bite?
#
# For each mutation: copy the checkout to a scratch directory, plant one fault in what #33062 built,
# run handlers/codex-start-budget.bats, and report REFUSED (the suite failed, as it must) with the
# tests that failed, or SURVIVED (nothing noticed). A mutation whose text is not found aborts the run
# rather than scoring a no-op. The untouched copy must pass first.
#
# usage: bash mmry/tests/mutation/run-33062-mutations.sh [name ...]   exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="${TMPDIR:-/tmp}/mmry-33062-mut-$$"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
SUITE="handlers/codex-start-budget.bats"
HOOK="mmry/hooks-handlers/codex-hook.sh"
INIT="mmry/hooks-handlers/session-init.sh"
START="mmry/hooks-handlers/session-start.sh"

# _rep FILE OLD NEW - replace the first occurrence; fail if OLD is not there.
_rep() {
    local t; t="$(cat "$1"; printf x)"; t="${t%x}"
    [[ "$t" == *"$2"* ]] || { echo "  mutation text not found in $1: ${2:0:60}" >&2; return 1; }
    printf '%s' "${t/"$2"/"$3"}" > "$1"
}

# Each mutation is a function that edits the copy in $1.
m_no_deliver_first() { _rep "$1/$HOOK" '{ _mmry_codex_start "$@" <&3' '{ bash "$TARGET" "$@" <&3'; }
m_update_first() { _rep "$1/$START" 'if (( _mmry_codex == 0 )); then
    bash "${PLUGIN_ROOT}/hooks-handlers/self-update.sh"' 'if true; then
    bash "${PLUGIN_ROOT}/hooks-handlers/self-update.sh"'; }
m_register_first() { _rep "$1/$START" 'if (( _mmry_codex == 0 )); then
    mmry_register_session' 'if true; then
    mmry_register_session'; }
m_hook_holds_output() { _rep "$1/$HOOK" '    exec >/dev/null
    wait "$start_pid"' '    wait "$start_pid"'; }
m_start_holds_output() { _rep "$1/$START" '    exec >/dev/null
    mmry_register_session' '    mmry_register_session'; }
m_stdin_lost() { _rep "$1/$HOOK" '_mmry_codex_start "$@" <&3 3<&-' '_mmry_codex_start "$@" 3<&-'; }
m_stderr_held() { _rep "$1/$HOOK" '3<&- 2>"$_mmry_errlog" &' '3<&- &'; }
m_init_skips_update() { _rep "$1/$INIT" 'if [[ "$_MMRY_HOST_V" == "codex" ]] && mmry_host_assert_own_credential' 'if false && mmry_host_assert_own_credential'; }
m_start_twice() { _rep "$1/$INIT" 'if [[ "${1:-}" != "--after-delivery" || "$_MMRY_HOST_V" != "codex" ]]; then' 'if true; then'; }
m_no_notice() { _rep "$1/$HOOK" 'if (( _mmry_late == 1 )); then' 'if false; then'; }
# bash 3.2 reports a timeout as the end of the output: without the second test the notice is never
# given there. Only a macOS (bash 3.2) run can see this one refuse.
m_no_bash32_timeout() { _rep "$1/$HOOK" '        elif [[ "$_mmry_out" != *"}" ]]' '        elif false && [[ "$_mmry_out" != *"}" ]]'; }
m_no_budget() { _rep "$1/$HOOK" "read -r -d '' -t \"\$_mmry_left\" _mmry_out" "read -r -d '' _mmry_out"; }
m_launcher_clock_ignored() { _rep "$1/$HOOK" '                _mmry_spent=$_mmry_since' '                :'; }
# The measured time check itself: a budget past the limit and a start that needs 35 s before it
# delivers. Only the elapsed-time assertion can catch this; the memories do arrive.
m_budget_past_limit() {
    _rep "$1/$HOOK" '(( _mmry_budget < 1 || _mmry_budget > 25 ))' '(( _mmry_budget < 1 || _mmry_budget > 99 ))' &&
    _rep "$1/$HOOK" '_mmry_budget="${MMRY_CODEX_START_BUDGET:-20}"' '_mmry_budget="${MMRY_CODEX_START_BUDGET:-60}"' &&
    _rep "$1/$START" 'MEM_FILE="${MMRY_TMPDIR}/mmry-memories.md"' 'sleep 35
MEM_FILE="${MMRY_TMPDIR}/mmry-memories.md"'
}
# Requirement 3's control: Claude Code losing its update check before the memories.
m_claude_update_skipped() { _rep "$1/$START" 'if (( _mmry_codex == 0 )); then
    bash "${PLUGIN_ROOT}/hooks-handlers/self-update.sh"' 'if false; then
    bash "${PLUGIN_ROOT}/hooks-handlers/self-update.sh"'; }

ALL=(no_deliver_first update_first register_first hook_holds_output start_holds_output stdin_lost
     stderr_held init_skips_update start_twice no_notice no_bash32_timeout no_budget launcher_clock_ignored budget_past_limit
     claude_update_skipped)
(( $# > 0 )) && ALL=("$@")

copy() {
    rm -rf "$1"; mkdir -p "$1"
    ( cd "$REPO_SRC" && tar cf - --exclude=.git . ) | ( cd "$1" && tar xf - )
}
run_suite() { ( cd "$1/mmry/tests" && ./libs/bats-core/bin/bats "$SUITE" ) > "$2" 2>&1; }

echo "== baseline (no mutation)"
copy "$WORK/base"
if ! run_suite "$WORK/base" "$WORK/base.out"; then
    echo "the untouched copy does not pass $SUITE; mutations would prove nothing"
    grep '^not ok' "$WORK/base.out"
    exit 2
fi
echo "   passes: $(grep -c '^ok' "$WORK/base.out") tests"

survived=0
for name in "${ALL[@]}"; do
    if [[ "$name" == no_bash32_timeout ]] && (( BASH_VERSINFO[0] >= 4 )); then
        echo "== $name: NOT APPLICABLE on bash $BASH_VERSION (only bash 3.2 reports a timeout as the end of the output; run this on a stock Mac)"
        continue
    fi
    copy "$WORK/m"
    if ! "m_${name}" "$WORK/m"; then echo "== $name: could not be applied"; exit 2; fi
    if run_suite "$WORK/m" "$WORK/$name.out"; then
        echo "== $name: SURVIVED"
        survived=$((survived + 1))
    else
        echo "== $name: REFUSED by: $(grep '^not ok' "$WORK/$name.out" | sed 's/^not ok \([0-9]*\).*/\1/' | tr '\n' ' ')"
    fi
done
(( survived == 0 ))
