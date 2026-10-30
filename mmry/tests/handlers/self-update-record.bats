#!/usr/bin/env bats
# self-update-record.bats - the installed version record (.last-self-update) comes only from a
# verified release (#33033 fix round 7, QA round 6 finding F3, requirement 3).
#
# self-update used to write the MARKETPLACE version into .last-self-update, in the plugin root and
# in the installed copy, after every update, whether or not the release it downloaded was verified.
# A session reads that record as the installed version whenever the installed plugin.json names
# none, so an unverified download could pin the installed copy at a version it never held, and
# every real release below that version was then refused as older (QA probe f3-probe.log, case F).
# Now the record is written only when the release's file list loads and is for the version its own
# plugin.json states, and what is written is that version. Otherwise any existing record is left
# exactly as it was.
#
# Each unverified case below is a release whose plugin.json names no version, served while the
# marketplace says 99.0.0, so the record is the only thing a later session can go by. The plugin
# root starts with no record and the installed copy with 0.0.1. After the update neither may
# change, and a verified 3.1.0 session must then install. Same fixtures and setup as
# self-update-finish.bats (helpers/self-update-release.bash): HOME and TMPDIR are the test's own,
# the network is a curl mock, nothing reaches the machine's real install.

load '../helpers/test-helper'
load '../helpers/self-update-release'

setup() {
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"
    mkdir -p "$TEST_TMPDIR/mock-bin"
    export PATH="$TEST_TMPDIR/mock-bin:$PATH"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    rm -f "$TMPDIR/.mmry-update-checked"
    unset MMRY_NO_SELF_UPDATE MMRY_HOST CODEX_HOME || true
}

# Make the curl mock's marketplace report version $1, whatever the archive holds.
_marketplace() {
    # The mock's last line prints the marketplace; replace it whole.
    sed -i '/plugins/d' "$TEST_TMPDIR/mock-bin/curl"
    printf "printf '%%s' '{\"plugins\":[{\"name\":\"mmry\",\"version\":\"%s\"}]}'\n" "$1" >> "$TEST_TMPDIR/mock-bin/curl"
    grep -q "\"version\":\"$1\"" "$TEST_TMPDIR/mock-bin/curl" || fail "the marketplace mock was not set to $1"
}

# The served release's plugin.json, rewritten to name no version, and the archive rebuilt.
_release_without_version() {
    printf '{ "name": "mmry" }\n' > "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/.claude-plugin/plugin.json"
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
}

# The old install, with no record in the plugin root and record 0.0.1 in the installed copy.
_old_install_with_last_update() {
    _old_install
    rm -f "$INSTALL_ROOT/.last-self-update"
    printf '0.0.1\n' > "$STATE_DIR/.last-self-update"
}

# Neither folder's record changed.
_assert_last_update_unchanged() {
    [ ! -e "$INSTALL_ROOT/.last-self-update" ] \
        || fail "an unverified release wrote the plugin root's version record: $(cat "$INSTALL_ROOT/.last-self-update"): $output"
    [[ "$(cat "$STATE_DIR/.last-self-update")" == "0.0.1" ]] \
        || fail "an unverified release changed the installed copy's version record to $(cat "$STATE_DIR/.last-self-update"): $output"
}

# A verified 3.1.0 session (its list names every file and is for 3.1.0) starts, and is not refused:
# it installs over the installed copy. The memory load is replaced by a probe.
_later_verified_session_installs() {
    local root="$TEST_TMPDIR/cache/3.1.0"
    mkdir -p "$root/hooks-handlers" "$root/setup" "$root/.claude-plugin" "$root/commands"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT"/setup/*.sh "$root/setup/"
    printf '#!/usr/bin/env bash\necho "DELEGATE RAN"\n' > "$root/hooks-handlers/session-start.sh"
    printf '{ "name": "mmry", "version": "3.1.0" }\n' > "$root/.claude-plugin/plugin.json"
    printf 'database\n' > "$root/commands/database.md"
    {
        printf '# mmry release files 3.1.0\n'
        {
            ( cd "$root" && find . -type f ! -name release-files.txt | sed 's|^\./||' )
            printf '%s\n' release-files.txt
        } | LC_ALL=C sort -u
    } > "$TEST_TMPDIR/list.tmp"
    mv "$TEST_TMPDIR/list.tmp" "$root/release-files.txt"

    run env -u CODEX_HOME -u MMRY_HOST HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    [[ "$status" -eq 0 ]] || fail "the later session failed, status $status: $output"
    [[ "$output" != *"newer than this session's 3.1.0"* ]] \
        || fail "a verified 3.1.0 session was refused on a version no verified release set: $output"
    grep -q '"version": "3.1.0"' "$STATE_DIR/.claude-plugin/plugin.json" \
        || fail "the verified 3.1.0 session did not install: $(cat "$STATE_DIR/.claude-plugin/plugin.json"): $output"
    cmp -s "$root/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the installed mmry-client.sh is not the 3.1.0 session's: $output"
}

@test "33033 refusal record: a release with no file list records no version, and a later verified session installs" {
    _release 2.0.0 none
    _release_without_version
    _marketplace 99.0.0
    _old_install_with_last_update

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"could not read the release's file list"* ]] || fail "$output"
    _assert_last_update_unchanged
    [[ "$output" == *"recording no version"* ]] || fail "the unrecorded version was not explained: $output"
    _later_verified_session_installs
}

@test "33033 refusal record: a file list that is not one records no version, and a later verified session installs" {
    _release 2.0.0 garbage
    _release_without_version
    _marketplace 99.0.0
    _old_install_with_last_update

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"is not a release file list"* ]] || fail "$output"
    _assert_last_update_unchanged
    [[ "$output" == *"recording no version"* ]] || fail "the unrecorded version was not explained: $output"
    _later_verified_session_installs
}

@test "33033 refusal record: a file list for another version records no version, and a later verified session installs" {
    _release 2.0.0 wrongversion
    _release_without_version
    _marketplace 99.0.0
    _old_install_with_last_update

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"file list is for '0.0.0-other'"* ]] || fail "$output"
    _assert_last_update_unchanged
    [[ "$output" == *"recording no version"* ]] || fail "the unrecorded version was not explained: $output"
    _later_verified_session_installs
}

# A list for another version, with the release's plugin.json still naming one: the mismatch is
# refused for the record too, though the plugin.json then decides the installed version itself.
@test "33033 refusal record: a list for another version beside a versioned plugin.json records no version" {
    _release 9.9.8 wrongversion
    _old_install_with_last_update

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"file list is for '0.0.0-other' but its plugin.json says '9.9.8'"* ]] || fail "$output"
    _assert_last_update_unchanged
}

@test "33033 refusal record: a release without the removal library records no version, and a later verified session installs" {
    _release 2.0.0 good
    rm -f "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/hooks-handlers/lib-release-files.sh"
    _release_without_version
    _marketplace 99.0.0
    _old_install_with_last_update
    rm -f "$INSTALL_ROOT/hooks-handlers/lib-release-files.sh"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"removal code (lib-release-files.sh) could not be loaded"* ]] || fail "$output"
    _assert_last_update_unchanged
    [[ "$output" == *"recording no version"* ]] || fail "the unrecorded version was not explained: $output"
    _later_verified_session_installs
}

# A verified release served while the marketplace names another version: the record is the
# release's own version, never the marketplace's. The installed plugin.json is then taken away so
# that the record alone decides, as it does on an install whose plugin.json was lost.
@test "33033 refusal record: a verified release records its own version, not the marketplace's" {
    _release 2.15.4 good
    _marketplace 99.0.0
    _old_install_with_last_update

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"MMRY AI plugin updated"* ]] || fail "$output"
    [[ "$(cat "$INSTALL_ROOT/.last-self-update")" == "2.15.4" ]] \
        || fail "the plugin root recorded $(cat "$INSTALL_ROOT/.last-self-update" 2>/dev/null), not the release's 2.15.4: $output"
    [[ "$(cat "$STATE_DIR/.last-self-update")" == "2.15.4" ]] \
        || fail "the installed copy recorded $(cat "$STATE_DIR/.last-self-update"), not the release's 2.15.4: $output"
    rm -f "$STATE_DIR/.claude-plugin/plugin.json"
    _later_verified_session_installs
}

# Finish mode: an older self-update has copied a download into the plugin root and read on into
# this script. The download holds an mmry/ folder, but no verified release: no file list, and a
# plugin.json naming no version. Nothing is recorded in the installed copy (finish mode never writes
# the plugin root's record unless verified either).
@test "33033 refusal record: finish mode with an unverified release records no version, and a later verified session installs" {
    _old_install_with_last_update
    printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/mock-bin/curl"
    chmod +x "$TEST_TMPDIR/mock-bin/curl"
    local dl="$TEST_TMPDIR/dl/mmry-plugin-master/mmry"
    mkdir -p "$dl/hooks-handlers" "$dl/.claude-plugin"
    printf '{ "name": "mmry" }\n' > "$dl/.claude-plugin/plugin.json"
    printf 'new\n' > "$dl/hooks-handlers/save-entry.sh"

    run env -u MMRY_HOST -u CODEX_HOME HOME="$HOME" \
        extracted_dir="$TEST_TMPDIR/dl/mmry-plugin-master" tmp_extract="$TEST_TMPDIR/dl" remote_version=99.0.0 \
        bash "$INSTALL_ROOT/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"could not read the release's file list"* ]] || fail "$output"
    _assert_last_update_unchanged
    [[ "$output" == *"recording no version"* ]] || fail "the unrecorded version was not explained: $output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    _later_verified_session_installs
}
