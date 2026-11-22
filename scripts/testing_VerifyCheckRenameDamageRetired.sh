#!/usr/bin/env bash
# testing_VerifyCheckRenameDamageRetired.sh - proves the RETIRED list of scripts/check-rename-damage.sh
# (#31854). The same file lives in MMRY-AI/mmry and MMRY-AI/mmry-plugin.
#
# The RETIRED list lets a ticket declare that a Formation name was removed on purpose. This proves
# two things, in a throwaway git repository (this repository is never touched):
#   - a Formation name that is removed and listed in RETIRED is not a finding (exit 0);
#   - the guard still FAILS on a removal that is not listed (exit 1, naming it), also when a listed
#     name is removed in the same change, and also for a name that merely begins with a listed one.
#
# Usage: bash scripts/testing_VerifyCheckRenameDamageRetired.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/check-rename-damage.sh"
[ -f "$guard" ] || { echo "REFUSED: $guard missing."; exit 2; }

tmp="$(mktemp -d)" || { echo "REFUSED: no scratch folder."; exit 2; }
trap 'rm -rf "${tmp:?}"' EXIT
fx="$tmp/fixture"
mkdir -p "$fx/src" || exit 2

pass=0; failc=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
bad() { failc=$((failc+1)); echo "  FAIL $1"; }
g() { git -C "$fx" -c user.name=fixture -c user.email=fixture@example.invalid -c core.autocrlf=false "$@"; }

# The listed name the fixture removes: the first entry, retired by #31854.
listed="Formations.GetByIdAsync"
unlisted="Formations.UnlistedFixtureAsync"
longer="Formations.GetByIdAsyncLonger"

# The base: one code file calling 25 names that stay, the listed name, an unlisted one, and a name
# that begins with the listed one. The guard refuses a base with fewer than 20 names.
write_base() {
    {
        echo "class Fixture {"
        echo "    void Run() {"
        i=1
        while [ "$i" -le 25 ]; do printf '        Formations.Keep%02dAsync();\n' "$i"; i=$((i+1)); done
        echo "        $listed(1);"
        echo "        $unlisted(1);"
        echo "        $longer(1);"
        echo "    }"
        echo "}"
    } > "$fx/src/Fixture.cs"
}
g init -q . || { echo "REFUSED: cannot create the fixture repository."; exit 2; }
write_base
g add -A && g commit -q -m "base" || { echo "REFUSED: cannot commit the fixture."; exit 2; }
g tag fixture-base

run_guard() { bash "$guard" --base fixture-base --root "$fx" 2>&1; }
restore() { write_base; }
drop() { # remove every line calling the name (anchored on the open bracket, so a longer name stays)
    grep -v -F "$1(" "$fx/src/Fixture.cs" > "$tmp/next" && cp "$tmp/next" "$fx/src/Fixture.cs"
}
to_comment() { # the call goes; the name is left behind in a comment
    drop "$1"; echo "// was $1" >> "$fx/src/Fixture.cs"
}

# The list itself: present, and every name on it carries a reason in the comment above it.
names="$(sed -n 's/^RETIRED="\(.*\)"$/\1/p' "$guard")"
if [ -n "$(printf '%s' "$names" | tr -d ' ')" ]; then ok "the guard holds a RETIRED list"; else bad "the guard holds no RETIRED list"; fi
case " $names " in *" $listed "*) ok "$listed is on the RETIRED list" ;; *) bad "$listed is not on the RETIRED list" ;; esac
for n in $names; do
    if grep -q -E "^#   $(printf '%s' "$n" | sed 's/[.]/[.]/g'): .*#[0-9]+" "$guard"; then ok "reason given for $n, naming its ticket"; else bad "no reason line naming a ticket for $n"; fi
done

o="$(run_guard)"; rc=$?
[ $rc -eq 0 ] && ok "positive control: the fixture as committed passes" || { bad "positive control (exit $rc)"; printf '%s\n' "$o" | tail -3; }

restore; drop "$listed"
o="$(run_guard)"; rc=$?
[ $rc -eq 0 ] && ok "a listed name removed outright is not a finding (exit 0)" || { bad "listed name removed (exit $rc, wanted 0)"; printf '%s\n' "$o" | tail -3; }

restore; to_comment "$listed"
o="$(run_guard)"; rc=$?
[ $rc -eq 0 ] && ok "a listed name left only in a comment is not a finding (exit 0)" || { bad "listed name left in a comment (exit $rc, wanted 0)"; printf '%s\n' "$o" | tail -3; }

restore; drop "$unlisted"
o="$(run_guard)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$o" | grep -qF -- "formation name gone: $unlisted"; then ok "an unlisted name removed outright is refused, by name"; else bad "unlisted name removed (exit $rc, wanted 1 naming it)"; printf '%s\n' "$o" | tail -3; fi

restore; to_comment "$unlisted"
o="$(run_guard)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$o" | grep -qF -- "formation name gone from code: $unlisted"; then ok "an unlisted name left only in a comment is refused, by name"; else bad "unlisted name left in a comment (exit $rc, wanted 1 naming it)"; printf '%s\n' "$o" | tail -3; fi

restore; drop "$unlisted"; drop "$listed"
o="$(run_guard)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$o" | grep -qF -- "formation name gone: $unlisted" && ! printf '%s' "$o" | grep -qF -- "gone: $listed " \
   && printf '%s' "$o" | grep -q -- "check-rename-damage: 1 finding"; then
    ok "a listed and an unlisted name removed together: one finding, the unlisted one"
else bad "listed and unlisted removed together (exit $rc, wanted 1 with one finding)"; printf '%s\n' "$o" | tail -3; fi

restore; drop "$longer"
o="$(run_guard)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$o" | grep -qF -- "formation name gone: $longer"; then ok "a name that only begins with a listed one is refused, by name"; else bad "longer name removed (exit $rc, wanted 1 naming it)"; printf '%s\n' "$o" | tail -3; fi

echo "$pass passed, $failc failed"; [ $failc -eq 0 ]
