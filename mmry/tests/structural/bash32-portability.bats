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
# mapfile in a comment is not a use
BAD
    local hits; hits="$(_scan_bash4 "$root")"
    local expect
    for expect in "mapfile or readarray" "associative array" "case-modification" "&>>" \
                  "case fall-through" "transformation expansion" "EPOCHSECONDS" "wait -n"; do
        [[ "$hits" == *"$expect"* ]] || { echo "the scanner missed: $expect"; echo "$hits"; return 1; }
    done
    [[ "$(grep -c 'mapfile or readarray' <<< "$hits")" -eq 2 ]] || {
        echo "the comment line was counted, or a real use was missed:"; echo "$hits"; return 1; }
}
