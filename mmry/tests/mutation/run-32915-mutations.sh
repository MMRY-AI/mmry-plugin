#!/usr/bin/env bash
# run-32915-mutations.sh - does each #32915 check bite? (#32915)
#
# For each mutation: copy the plugin to a scratch directory, break one thing #32915 built, run
# tests/structural/startup-memories-isolation.bats against the copy, and report REFUSED (the suite
# failed, as it must) or SURVIVED (nothing noticed). A mutation whose text is not found aborts the run
# rather than scoring a no-op, the same guard tests/mutation/run-mutations.sh has. The untouched copy
# must pass first.
#
# The first mutation is the one the ticket's test case 5 names: the account-and-server key dropped
# from the startup file's name, which is exactly the develop behaviour the ticket was filed against.
#
# usage: bash mmry/tests/mutation/run-32915-mutations.sh [name ...]     exit 0 only if every one REFUSED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
K="hooks-handlers/lib-foundation-key.sh"
S="hooks-handlers/session-start.sh"
H="hooks-handlers/userpromptsubmit-foundation.sh"
C="hooks-handlers/mmry-client.sh"
SUITE="tests/structural/startup-memories-isolation.bats"
# Work folder (#33618): made inside an existing TMPDIR by a checked mktemp, never in a fallback /tmp,
# and removed only through mmry_work_dir_remove, which refuses anything it did not make.
# shellcheck source=../helpers/work-dir.bash
. "$SCRIPT_DIR/../helpers/work-dir.bash" || { echo "REFUSED TO START: tests/helpers/work-dir.bash is missing" >&2; exit 2; }
mmry_work_dir_new 32915-mut || exit 2
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

add memories-unkeyed "the account-and-server key is dropped from the startup file's name (the develop defect, test case 5)" \
    '_MMRY_FND_MEMORIES_NAME="${1}/mmry-memories.${_MMRY_FND_ACCT}${sid:+.$sid}.md"' \
    '_MMRY_FND_MEMORIES_NAME="${1}/mmry-memories.md"' "$K"
add memories-session-only "the startup file is named by the session id alone, so two accounts with no session id share one" \
    '_MMRY_FND_MEMORIES_NAME="${1}/mmry-memories.${_MMRY_FND_ACCT}${sid:+.$sid}.md"' \
    '_MMRY_FND_MEMORIES_NAME="${1}/mmry-memories${sid:+.$sid}.md"' "$K"
add memories-account-only "the startup file is named by the account alone, so a second session of one account replaces the first's file" \
    '_MMRY_FND_MEMORIES_NAME="${1}/mmry-memories.${_MMRY_FND_ACCT}${sid:+.$sid}.md"' \
    '_MMRY_FND_MEMORIES_NAME="${1}/mmry-memories.${_MMRY_FND_ACCT}.md"' "$K"
add instruction-legacy "the file is written under its keyed name but the model is told to read the legacy machine-wide one" \
    'model_path="$(mmry_host_path_for_model "$MEM_FILE")"' \
    'model_path="$(mmry_host_path_for_model "${MMRY_TMPDIR}/mmry-memories.md")"' "$S"
add stamp-dropped "the startup file is no longer stamped with the account it was written for" \
    'echo "# MMRY AI — Loaded Memories (account ${_MMRY_FND_ACCT})"' \
    'echo "# MMRY AI — Loaded Memories"' "$S"
add failclosed-off "a session whose account or server cannot be identified loads memories anyway" \
    'if ! mmry_foundation_identity_known_v || [[ "${MMRY_AUTH_METHOD:-}" != "apikey" ]]; then' \
    'if false; then' "$S"
add url-default-counts "an empty server address is taken as the default server, so the identity is never unknown for want of one" \
    '    [[ -n "$MMRY_API_URL" ]] && _MMRY_CFG_URL_GIVEN=1' \
    '    _MMRY_CFG_URL_GIVEN=1' "$C"
add legacy-not-swept "the startup memories files, the legacy machine-wide one and every keyed per-session one, are left out of the week-old sweep" \
    "-o -name 'mmry-memories.md' -o -name 'mmry-memories.*.md'" \
    "" "$S"
add log-unkeyed "the failure log goes back to the shared name" \
    '_MMRY_FND_LOG_NAME="${1}/mmry-foundation.${_MMRY_FND_ACCT}.log"' \
    '_MMRY_FND_LOG_NAME="${1}/mmry-foundation.log"' "$K"
add refresh-stamp-unkeyed "the refresh throttle stamp goes back to the shared name, so one account's stamp throttles the other" \
    '_MMRY_FND_REFRESH_CHECKED_NAME="${1}/.mmry-foundation-refresh-checked.${_MMRY_FND_ACCT}"' \
    '_MMRY_FND_REFRESH_CHECKED_NAME="${1}/.mmry-foundation-refresh-checked"' "$K"
add refresh-lock-unkeyed "the refresh lock goes back to the shared name" \
    '_MMRY_FND_REFRESH_NAME="${1}/.mmry-foundation-refresh.${_MMRY_FND_ACCT}"' \
    '_MMRY_FND_REFRESH_NAME="${1}/.mmry-foundation-refresh"' "$K"
add byref-unkeyed "the by-reference copy goes back to the session-or-token name, shared when there is neither (NEW-2)" \
    '_MMRY_FND_BYREF_NAME="${1}/mmry-foundation.byref.${_MMRY_FND_ACCT}${2:+.$2}.md"' \
    '_MMRY_FND_BYREF_NAME="${1}/mmry-foundation.byref${2:+.$2}.md"' "$K"
# QA round 1 (#32915). Requirement 3: the per-prompt hook's gates. Requirement 2: the per-session markers.
add worker-gate-off "the worker's refresh and delivery run for a session SessionStart refused as unidentified (QA probe3)" \
    'if ! mmry_foundation_identity_known_v || [[ "${MMRY_AUTH_METHOD:-}" != "apikey" ]]; then
    _mmry_fnd_nothing' \
    'if false; then
    _mmry_fnd_nothing' "$H"
add supervisor-gate-off "the supervisor serves a set standing at the name an unidentified session computes" \
    '    if ! mmry_foundation_identity_known_v || ! mmry_foundation_auth_apikey_v; then
        exit 0' \
    '    if false; then
        exit 0' "$H"
add session-part-unkeyed "the account key is dropped from every session part, so two accounts in one session, or with no session id, share every per-session marker again" \
    '_MMRY_FND_SESSION_PART="${_MMRY_FND_ACCT}.${v:-none}"' \
    '_MMRY_FND_SESSION_PART="${v:-none}"' "$K"
add prepared-unkeyed "the prepared copy, claim, result and stored check drop the account key and go back to the bare session id, or the bare token when there is none, so two accounts share them on one id or with no id" \
    '    _FND_KEY="$_MMRY_FND_SESSION_PART"' \
    '    _FND_KEY="${_FND_STAMP:-none}"' "$H"
# QA round 2 (#32915). F-B: the four notice markers made with no session id.
add inflight-unkeyed "the in-flight marker goes back to the id-or-nothing name, so one account's killed turn is reported to the other account" \
    '_INFLIGHT="${_FOUND_TMPDIR}/.mmry-foundation-inflight.${_FND_SIDPART}${_SFX}"' \
    '_INFLIGHT="${_FOUND_TMPDIR}/.mmry-foundation-inflight${MMRY_FND_SID:+.$MMRY_FND_SID}${_SFX}"' "$H"
add cutshort-unkeyed "the cut-short marker goes back to the id-or-nothing name" \
    '_CUTSHORT="${_FOUND_TMPDIR}/.mmry-foundation-cutshort.${_FND_SIDPART}${_SFX}"' \
    '_CUTSHORT="${_FOUND_TMPDIR}/.mmry-foundation-cutshort${MMRY_FND_SID:+.$MMRY_FND_SID}${_SFX}"' "$H"
add byref-told-unkeyed "the by-reference told marker goes back to the id-or-nothing name, so one account's telling stands for the other's" \
    '_told="${_FOUND_TMPDIR}/.mmry-foundation-byref-told.${_FND_SIDPART}" _tok="" _told_tok=""' \
    '_told="${_FOUND_TMPDIR}/.mmry-foundation-byref-told${MMRY_FND_SID:+.$MMRY_FND_SID}" _tok="" _told_tok=""' "$H"
add empty-told-unkeyed "SessionStart writes the empty-set told marker back at the bare shared name" \
    '"${MMRY_TMPDIR}/.mmry-foundation-empty-told.${_MMRY_FND_SESSION_PART}"' \
    '"${MMRY_TMPDIR}/.mmry-foundation-empty-told"' "$S"
# QA round 2 (#32915). F-C: the auth-method half of the supervisor's gate.
add supervisor-auth-dropped "the supervisor asks only whether the server was given, so an OAuth session refused at SessionStart is served the set an API-key session stored at the same name (QA probe4)" \
    '    if ! mmry_foundation_identity_known_v || ! mmry_foundation_auth_apikey_v; then
        exit 0' \
    '    if ! mmry_foundation_identity_known_v; then
        exit 0' "$H"
add auth-oauth-as-apikey "the library takes any credential for an API key, so the auth method named in the config never refuses" \
    '    [[ -z "$auth" && -n "$key" ]] && auth="apikey"' \
    '    [[ -n "$key" ]] && auth="apikey"' "$K"
# QA round 2 (#32915). F-A: the Codex writer's quick path.
add codex-stored-quick-unkeyed "the Codex writer's quick path spells the stored marker from the bare id or token, without the account key, so two Codex accounts share mmry-foundation.stored.unknown with no session id (QA probe5), or mmry-foundation.stored.<sid> on one id" \
    'printf '"'"'%s'"'"' "$entries" > "${cache%/*}/mmry-foundation.stored.${_MMRY_FND_SESSION_PART}" 2>/dev/null || true' \
    'printf '"'"'%s'"'"' "$entries" > "${cache%/*}/mmry-foundation.stored.${sid}" 2>/dev/null || true' "$C"

run_suite() { ( cd "$1/tests" && PLUGIN_ROOT="$1" ./libs/bats-core/bin/bats "${SUITE#tests/}" ) > "$2" 2>&1; }

copy() { mmry_work_reset "$1" || exit 2; cp -R "$PLUGIN_SRC/." "$1/"; }

echo "baseline: the untouched copy"
copy "$WORK/base"
if ! run_suite "$WORK/base" "$WORK/base.out"; then
    # With the failing test's own lines: the work directory goes at exit, so this is the only trace.
    echo "BASELINE FAILED; nothing can be scored"; grep -A8 '^not ok' "$WORK/base.out"; exit 2
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
