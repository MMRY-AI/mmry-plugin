#!/usr/bin/env bats
# session-init-no-downgrade.bats - a session never installs an older release over a newer one
# (#32957 fix round 4b).
#
# session-init.sh copies the RUNNING session's handlers into the installed copy (~/.claude/mmry, or
# ~/.codex/mmry on Codex) on every session start. It used to do that with no version check and no
# deletion, so a session still loaded from an older plugin cache folder, starting after an update,
# put the old handlers back: new scripts beside an old mmry-client.sh, and query-entries.sh failing
# with "mmry_get_entries: command not found". Measured on a real machine on 2026-10-28.
#
# Now it copies only when its own release is the same as or newer than the installed one, and when
# it copies it removes what its own release-files.txt does not list, by the same rules self-update
# uses. These run the real script against fabricated plugin roots in the test's own HOME and
# TMPDIR, with a curl mock first on PATH, and with the memory load replaced by a probe.

load '../helpers/test-helper'
load '../helpers/mock-config'

NEW_VERSION="3.1.0"
OLD_VERSION="3.0.9"

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME || true
    STATE_DIR="$HOME/.claude/mmry"
}

# Write $1/release-files.txt for release $2, naming every file in the root.
_write_list() {
    local root="$1" version="$2"
    {
        printf '# mmry release files %s\n' "$version"
        {
            ( cd "$root" && find . -type f ! -name release-files.txt ! -name '.mmry-host' | sed 's|^\./||' )
            printf '%s\n' release-files.txt
        } | LC_ALL=C sort -u
    } > "$TEST_TMPDIR/list.tmp"
    mv "$TEST_TMPDIR/list.tmp" "$root/release-files.txt"
}

# A plugin root (a cache folder a session runs from) for release $2, at $1. Built from this
# checkout's handlers, so it runs the session-init.sh under test, with the memory load replaced by
# a probe. $3 "old" makes it the older release of the measured incident: its client has no
# mmry_get_entries and it still ships one of the old database scripts.
_plugin_root() {
    local root="$1" version="$2" kind="${3:-new}"
    mkdir -p "$root/hooks-handlers" "$root/setup" "$root/.claude-plugin" "$root/commands"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT"/setup/*.sh "$root/setup/"
    printf '#!/usr/bin/env bash\necho "DELEGATE RAN"\n' > "$root/hooks-handlers/session-start.sh"
    printf '{ "name": "mmry", "version": "%s" }\n' "$version" > "$root/.claude-plugin/plugin.json"
    printf 'database\n' > "$root/commands/database.md"
    if [[ "$kind" == "old" ]]; then
        sed 's/mmry_get_entries/mmry_get_records/g' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh" \
            > "$root/hooks-handlers/mmry-client.sh"
        printf '#!/usr/bin/env bash\necho old\n' > "$root/hooks-handlers/query-records.sh"
    fi
    _write_list "$root" "$version"
}

# The installed copy as self-update leaves it: the whole release, plus its sentinel.
_installed_by_self_update() {
    local root="$1" version="$2"
    mkdir -p "$STATE_DIR"
    cp -R "$root/." "$STATE_DIR/"
    printf '%s\n' "$version" > "$STATE_DIR/.last-self-update"
}

_session_init() {
    local root="$1"; shift
    run env -u CODEX_HOME "$@" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
}

# Run the INSTALLED query-entries.sh the way the model does, against the mock API.
_query_entries_from_installed() {
    create_test_config "http://localhost:5291" "test-api-key" "apikey" >/dev/null
    run env -u CLAUDE_PLUGIN_ROOT bash "$STATE_DIR/hooks-handlers/query-entries.sh" --database-id 42
}

@test "4b: an older session does NOT overwrite a newer installed copy, and query-entries.sh still works" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$new" "$NEW_VERSION"

    _session_init "$old" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"DELEGATE RAN"* ]] || fail "the session did not go on to load memories: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the older session overwrote mmry-client.sh in $STATE_DIR: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "the older session added its old script: $output"
    grep -q "\"version\": \"$NEW_VERSION\"" "$STATE_DIR/.claude-plugin/plugin.json" || fail "installed version changed"
    [[ "$output" == *"installed copy at $STATE_DIR is $NEW_VERSION, newer than this session's $OLD_VERSION"* ]] \
        || fail "the refusal was not explained: $output"

    _query_entries_from_installed
    [[ "$status" -eq 0 ]] || fail "query-entries.sh failed from the installed copy: $output"
    [[ "$output" != *"command not found"* ]] || fail "$output"
    [[ "$output" == *"2 entries in Migraine log:"* ]] || fail "$output"
    grep -q "GET http://localhost:5291/api/databases/42/entries" "$TEST_TMPDIR/curl-log.txt" \
        || fail "the request did not reach the mock"
}

@test "4b: a session records the version it installed, so a later older session cannot overwrite it" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old

    # The installed copy is filled by a session, not by self-update: nothing else says its version.
    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    grep -q "\"version\": \"$NEW_VERSION\"" "$STATE_DIR/.claude-plugin/plugin.json" 2>/dev/null \
        || fail "the session did not record the version it installed: $output"

    _session_init "$old" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the older session overwrote mmry-client.sh: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "$output"
}

@test "4b: a newer session updates an older installed copy and removes a handler its release does not ship" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
    printf 'old\n' > "$STATE_DIR/hooks-handlers/save-record.sh"
    printf 'old\n' > "$STATE_DIR/commands/list-formats.md"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the newer session did not update mmry-client.sh: $output"
    grep -q "\"version\": \"$NEW_VERSION\"" "$STATE_DIR/.claude-plugin/plugin.json" || fail "version not recorded: $output"
    local f
    for f in hooks-handlers/save-record.sh hooks-handlers/query-records.sh commands/list-formats.md; do
        [ ! -e "$STATE_DIR/$f" ] || fail "$f survived in $STATE_DIR: $output"
        [[ "$output" == *"removed $f from $STATE_DIR (not in release $NEW_VERSION)"* ]] || fail "removal of $f not printed: $output"
    done
    [ -f "$STATE_DIR/hooks-handlers/query-entries.sh" ]
    [ -f "$STATE_DIR/commands/database.md" ]
}

@test "4b: an equal version copies, which repairs a copy the real 2.15.2 session-init downgraded" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    # The older cache folder runs the session-init 2.15.2 shipped, which no release can change.
    cp "$BATS_TEST_DIRNAME/../fixtures/session-init-2.15.2.sh" "$old/hooks-handlers/session-init.sh"
    _installed_by_self_update "$new" "$NEW_VERSION"

    # The incident: the old session puts its handlers back.
    _session_init "$old" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    ! cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "precondition: the 2.15.2 session-init did not downgrade the client"
    [ -f "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "precondition: no old script planted"

    # The next session on the installed version repairs it.
    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "an equal-version session did not copy: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "query-records.sh survived: $output"
    [[ "$output" == *"removed hooks-handlers/query-records.sh from $STATE_DIR (not in release $NEW_VERSION)"* ]] || fail "$output"

    _query_entries_from_installed
    [[ "$status" -eq 0 ]] || fail "query-entries.sh failed after the repair: $output"
    [[ "$output" == *"2 entries in Migraine log:"* ]] || fail "$output"
}

@test "4b control: the credential, Formation state and run-time files survive a copy that removes" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
    printf '{"apiKey":"sentinel-not-a-key"}' > "$HOME/.claude/mmry-config.json"
    printf '{}' > "$STATE_DIR/mmry-config.json"
    printf '{}' > "$STATE_DIR/hooks-handlers/mmry-config.local.json"
    printf 'f1\n' > "$TMPDIR/.mmry-formation-sess1"
    printf 'f1\n' > "$STATE_DIR/hooks-handlers/.mmry-formation-sess1"
    mkdir -p "$STATE_DIR/tool-server" "$STATE_DIR/commands/.cache"
    printf '1\n' > "$STATE_DIR/tool-server/session-abc"
    printf 'x\n' > "$STATE_DIR/commands/.cache/entry"
    printf 'x\n' > "$STATE_DIR/hooks-handlers/debug.log"
    printf 'mine\n' > "$STATE_DIR/my-notes.txt"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    # The removals did run, so what survives below survived the rules, not a skipped step.
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "the session did not run its removals: $output"
    local f
    for f in "$HOME/.claude/mmry-config.json" "$STATE_DIR/mmry-config.json" \
             "$STATE_DIR/hooks-handlers/mmry-config.local.json" "$TMPDIR/.mmry-formation-sess1" \
             "$STATE_DIR/hooks-handlers/.mmry-formation-sess1" "$STATE_DIR/tool-server/session-abc" \
             "$STATE_DIR/commands/.cache/entry" "$STATE_DIR/hooks-handlers/debug.log" \
             "$STATE_DIR/my-notes.txt" "$STATE_DIR/.mmry-host" "$STATE_DIR/.last-self-update"; do
        [ -e "$f" ] || fail "$f did not survive: $output"
    done
    [[ "$(cat "$HOME/.claude/mmry-config.json")" == '{"apiKey":"sentinel-not-a-key"}' ]] || fail "credential changed"
}

@test "4b control: an installed copy with no readable version is installed over, as before, and says so" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    mkdir -p "$STATE_DIR/hooks-handlers"
    printf 'old client\n' > "$STATE_DIR/hooks-handlers/mmry-client.sh"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" || fail "$output"
    [[ "$output" == *"has no readable version"* ]] || fail "the fallback was not explained: $output"
}

@test "4b control: a release with no readable file list copies but removes nothing, and says so" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
    rm -f "$new/release-files.txt"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" || fail "$output"
    [ -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "something was removed without a list: $output"
    [[ "$output" == *"could not read this release's file list"*"removing nothing"* ]] || fail "$output"
}

@test "4b codex: an older session does NOT overwrite a newer ~/.codex/mmry" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    STATE_DIR="$HOME/.codex/mmry"
    _installed_by_self_update "$new" "$NEW_VERSION"

    _session_init "$old" MMRY_HOST=codex
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the older Codex session overwrote mmry-client.sh: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "$output"
    [ ! -d "$HOME/.claude/mmry" ] || fail "a Codex session wrote the Claude install"
}
