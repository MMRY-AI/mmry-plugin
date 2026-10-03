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

# ---------------------------------------------------------------------------------------------
# Assertions that cannot fail on bash 3.2 (#31245 QA round 9)
# ---------------------------------------------------------------------------------------------
#
# bats fails a test through set -e, and on bash 3.2 set -e does not act on a failing [[ ]]. So a
# bare [[ ... ]] line that is not the LAST command of a test is an assertion that cannot fail on
# macOS: the test runs on to its end and passes. QA round 9 listed twelve of them in this
# branch's files; a scan found 113. Each now ends "|| return 1".
#
# The guard covers every test file except the ones below, which came from master with the same
# pattern already in them (476 sites when this was written). They are named rather than silently
# exempt, so the debt is visible, and a NEW test file is covered from its first line. Fixing them
# is a follow-up of its own, not part of #31245.
_INERT_GRANDFATHERED=(
    e2e/install-uninstall.bats
    e2e/setup-join.bats
    handlers/deactivate-memory.bats
    handlers/link-memories.bats
    handlers/list-groups.bats
    handlers/make-private.bats
    handlers/plan-accepted.bats
    handlers/precompact-check.bats
    handlers/reinforce-memory.bats
    handlers/save-memory.bats
    handlers/search-memories.bats
    handlers/self-update.bats
    handlers/session-start-macos.bats
    handlers/session-start.bats
    handlers/stop-check.bats
    handlers/userpromptsubmit-foundation.bats
    handlers/visibility.bats
    integration/links.bats
    integration/memory-lifecycle.bats
    integration/search.bats
    integration/session-registration.bats
    structural/cross-platform.bats
    structural/file-integrity.bats
    structural/formation-assign.bats
    structural/formation-claim.bats
    structural/formation-delivery.bats
    structural/formation-directed.bats
    structural/formation-leave.bats
    structural/formation-list.bats
    structural/formation-progress.bats
    structural/formation-report.bats
    structural/formation-say.bats
    structural/hooks-guards.bats
    structural/hooks-json.bats
    structural/macos-hook-payload.bats
    structural/marketplace-sync.bats
    structural/plugin-json.bats
    unit/auth-header.bats
    unit/config-loading.bats
    unit/format-error.bats
    unit/hook-payload-read.bats
    unit/http-core.bats
    unit/lib-jq.bats
)

_is_grandfathered() {
    local g
    for g in "${_INERT_GRANDFATHERED[@]}"; do [[ "$g" == "$1" ]] && return 0; done
    return 1
}

# Prints file:line for each bare [[ ]] line that is followed, inside its @test, by another command.
_inert_assertions() {
    awk '
        FNR == 1 { intest = 0; pend = "" }
        /^@test / { intest = 1; pend = ""; next }
        intest && $0 == "}" { intest = 0; pend = ""; next }
        intest {
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
            if (pend != "") { print pend; pend = "" }
            if ($0 ~ /^[[:space:]]*\[\[ .* \]\][[:space:]]*$/) pend = FILENAME ":" FNR
        }
    ' "$@"
}

@test "portability: no test outside the grandfathered list has an assertion bash 3.2 cannot fail" {
    local tests_root f rel files=() hits
    tests_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    while IFS= read -r f; do
        rel="${f#$tests_root/}"
        _is_grandfathered "$rel" && continue
        files[${#files[@]}]="$f"
    done < <(find "$tests_root" -path "$tests_root/libs" -prune -o -type f -name '*.bats' -print | sort)
    [[ ${#files[@]} -gt 10 ]] || { echo "only ${#files[@]} files scanned"; return 1; }
    hits="$(_inert_assertions "${files[@]}")"
    [[ -z "$hits" ]] || {
        echo "these bare [[ ]] lines are not a test's last command, so on bash 3.2 they cannot fail it." >&2
        echo "End each with || return 1:" >&2
        echo "$hits" >&2
        return 1
    }
}

@test "control: the inert-assertion scan finds a mid-test bare [[ ]] and spares the last one" {
    local f="${BATS_TEST_TMPDIR}/sample.bats"
    printf '%s\n' '@test "x" {' '    [[ 1 -eq 2 ]]' '    # a comment' '    [[ 1 -eq 1 ]] || return 1' '    [[ 2 -eq 2 ]]' '}' > "$f"
    local hits; hits="$(_inert_assertions "$f")"
    [[ "$hits" == "$f:2" ]] || { echo "expected exactly $f:2, got: $hits"; return 1; }
}
