#!/usr/bin/env bats
# bash 3.2 is the floor (#31245 QA round 8), and the macOS sed is too (#31737).
#
# macOS ships bash 3.2 and this product says so in its own code comments, and the CI matrix runs
# macos-latest to honour it. QA round 8 still found a bash 4 builtin, mapfile, in a test file
# (codex-docs-and-eol.bats), where only a live macOS runner would have said so. This is the check
# QA proposed: the constructs bash 3.2 does not have, refused across every shipped handler, setup
# script and test file, on any machine. It is not quick on Windows, where every grep starts a new
# process: one grep over every file first keeps most files to a single pass.
#
# It also refuses the sed programs a stock Mac cannot run, by reading them the way bash and sed
# will (sed-program-scan.awk, #31737 QA round 1), because the 2.9.1 line join passed every regex
# over its text once it was written in double quotes.
#
# What it still cannot see, stated rather than implied: other GNU and BSD differences (date, stat,
# touch, grep), which no scan of a bash construct answers, and a sed program held in a variable or
# a file. The macOS CI leg is the check that sees those.

# One pattern per construct, so a refusal names what it found. Comment lines are ignored, because a
# comment explaining why mapfile is not used is not a use of mapfile. Each name is unique and none
# contains another, so the control below can tell which pattern found a line.
_BASH4_PATTERNS=(
    'mapfile or readarray (bash 4)|(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)'
    'associative array (bash 4)|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A'
    'case-modification expansion (bash 4)|\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}'
    'append-both redirection &>> (bash 4)|&>>'
    'case fall-through ;& or ;;& (bash 4)|;;?&([[:space:]]|$)'
    'transformation expansion ${x@Q} (bash 4.4)|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}'
    'EPOCHSECONDS or EPOCHREALTIME (bash 5)|EPOCH(SECONDS|REALTIME)'
    'wait -n (bash 4.3)|wait[[:space:]]+-n'
    # Not bash, but the same macOS failure: BSD sed rejects the label, exits 0 and passes the text
    # through unescaped (#31245 QA round 10, session-start.sh setup message, found on a Mac).
    'GNU-only sed label loop :a;N;$!ba|:a;N;[$]!ba'
    # Other spellings, kept as quick literal checks. sed-program-scan.awk is what reads them all.
    # The separate -e spelling runs on BSD sed (QA #2's Mac probe), so it is not called GNU-only. It is
    # still refused, by the Lead's ruling (2026-10-05): under POSIX, N on the last line prints nothing,
    # so a one-line input comes out empty on a Mac, and the shipped code uses the bash join anyway.
    'sed line join written as separate -e parts, which BSD sed empties for one-line input|-e[[:space:]]*.?:a.?[[:space:]]+-e'
    'GNU-only sed branch written $!b a|[$]!b[[:space:]]+a([^[:alnum:]_]|$)'
    'GNU-only sed -z (NUL-separated input)|sed[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*z([[:space:]]|$)'
)

# Every file the two scans read: shipped handlers, setup scripts and tests. This file is the one
# place that must name every construct, so it is the one file not scanned.
_portability_files() {
    local root="$1"
    find "$root" -path "$root/tests/libs" -prune -o -type f \
        \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) ! -name 'bash32-portability.bats' -print
}

# Prints "file:line: construct" for every hit under the given root.
# -e before the pattern, because a pattern that starts with "-e" is otherwise read by grep as an
# option and a different pattern runs (#31737 QA round 1).
_scan_bash4() {
    local root="$1" f entry name re all=()
    for entry in "${_BASH4_PATTERNS[@]}"; do all+=(-e "${entry#*|}"); done
    while IFS= read -r f; do
        for entry in "${_BASH4_PATTERNS[@]}"; do
            name="${entry%%|*}"
            re="${entry#*|}"
            grep -n -E -e "$re" "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' | while IFS= read -r hit; do
                printf '%s:%s: %s\n' "${f#$root/}" "${hit%%:*}" "$name"
            done
        done
    # One grep over every file first, so only a file holding some pattern is read pattern by pattern:
    # the same output from a fraction of the processes (#31737 QA round 1, performance review). The
    # extra /dev/null keeps grep off stdin if the list is ever empty.
    done < <(_portability_files "$root" | tr '\n' '\0' | xargs -0 grep -l -E "${all[@]}" /dev/null 2>/dev/null)
}

# Prints "file:line: finding" for every sed program a stock Mac will not run as the author meant.
_scan_sed_programs() {
    local root="$1"
    _portability_files "$root" | awk -v root="$root" -f "${BATS_TEST_DIRNAME}/sed-program-scan.awk"
}

@test "portability: no handler, setup script or test uses a construct bash 3.2 or the macOS sed does not have" {
    local plugin; plugin="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    local hits; hits="$(_scan_bash4 "$plugin"; _scan_sed_programs "$plugin")"
    [[ -z "$hits" ]] || {
        echo "bash 3.2 and the sed macOS ships do not have these:" >&2
        echo "$hits" >&2
        return 1
    }
}

@test "control: the scanners name each construct they claim to refuse, at its line, and nothing else" {
    # Without this the test above passes on a scanner that matches nothing. Every expectation is a
    # whole output line, file:line: name, so a finding cannot be credited to the wrong pattern: the
    # 2.9.1 line is held to the name of the pattern written for it, and a broken pattern fails here
    # even when another pattern still catches the same line (#31737 QA round 1).
    local root="${BATS_TEST_TMPDIR}/sample"
    mkdir -p "$root/hooks-handlers"
    # Lines 11 to 14 are the round 1 spellings. Lines 15 to 21 are QA's U1 to U7, each of which got
    # past round 1 and each of which fails on a stock Mac (QA #2's probe). Line 15 is the 2.9.1
    # program exactly, written in double quotes. Lines 22 and 23 are comments, line 24 is an
    # ordinary sed program, line 25 is what pattern 28 would match if grep read its leading -e as an
    # option (QA round 1, software-engineer review), and line 26 carries U1 in a trailing comment.
    # None of those five may be refused. Lines 27 to 30 are QA round 2's: the Mac's in-place form,
    # sed -i '' PROGRAM FILE, which the scanner read the GNU way and took '' for the program, and its
    # GNU twin; an abbreviated long option, --null; and a $'...' program. Each got past or survived a
    # scanner mutant.
    cat > "$root/hooks-handlers/bad.sh" <<'BAD'
mapfile -t lines < f
readarray x < f
declare -A table
local -A other
echo "${name,,}" "${name^^}"
cmd &>> log
case x in a) echo ;;& esac
echo "${v@Q}"
echo "$EPOCHSECONDS"
wait -n
printf x | sed ':a;N;$!ba;s/\n/ /g'
printf x | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g'
printf x | sed ':a;N;$!b a;s/\n/ /g'
printf x | sed -z 's/\n/ /g'
printf x | sed ":a;N;\$!ba;s/\n/ /g"
printf x | sed ':a; N; $!ba; s/\n/ /g'
printf x | sed ':x;N;$!bx;s/\n/ /g'
printf x | sed ':a;$!{N;ba};s/\n/ /g'
printf x | sed -zE 's/\n/ /g'
printf x | sed --null-data 's/\n/ /g'
printf x | sed -n 'H;${x;s/\n/ /g;p}'
# mapfile in a comment is not a use
# printf x | sed ':a;N;$!ba;s/\n/ /g' in a comment is not a use either
printf x | sed 's/a/b/g; s/c/d/'
echo host:a -e x
echo ok # sed ":a;N;\$!ba;s/\n/ /g" in a trailing comment is not a use either
sed -i '' ':x;N;$!bx;s/\n/ /g' FILE
sed -i ':x;N;$!bx;s/\n/ /g' FILE
sed --null 's/\n/ /g'
sed $':x;N;$!bx;s/\\n/ /g'
BAD
    local hits; hits="$(_scan_bash4 "$root"; _scan_sed_programs "$root")"
    local label="sed reads a label or branch that runs into ; or } (GNU-only: BSD sed takes the rest of the line as the label)"
    local null="sed reads -z or --null-data (GNU-only: BSD sed has no NUL-separated mode)"
    local join="sed reads a line join (N, H, G or -z, then a newline in s or y): use the bash join. BSD sed's N prints nothing on the last line, so a one-line input comes out empty"
    local brace="sed reads a } with no ; or newline before it (BSD sed rejects it; write ;})"
    local want=(
        "1: mapfile or readarray (bash 4)"
        "2: mapfile or readarray (bash 4)"
        "3: associative array (bash 4)"
        "4: associative array (bash 4)"
        "5: case-modification expansion (bash 4)"
        "6: append-both redirection &>> (bash 4)"
        "7: case fall-through ;& or ;;& (bash 4)"
        "8: transformation expansion \${x@Q} (bash 4.4)"
        "9: EPOCHSECONDS or EPOCHREALTIME (bash 5)"
        "10: wait -n (bash 4.3)"
        "11: GNU-only sed label loop :a;N;\$!ba" "11: $label" "11: $join"
        "12: sed line join written as separate -e parts, which BSD sed empties for one-line input" "12: $join"
        "13: GNU-only sed branch written \$!b a" "13: $label" "13: $join"
        "14: GNU-only sed -z (NUL-separated input)" "14: $null" "14: $join"
        "15: $label" "15: $join"
        "16: $label" "16: $join"
        "17: $label" "17: $join"
        "18: $label" "18: $join" "18: $brace"
        "19: $null" "19: $join"
        "20: $null" "20: $join"
        "21: $join" "21: $brace"
        "27: $label" "27: $join"
        "28: $label" "28: $join"
        "29: $null" "29: $join"
        "30: $label" "30: $join"
    )
    local w
    for w in "${want[@]}"; do
        grep -Fxq -e "hooks-handlers/bad.sh:$w" <<< "$hits" || {
            echo "the scanners did not report: hooks-handlers/bad.sh:$w"; echo "$hits"; return 1; }
    done
    # Exactly these and nothing more: no comment line, no ordinary program, no double count.
    [[ "$(printf '%s\n' "$hits" | grep -c .)" -eq "${#want[@]}" ]] || {
        echo "expected ${#want[@]} findings, got:"; echo "$hits"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# Assertions that cannot fail on bash 3.2 (#31245 QA rounds 9 and 10)
# ---------------------------------------------------------------------------------------------
#
# bats fails a test through set -e, and on bash 3.2 set -e does not act on a failing [[ ]] or
# (( )). So a bare [[ ... ]] or (( ... )) line that is not the LAST command of a test is an
# assertion that cannot fail on macOS: the test runs on to its end and passes. Each one here ends
# "|| return 1" instead.
#
# PINNED BY COUNT, NOT EXEMPTED BY FILE (#31245 QA round 10). Round 9 exempted whole files that
# came from master with the pattern already in them, and the exemption hid 35 lines this branch
# ADDED to those files, among them stop-check.bats:155, which round 9 had named. Now each such file
# carries the number of inert lines it held at develop (b707c26, counted with this scan), and the
# test holds it to exactly that number. One more fails, naming the file. One fewer fails too, asking
# for the pin to come down, so a fix cannot be quietly spent on a new inert line later. The four
# files this branch had touched were cleared outright and are not pinned at all; neither is any file
# master did not have, which is covered from its first line.
#
# (( )) is scanned since round 10. The first scan matched [[ ]] only, and six (( )) lines this
# branch added were inert in exactly the same way.
_INERT_PINNED=(
    "e2e/setup-join.bats 29"
    "handlers/deactivate-memory.bats 5"
    "handlers/link-memories.bats 5"
    "handlers/list-groups.bats 8"
    "handlers/make-private.bats 7"
    "handlers/plan-accepted.bats 4"
    "handlers/precompact-check.bats 6"
    "handlers/reinforce-memory.bats 5"
    "handlers/save-memory.bats 17"
    "handlers/search-memories.bats 8"
    "handlers/session-start-macos.bats 3"
    "handlers/visibility.bats 22"
    "integration/links.bats 2"
    "integration/memory-lifecycle.bats 2"
    "integration/search.bats 3"
    "integration/session-registration.bats 1"
    "structural/cross-platform.bats 3"
    "structural/file-integrity.bats 2"
    "structural/formation-assign.bats 24"
    "structural/formation-claim.bats 28"
    "structural/formation-delivery.bats 1"
    "structural/formation-directed.bats 23"
    "structural/formation-leave.bats 17"
    "structural/formation-list.bats 5"
    "structural/formation-progress.bats 22"
    "structural/formation-report.bats 10"
    "structural/formation-say.bats 28"
    "structural/hooks-guards.bats 5"
    "structural/hooks-json.bats 8"
    "structural/macos-hook-payload.bats 6"
    "structural/marketplace-sync.bats 2"
    "structural/plugin-json.bats 5"
    "unit/auth-header.bats 1"
    "unit/config-loading.bats 13"
    "unit/format-error.bats 5"
    "unit/hook-payload-read.bats 12"
    "unit/http-core.bats 1"
    "unit/lib-jq.bats 1"
)

# The inherited count for a test file, or return 1 if the file carries none.
_inert_pin() {
    local e
    for e in "${_INERT_PINNED[@]}"; do
        [[ "${e% *}" == "$1" ]] && { printf '%s' "${e##* }"; return 0; }
    done
    return 1
}

# Prints file:line for each bare [[ ]] or (( )) line followed, inside its @test, by another command.
_inert_assertions() {
    awk '
        FNR == 1 { intest = 0; pend = "" }
        /^@test / { intest = 1; pend = ""; next }
        intest && $0 == "}" { intest = 0; pend = ""; next }
        intest {
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
            if (pend != "") { print pend; pend = "" }
            if ($0 ~ /^[[:space:]]*\[\[ .* \]\][[:space:]]*$/ || $0 ~ /^[[:space:]]*\(\( .* \)\)[[:space:]]*$/) pend = FILENAME ":" FNR
        }
    ' "$@"
}

# Every .bats file under a tests root, judged against its pin. Prints one problem per line; prints
# nothing when every file is within its inherited count. Sets INERT_SCANNED to the files read.
_inert_verdict() {
    local root="$1" f rel hits n pin
    INERT_SCANNED=0
    while IFS= read -r f; do
        rel="${f#$root/}"
        INERT_SCANNED=$((INERT_SCANNED + 1))
        hits="$(_inert_assertions "$f")"
        n=0
        [[ -n "$hits" ]] && n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
        if pin="$(_inert_pin "$rel")"; then
            if (( n > pin )); then
                printf '%s: %s inert, %s inherited from develop. The new ones are among: %s\n' "$rel" "$n" "$pin" "$(printf '%s' "$hits" | tr '\n' ' ')"
            elif (( n < pin )); then
                printf '%s: %s inert, pinned at %s. Lower the pin to %s.\n' "$rel" "$n" "$pin" "$n"
            fi
        elif (( n > 0 )); then
            printf '%s\n' "$hits"
        fi
    done < <(find "$root" -path "$root/libs" -prune -o -type f -name '*.bats' -print | sort)
}

@test "portability: no test has an assertion bash 3.2 cannot fail, beyond its file's inherited count" {
    local tests_root problems
    tests_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    problems="$(_inert_verdict "$tests_root"; echo "scanned=$INERT_SCANNED")"
    local scanned="${problems##*scanned=}"
    problems="${problems%scanned=*}"
    echo "test files scanned: $scanned" >&3
    (( scanned > 50 )) || { echo "only $scanned files scanned"; return 1; }
    [[ -z "${problems//[[:space:]]/}" ]] || {
        echo "these bare [[ ]] or (( )) lines are not a test's last command, so on bash 3.2 they" >&2
        echo "cannot fail it. End each with || return 1:" >&2
        printf '%s\n' "$problems" >&2
        return 1
    }
}

@test "portability: every pinned file still exists, so a pin cannot outlive its debt" {
    local tests_root e missing=""
    tests_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    for e in "${_INERT_PINNED[@]}"; do
        [[ -f "$tests_root/${e% *}" ]] || missing="$missing ${e% *}"
    done
    [[ -z "$missing" ]] || { echo "pinned but gone:$missing"; return 1; }
}

@test "control: the inert-assertion scan finds a mid-test bare [[ ]] and (( )), and spares the last one" {
    local f="${BATS_TEST_TMPDIR}/sample.bats"
    printf '%s\n' '@test "x" {' '    [[ 1 -eq 2 ]]' '    # a comment' '    (( 1 > 2 ))' '    [[ 1 -eq 1 ]] || return 1' '    [[ 2 -eq 2 ]]' '}' > "$f"
    local hits; hits="$(_inert_assertions "$f" | tr '\n' ' ')"
    [[ "$hits" == "$f:2 $f:4 " ]] || { echo "expected exactly $f:2 and $f:4, got: $hits"; return 1; }
}

@test "control: a pinned file is held to its count in BOTH directions, and an unpinned one to zero" {
    # Built from a real pin, so the control exercises the same lookup the guard does.
    local root="${BATS_TEST_TMPDIR}/tests" pinned="${_INERT_PINNED[0]% *}" pin="${_INERT_PINNED[0]##* }"
    local i body=""
    mkdir -p "$root/$(dirname "$pinned")" "$root/unit"
    for (( i = 0; i <= pin; i++ )); do body="${body}    [[ 1 -eq 1 ]]"$'\n'; done
    # One MORE inert line than the pin allows (the last [[ ]] is the final command, so not inert).
    printf '@test "x" {\n%s    true\n}\n' "$body" > "$root/$pinned"
    local out; out="$(_inert_verdict "$root")"
    [[ "$out" == *"$pinned: $((pin + 1)) inert, $pin inherited"* ]] || { echo "one over the pin was not refused: $out"; return 1; }
    # One FEWER.
    body=""; for (( i = 0; i < pin - 1; i++ )); do body="${body}    [[ 1 -eq 1 ]]"$'\n'; done
    printf '@test "x" {\n%s    true\n}\n' "$body" > "$root/$pinned"
    out="$(_inert_verdict "$root")"
    [[ "$out" == *"Lower the pin to $((pin - 1))"* ]] || { echo "one under the pin was not reported: $out"; return 1; }
    # Exactly the pin: silent.
    body=""; for (( i = 0; i < pin; i++ )); do body="${body}    [[ 1 -eq 1 ]]"$'\n'; done
    printf '@test "x" {\n%s    true\n}\n' "$body" > "$root/$pinned"
    out="$(_inert_verdict "$root")"
    [[ -z "$out" ]] || { echo "the exact pin was refused: $out"; return 1; }
    # An unpinned file with a single inert line.
    printf '@test "y" {\n    (( 1 > 2 ))\n    true\n}\n' > "$root/unit/new-file.bats"
    out="$(_inert_verdict "$root")"
    [[ "$out" == *"unit/new-file.bats:2"* ]] || { echo "an unpinned file was let through: $out"; return 1; }
}
