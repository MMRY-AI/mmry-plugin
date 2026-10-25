#!/usr/bin/env bats
# bash 3.2 is the floor (#31245 QA round 8), and BSD sed is the other half of it (#31737).
#
# macOS ships bash 3.2 and BSD sed, this product says so in its own code comments, and the CI matrix
# runs macos-latest to honour it. QA round 8 still found a bash 4 builtin, mapfile, in a test file
# (codex-docs-and-eol.bats), where only a live macOS runner would have said so. This is the check
# QA proposed: the constructs bash 3.2 does not have, refused across every shipped handler, setup
# script and test file, on any machine. On Windows Git Bash the whole scan takes a few seconds.
#
# What it sees of GNU and BSD tool differences, stated rather than implied: sed's line join and
# sed -z, read the way sed reads them (sed-programs.awk, below). Nothing else differs by tool here:
# date, stat, touch, find and the rest are not judged by this file.

# One pattern per construct, so a refusal names what it found: key|name|extended regex. Comment lines
# are ignored, because a comment explaining why mapfile is not used is not a use of mapfile. A name
# holds no ": " and no " -- ", which the output and the control use as separators.
_BASH4_PATTERNS=(
    'b4map|mapfile or readarray (bash 4)|(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)'
    'b4assoc|associative array (bash 4)|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A'
    'b4case|case-modification expansion (bash 4)|\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}'
    'b4app|append-both redirection &>> (bash 4)|&>>'
    'b4fall|case fall-through ;& or ;;& (bash 4)|;;?&([[:space:]]|$)'
    'b44xform|transformation expansion ${x@Q} (bash 4.4)|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}'
    'b5epoch|EPOCHSECONDS or EPOCHREALTIME (bash 5)|EPOCH(SECONDS|REALTIME)'
    'b43wait|wait -n (bash 4.3)|wait[[:space:]]+-n'
    # Not bash, but the same macOS failure: BSD sed rejects the label, exits 0 and passes the text
    # through unescaped (#31245 QA round 10, session-start.sh setup message, found on a Mac). Kept
    # as TEXT, under its own name, as a net for the spelling that shipped wherever it is written,
    # a variable included. The optional backslash is the same program written in double quotes.
    'p27|GNU-only sed label loop :a;N;$!ba|:a;N;\\?[$]!ba'
)

# The sed rules (#31737 QA round 1). A text pattern cannot close this class: sed ":a;N;\$!ba" and
# sed ':a;N;$!ba' are different text and one program, and the label can be any name, spaced, braced
# or split across -e parts. So sed-programs.awk reads each file the way the shell does (quotes,
# backslashes, $'...', $(...), backticks, here-documents, bash -c and eval strings, and a variable
# given a literal earlier in the same file), recovers the arguments each sed is actually given, and
# reads the program the way sed does. key|name, keyed to what the reader prints.
#
#   label     GNU sed ends a label or branch name at ; or } or a blank. BSD sed reads the name to the
#             end of the line, so :a;N;$!ba defines a label called "a;N;$!ba", the branch has nowhere
#             to go, and sed exits 0 with the text not joined. Found on the Mac bench (#31737).
#   join      Joining lines in sed at all, by N or the hold space and a match on the newline, in any
#             spelling. Even the spellings BSD sed parses depend on GNU behaviour: under POSIX, which
#             BSD sed follows, N on the last line ends the script WITHOUT printing, so a one-line
#             input comes out empty (GNU sed shows it too, with POSIXLY_CORRECT=1). Join lines with
#             the portable escaper, _mmry_json_escape in mmry-client.sh, or with tr.
#   nulldata  -z anywhere in an option group, --null-data, --zero-terminated, or an abbreviation of
#             either: GNU's other way to join lines, which BSD sed does not have.
#   lost      A file whose quoting the reader cannot follow to the end. Refused, not skipped, so the
#             reader cannot go blind on a file without saying so.
#
# What the reader cannot judge: a program sed gets from a function's argument, from a file (-f), or
# from a variable given anything but a literal. p27 above still catches the shipped spelling as text.
_SED_RULES=(
    'label|GNU-only sed label or branch name ended by ; or } on its line'
    'join|sed line join with N or the hold space, which this plugin does not ship in any spelling'
    'nulldata|GNU-only sed -z or --null-data (NUL-separated input)'
    'lost|quoting the sed reader cannot follow, so no sed program after this line is judged'
)
_SED_AWK="${BATS_TEST_DIRNAME}/sed-programs.awk"

# The name for a sed rule key, or the key itself if it has none, in _RULE_NAME (no subshell).
_sed_rule_name() {
    local e
    _RULE_NAME="$1"
    for e in "${_SED_RULES[@]}"; do
        [[ "${e%%|*}" == "$1" ]] && { _RULE_NAME="${e#*|}"; return 0; }
    done
}

# Prints "file:line: name" for every hit under the given root, and for a sed hit " -- " and what sed
# receives. One grep per pattern and one awk over every file: the scan used to start a grep pair per
# file per pattern, some 3,000 processes, about 105 s on Windows (#31737 QA round 1). A subshell
# function, so its cd stays inside it.
_scan_portability() (
    root="$1"
    cd "$root" || { printf '%s:0: %s\n' "$root" "the scan could not enter this directory"; exit 0; }
    files=()
    # This file is the one place that must name every construct, so it is the one file not scanned.
    while IFS= read -r f; do
        files[${#files[@]}]="${f#./}"
    done < <(find . -path ./tests/libs -prune -o -type f \
                \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) ! -name 'bash32-portability.bats' -print)
    [[ ${#files[@]} -gt 0 ]] || exit 0
    tmp="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/portability-scan.$$"
    for entry in "${_BASH4_PATTERNS[@]}"; do
        rest="${entry#*|}"; name="${rest%%|*}"; re="${rest#*|}"
        # -e, so a pattern that starts with a dash is a pattern and not an option (QA round 1).
        grep -H -n -E -e "$re" "${files[@]}" > "$tmp" 2>/dev/null
        while IFS= read -r hit; do
            loc="${hit#*:}"; text="${loc#*:}"
            text="${text#"${text%%[![:space:]]*}"}"
            [[ "$text" == "#"* ]] && continue
            printf '%s:%s: %s\n' "${hit%%:*}" "${loc%%:*}" "$name"
        done < "$tmp"
    done
    LC_ALL=C awk -f "$_SED_AWK" "${files[@]}" > "$tmp" 2>&1; rc=$?
    if [[ $rc -ne 0 ]]; then
        # A reader that did not run must not read as a clean tree.
        printf 'sed-programs.awk:0: the sed reader did not run -- awk exit %s: ' "$rc"
        head -3 "$tmp" | tr '\n' ' '; echo
        exit 0
    fi
    while IFS=$'\t' read -r path line rule detail; do
        [[ -n "$path" ]] || continue
        _sed_rule_name "$rule"
        printf '%s:%s: %s -- %s\n' "$path" "$line" "$_RULE_NAME" "$detail"
    done < "$tmp"
    rm -f "$tmp"
)

@test "portability: no handler, setup script or test uses a construct bash 3.2 does not have" {
    local plugin; plugin="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    local hits; hits="$(_scan_portability "$plugin")"
    [[ -z "$hits" ]] || {
        echo "bash 3.2 and BSD sed, the floor macOS ships, do not have these:" >&2
        echo "$hits" >&2
        echo "Lines are joined with _mmry_json_escape (mmry-client.sh) or tr, never with sed." >&2
        return 1
    }
}

# The key for a refusal's name, a pattern's or a sed rule's, in _KEY (no subshell).
_key_for_name() {
    local e r
    _KEY="?$1"
    for e in "${_BASH4_PATTERNS[@]}" "${_SED_RULES[@]}"; do
        r="${e#*|}"
        [[ "${r%%|*}" == "$1" ]] && { _KEY="${e%%|*}"; return 0; }
    done
}

@test "control: the scanner refuses each construct at its own line, under its own name, and nothing else" {
    # Without this the test above passes on a scanner that matches nothing. Every line of bad.sh ends
    # "#@ " and the keys of EXACTLY the refusals it must draw, "-" for none, and the scanner's
    # refusals must equal that set: a key missing at its line fails, and so does one extra. Every
    # pattern and rule must be some line's key, so a pattern mutated to match nothing fails this
    # (#31737 QA round 1: at 55fae25 pattern 27 could match nothing and this still passed).
    local root="${BATS_TEST_TMPDIR}/sample"
    mkdir -p "$root/hooks-handlers"
    cat > "$root/hooks-handlers/bad.sh" <<'BAD'
mapfile -t lines < f #@ b4map
readarray x < f #@ b4map
declare -A table #@ b4assoc
local -A other #@ b4assoc
echo "${name,,}" "${name^^}" #@ b4case
cmd &>> log #@ b4app
case x in a) echo ;;& esac #@ b4fall
echo "${v@Q}" #@ b44xform
echo "$EPOCHSECONDS" #@ b5epoch
wait -n #@ b43wait
# mapfile in a comment is not a use #@ -
printf x | sed ':a;N;$!ba;s/\n/ /g' #@ p27 label join
printf x | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g' #@ join
printf x | sed ':a;N;$!b a;s/\n/ /g' #@ label join
printf x | sed -z 's/\n/ /g' #@ nulldata
printf x | sed ":a;N;\$!ba;s/\n/ /g" #@ p27 label join
printf x | sed ':a; N; $!ba; s/\n/ /g' #@ label join
printf x | sed ':x;N;$!bx;s/\n/ /g' #@ label join
printf x | sed ':a;$!{N;ba};s/\n/ /g' #@ label join
printf x | sed -zE 's/\n/ /g' #@ nulldata
printf x | sed --null-data 's/\n/ /g' #@ nulldata
printf x | sed -n 'H;${x;s/\n/ /g;p}' #@ join
escaped="$(printf '%s' "$framed" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')" #@ p27 label join
SETUP_MSG_ESCAPED="$(printf '%s' "$SETUP_MSG" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')" #@ p27 label join
printf x | sed --expression=':a;N;$!ba;s/\n/ /g' #@ p27 label join
printf x | sed ':a;N;$!b'"a;s/\n/ /g" #@ label join
printf x | sed $':a\nN\n$!ba\ns/\\n/ /g' #@ join
printf x | sed -n -e ':a' -e '$!{N;ba' -e '}' -e 's/\n/ /g;p' #@ join
printf x | sed -n '1h;1!H;${g;s/\n/ /g;p;}' #@ join
printf x | sed -nz 's/\n/ /gp' #@ nulldata
printf x | sed --null 's/\n/ /g' #@ nulldata
printf x | /usr/bin/sed --zero-terminated 's/\n/ /g' #@ nulldata
printf x | command sed ":a;N;\$!b a;s/\n/ /g" #@ label join
printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g' #@ -
body="$(echo "$r" | sed '$d')" #@ -
sed -n '1p' "$f" 2>/dev/null #@ -
printf '%s' "$s" | sed -e 's|%|%25|g' -e 's| |%20|g' -e 's|#|%23|g' #@ -
sed -n '/^_poll_once()/,/^}/p' "$f" #@ -
printf x | sed -e ':a' -e 's/x/y/;ta' #@ -
printf x | sed -ez 's/x/y/' #@ -
grep -c 'sed -z' "$f" #@ -
printf x | tr '\n' ' ' #@ -
x=1 # sed -z in a trailing comment is not a use #@ -
BAD
    # Shapes one line cannot carry: a continued command, a program in a variable, a here-document
    # fed to bash, a program spanning lines (its labels end at newlines, but it is still a join), a
    # bash -c string, and quoting that is never closed.
    cat > "$root/hooks-handlers/multi.sh" <<'MULTI'
printf x | sed \
    -e ':a' \
    -e 'N' -e '$!ba' -e 's/\n/ /g'
_j=':a;N;$!ba;s/\n/ /g'
printf x | sed "$_j"
bash <<'EOF'
printf x | sed -z 's/\n/ /g'
EOF
sed -n '
:a
N
$!ba
s/\n/ /gp' "$f"
bash -c "printf x | sed ':a;N;\$!ba;s/\n/ /g'"
MULTI
    printf '%s\n' 'echo fine' 'echo "this string is never closed' "printf x | sed -z 's/x/y/'" > "$root/hooks-handlers/lost.sh"
    local expect_other=(
        "hooks-handlers/multi.sh:1 join"
        "hooks-handlers/multi.sh:4 p27"
        "hooks-handlers/multi.sh:5 label" "hooks-handlers/multi.sh:5 join"
        "hooks-handlers/multi.sh:7 nulldata"
        "hooks-handlers/multi.sh:9 join"
        "hooks-handlers/multi.sh:14 p27" "hooks-handlers/multi.sh:14 label" "hooks-handlers/multi.sh:14 join"
        "hooks-handlers/lost.sh:2 lost"
    )

    local hits; hits="$(_scan_portability "$root")"
    local got="" exp="" h n=0 line k
    while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        k="${h#*: }"; _key_for_name "${k%% -- *}"
        got="${got}${h%%: *} ${_KEY}"$'\n'
    done <<< "$hits"
    while IFS= read -r line; do
        n=$((n + 1))
        [[ "$line" == *'#@ '* ]] || { exp="${exp}hooks-handlers/bad.sh:${n} NO-MARKER"$'\n'; continue; }
        for k in ${line##*#@ }; do
            [[ "$k" == "-" ]] || exp="${exp}hooks-handlers/bad.sh:${n} ${k}"$'\n'
        done
    done < "$root/hooks-handlers/bad.sh"
    for k in "${expect_other[@]}"; do exp="${exp}${k}"$'\n'; done
    got="$(printf '%s' "$got" | sort -u)"
    exp="$(printf '%s' "$exp" | sort -u)"
    [[ "$got" == "$exp" ]] || {
        echo "the scanner's refusals differ from the plants' (< expected and missing, > refused but not expected):"
        diff <(printf '%s\n' "$exp") <(printf '%s\n' "$got")
        echo "full scanner output:"; printf '%s\n' "$hits"
        return 1
    }
    # Every pattern and rule is some plant's key, so none can be broken without this test noticing.
    local e
    for e in "${_BASH4_PATTERNS[@]}" "${_SED_RULES[@]}"; do
        [[ $'\n'"$exp"$'\n' == *" ${e%%|*}"$'\n'* ]] || { echo "no plant exercises ${e%%|*}"; return 1; }
    done
}

@test "control: every pattern and rule has its own key and its own name, so a refusal names one thing" {
    local e r names="" keys="" dup
    for e in "${_BASH4_PATTERNS[@]}" "${_SED_RULES[@]}"; do
        r="${e#*|}"; r="${r%%|*}"
        keys="${keys}${e%%|*}"$'\n'; names="${names}${r}"$'\n'
        [[ "$r" != *": "* && "$r" != *" -- "* ]] || { echo "a name holds a separator: $r"; return 1; }
    done
    dup="$(printf '%s' "$keys" | sort | uniq -d)"
    [[ -z "$dup" ]] || { echo "keys used twice: $dup"; return 1; }
    dup="$(printf '%s' "$names" | sort | uniq -d)"
    [[ -z "$dup" ]] || { echo "names used twice: $dup"; return 1; }
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
