#!/usr/bin/env bats
# No test file may grow past what bats can gather on Windows (#31245 QA round 8).
#
# MEASURED, NOT ASSUMED. On Windows Git Bash, with the vendored bats-core, a .bats file larger than
# 64 KiB hangs while bats gathers its tests: no CPU, no output, no timeout, for EVERY test in the
# file, including ones a -f filter selects. Byte-identical content hung at 65544 bytes and ran at
# 65526; padding a working copy past 65536 made it hang. formation-delivery.bats reached 65545
# bytes while QA round 8's fixes were being written, and the symptom was a run that never finished,
# which reads as a slow machine rather than as a broken suite.
#
# The limit leaves a margin under 65536 so a file is refused while it still runs, not on the
# commit that makes it hang.

LIMIT=64000

# Every .bats file outside the vendored libraries, one per line, with its size in front.
_sizes() {
    local root="$1" f
    while IFS= read -r f; do
        printf '%s %s\n' "$(wc -c < "$f" | tr -d '[:space:]')" "${f#$root/}"
    done < <(find "$root" -path "$root/libs" -prune -o -type f -name '*.bats' -print)
}

@test "structural: no test file is large enough to hang bats on Windows" {
    local tests_root size name over="" count=0
    tests_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    while read -r size name; do
        count=$((count + 1))
        [[ "$size" -gt "$LIMIT" ]] && over="${over}
  ${name} is ${size} bytes"
    done < <(_sizes "$tests_root")
    # A find that matched nothing would pass the check below for the wrong reason.
    [[ "$count" -gt 10 ]] || { echo "only ${count} test files found under ${tests_root}"; return 1; }
    [[ -z "$over" ]] || {
        echo "these test files are over ${LIMIT} bytes; past 65536 bats hangs gathering them on Windows." >&2
        echo "Split the file rather than raising the limit:${over}" >&2
        return 1
    }
}

@test "control: the size check reports a file that is over the limit" {
    local dir="${BATS_TEST_TMPDIR}/sizes"
    mkdir -p "$dir/structural"
    head -c $((LIMIT + 1)) /dev/zero | tr '\0' '#' > "${dir}/structural/huge.bats"
    printf '#\n' > "${dir}/structural/small.bats"
    run _sizes "$dir"
    [[ "$output" == *"$((LIMIT + 1)) structural/huge.bats"* ]] || { echo "got: $output"; return 1; }
    [[ "$output" == *"2 structural/small.bats"* ]] || { echo "got: $output"; return 1; }
}
