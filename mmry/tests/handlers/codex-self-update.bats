#!/usr/bin/env bats
# codex-self-update.bats - what self-update.sh does on Codex, run from the plugin folder (#33062 fix
# round 5, option (a)).
#
# On Codex the hooks and the MCP server run from the plugin folder Codex installed
# (<CODEX_HOME>/plugins/cache/...), and Codex fingerprints that folder for hook trust. So:
#   - a newer VERIFIED release is written into the plugin folder and the Codex home's copy, and its
#     bookkeeping (.last-release-cleanup, .last-self-update) goes in the Codex home only;
#   - anything else (no list, a damaged list, a list for another version, an unsafe list, a release
#     that is not newer) leaves the plugin folder byte-identical and records nothing;
#   - a session with no release changes nothing in the plugin folder: the once-per-version cleanup
#     tidies the Codex home's copy only.
# 33033's own refusals (whole names, unsafe entries, version comparison, the record) are proven for the
# removal step by self-update-cleanup.bats, self-update-finish.bats and self-update-record.bats, which
# this does not repeat; these tests prove the same refusals stop a write into Codex's plugin folder.
#
# Run the real script against fabricated releases served by a curl mock (helpers/self-update-release).

load '../helpers/test-helper'
load '../helpers/self-update-release'

setup() {
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"
    mkdir -p "$TEST_TMPDIR/mock-bin"
    export PATH="$TEST_TMPDIR/mock-bin:$PATH"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    rm -f "$TMPDIR/.mmry-update-checked"
    unset MMRY_NO_SELF_UPDATE MMRY_HOST || true
    CX="$TEST_TMPDIR/codexhome"
    ROOT="$CX/plugins/cache/mmry-plugin/mmry/local"
    ST="$CX/mmry"
    mkdir -p "$ST/hooks-handlers"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key-12345"}' > "$CX/mmry-config.json"
}

# A Codex plugin folder holding a whole release at version $1 (a verified one: its list is for $1).
_codex_root_at() {
    _release "$1" good
    rm -rf "$ROOT"; mkdir -p "$ROOT"
    ( cd "$TEST_TMPDIR/remote/mmry-plugin-master/mmry" && tar -cf - . ) | ( cd "$ROOT" && tar -xf - )
}

# Every path, type and byte of the plugin folder, for a before/after comparison.
_root_sig() {
    ( cd "$ROOT" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort -k3 \
        && find . -type f -perm -u+x -print | LC_ALL=C sort )
}

_run_codex() {
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" bash "$ROOT/hooks-handlers/self-update.sh"
}

@test "codex update: a newer verified release goes into the plugin folder and the Codex home, its records into the Codex home only" {
    _codex_root_at 3.0.0
    printf 'old\n' > "$ROOT/hooks-handlers/save-record.sh"     # a file 3.0.0 shipped and 3.1.0 does not
    printf 'old\n' > "$ST/hooks-handlers/save-record.sh"
    _release 3.1.0 good
    _run_codex
    [ "$status" -eq 0 ] || fail "status $status: $output"
    grep -q '"version": "3.1.0"' "$ROOT/.claude-plugin/plugin.json" || fail "the plugin folder was not updated: $output"
    grep -q '"version": "3.1.0"' "$ST/.claude-plugin/plugin.json" || fail "the Codex home's copy was not updated: $output"
    [ ! -e "$ROOT/hooks-handlers/save-record.sh" ] || fail "the plugin folder kept a file the release does not list: $output"
    [ ! -e "$ST/hooks-handlers/save-record.sh" ] || fail "the Codex home kept a file the release does not list: $output"
    [ "$(tr -d '\r' < "$ST/.last-self-update")" = "3.1.0" ] || fail "no version record in the Codex home: $output"
    [ "$(tr -d '\r' < "$ST/.last-release-cleanup")" = "3.1.0" ] || fail "no cleanup record in the Codex home: $output"
    local f
    for f in .last-self-update .last-release-cleanup .mmry-host; do
        [ ! -e "$ROOT/$f" ] || fail "$f was written into the plugin folder Codex fingerprints"
    done
    [[ "$output" == *"MMRY AI plugin updated: 3.0.0 -> 3.1.0"* ]] || fail "no update line: $output"
}

@test "codex update: versions compare as numbers, so 2.10.0 is applied over 2.9.1" {
    _codex_root_at 2.9.1
    _release 2.10.0 good
    _run_codex
    grep -q '"version": "2.10.0"' "$ROOT/.claude-plugin/plugin.json" || fail "2.10.0 was not applied over 2.9.1: $output"
}

@test "codex update: an older release is not written into the plugin folder" {
    _codex_root_at 3.0.0
    local before; before="$(_root_sig)"
    _release 2.0.0 good
    _run_codex
    [ "$status" -eq 0 ] || fail "status $status: $output"
    [ "$before" = "$(_root_sig)" ] || fail "the plugin folder changed for an older release: $output"
    [ ! -e "$ST/.last-self-update" ] || fail "an older release was recorded: $output"
    [[ "$output" == *"is not newer than 3.0.0"* ]] || fail "the refusal was not said: $output"
}

@test "codex update: an unverified release (no list, damaged, another version's, without core files, unsafe) changes nothing" {
    local mode before
    for mode in none garbage wrongversion nocore unsafe; do
        _codex_root_at 3.0.0
        rm -f "$ST/.last-self-update" "$ST/.claude-plugin/plugin.json" "$TMPDIR/.mmry-update-checked"
        before="$(_root_sig)"
        _release 3.1.0 "$mode"
        _run_codex
        [ "$status" -eq 0 ] || fail "$mode: status $status: $output"
        [ "$before" = "$(_root_sig)" ] || fail "$mode: the plugin folder changed: $output"
        [ ! -e "$ST/.last-self-update" ] || fail "$mode: a version was recorded: $output"
        [ ! -e "$ST/.claude-plugin/plugin.json" ] || fail "$mode: the Codex home's copy was written: $output"
        [[ "$output" == *"nothing applied"* ]] || fail "$mode: the refusal was not said: $output"
    done
}

@test "codex update: with no release the plugin folder is byte-identical, and only the Codex home is tidied" {
    _codex_root_at 3.0.0       # the curl mock now offers 3.0.0, the version installed: no release
    printf 'old\n' > "$ROOT/hooks-handlers/save-record.sh"
    printf 'old\n' > "$ST/hooks-handlers/save-record.sh"
    local before; before="$(_root_sig)"
    _run_codex
    [ "$status" -eq 0 ] || fail "status $status: $output"
    [ "$before" = "$(_root_sig)" ] || fail "a session with no release changed the plugin folder: $output"
    [ ! -e "$ST/hooks-handlers/save-record.sh" ] || fail "the Codex home was not tidied: $output"
    [ "$(tr -d '\r' < "$ST/.last-release-cleanup")" = "3.0.0" ] || fail "no cleanup record in the Codex home: $output"
    [[ "$output" != *"plugin updated"* ]] || fail "an update was claimed: $output"
}

@test "codex update: a second run with no release, once the Codex home is tidied, does no work at all" {
    _codex_root_at 3.0.0
    _run_codex
    local before; before="$(_root_sig)"
    rm -f "$TMPDIR/.mmry-update-checked"
    _run_codex
    [ "$before" = "$(_root_sig)" ] || fail "the plugin folder changed on a second run: $output"
    [[ "$output" != *"removing"* && "$output" != *"removed"* ]] || fail "the second run tidied again: $output"
}
