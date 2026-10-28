#!/usr/bin/env bats
# self-update-cleanup.bats - self-update removes what a release no longer ships (#32957 fix round 4).
#
# self-update copied a release over the install folder and deleted nothing, so the nine old database
# scripts (save-record.sh and the rest) stayed on customer machines after 2.15.2. It now removes
# from the plugin's own folders whatever the release's release-files.txt does not name. These run
# the real script against a fabricated release, because what matters is what it removes and what it
# leaves, not what its source says. HOME and TMPDIR are the test's own; nothing here reaches the
# machine's real install.

load '../helpers/test-helper'

setup() {
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"
    mkdir -p "$TEST_TMPDIR/mock-bin"
    export PATH="$TEST_TMPDIR/mock-bin:$PATH"
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    rm -f "$TMPDIR/.mmry-update-checked"
    unset MMRY_NO_SELF_UPDATE
}

# A plugin tree on an older version, with the libraries the resolver needs.
_updatable_plugin() {
    local root="$1"
    mkdir -p "$root/hooks-handlers" "$root/.claude-plugin"
    cp "$PLUGIN_ROOT/hooks-handlers/self-update.sh" "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-jq.sh" "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$root/hooks-handlers/"
    printf '%s' '{ "name": "mmry", "version": "0.0.1" }' > "$root/.claude-plugin/plugin.json"
}

# A release archive served by a curl mock. $1 version; $2 list: good, none, garbage, wrongversion.
_release() {
    local version="$1" list="${2:-good}"
    local rel="$TEST_TMPDIR/remote/mmry-plugin-master/mmry"
    local listed_version="$version"
    rm -rf "$TEST_TMPDIR/remote" "$TEST_TMPDIR/remote.tar.gz"
    mkdir -p "$rel/hooks-handlers" "$rel/.claude-plugin" "$rel/commands"
    cp "$PLUGIN_ROOT/hooks-handlers/self-update.sh" "$PLUGIN_ROOT/hooks-handlers/lib-jq.sh" \
       "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$rel/hooks-handlers/"
    printf 'new\n' > "$rel/hooks-handlers/save-entry.sh"
    printf 'new\n' > "$rel/commands/database.md"
    printf 'readme\n' > "$rel/README.md"
    printf '{ "name": "mmry", "version": "%s" }\n' "$version" > "$rel/.claude-plugin/plugin.json"
    [[ "$list" == "wrongversion" ]] && listed_version="0.0.0-other"
    case "$list" in
        good|wrongversion)
            {
                printf '# mmry release files %s\n' "$listed_version"
                {
                    ( cd "$rel" && find . -type f | sed 's|^\./||' )
                    printf '%s\n' release-files.txt tests/libs/bats-core/
                } | LC_ALL=C sort -u
            } > "$TEST_TMPDIR/list.tmp"
            mv "$TEST_TMPDIR/list.tmp" "$rel/release-files.txt"
            ;;
        garbage)
            printf 'this is not a release file list\nhooks-handlers/self-update.sh\n' > "$rel/release-files.txt"
            ;;
        none) ;;
    esac
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
    {
        printf '#!/usr/bin/env bash\n'
        printf 'out=""; prev=""\n'
        printf 'for arg in "$@"; do [[ "$prev" == "-o" ]] && out="$arg"; prev="$arg"; done\n'
        printf 'if [[ -n "$out" ]]; then cp "%s" "$out"; exit 0; fi\n' "$TEST_TMPDIR/remote.tar.gz"
        printf "printf '%%s' '{\"plugins\":[{\"name\":\"mmry\",\"version\":\"%s\"}]}'\n" "$version"
    } > "$TEST_TMPDIR/mock-bin/curl"
    chmod +x "$TEST_TMPDIR/mock-bin/curl"
}

# An install from an older release: the plugin root, plus the installed copy in ~/.claude/mmry,
# each holding one of the old database scripts that 2.15.2 renamed away.
_old_install() {
    INSTALL_ROOT="$TEST_TMPDIR/cache/mmry"
    _updatable_plugin "$INSTALL_ROOT"
    STATE_DIR="$HOME/.claude/mmry"
    mkdir -p "$STATE_DIR/hooks-handlers"
    printf 'old\n' > "$INSTALL_ROOT/hooks-handlers/save-record.sh"
    printf 'old\n' > "$STATE_DIR/hooks-handlers/save-record.sh"
}

_run_update() {
    run env -u MMRY_HOST -u CODEX_HOME HOME="$HOME" bash "$INSTALL_ROOT/hooks-handlers/self-update.sh"
}

@test "32957 plant: an old script the release does not list is removed, from the plugin root and the installed copy" {
    _release 9.9.9 good
    _old_install

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ ! -e "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "save-record.sh survived in the plugin root: $output"
    [ ! -e "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "save-record.sh survived in ~/.claude/mmry: $output"
    # What the release ships is there, and each removal was printed.
    [ -f "$INSTALL_ROOT/hooks-handlers/save-entry.sh" ]
    [ -f "$STATE_DIR/hooks-handlers/save-entry.sh" ]
    [[ "$output" == *"removed hooks-handlers/save-record.sh from $INSTALL_ROOT (not in release 9.9.9)"* ]] || fail "$output"
    [[ "$output" == *"removed hooks-handlers/save-record.sh from $STATE_DIR (not in release 9.9.9)"* ]] || fail "$output"
    [[ "$output" == *"MMRY AI plugin updated: 0.0.1 -> 9.9.9"* ]] || fail "$output"
}

@test "32957 control: the credential, Formation state, run-time state and files outside the shipped folders survive" {
    _release 9.9.9 good
    _old_install
    # The credential where it really lives, and copies where a customer might have dropped one.
    printf '{"apiKey":"sentinel-not-a-key"}' > "$HOME/.claude/mmry-config.json"
    printf '{}' > "$INSTALL_ROOT/mmry-config.json"
    printf '{}' > "$INSTALL_ROOT/hooks-handlers/mmry-config.json"
    printf '{}' > "$STATE_DIR/hooks-handlers/mmry-config.local.json"
    # Formation state lives in TMPDIR; a stray one inside a plugin folder is kept too.
    printf 'f1\n' > "$TMPDIR/.mmry-formation-sess1"
    printf 'f1\n' > "$INSTALL_ROOT/hooks-handlers/.mmry-formation-sess1"
    # Run-time files the plugin and the host write inside the install folders.
    mkdir -p "$STATE_DIR/tool-server" "$INSTALL_ROOT/.in_use" "$INSTALL_ROOT/commands/.cache"
    printf '1\n' > "$STATE_DIR/tool-server/session-abc"
    printf 'claude\n' > "$STATE_DIR/.mmry-host"
    printf 'x\n' > "$INSTALL_ROOT/.in_use/lock"
    printf 'x\n' > "$INSTALL_ROOT/commands/.cache/entry"
    printf 'x\n' > "$INSTALL_ROOT/hooks-handlers/debug.log"
    # A file at the top of the install folder, and a folder the release does not ship.
    printf 'mine\n' > "$INSTALL_ROOT/my-notes.txt"
    mkdir -p "$INSTALL_ROOT/my-stuff"
    printf 'mine\n' > "$INSTALL_ROOT/my-stuff/keep.sh"
    # Content of a submodule folder the list keeps whole.
    mkdir -p "$INSTALL_ROOT/tests/libs/bats-core/bin"
    printf 'bats\n' > "$INSTALL_ROOT/tests/libs/bats-core/bin/bats"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    # The removals did run, so the survivors below survived the rules and not a skipped step.
    [ ! -e "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "the update did not run its removals: $output"
    local f
    for f in "$HOME/.claude/mmry-config.json" "$INSTALL_ROOT/mmry-config.json" \
             "$INSTALL_ROOT/hooks-handlers/mmry-config.json" "$STATE_DIR/hooks-handlers/mmry-config.local.json" \
             "$TMPDIR/.mmry-formation-sess1" "$INSTALL_ROOT/hooks-handlers/.mmry-formation-sess1" \
             "$STATE_DIR/tool-server/session-abc" "$STATE_DIR/.mmry-host" "$INSTALL_ROOT/.in_use/lock" \
             "$INSTALL_ROOT/commands/.cache/entry" "$INSTALL_ROOT/hooks-handlers/debug.log" \
             "$INSTALL_ROOT/my-notes.txt" "$INSTALL_ROOT/my-stuff/keep.sh" \
             "$INSTALL_ROOT/tests/libs/bats-core/bin/bats"; do
        [ -f "$f" ] || fail "removed a file that is not the plugin's to remove: $f"$'\n'"$output"
    done
    [[ "$(cat "$HOME/.claude/mmry-config.json")" == '{"apiKey":"sentinel-not-a-key"}' ]]
}

@test "32957 control: a release with no file list removes nothing and says so" {
    _release 9.9.9 none
    _old_install

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ]
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ]
    [[ "$output" == *"could not read the release's file list"*"removing nothing"* ]] || fail "$output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    # The update itself still went in.
    [ -f "$INSTALL_ROOT/hooks-handlers/save-entry.sh" ]
}

@test "32957 control: a file list that is not one removes nothing" {
    _release 9.9.9 garbage
    _old_install

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ]
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ]
    [[ "$output" == *"is not a release file list"*"removing nothing"* ]] || fail "$output"
}

@test "32957 control: a file list for another version removes nothing" {
    _release 9.9.8 wrongversion
    _old_install

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ]
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ]
    [[ "$output" == *"file list is for '0.0.0-other'"*"removing nothing"* ]] || fail "$output"
}

@test "32957 control: an unreadable installed file list removes nothing" {
    _release 9.9.9 good
    _old_install
    # The once-per-version pass (no update: the installed version is the remote one).
    cp "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/release-files.txt" "$INSTALL_ROOT/release-files.txt"
    printf '{ "name": "mmry", "version": "9.9.9" }' > "$INSTALL_ROOT/.claude-plugin/plugin.json"
    chmod 000 "$INSTALL_ROOT/release-files.txt"
    if [[ -r "$INSTALL_ROOT/release-files.txt" ]]; then
        # Root, or Windows Git Bash, where a file cannot be made unreadable. An empty list is the
        # nearest thing: it has no header, so it cannot be read as a release file list.
        chmod 644 "$INSTALL_ROOT/release-files.txt"
        : > "$INSTALL_ROOT/release-files.txt"
    fi

    _run_update
    chmod 644 "$INSTALL_ROOT/release-files.txt" 2>/dev/null || true
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ]
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ]
    [[ "$output" == *"could not read the installed release's file list"*"removing nothing"* ]] || fail "$output"
    [ ! -e "$INSTALL_ROOT/.last-release-cleanup" ]
}

@test "32957: an install already on the release is cleaned once, from its own installed list" {
    # How an install that received this release from an OLDER self-update is cleaned: no download;
    # the list that came with the release decides.
    _release 9.9.9 good
    _old_install
    cp "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/release-files.txt" "$INSTALL_ROOT/release-files.txt"
    printf '{ "name": "mmry", "version": "9.9.9" }' > "$INSTALL_ROOT/.claude-plugin/plugin.json"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ ! -e "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
    [ ! -e "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "$output"
    [[ "$output" != *"MMRY AI plugin updated"* ]] || fail "$output"
    [[ "$(cat "$INSTALL_ROOT/.last-release-cleanup")" == "9.9.9" ]] || return 1
    # What the release lists is never removed, even when the install has no copy of a listed file.
    [ -f "$INSTALL_ROOT/hooks-handlers/self-update.sh" ]
    [ -f "$INSTALL_ROOT/hooks-handlers/lib-jq.sh" ]
    [ -f "$INSTALL_ROOT/hooks-handlers/lib-host.sh" ]
}

@test "32957: a checkout is never cleaned, even with a list that does not name its files" {
    _release 9.9.9 good
    local repo="$TEST_TMPDIR/checkout"
    mkdir -p "$repo/.git"
    _updatable_plugin "$repo/mmry"
    cp "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/release-files.txt" "$repo/mmry/release-files.txt"
    printf '{ "name": "mmry", "version": "9.9.9" }' > "$repo/mmry/.claude-plugin/plugin.json"
    printf 'work in progress\n' > "$repo/mmry/hooks-handlers/my-new-handler.sh"

    run bash "$repo/mmry/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$repo/mmry/hooks-handlers/my-new-handler.sh" ]
    [[ "$output" == *"git checkout; refusing"* ]] || fail "$output"
}

# THE UPDATE FROM 2.15.2 ITSELF. When 2.15.3 arrives every customer runs the OLD self-update.sh,
# which knows nothing of the list. bash reads a script as it runs it, so after the old script copies
# the new one over itself it reads on in the new file's text from byte 7345. The new file keeps
# comment-only lines there and its code in one brace group, so the old process runs the new code and
# finishes the update, removals included. This runs the real 2.15.2 script, byte for byte
# (tests/fixtures/self-update-2.15.2.sh, from d769a38).
@test "32957 plant: updating FROM the real 2.15.2 self-update removes the old scripts in the same run" {
    _release 9.9.9 good
    _old_install
    cp "$PLUGIN_ROOT/tests/fixtures/self-update-2.15.2.sh" "$INSTALL_ROOT/hooks-handlers/self-update.sh"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ ! -e "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
    [ ! -e "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "$output"
    [[ "$output" == *"MMRY AI plugin updated: 0.0.1 -> 9.9.9"* ]] || fail "$output"
    [[ "$output" != *"command not found"* ]] || fail "$output"
    [[ "$(cat "$INSTALL_ROOT/.last-self-update")" == "9.9.9" ]] || return 1
    [[ "$(cat "$STATE_DIR/.last-self-update")" == "9.9.9" ]] || return 1
    # The old script's temporary files were cleaned up.
    local leftovers
    leftovers="$(ls -A "$TMPDIR" | grep -E '^mmry-(update|prune)-' || true)"
    [[ -z "$leftovers" ]] || fail "left behind in TMPDIR: $leftovers"
}

@test "32957: every shipped self-update.sh resumes inside the comment-only landing pad" {
    # The byte at which each self-update.sh mmry has shipped resumes reading after copying a release
    # over itself (the end of its `cp ... || { ... }` block): 702898c 5100, b55c306 5236,
    # 9e33f1a 5918, 7a0c9df 6663, c4aca93 (= 2.15.2) 7345. Each must fall in a line of only '#'.
    local script="$PLUGIN_ROOT/hooks-handlers/self-update.sh"
    local fixture="$PLUGIN_ROOT/tests/fixtures/self-update-2.15.2.sh"
    local n e off before after line
    n="$(grep -n 'cp -r "${extracted_dir}/mmry/"\* "${PLUGIN_ROOT}/"' "$fixture" | head -1 | cut -d: -f1)"
    e="$(awk -v s="$n" 'NR>=s && /^}/ {print NR; exit}' "$fixture")"
    [[ "$(head -n "$e" "$fixture" | wc -c | tr -d ' ')" == "7345" ]] || fail "the 2.15.2 fixture no longer resumes at 7345"
    for off in 5100 5236 5918 6663 7345; do
        # The text of the line that holds byte $off (0-based): what precedes it on its line, and
        # what follows it to the end of the line.
        before="$(head -c "$off" "$script" | tail -n 1)"
        after="$(tail -c "+$((off + 1))" "$script" | head -n 1)"
        line="${before}${after}"
        [[ "$line" =~ ^#+$ ]] || fail "byte $off of self-update.sh is in the line '$line', not in the landing pad"
    done
    # The code is one brace group, and it ends in exit.
    [[ "$(tail -n 2 "$script")" == $'exit 0\n}' ]] || fail "self-update.sh does not end in 'exit 0' and '}'"
}
