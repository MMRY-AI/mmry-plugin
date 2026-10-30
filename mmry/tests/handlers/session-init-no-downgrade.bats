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

# ── #33033: every refusal proven by a test that fails when the refusal is removed ──

@test "33033 refusal: versions compare as numbers, field by field, not as text" {
    # shellcheck source=/dev/null
    log() { :; }
    source "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh"
    local rc
    rc=0; _su_version_newer 2.10.0 2.9.1 || rc=$?;   [[ "$rc" -eq 0 ]] || fail "2.10.0 not newer than 2.9.1 (rc $rc)"
    rc=0; _su_version_newer 2.9.1 2.10.0 || rc=$?;   [[ "$rc" -eq 1 ]] || fail "2.9.1 newer than 2.10.0 (rc $rc)"
    rc=0; _su_version_newer 2.15.10 2.15.9 || rc=$?; [[ "$rc" -eq 0 ]] || fail "2.15.10 not newer than 2.15.9 (rc $rc)"
    rc=0; _su_version_newer 2.15.9 2.15.10 || rc=$?; [[ "$rc" -eq 1 ]] || fail "2.15.9 newer than 2.15.10 (rc $rc)"
}

@test "33033 refusal: an older session is refused by number: 2.9.1 under 2.10.0, and 2.15.9 under 2.15.10" {
    local pair inst sess new old
    for pair in "2.10.0 2.9.1" "2.15.10 2.15.9"; do
        inst="${pair% *}"; sess="${pair#* }"
        rm -rf "$STATE_DIR" "$TEST_TMPDIR/cache"
        new="$TEST_TMPDIR/cache/$inst"; old="$TEST_TMPDIR/cache/$sess"
        _plugin_root "$new" "$inst"
        _plugin_root "$old" "$sess" old
        _installed_by_self_update "$new" "$inst"

        _session_init "$old" -u MMRY_HOST
        [[ "$status" -eq 0 ]] || fail "$pair: status $status: $output"
        [[ "$output" == *"installed copy at $STATE_DIR is $inst, newer than this session's $sess; leaving it as it is"* ]] \
            || fail "$pair: the older session was not refused: $output"
        cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
            || fail "$pair: the older session overwrote mmry-client.sh: $output"
        [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "$pair: $output"
    done
}

@test "33033 refusal: a list for another version is refused at the session-start mirror" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
    sed -i.bak '1s/.*/# mmry release files 3.0.0/' "$new/release-files.txt" && rm -f "$new/release-files.txt.bak"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"this release's file list is for '3.0.0' but its plugin.json says '$NEW_VERSION'; removing nothing from $STATE_DIR"* ]] \
        || fail "$output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    [ -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "a list for another version removed a file: $output"
    [ ! -e "$STATE_DIR/.last-release-mirror" ] || fail "a refused list was recorded as mirrored"
}

@test "33033 refusal: a development checkout is never touched by session start, and nothing is removed for it" {
    local repo="$TEST_TMPDIR/checkout" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    mkdir -p "$repo/.git"
    _plugin_root "$repo/mmry" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
    # A developer's new handler, in no list yet, and an old script still in the installed copy.
    printf '#!/usr/bin/env bash\necho wip\n' > "$repo/mmry/hooks-handlers/my-new-handler.sh"
    local before after
    before="$(cd "$repo" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)"

    _session_init "$repo/mmry" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"DELEGATE RAN"* ]] || fail "$output"
    [[ "$output" != *"removed "* ]] || fail "session start removed files for a checkout: $output"
    [ -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "removed from the installed copy by a checkout's list: $output"
    [ -e "$STATE_DIR/hooks-handlers/my-new-handler.sh" ] || fail "the developer's new handler was removed: $output"
    after="$(cd "$repo" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)"
    [[ "$before" == "$after" ]] || fail "the checkout changed:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
}

# The other half of the same refusal (#33033 fix round 7): the plugin folder is itself the checkout,
# with .git inside it and none beside it, so only the "$P/.git" check can refuse.
@test "33033 refusal: a plugin folder holding its own .git is a checkout, and session start removes nothing for it" {
    local repo="$TEST_TMPDIR/checkout-inner" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$repo/mmry" "$NEW_VERSION"
    mkdir -p "$repo/mmry/.git"
    printf 'ref: refs/heads/wip\n' > "$repo/mmry/.git/HEAD"
    [ ! -e "$repo/.git" ] || fail "precondition: a .git beside the plugin folder would refuse on its own"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
    # A developer's new handler, in no list yet, and an old script still in the installed copy:
    # a mirror that went ahead would remove both from the installed copy.
    printf '#!/usr/bin/env bash\necho wip\n' > "$repo/mmry/hooks-handlers/my-new-handler.sh"
    local before after
    before="$(cd "$repo" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)"

    _session_init "$repo/mmry" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"DELEGATE RAN"* ]] || fail "$output"
    [[ "$output" != *"removed "* ]] || fail "session start removed files for a checkout: $output"
    [ -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "removed from the installed copy by a checkout's list: $output"
    [ -e "$STATE_DIR/hooks-handlers/my-new-handler.sh" ] || fail "the developer's new handler was removed: $output"
    [ ! -e "$STATE_DIR/.last-release-mirror" ] || fail "a checkout was recorded as mirrored: $output"
    [ -f "$repo/mmry/.git/HEAD" ] || fail "the checkout's .git was touched"
    after="$(cd "$repo" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)"
    [[ "$before" == "$after" ]] || fail "the checkout changed:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
}

@test "33033 fix: a release whose manifest overstates its version leaves the installed version alone" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" bad="$TEST_TMPDIR/cache/99.0.0"
    _plugin_root "$new" "$NEW_VERSION"
    _installed_by_self_update "$new" "$NEW_VERSION"
    # An older release whose plugin.json claims 99.0.0; its own list says what it really is.
    _plugin_root "$bad" "$OLD_VERSION" old
    printf '{ "name": "mmry", "version": "99.0.0" }\n' > "$bad/.claude-plugin/plugin.json"

    _session_init "$bad" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    grep -q "\"version\": \"$NEW_VERSION\"" "$STATE_DIR/.claude-plugin/plugin.json" \
        || fail "the overstated version was recorded: $(cat "$STATE_DIR/.claude-plugin/plugin.json") $output"
    [[ "$output" == *"not recording 99.0.0 as the installed version"* ]] || fail "$output"
    [[ "$(cat "$STATE_DIR/.last-release-mirror" 2>/dev/null)" != "99.0.0" ]] || fail "the mirror marker was pinned"

    # So the real release is not refused as older afterwards, and repairs the copy.
    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" != *"newer than this session's"* ]] || fail "the real release was refused: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" || fail "$output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "$output"
}

@test "33033 fix: a stale file in a shipped folder other than hooks-handlers/ and setup/ triggers the refresh" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _installed_by_self_update "$new" "$NEW_VERSION"
    # First session mirrors the version and records it, so the next one takes the cheap path.
    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$(cat "$STATE_DIR/.last-release-mirror")" == "$NEW_VERSION" ]] || fail "precondition: not mirrored: $output"
    # What an older copy leaves ONLY outside the two folders that used to be watched, so nothing
    # in hooks-handlers/ or setup/ can start the refresh instead.
    printf 'old\n' > "$STATE_DIR/commands/list-formats.md"
    mkdir -p "$STATE_DIR/commands/old"
    printf 'old\n' > "$STATE_DIR/commands/old/list-records.md"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    local f
    for f in commands/list-formats.md commands/old/list-records.md; do
        [ ! -e "$STATE_DIR/$f" ] || fail "$f survived: the refresh did not run: $output"
        [[ "$output" == *"removed $f from $STATE_DIR (not in release $NEW_VERSION)"* ]] || fail "$output"
    done
    [ -f "$STATE_DIR/commands/database.md" ] || fail "a shipped command was removed: $output"
}

# ---------------------------------------------------------------------------------------------
# #33033 fix round 8: refusals from the developer's own inventory
# (R:\Intranet\ClaudeAI\plans\MMRY\v1.32.1\33033-refusal-inventory.md), each red when removed.
# ---------------------------------------------------------------------------------------------

# A newer release over an older installed copy that still holds query-records.sh, which this
# release does not list: a session that mirrors removes it.
_newer_over_older() {
    NEW_ROOT="$TEST_TMPDIR/cache/$NEW_VERSION"
    local old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$NEW_ROOT" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$old" "$OLD_VERSION"
}

_assert_session_removed_nothing() {
    [[ "$output" != *"removed "* ]] || fail "session start removed files: $output"
    [ -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "query-records.sh was removed: $output"
    [ ! -e "$STATE_DIR/.last-release-mirror" ] || fail "the mirror was recorded as done: $output"
}

# session-init.sh, the library check: the library is used only when it defines the version
# comparison. A library without it is not used at all, so nothing is removed.
@test "33033 refusal partial library: a session whose removal library lacks the version comparison removes nothing" {
    _newer_over_older
    printf '\nunset -f _su_version_newer\n' >> "$NEW_ROOT/hooks-handlers/lib-release-files.sh"
    _session_init "$NEW_ROOT" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"lib-release-files.sh could not be loaded; installing without the version check, removing nothing"* ]] \
        || fail "the library without _su_version_newer was used: $output"
    _assert_session_removed_nothing
}

# session-init.sh _mmry_verified_release: the stop after a list that will not load. This list is
# sorted, has a good header and this release's version, so it fails only at the core-entry check,
# after _su_load_list has set the version and written its lines. Without the stop the versions
# match and the mirror prunes with those lines.
@test "33033 refusal session list: a release list that fails after a good header removes nothing at session start" {
    _newer_over_older
    grep -Fvx hooks-handlers/self-update.sh "$NEW_ROOT/release-files.txt" > "$TEST_TMPDIR/list.tmp"
    mv "$TEST_TMPDIR/list.tmp" "$NEW_ROOT/release-files.txt"
    [[ "$(head -n 1 "$NEW_ROOT/release-files.txt")" == "# mmry release files $NEW_VERSION" ]] || fail "precondition: header"
    _session_init "$NEW_ROOT" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"could not read this release's file list ("*"does not name the release's own core files"*"); removing nothing from $STATE_DIR"* ]] \
        || fail "the untrusted list was not refused: $output"
    [[ "$output" == *"not recording $NEW_VERSION as the installed version"* ]] || fail "$output"
    _assert_session_removed_nothing
}

# session-init.sh _mmry_mirror, the once-mirrored path: when the installed copy holds nothing in a
# shipped folder that this release lacks, apart from run-time files (the credential, logs, dot
# files and dot folders), no comparison runs. Each of those exclusions, and the stop itself, is
# what keeps a session from re-running the full comparison on every start.
@test "33033 refusal mirror once: once a version is mirrored, run-time files in the installed copy start no comparison" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _installed_by_self_update "$new" "$NEW_VERSION"
    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$(cat "$STATE_DIR/.last-release-mirror")" == "$NEW_VERSION" ]] || fail "precondition: not mirrored: $output"
    [[ "$output" == *"nothing to remove from $STATE_DIR"* ]] || fail "precondition: the first session did not compare: $output"
    mkdir -p "$STATE_DIR/commands/.cache"
    printf '{}' > "$STATE_DIR/hooks-handlers/mmry-config.local.json"
    printf 'x\n' > "$STATE_DIR/hooks-handlers/debug.log"
    printf 'f1\n' > "$STATE_DIR/hooks-handlers/.mmry-formation-sess1"
    printf 'x\n' > "$STATE_DIR/commands/.cache/entry"

    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" != *"nothing to remove from"* ]] || fail "a session on a mirrored version compared again: $output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    local f
    for f in hooks-handlers/mmry-config.local.json hooks-handlers/debug.log hooks-handlers/.mmry-formation-sess1 commands/.cache/entry; do
        [ -e "$STATE_DIR/$f" ] || fail "$f was removed: $output"
    done
}

# session-init.sh _mmry_mirror: the mirror is recorded only when its removal step succeeded. A comm
# that fails makes the prune refuse; the next session must then try again, so nothing is recorded.
@test "33033 refusal mirror marker: a mirror whose removal step failed is not recorded as done" {
    _newer_over_older
    local bin="$TEST_TMPDIR/failing-comm-bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/comm"
    chmod +x "$bin/comm"
    _session_init "$NEW_ROOT" -u MMRY_HOST PATH="$bin:$PATH"
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"could not compare $STATE_DIR with the release's file list; removing nothing"* ]] \
        || fail "precondition: the prune did not fail: $output"
    _assert_session_removed_nothing
}

# lib _su_version_newer: each field is read as a decimal number (10#). Without it a field with a
# leading zero is read as octal, so 2.010.0 ranks below 2.9.0 and 2.08.0 is not a number at all.
@test "33033 refusal: a version field with a leading zero is still compared as a decimal number" {
    log() { :; }
    # shellcheck source=/dev/null
    source "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh"
    local rc
    rc=0; _su_version_newer 2.010.0 2.9.0 2>/dev/null || rc=$?; [[ "$rc" -eq 0 ]] || fail "2.010.0 not newer than 2.9.0 (rc $rc)"
    rc=0; _su_version_newer 2.9.0 2.010.0 2>/dev/null || rc=$?; [[ "$rc" -eq 1 ]] || fail "2.9.0 newer than 2.010.0 (rc $rc)"
    rc=0; _su_version_newer 2.08.0 2.7.0 2>/dev/null || rc=$?;  [[ "$rc" -eq 0 ]] || fail "2.08.0 not newer than 2.7.0 (rc $rc)"
}

# session-init.sh, the installed version: with no plugin.json in the installed copy, the
# .last-self-update self-update writes beside it is the installed version. Without that fallback
# the installed copy has no version, so an older session installs over it and mirrors its own
# older list against it.
@test "33033 refusal: an installed copy known only by its .last-self-update is still newer than an older session" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$new" "$NEW_VERSION"
    rm -f "$STATE_DIR/.claude-plugin/plugin.json"
    [[ "$(cat "$STATE_DIR/.last-self-update")" == "$NEW_VERSION" ]] || fail "precondition: sentinel"

    _session_init "$old" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"installed copy at $STATE_DIR is $NEW_VERSION, newer than this session's $OLD_VERSION; leaving it as it is"* ]] \
        || fail "the older session was not refused: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the older session overwrote mmry-client.sh: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "the older session added its old script: $output"
    [[ "$output" != *"removed "* ]] || fail "the older session removed files: $output"
}

# The same check, the other way: the installed plugin.json, when there is one, is the installed
# version, and an older .last-self-update beside it (left by an earlier self-update, before a
# session installed a newer release) does not make the copy look older than it is.
@test "33033 refusal: the installed plugin.json outranks an older .last-self-update beside it" {
    local new="$TEST_TMPDIR/cache/$NEW_VERSION" old="$TEST_TMPDIR/cache/$OLD_VERSION"
    _plugin_root "$new" "$NEW_VERSION"
    _plugin_root "$old" "$OLD_VERSION" old
    _installed_by_self_update "$new" "$NEW_VERSION"
    printf '%s\n' "$OLD_VERSION" > "$STATE_DIR/.last-self-update"

    _session_init "$old" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"installed copy at $STATE_DIR is $NEW_VERSION, newer than this session's $OLD_VERSION; leaving it as it is"* ]] \
        || fail "the older session was not refused: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "the older session overwrote mmry-client.sh: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "the older session added its old script: $output"
}

# _su_version_newer, versions with different numbers of fields (#33033 round 6, QA finding X1).
# The comparison must run over the LONGER of the two versions, a missing field counting as 0.
# Run over the shorter one, an installed 3.1.1 and a 3.1 session compare equal, so the older
# session installs over the newer copy and its mirror removes what release 3.1 does not list.
@test "33033 refusal field count: versions with different numbers of fields compare over the longer one" {
    log() { :; }
    # shellcheck source=/dev/null
    source "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh"
    local rc
    rc=0; _su_version_newer 3.1.1 3.1 || rc=$?; [[ "$rc" -eq 0 ]] || fail "3.1.1 not newer than 3.1 (rc $rc)"
    rc=0; _su_version_newer 3.1 3.1.1 || rc=$?; [[ "$rc" -eq 1 ]] || fail "3.1 newer than 3.1.1 (rc $rc)"
    rc=0; _su_version_newer 3.1 3.1.0 || rc=$?; [[ "$rc" -eq 1 ]] || fail "3.1 newer than 3.1.0 (rc $rc)"
    rc=0; _su_version_newer 3.1.0 3.1 || rc=$?; [[ "$rc" -eq 1 ]] || fail "3.1.0 newer than 3.1 (rc $rc)"
}

@test "33033 refusal field count: an installed 3.1.1 is newer than a 3.1 session, and a 3.1.1 session installs over 3.1" {
    # Installed 3.1.1, session 3.1: refused, nothing copied, nothing removed.
    local new="$TEST_TMPDIR/cache/3.1.1" old="$TEST_TMPDIR/cache/3.1"
    _plugin_root "$new" 3.1.1
    printf 'only in 3.1.1\n' > "$new/commands/only-in-new.md"
    _write_list "$new" 3.1.1
    _plugin_root "$old" 3.1 old
    _installed_by_self_update "$new" 3.1.1

    _session_init "$old" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "3.1 over 3.1.1: status $status: $output"
    [[ "$output" == *"installed copy at $STATE_DIR is 3.1.1, newer than this session's 3.1; leaving it as it is"* ]] \
        || fail "3.1 over 3.1.1: the older session was not refused: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "3.1 over 3.1.1: the older session overwrote mmry-client.sh: $output"
    [ -f "$STATE_DIR/commands/only-in-new.md" ] || fail "3.1 over 3.1.1: the older session's mirror removed commands/only-in-new.md: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "3.1 over 3.1.1: the older session added its old script: $output"
    grep -q '"version": "3.1.1"' "$STATE_DIR/.claude-plugin/plugin.json" || fail "3.1 over 3.1.1: installed version changed: $output"
    [[ "$output" != *"removed "* ]] || fail "3.1 over 3.1.1: the older session removed files: $output"

    # The reverse, installed 3.1 and session 3.1.1: the newer session installs and mirrors.
    rm -rf "$STATE_DIR"
    _installed_by_self_update "$old" 3.1
    _session_init "$new" -u MMRY_HOST
    [[ "$status" -eq 0 ]] || fail "3.1.1 over 3.1: status $status: $output"
    cmp -s "$new/hooks-handlers/mmry-client.sh" "$STATE_DIR/hooks-handlers/mmry-client.sh" \
        || fail "3.1.1 over 3.1: the newer session did not update mmry-client.sh: $output"
    grep -q '"version": "3.1.1"' "$STATE_DIR/.claude-plugin/plugin.json" || fail "3.1.1 over 3.1: version not recorded: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/query-records.sh" ] || fail "3.1.1 over 3.1: the old script survived: $output"
    [[ "$output" == *"removed hooks-handlers/query-records.sh from $STATE_DIR (not in release 3.1.1)"* ]] \
        || fail "3.1.1 over 3.1: removal not printed: $output"
}
