#!/usr/bin/env bats
# folder-deletes-check.bats - no plugin script or test deletes a folder whose path could be empty,
# unset or the shared temporary folder (#33618).
#
# WHY. On 2026-11-08 a test script whose work folder had not been created deleted the computer's
# shared temporary folder. QA of 33363 found the same unguarded pattern here: the mutation runners and
# several older scripts delete a folder named by a variable, and some fell back to /tmp when TMPDIR was
# not set.
#
# What these tests prove:
#   1. scripts/check-folder-deletes.sh passes the real repository, says how much it read, and names the
#      frozen release fixtures it does not read.
#   2. A planted unguarded recursive delete is refused, naming the file and line, in every spelling; the
#      same line written ${X:?} passes. A file that cannot be read is a failure to pass (exit 2).
#   3. CI runs the check.
#   4. tests/helpers/work-dir.bash makes a work folder only inside an existing TMPDIR, with a checked
#      mktemp, and removes only a folder it made: never an empty path, /, HOME, TMPDIR itself, or a
#      path outside TMPDIR.
#   5. Each mutation runner run with TMPDIR set to a folder that does not exist, or with TMPDIR unset,
#      stops with a plain message, and sentinel files in a scratch stand-in and in HOME survive.
#   6. The test teardown refuses to delete HOME.
#
# Fixtures below spell the command RM, so this file, which the check also reads, does not carry the
# lines it plants. _plant turns RM into rm in the scratch copy only. Every folder a test deletes is
# under its own BATS_TEST_TMPDIR.

load '../helpers/test-helper'

REPO_ROOT=""
CHECK=""

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    CHECK="$REPO_ROOT/scripts/check-folder-deletes.sh"
}

# _plant NAME BODY: a scratch .sh whose line 1 is a shebang, so line N of BODY is line N+1.
_plant() {
    local b="$2"
    printf '#!/usr/bin/env bash\n%b\n' "${b//RM /rm }" > "$BATS_TEST_TMPDIR/$1.sh"
}
_refused() { # NAME BODY LINE
    _plant "$1" "$2"
    run bash "$CHECK" --file "$BATS_TEST_TMPDIR/$1.sh"
    [[ "$status" -eq 1 ]] || fail "$1: exit $status, wanted 1: $output"
    [[ "$output" == *"$1.sh:$3:"* ]] || fail "$1: the refusal does not name $1.sh:$3: $output"
}
_passes() { # NAME BODY
    _plant "$1" "$2"
    run bash "$CHECK" --file "$BATS_TEST_TMPDIR/$1.sh"
    [[ "$status" -eq 0 ]] || fail "$1: exit $status, wanted 0: $output"
}

# ---------------------------------------------------------------- 1. the real repository
@test "33618: the folder-delete check passes the plugin repository and says what it read" {
    [[ -f "$CHECK" ]] || fail "scripts/check-folder-deletes.sh does not exist"
    run bash "$CHECK"
    [[ "$status" -eq 0 ]] || fail "exit $status: $output"
    [[ "$output" == *"OK: "*" recursive deletes of variable paths, all guarded"* ]] || fail "$output"
    local n
    n="$(printf '%s\n' "$output" | sed -n 's/.* across \([0-9][0-9]*\) shell files.*/\1/p' | tail -1)"
    [[ -n "$n" && "$n" -gt 100 ]] || fail "read too few shell files ('$n'): $output"
    [[ "$output" == *"tests/fixtures/self-update-2.15.2.sh"* ]] || fail "the frozen fixtures it skips are not named: $output"
}

# ---------------------------------------------------------------- 2. it refuses
@test "33618: a planted unguarded delete is refused naming the file and line; written \${X:?} it passes" {
    [[ -f "$CHECK" ]] || fail "scripts/check-folder-deletes.sh does not exist"
    _refused planted 'X="$1"\nRM -rf "$X/tmp"' 3
    _passes  planted-guarded 'X="$1"\nRM -rf "${X:?}/tmp"'
}

@test "33618: every spelling of an unguarded recursive delete is refused" {
    [[ -f "$CHECK" ]] || fail "scripts/check-folder-deletes.sh does not exist"
    _refused bare        'RM -rf "$W"' 2
    _refused unquoted    'RM -rf $W/tmp' 2
    _refused braced      'RM -rf "${W}/tmp"' 2
    _refused default     'RM -rf "${TMPDIR:-/tmp}/x"' 2
    _refused plain-r     'RM -r "$W"' 2
    _refused fr          'RM -fr "$W"' 2
    _refused capital-R   'RM -Rf "$W"' 2
    _refused split       'RM -f -r "$W"' 2
    _refused long        'RM --recursive --force "$W"' 2
    _refused dashdash    'RM -rf -- "$W"' 2
    _refused positional  'copy() { RM -rf "$1"; mkdir -p "$1"; }' 2
    _refused in-trap     "trap 'RM -rf \"\$WORK\"' EXIT" 2
    _refused second      'RM -rf "${A:?}/x" "$B/y"' 2
    _refused after-and   '[[ -n "$p" ]] && RM -rf "$p"' 2
    _refused subst       'RM -rf "$(pwd)/x"' 2
    _refused continued   'RM -rf \\\n    "$W"' 2
    _refused no-reason   'RM -rf "$W" # rm-guard-exempt:' 2
}

@test "33618: guarded, literal, non-recursive, commented and exempted lines pass" {
    [[ -f "$CHECK" ]] || fail "scripts/check-folder-deletes.sh does not exist"
    _passes g-bare     'RM -rf "${W:?}"'
    _passes g-trap     "trap 'RM -rf \"\${WORK:?}\"' EXIT"
    _passes g-later    'RM -rf "${TMPDIR:?}/.mmry-formation-cs-$(_sid)"'
    _passes g-two      'RM -rf "${A:?}/x" "${B:?}/y"'
    _passes literal    'RM -rf build/out'
    _passes not-r      'RM -f "$W"'
    _passes comment    '# RM -rf "$W" used to be here'
    _passes exempt     'RM -rf "$W" # rm-guard-exempt: W is the checked mktemp -d result above'
    _passes redirect   'RM -rf -- "${W:?}" 2>/dev/null || true'
}

@test "33618: an rm inside a quoted payload ends with its string; one in a message is still read" {
    [[ -f "$CHECK" ]] || fail "scripts/check-folder-deletes.sh does not exist"
    _passes  payload-double  'printf "%s" "42; RM -rf /" > "${TMPDIR:?}/f"'
    _passes  payload-single  "call '{\"id\":\"41; RM -rf /\"}' \"\$(other)\""
    _refused message-var     'echo "then RM -rf $W"' 2
}

@test "33618: a file that cannot be read is a failure to pass, not a pass" {
    [[ -f "$CHECK" ]] || fail "scripts/check-folder-deletes.sh does not exist"
    run bash "$CHECK" --file "$BATS_TEST_TMPDIR/not-there.sh"
    [[ "$status" -eq 2 ]] || fail "exit $status: $output"
}

# ---------------------------------------------------------------- 3. CI
@test "33618: CI runs the folder-delete check as its own step" {
    grep -q 'bash scripts/check-folder-deletes.sh' "$REPO_ROOT/.github/workflows/test.yml" \
        || fail "test.yml does not run scripts/check-folder-deletes.sh"
}

# ---------------------------------------------------------------- 4. the work-folder helper
_helper() { printf '%s' "$PLUGIN_ROOT/tests/helpers/work-dir.bash"; }

@test "33618: the work-folder helper makes a folder only inside an existing TMPDIR" {
    [[ -f "$(_helper)" ]] || fail "tests/helpers/work-dir.bash does not exist"
    local t="$BATS_TEST_TMPDIR/t"; mkdir -p "$t"
    run env TMPDIR="$t" bash -c '. "$1"; mmry_work_dir_new demo || exit 9; printf "%s" "$MMRY_WORK_DIR"' _ "$(_helper)"
    [[ "$status" -eq 0 ]] || fail "exit $status: $output"
    [[ "$output" == "$t/mmry-demo."* && -d "$output" ]] || fail "made '$output', not a new folder in $t"
    run env TMPDIR="$t/missing" bash -c '. "$1"; mmry_work_dir_new demo' _ "$(_helper)"
    [[ "$status" -ne 0 && "$output" == *"TMPDIR"*"does not exist"* ]] || fail "missing TMPDIR: exit $status: $output"
    [[ ! -e "$t/missing" ]] || fail "the missing TMPDIR was created"
    run env -u TMPDIR bash -c '. "$1"; mmry_work_dir_new demo' _ "$(_helper)"
    [[ "$status" -ne 0 && "$output" == *"TMPDIR is not set"* ]] || fail "unset TMPDIR: exit $status: $output"
}

@test "33618: the work-folder helper removes only a folder it made" {
    [[ -f "$(_helper)" ]] || fail "tests/helpers/work-dir.bash does not exist"
    local t="$BATS_TEST_TMPDIR/t" h="$BATS_TEST_TMPDIR/h" other="$BATS_TEST_TMPDIR/other" p
    mkdir -p "$t/keep" "$h" "$other/mmry-x.abc"
    : > "$t/sentinel"; : > "$h/sentinel"; : > "$other/mmry-x.abc/sentinel"
    # Every refusal: empty, TMPDIR itself (with and without a slash), HOME, a folder outside TMPDIR
    # that looks like a work folder, a folder in TMPDIR not named like one, and a climb out with ..
    for p in "" "$t" "$t/" "$h" "$other/mmry-x.abc" "$t/keep" "$t/mmry-x.abc/.." ; do
        run env TMPDIR="$t" HOME="$h" bash -c '. "$1"; mmry_work_dir_remove "$2"' _ "$(_helper)" "$p"
        [[ "$status" -ne 0 ]] || fail "removing '$p' was not refused"
    done
    [[ -f "$t/sentinel" && -d "$t/keep" && -f "$h/sentinel" && -f "$other/mmry-x.abc/sentinel" ]] \
        || fail "a refused removal deleted something"
    # Inputs only one check stops, so removing that check turns this test red (round 1b mutations).
    # The containment check: TMPDIR itself, and a work-folder name outside it, when both are relative
    # and named like a work folder (no slash, so the "directly inside" check cannot catch them).
    local rel="$BATS_TEST_TMPDIR/rel"
    mkdir -p "$rel/mmry-t.1/mmry-in.abc" "$rel/mmry-out.abc"
    : > "$rel/mmry-t.1/sentinel"; : > "$rel/mmry-out.abc/sentinel"
    for p in "mmry-t.1" "mmry-out.abc" ; do
        run env TMPDIR="mmry-t.1" HOME="$h" bash -c 'cd "$3" || exit 9; . "$1"; mmry_work_dir_remove "$2"' _ "$(_helper)" "$p" "$rel"
        [[ "$status" -ne 0 && "$status" -ne 9 ]] || fail "removing relative '$p' (TMPDIR=mmry-t.1) was not refused: exit $status: $output"
    done
    [[ -f "$rel/mmry-t.1/sentinel" && -f "$rel/mmry-out.abc/sentinel" ]] || fail "a refused relative removal deleted something"
    # The "directly inside" check: a folder nested in a work folder, whose name still starts mmry-.
    mkdir -p "$t/mmry-a.b/sub"; : > "$t/mmry-a.b/sub/sentinel"
    run env TMPDIR="$t" HOME="$h" bash -c '. "$1"; mmry_work_dir_remove "$2"' _ "$(_helper)" "$t/mmry-a.b/sub"
    [[ "$status" -ne 0 && -f "$t/mmry-a.b/sub/sentinel" ]] || fail "a folder nested in a work folder was removed: exit $status: $output"
    # The one it made goes.
    run env TMPDIR="$t" HOME="$h" bash -c '. "$1"; mmry_work_dir_new demo || exit 9; : > "$MMRY_WORK_DIR/f"; mmry_work_dir_remove "$MMRY_WORK_DIR" || exit 8; [ ! -e "$MMRY_WORK_DIR" ]' _ "$(_helper)"
    [[ "$status" -eq 0 ]] || fail "its own work folder was not removed: exit $status: $output"
    [[ -f "$t/sentinel" ]] || fail "TMPDIR's sentinel went with it"
}

@test "33618: the work-folder helper resets only a folder strictly inside the work folder" {
    [[ -f "$(_helper)" ]] || fail "tests/helpers/work-dir.bash does not exist"
    local t="$BATS_TEST_TMPDIR/t"; mkdir -p "$t"; : > "$t/sentinel"
    run env TMPDIR="$t" bash -c '
        . "$1"; mmry_work_dir_new demo || exit 9; w="$MMRY_WORK_DIR"
        mkdir -p "$w/m"; : > "$w/m/old"; : > "$w/keep"
        mmry_work_reset "$w/m" || exit 8; [ -d "$w/m" ] && [ ! -e "$w/m/old" ] || exit 7
        mmry_work_reset "$w" && exit 6
        mmry_work_reset "" && exit 5
        mmry_work_reset "$1" && exit 4
        mmry_work_reset "$w/m/.." && exit 3
        [ -f "$w/keep" ] || exit 2
        mmry_work_dir_remove "$w"' _ "$(_helper)"
    [[ "$status" -eq 0 ]] || fail "exit $status (8 reset failed, 7 not emptied, 6-3 a refusal missing, 2 the work folder lost a file): $output"
    [[ -f "$t/sentinel" ]] || fail "TMPDIR's sentinel was deleted"
}

# ---------------------------------------------------------------- 5. the mutation runners
# A runner that is not yet built on the helper would, with a missing TMPDIR, create it and start the
# whole mutation run. That is not something to start from a test, so such a runner fails here BEFORE
# it is run.
_runners() { ls "$PLUGIN_ROOT"/tests/mutation/run-*.sh "$PLUGIN_ROOT"/tests/structural/run-codex-mutations.sh; }

@test "33618: every mutation runner stops with a message when TMPDIR does not exist, and deletes nothing" {
    local standin="$BATS_TEST_TMPDIR/shared-tmp-standin" h="$BATS_TEST_TMPDIR/home" r n=0
    mkdir -p "$standin" "$h"
    : > "$standin/sentinel-other-work"; mkdir -p "$standin/other-session"; : > "$standin/other-session/f"
    : > "$h/sentinel-home"
    for r in $(_runners); do
        grep -q 'mmry_work_dir_new' "$r" || fail "$(basename "$r") does not make its work folder with tests/helpers/work-dir.bash, so it is not run"
        run env TMPDIR="$standin/missing" HOME="$h" bash "$r"
        [[ "$status" -ne 0 ]] || fail "$(basename "$r") exited 0 with a missing TMPDIR: $output"
        [[ "$output" == *"REFUSED TO START"*"does not exist"* ]] || fail "$(basename "$r") gave no plain message: $output"
        [[ ! -e "$standin/missing" ]] || fail "$(basename "$r") created the missing TMPDIR"
        run env -u TMPDIR HOME="$h" bash "$r"
        [[ "$status" -ne 0 && "$output" == *"TMPDIR is not set"* ]] || fail "$(basename "$r") with TMPDIR unset: exit $status: $output"
        n=$((n + 1))
    done
    [[ "$n" -ge 10 ]] || fail "only $n runners found"
    [[ -f "$standin/sentinel-other-work" && -f "$standin/other-session/f" ]] || fail "the stand-in's files were deleted"
    [[ -f "$h/sentinel-home" ]] || fail "HOME's sentinel was deleted"
}

@test "33618: no mutation runner or perf script falls back to /tmp for its work folder" {
    local f bad=""
    for f in $(_runners) "$PLUGIN_ROOT"/tests/perf/*.sh; do
        # A work-folder assignment or a mktemp that falls back to /tmp. Mutation text that quotes the
        # production code's own ${TMPDIR:-/tmp} (inside a quoted string) is not a work folder.
        grep -nE '^[[:space:]]*((export|local)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\{TMPDIR:-/tmp\}|mktemp[^|;]*TMPDIR:-/tmp|TMPDIR=/tmp' "$f" >/dev/null && bad="$bad $(basename "$f")"
    done
    [[ -z "$bad" ]] || fail "falls back to /tmp:$bad"
}

# ---------------------------------------------------------------- 6. the test teardown
@test "33618: the test teardown refuses to delete HOME" {
    # The teardown's job is to delete the test's own folder, which is also that test's TMPDIR, so
    # TMPDIR is not refused here. HOME is, with or without a trailing slash. The root is refused by
    # the same code and is deliberately never planted.
    local h="$BATS_TEST_TMPDIR/home-standin"
    mkdir -p "$h"; : > "$h/sentinel"
    run env HOME="$h" bash -c '. "$1/tests/helpers/teardown-tmp.bash"; mmry_teardown_tmp "$HOME"' _ "$PLUGIN_ROOT"
    [[ -f "$h/sentinel" ]] || fail "the teardown deleted HOME: $output"
    run env HOME="$h" bash -c '. "$1/tests/helpers/teardown-tmp.bash"; mmry_teardown_tmp "$HOME/"' _ "$PLUGIN_ROOT"
    [[ -f "$h/sentinel" ]] || fail "the teardown deleted HOME/: $output"
}
