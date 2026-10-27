#!/usr/bin/env bash
# testing_VerifyCheckRenameDamage.sh - proves scripts/check-rename-damage.sh (#32957 fix round 3) can
# FAIL. The same file lives in MMRY-AI/mmry and MMRY-AI/mmry-plugin. Each control works in a scratch
# git worktree of HEAD (the real tree is never touched), plants one change, and the guard must exit
# 1 naming it. The positive control (the worktree as committed) must exit 0.
#
# The first control re-creates the exact damage round 1 of #32957 did in this repository: the
# substring rename that turned a Formation name into "...databaseion...".
#
# Usage: bash scripts/testing_VerifyCheckRenameDamage.sh [--base REF]   (default origin/develop)
set -uo pipefail
base="origin/develop"
[ "${1:-}" = "--base" ] && base="${2:-origin/develop}"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "REFUSED: not inside a git repository."; exit 2; }
cd "$root" || exit 2
guard="scripts/check-rename-damage.sh"
[ -f "$guard" ] || { echo "REFUSED: $guard missing."; exit 2; }

tmp="$(mktemp -d)"; wt="$tmp/wt"
cleanup() { git worktree remove --force "$wt" > /dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT
git worktree add -q --detach "$wt" HEAD || { echo "REFUSED: cannot add a scratch worktree."; exit 2; }
cp "$guard" "$wt/$guard"   # the guard as it is now, even before it is committed

pass=0; failc=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
bad() { failc=$((failc+1)); echo "  FAIL $1"; }
reset_wt() { (cd "$wt" && git checkout -q -- . && git reset -q --hard HEAD && git clean -qfd) ; cp "$guard" "$wt/$guard"; }
run_guard() { bash "$wt/$guard" --base "$base" --root "$wt" 2>&1; }

out="$(run_guard)"; rc=$?
[ $rc -eq 0 ] && ok "positive control: HEAD as committed passes" || { bad "positive control (exit $rc)"; printf '%s\n' "$out" | tail -5; }

control() { # name, file, perl substitution, text the output must contain[, another file to apply it to]
    reset_wt
    local f="$wt/$2"
    [ -f "$f" ] || { bad "$1: $2 does not exist, so the control is void"; return; }
    cp "$f" "$tmp/orig"; perl -pi -e "$3" "$f"
    [ -n "${5:-}" ] && perl -pi -e "$3" "$wt/$5"
    if cmp -s "$f" "$tmp/orig"; then bad "$1: the plant changed nothing, so the control is void"; return; fi
    local o rc; o="$(run_guard)"; rc=$?
    if [ $rc -eq 1 ] && printf '%s' "$o" | grep -qF -- "$4"; then ok "$1 refused"; else bad "$1 (exit $rc, wanted: $4)"; printf '%s\n' "$o" | tail -3; fi
}

if [ -f mmry/hooks-handlers/mmry-client.sh ]; then
    # The plugin: round 1 turned mmry_create_formation into mmry_create_databaseion.
    control "round 1's damage: mmry_create_formation -> mmry_create_databaseion" mmry/hooks-handlers/mmry-client.sh \
        's/\bmmry_create_formation\b/mmry_create_databaseion/g' "damaged word: databaseion"
    control "a Formation function renamed away" mmry/hooks-handlers/mmry-client.sh \
        's/\bmmry_create_formation\b/mmry_start_group/g' "formation name gone: mmry_create_formation" \
        mmry/hooks-handlers/formation-start.sh
    control "a damaged entry join" mmry/hooks-handlers/save-entry.sh 's/^(#!.*)$/$1\n# saves one myentry/' "damaged word: myentry"
    ffile="mmry/hooks-handlers/formation-start.sh"
else
    # The API: round 1 turned readMemoryFormationId into readMemoryDatabaseionId.
    control "round 1's damage: readMemoryFormationId -> readMemoryDatabaseionId" testing/backend/lib/db.ts \
        's/\breadMemoryFormationId\b/readMemoryDatabaseionId/g' "damaged word: databaseion"
    control "a Formation test name renamed away" src/Mnemo.Api.Tests/Mcp/FormationProgressClaimReportMcpToolTests.cs \
        's/\bEvery_new_tool_states_the_pull_only_delivery_contract_and_says_Formation\b/Every_new_tool_states_the_pull_only_delivery_contract/' \
        "formation name gone: Every_new_tool_states_the_pull_only_delivery_contract_and_says_Formation"
    control "a damaged entry join" src/Mnemo.Api/Services/AiDatabaseService.cs 's/out var storedValues/out var storedEntryion/' "damaged word: entryion"
    ffile="testing/backend/tests/formation-transmissions.test.ts"
fi

# A Formation file moved away.
reset_wt
(cd "$wt" && git mv -f "$ffile" "${ffile%/*}/moved-away.${ffile##*.}") || bad "could not move $ffile"
o="$(run_guard)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$o" | grep -qF -- "formation file gone: $ffile"; then ok "a Formation file moved away refused"; else bad "Formation file moved (exit $rc)"; printf '%s\n' "$o" | tail -3; fi

reset_wt
bash "$wt/$guard" --base "no-such-ref-32957" --root "$wt" > /dev/null 2>&1; [ $? -eq 2 ] && ok "a base it cannot read is exit 2, never a pass" || bad "unreadable base"

echo "$pass passed, $failc failed"; [ $failc -eq 0 ]
