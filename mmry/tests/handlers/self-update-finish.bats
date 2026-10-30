#!/usr/bin/env bats
# self-update-finish.bats - what self-update records after an update, and when it records nothing
# (#33033 round 10). Split from self-update-cleanup.bats, which had reached the 64000-byte limit
# structural/test-file-size.bats sets for bats on Windows. Same fixtures (helpers/self-update-release.bash)
# and the same setup: the real script against a fabricated release, HOME and TMPDIR the test's own,
# nothing reaching the machine's real install.

load '../helpers/test-helper'
load '../helpers/self-update-release'

setup() {
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"
    mkdir -p "$TEST_TMPDIR/mock-bin"
    export PATH="$TEST_TMPDIR/mock-bin:$PATH"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    rm -f "$TMPDIR/.mmry-update-checked"
    unset MMRY_NO_SELF_UPDATE
}

# Finish mode needs the download to hold a release: ${extracted_dir}/mmry (#33033 round 6, QA
# finding U304b). Inherited variables naming a download folder with no mmry/ in it are not an
# older self-update's continuation, so nothing is recorded: no .last-self-update in either folder
# names their version, and no "updated" line claims an update. Without that check the inherited
# remote_version becomes the installed version record, which requirement 3 says only a verified
# release may set.
@test "33033 refusal finish mode: a download with no mmry/ folder records no version and claims no update" {
    _old_install
    printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/mock-bin/curl"
    chmod +x "$TEST_TMPDIR/mock-bin/curl"
    mkdir -p "$TEST_TMPDIR/dl/mmry-plugin-x"
    printf 'not a release\n' > "$TEST_TMPDIR/dl/mmry-plugin-x/README.md"
    # The installed copy already has a record; the plugin root has none.
    printf '0.0.1\n' > "$STATE_DIR/.last-self-update"
    rm -f "$INSTALL_ROOT/.last-self-update"

    run env -u MMRY_HOST -u CODEX_HOME HOME="$HOME" \
        extracted_dir="$TEST_TMPDIR/dl/mmry-plugin-x" tmp_extract="$TEST_TMPDIR/dl" remote_version=9.9.9 \
        bash "$INSTALL_ROOT/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" != *"MMRY AI plugin updated"* ]] || fail "a download with no release in it was reported as an update: $output"
    [ ! -e "$INSTALL_ROOT/.last-self-update" ] \
        || fail "the plugin root's version record was written from inherited variables: $(cat "$INSTALL_ROOT/.last-self-update"): $output"
    [[ "$(cat "$STATE_DIR/.last-self-update")" == "0.0.1" ]] \
        || fail "the installed copy's version record changed to $(cat "$STATE_DIR/.last-self-update"): $output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "$output"
}

# The update path's copy-failure stop (#33033 round 6, found while adding .last-self-update to the
# inventory's markers). When the release cannot be copied into the plugin root, self-update stops
# before _su_finish_update: the plugin root still holds the OLD release, so removing what the new
# list does not name would take files the old code still uses, and recording the new version
# would make the old copy look current. A cp that fails on the release's files stands in for a
# full or read-only disk.
@test "33033 refusal copy failure: a release that could not be copied removes nothing and records no version" {
    _release 9.9.9 good
    _old_install
    local real_cp
    real_cp="$(command -v cp)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for a in "$@"; do [[ "$a" == */mmry-plugin-*/mmry/* ]] && exit 1; done\n'
        printf 'exec "%s" "$@"\n' "$real_cp"
    } > "$TEST_TMPDIR/mock-bin/cp"
    chmod +x "$TEST_TMPDIR/mock-bin/cp"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"failed to copy update into plugin root"* ]] || fail "the copy failure was not reported: $output"
    [[ "$output" != *"MMRY AI plugin updated"* ]] || fail "a failed copy was reported as an update: $output"
    [[ "$output" != *"removed "* ]] || fail "a failed copy started removals: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "save-record.sh removed from the plugin root: $output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "save-record.sh removed from the installed copy: $output"
    [ ! -e "$INSTALL_ROOT/.last-self-update" ] || fail "a failed copy recorded version $(cat "$INSTALL_ROOT/.last-self-update"): $output"
    [ ! -e "$STATE_DIR/.last-self-update" ] || fail "a failed copy recorded version $(cat "$STATE_DIR/.last-self-update") in the installed copy: $output"
    [ ! -e "$INSTALL_ROOT/.last-release-cleanup" ] || fail "a failed copy was recorded as cleaned: $output"
}

# Every file under $1 with its checksum, one per line, sorted.
_tree_sums() {
    ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum )
}

# The update path's extraction-failure stop, self-update.sh's `exit 0` after "failed to extract
# update archive" (#33033 fix round 7, QA round 6 finding S392). A truncated archive is the case
# that matters: tar writes the part it could read before it fails, so the download folder holds a
# half release. Without the stop that half is copied over the plugin root (a new plugin.json beside
# missing handlers), recorded as the installed version and reported as an update, and since the
# local and marketplace versions then agree, no later update repairs it.
@test "33033 refusal extract failure: a truncated archive copies nothing, records no version and claims no update" {
    _release 9.9.9 good
    # Make the release big enough that a cut archive still yields files before tar fails.
    local rel="$TEST_TMPDIR/remote/mmry-plugin-master/mmry"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$rel/hooks-handlers/"
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
    local size
    size="$(wc -c < "$TEST_TMPDIR/remote.tar.gz" | tr -d '[:space:]')"
    head -c "$(( size * 7 / 10 ))" "$TEST_TMPDIR/remote.tar.gz" > "$TEST_TMPDIR/cut.tar.gz"
    mv "$TEST_TMPDIR/cut.tar.gz" "$TEST_TMPDIR/remote.tar.gz"
    _old_install
    _tree_sums "$INSTALL_ROOT" > "$TEST_TMPDIR/root.before"
    _tree_sums "$STATE_DIR" > "$TEST_TMPDIR/state.before"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"failed to extract update archive"* ]] || fail "the extraction failure was not reported: $output"
    [[ "$output" != *"MMRY AI plugin updated"* ]] || fail "a truncated archive was reported as an update: $output"
    _tree_sums "$INSTALL_ROOT" > "$TEST_TMPDIR/root.after"
    _tree_sums "$STATE_DIR" > "$TEST_TMPDIR/state.after"
    cmp -s "$TEST_TMPDIR/root.before" "$TEST_TMPDIR/root.after" \
        || fail "a half-extracted release was copied into the plugin root: $(diff "$TEST_TMPDIR/root.before" "$TEST_TMPDIR/root.after"): $output"
    cmp -s "$TEST_TMPDIR/state.before" "$TEST_TMPDIR/state.after" \
        || fail "a half-extracted release was copied into the installed copy: $(diff "$TEST_TMPDIR/state.before" "$TEST_TMPDIR/state.after"): $output"
    [ ! -e "$INSTALL_ROOT/.last-self-update" ] || fail "a truncated archive recorded version $(cat "$INSTALL_ROOT/.last-self-update"): $output"
    [ ! -e "$STATE_DIR/.last-self-update" ] || fail "a truncated archive recorded version $(cat "$STATE_DIR/.last-self-update") in the installed copy: $output"
    [[ "$output" != *"removed "* ]] || fail "a truncated archive started removals: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "$output"
}
