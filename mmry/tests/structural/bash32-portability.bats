#!/usr/bin/env bats
# bash 3.2 is the floor (#31245 QA round 8).
#
# macOS ships bash 3.2 and this product says so in its own code comments, and the CI matrix runs
# macos-latest to honour it. QA round 8 still found a bash 4 builtin, mapfile, in a test file
# (codex-docs-and-eol.bats), where only a live macOS runner would have said so. This is the check
# QA proposed: the constructs bash 3.2 does not have, refused across every shipped handler, setup
# script and test file, in seconds and on any machine.
#
# What it cannot see, stated rather than implied: behaviour that differs between GNU and BSD tools
# (sed, date, stat, touch), which is not a bash question. The sentence splitter that used a GNU sed
# extension was fixed by hand in the same round.

# One pattern per construct, so a refusal names what it found. Comment lines are ignored, because a
# comment explaining why mapfile is not used is not a use of mapfile.
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
)

# Prints "file:line: construct: text" for every hit under the given root.
_scan_bash4() {
    local root="$1" f entry name re
    while IFS= read -r f; do
        for entry in "${_BASH4_PATTERNS[@]}"; do
            name="${entry%%|*}"
            re="${entry#*|}"
            grep -n -E "$re" "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' | while IFS= read -r hit; do
                printf '%s:%s: %s\n' "${f#$root/}" "${hit%%:*}" "$name"
            done
        done
    # This file is the one place that must name every construct, so it is the one file not scanned.
    done < <(find "$root" -path "$root/tests/libs" -prune -o -type f \
                \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) ! -name 'bash32-portability.bats' -print)
}

@test "portability: no handler, setup script or test uses a construct bash 3.2 does not have" {
    local plugin; plugin="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    local hits; hits="$(_scan_bash4 "$plugin")"
    [[ -z "$hits" ]] || {
        echo "bash 3.2, the floor macOS ships, does not have these:" >&2
        echo "$hits" >&2
        return 1
    }
}

@test "control: the scanner finds each construct it claims to refuse" {
    # Without this the test above passes on a scanner that matches nothing.
    local root="${BATS_TEST_TMPDIR}/sample"
    mkdir -p "$root/hooks-handlers"
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
# mapfile in a comment is not a use
BAD
    local hits; hits="$(_scan_bash4 "$root")"
    local expect
    for expect in "mapfile or readarray" "associative array" "case-modification" "&>>" \
                  "case fall-through" "transformation expansion" "EPOCHSECONDS" "wait -n" \
                  "GNU-only sed label loop"; do
        [[ "$hits" == *"$expect"* ]] || { echo "the scanner missed: $expect"; echo "$hits"; return 1; }
    done
    [[ "$(grep -c 'mapfile or readarray' <<< "$hits")" -eq 2 ]] || {
        echo "the comment line was counted, or a real use was missed:"; echo "$hits"; return 1; }
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
    "structural/formation-say.bats 29"
    "structural/hooks-guards.bats 11"
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
