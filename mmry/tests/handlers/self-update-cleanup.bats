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
    cp "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh" "$root/hooks-handlers/"
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
       "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh" \
       "$rel/hooks-handlers/"
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
        unsafe|nocore)
            # A good list, plus an entry that climbs out of the plugin folder (unsafe), or without
            # the three core entries self-update trusts a list by (nocore) (#33033).
            {
                printf '# mmry release files %s\n' "$version"
                {
                    ( cd "$rel" && find . -type f | sed 's|^\./||' )
                    printf '%s\n' release-files.txt
                    [[ "$list" == "unsafe" ]] && printf '%s\n' '../x'
                } | LC_ALL=C sort -u \
                  | if [[ "$list" == "nocore" ]]; then
                        grep -Fvx -e release-files.txt -e hooks-handlers/self-update.sh -e .claude-plugin/plugin.json
                    else
                        cat
                    fi
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

@test "32957 control: a release without the removal library installs and removes nothing (#32957 fix round 4b)" {
    # The list reader and the removal step moved to lib-release-files.sh. A partial release without
    # it must still install, and must not remove anything.
    _release 9.9.9 good
    rm -f "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/hooks-handlers/lib-release-files.sh"
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
    _old_install
    rm -f "$INSTALL_ROOT/hooks-handlers/lib-release-files.sh"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "$output"
    [[ "$output" == *"removal code (lib-release-files.sh) could not be loaded; removing nothing"* ]] || fail "$output"
    [[ "$output" == *"MMRY AI plugin updated: 0.0.1 -> 9.9.9"* ]] || fail "$output"
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
    # 2.15.2 shipped no lib-release-files.sh; the release being installed brings it.
    rm -f "$INSTALL_ROOT/hooks-handlers/lib-release-files.sh"

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

# ── #33033: every refusal proven by a test that fails when the refusal is removed ──

@test "33033 refusal: a file list entry ../x is refused, nothing is removed, and the parent folder is untouched" {
    _release 9.9.9 unsafe
    _old_install
    # Beside the plugin root and beside the installed copy: what '../' would reach.
    printf 'mine\n' > "$TEST_TMPDIR/cache/planted.txt"
    printf 'mine\n' > "$HOME/.claude/planted.txt"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"names an unsafe or empty path: '../x'"*"removing nothing"* ]] || fail "the refusal was not said: $output"
    [[ "$output" != *"removed "* ]] || fail "something was removed: $output"
    [ -f "$TEST_TMPDIR/cache/planted.txt" ] || fail "the file beside the plugin root was removed: $output"
    [ -f "$HOME/.claude/planted.txt" ] || fail "the file beside the installed copy was removed: $output"
    # Nothing at all was removed, which is what a refused list means.
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "a refused list still removed save-record.sh: $output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "a refused list still removed save-record.sh: $output"
    [ ! -e "$INSTALL_ROOT/.last-release-cleanup" ] || fail "a refused list was recorded as done"
    # The update itself still went in.
    [[ "$output" == *"MMRY AI plugin updated: 0.0.1 -> 9.9.9"* ]] || fail "$output"
}

@test "33033 refusal: a file list without the core entries removes nothing" {
    _release 9.9.9 nocore
    _old_install

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"does not name the release's own core files"*"removing nothing"* ]] || fail "$output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "an untrusted list removed save-record.sh: $output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "an untrusted list removed save-record.sh: $output"
}

@test "33033 refusal: an installed list for another version is refused at the reconcile" {
    # No download: the installed version is the remote one, so only the once-per-version pass runs.
    _release 9.9.9 good
    _old_install
    sed '1s/.*/# mmry release files 9.9.8/' "$TEST_TMPDIR/remote/mmry-plugin-master/mmry/release-files.txt" \
        > "$INSTALL_ROOT/release-files.txt"
    printf '{ "name": "mmry", "version": "9.9.9" }' > "$INSTALL_ROOT/.claude-plugin/plugin.json"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"the installed file list is for '9.9.8' but plugin.json says '9.9.9'; removing nothing"* ]] || fail "$output"
    [[ "$output" != *"removed "* ]] || fail "$output"
    [[ "$output" != *"MMRY AI plugin updated"* ]] || fail "precondition: an update ran: $output"
    [ -f "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
    [ -f "$STATE_DIR/hooks-handlers/save-record.sh" ] || fail "$output"
    [ ! -e "$INSTALL_ROOT/.last-release-cleanup" ] || fail "a refused list was recorded as done"
}

@test "33033 fix: a name holding a line break is one name, and no fragment of it is removed" {
    _release 9.9.9 good
    _old_install
    local odd=$'hooks-handlers/stale\nmy-notes.txt'
    printf 'x\n' > "$INSTALL_ROOT/$odd" || fail "this file system cannot hold a line break in a name"
    [ -f "$INSTALL_ROOT/$odd" ] || fail "precondition: the name with a line break was not created"
    # The fragment after the line break, as a real unlisted file at the top of the install folder,
    # which the removal step must never touch.
    printf 'mine\n' > "$INSTALL_ROOT/my-notes.txt"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [ -f "$INSTALL_ROOT/my-notes.txt" ] || fail "a fragment of a name removed a top-level file: $output"
    [ ! -e "$INSTALL_ROOT/$odd" ] || fail "the unlisted file with a line break in its name survived: $output"
    # Printed once, on one line, with the line break shown rather than written.
    local line one=""
    while IFS= read -r line; do
        [[ "$line" == *"removed "*"hooks-handlers/stale"*"my-notes.txt"*" from $INSTALL_ROOT (not in release 9.9.9; its name holds a line break)"* ]] && one=1
    done <<< "$output"
    [[ -n "$one" ]] || fail "the removal was not printed as one name on one line: $output"
    # No fragment is reported as if it were a file of its own.
    while IFS= read -r line; do
        [[ "$line" != *"removed my-notes.txt"* ]] || fail "a fragment was reported removed: $output"
        [[ "$line" != *"removed hooks-handlers/stale from"* ]] || fail "a fragment was reported removed: $output"
    done <<< "$output"
    # And the ordinary removals still happen.
    [ ! -e "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
}

@test "33033 fix: a symbolic link in place of the installed folder is refused, and where it points is untouched" {
    _release 9.9.9 good
    _old_install
    local elsewhere="$TEST_TMPDIR/elsewhere"
    mkdir -p "$elsewhere/hooks-handlers"
    printf 'mine\n' > "$elsewhere/hooks-handlers/save-record.sh"
    rm -rf "$STATE_DIR"
    # Git Bash copies instead of linking unless asked for a native link; Linux and macOS ignore MSYS.
    MSYS=winsymlinks:nativestrict ln -s "$elsewhere" "$STATE_DIR"
    [ -L "$STATE_DIR" ] || fail "precondition: $STATE_DIR is not a symbolic link"

    _run_update
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"refusing to remove anything from '$STATE_DIR': it is a symbolic link"* ]] || fail "$output"
    [ -f "$elsewhere/hooks-handlers/save-record.sh" ] || fail "removed a file through the link: $output"
    # The real plugin root is still cleaned.
    [ ! -e "$INSTALL_ROOT/hooks-handlers/save-record.sh" ] || fail "$output"
}

@test "33033 fix: sourcing the library leaves the calling script's shell options as they were" {
    local probe="$TEST_TMPDIR/probe.sh"
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
# No strict mode here, on purpose: the library must not turn it on.
before="$- $(set -o | grep -E '^(errexit|nounset|pipefail)[[:space:]]' | tr -s ' \t' ' ' | tr '\n' ';') $(shopt -p | tr '\n' ';')"
log() { :; }
source "$1"
after="$- $(set -o | grep -E '^(errexit|nounset|pipefail)[[:space:]]' | tr -s ' \t' ' ' | tr '\n' ';') $(shopt -p | tr '\n' ';')"
if [[ "$before" != "$after" ]]; then
    printf 'CHANGED\nbefore: %s\nafter:  %s\n' "$before" "$after"
    exit 1
fi
# Still a script without strict mode: an unset variable and a failing command do not end it.
: "$this_is_unset"
false
printf 'UNCHANGED\n'
# And the library works there: a good list loads.
mkdir -p "$TMPDIR/lst"
printf '%s\n' '# mmry release files 1.0.0' release-files.txt hooks-handlers/self-update.sh \
    .claude-plugin/plugin.json > "$TMPDIR/lst/release-files.txt"
_su_load_list "$TMPDIR/lst/release-files.txt" "$TMPDIR/lst/out" && printf 'LOADED %s\n' "$_SU_LIST_VERSION"
PROBE
    run bash "$probe" "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh"
    [[ "$status" -eq 0 ]] || fail "status $status: $output"
    [[ "$output" == *"UNCHANGED"* ]] || fail "$output"
    [[ "$output" == *"LOADED 1.0.0"* ]] || fail "$output"
}

# The two refusals at the top of _su_prune, called directly (#33033 fix round 5). Both can be reached
# through self-update.sh (a plugin root that is HOME; an installed copy without hooks-handlers); a
# direct call names the target exactly, so these source the real library and call the real function
# with the targets the refusals exist for. HOME and TMPDIR are the suite's own; curl is a mock that
# records any call.
_prune_probe() {
    PRUNE_PROBE="$TEST_TMPDIR/prune-probe.sh"
    cat > "$PRUNE_PROBE" <<'PROBE'
#!/usr/bin/env bash
# $1 library, $2 the target handed to _su_prune.
log() { printf 'LOG: %s\n' "$1"; }
source "$1"
mkdir -p "$TMPDIR/lst"
printf '%s\n' '# mmry release files 9.9.9' release-files.txt hooks-handlers/self-update.sh \
    .claude-plugin/plugin.json commands/database.md > "$TMPDIR/lst/release-files.txt"
_su_load_list "$TMPDIR/lst/release-files.txt" "$TMPDIR/lst/out" || { printf 'LIST NOT LOADED\n'; exit 3; }
_su_prune "$TMPDIR/lst/out" "$2" 9.9.9
printf 'RC=%s\n' "$?"
PROBE
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\n" "$*" >> "%s"\n' "$TEST_TMPDIR/curl-called"
        printf 'exit 7\n'
    } > "$TEST_TMPDIR/mock-bin/curl"
    chmod +x "$TEST_TMPDIR/mock-bin/curl"
}

# Fails unless _su_prune refused target $1 with refusal text $2 and removed nothing, made no scratch
# folder, and reached for no download.
_assert_refused() {
    local target="$1" reason="$2"
    run env HOME="$HOME" TMPDIR="$TMPDIR" bash "$PRUNE_PROBE" "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh" "$target"
    [[ "$output" != *"LIST NOT LOADED"* ]] || fail "precondition: the probe's list did not load: $output"
    [[ "$output" == *"RC=1"* ]] || fail "target '$target' was not refused (expected return 1): $output"
    [[ "$output" == *"refusing to remove anything from '"*"': ${reason}"* ]] \
        || fail "target '$target' was not refused for the stated reason '${reason}': $output"
    [[ "$output" != *"removed "* ]] || fail "target '$target': something was removed: $output"
    [[ "$output" != *"nothing to remove from"* ]] || fail "target '$target' was searched for removals: $output"
    [[ -z "$(ls -A "$TMPDIR" | grep -E '^mmry-prune-' || true)" ]] || fail "target '$target': scratch space was made, so the refusal came too late"
    [ ! -e "$TEST_TMPDIR/curl-called" ] || fail "target '$target': a download was attempted: $(cat "$TEST_TMPDIR/curl-called")"
}

@test "33033 refusal O4: an empty target, '/', and HOME, with and without a trailing slash, are refused and nothing is removed" {
    _prune_probe
    # The suite's private HOME, never the machine's.
    [[ "$HOME" == "$TEST_TMPDIR"/* ]] || fail "precondition: HOME is not the test's own: $HOME"
    # HOME made to look like a plugin folder, so only this refusal stands between it and a prune:
    # an unlisted file in a shipped folder, which a prune of HOME would remove.
    mkdir -p "$HOME/hooks-handlers" "$HOME/commands"
    printf 'mine\n' > "$HOME/hooks-handlers/my-script.sh"
    printf 'mine\n' > "$HOME/commands/my-notes.md"

    local target
    for target in "" "/" "//" "$HOME" "$HOME/" "$HOME//"; do
        _assert_refused "$target" "not a plugin folder"
        [[ "$output" != *"it has no hooks-handlers folder"* ]] \
            || fail "target '$target' was refused by the later hooks-handlers check, not as an empty target, '/' or HOME: $output"
        [ -f "$HOME/hooks-handlers/my-script.sh" ] || fail "target '$target': a file in HOME/hooks-handlers was removed: $output"
        [ -f "$HOME/commands/my-notes.md" ] || fail "target '$target': a file in HOME/commands was removed: $output"
    done
}

@test "33033 refusal O5: a folder with no hooks-handlers folder is refused and nothing is removed" {
    _prune_probe
    # A folder with the release's other shipped folders but no hooks-handlers, holding unlisted files
    # a prune would remove.
    local bare="$TEST_TMPDIR/not-a-plugin"
    mkdir -p "$bare/commands"
    printf 'mine\n' > "$bare/commands/my-notes.md"
    # hooks-handlers present, but as a file rather than a folder.
    local filed="$TEST_TMPDIR/file-not-folder"
    mkdir -p "$filed/commands"
    printf 'not a folder\n' > "$filed/hooks-handlers"
    printf 'mine\n' > "$filed/commands/my-notes.md"
    # And a folder that is not there at all.
    local missing="$TEST_TMPDIR/no-such-folder"

    local target
    for target in "$bare" "$bare/" "$filed" "$missing"; do
        _assert_refused "$target" "it has no hooks-handlers folder, so it is not a plugin folder"
    done
    [ -f "$bare/commands/my-notes.md" ] || fail "a file in the folder without hooks-handlers was removed"
    [ -f "$filed/commands/my-notes.md" ] || fail "a file in the folder whose hooks-handlers is a file was removed"
    [ -f "$filed/hooks-handlers" ] || fail "the hooks-handlers file was removed"
    [ ! -e "$missing" ] || fail "the missing folder was created"
}

# ---------------------------------------------------------------------------------------------
# Each list refusal on its own, and the compare fail-closed refusal (#33033 fix round 6).
# A probe sources the real library, loads list $2 with _su_load_list and, only if it loads, prunes
# plugin folder $3 with _su_prune. The folder holds an unlisted file, hooks-handlers/stray-old.sh,
# which any prune that goes ahead removes. So with a refusal taken out, the file is removed and the
# refusal is not said. HOME and TMPDIR are the suite's own; nothing here touches a real install.
# ---------------------------------------------------------------------------------------------

# The complete, trusted list for the probe plugin.
PROBE_GOOD_ENTRIES=(release-files.txt hooks-handlers/self-update.sh .claude-plugin/plugin.json hooks-handlers/save-entry.sh)

_list_probe() {
    LIST_PROBE="$TEST_TMPDIR/list-probe.sh"
    cat > "$LIST_PROBE" <<'PROBE'
#!/usr/bin/env bash
# $1 library, $2 list, $3 plugin folder.
log() { printf 'LOG: %s\n' "$1"; }
source "$1"
if _su_load_list "$2" "$TMPDIR/probe-list.out"; then
    printf 'LIST LOADED %s\n' "$_SU_LIST_VERSION"
    _su_prune "$TMPDIR/probe-list.out" "$3" 9.9.9
    printf 'RC=%s\n' "$?"
else
    printf 'LIST REFUSED: %s\n' "$_SU_LIST_PROBLEM"
fi
PROBE
    PROBE_PLUGIN="$TEST_TMPDIR/probe-plugin"
    rm -rf "$PROBE_PLUGIN"
    mkdir -p "$PROBE_PLUGIN/hooks-handlers" "$PROBE_PLUGIN/.claude-plugin"
    printf 'listed\n' > "$PROBE_PLUGIN/hooks-handlers/self-update.sh"
    printf 'listed\n' > "$PROBE_PLUGIN/hooks-handlers/save-entry.sh"
    printf 'old\n' > "$PROBE_PLUGIN/hooks-handlers/stray-old.sh"
    printf '{}\n' > "$PROBE_PLUGIN/.claude-plugin/plugin.json"
    printf 'listed\n' > "$PROBE_PLUGIN/release-files.txt"
}

# Writes $TEST_TMPDIR/probe-list.txt: the header, then one line per argument.
_probe_list() {
    PROBE_LIST="$TEST_TMPDIR/probe-list.txt"
    { printf '# mmry release files 9.9.9\n'; printf '%s\n' "$@"; } > "$PROBE_LIST"
}

_run_list_probe() {
    run env HOME="$HOME" TMPDIR="$TMPDIR" PATH="${PROBE_PATH:-$PATH}" \
        bash "$LIST_PROBE" "$PLUGIN_ROOT/hooks-handlers/lib-release-files.sh" "$PROBE_LIST" "$PROBE_PLUGIN"
}

# Fails unless nothing in the probe plugin was removed.
_assert_probe_untouched() {
    [ -f "$PROBE_PLUGIN/hooks-handlers/stray-old.sh" ] || fail "the unlisted file was removed: $output"
    [ -f "$PROBE_PLUGIN/hooks-handlers/self-update.sh" ] || fail "a listed file was removed: $output"
    [ -f "$PROBE_PLUGIN/hooks-handlers/save-entry.sh" ] || fail "a listed file was removed: $output"
    [[ "$output" != *"removed "* ]] || fail "something was removed: $output"
}

# Runs the probe on the good list plus entry $1, and fails unless that list was refused as unsafe
# for that entry and nothing was removed.
_assert_unsafe_refused() {
    local entry="$1"
    _list_probe
    _probe_list "${PROBE_GOOD_ENTRIES[@]}" "$entry"
    _run_list_probe
    [[ "$output" == *"LIST REFUSED: "*"names an unsafe or empty path: '${entry}'"* ]] \
        || fail "the entry '${entry}' was not refused as unsafe: $output"
    [[ "$output" != *"LIST LOADED"* ]] || fail "a list naming '${entry}' was loaded: $output"
    _assert_probe_untouched
}

# Runs the probe on the good list without entry $1, and fails unless that list was refused as
# untrusted and nothing was removed.
_assert_core_refused() {
    local missing="$1" e entries=()
    for e in "${PROBE_GOOD_ENTRIES[@]}"; do [[ "$e" == "$missing" ]] || entries+=("$e"); done
    [[ "${#entries[@]}" -eq 3 ]] || fail "precondition: '$missing' is not one of the good entries"
    _list_probe
    _probe_list "${entries[@]}"
    _run_list_probe
    [[ "$output" == *"LIST REFUSED: "*"does not name the release's own core files"* ]] \
        || fail "a list without only '${missing}' was not refused as untrusted: $output"
    [[ "$output" != *"LIST LOADED"* ]] || fail "a list without '${missing}' was loaded: $output"
    _assert_probe_untouched
}

# The control the refusals below are measured against: the good list loads and the prune removes
# exactly the unlisted file. Without it, "nothing removed" could mean the probe never prunes.
@test "33033 control: the probe's good list loads and its prune removes only the unlisted file" {
    _list_probe
    _probe_list "${PROBE_GOOD_ENTRIES[@]}"
    _run_list_probe
    [[ "$output" == *"LIST LOADED 9.9.9"* ]] || fail "$output"
    [[ "$output" == *"RC=0"* ]] || fail "$output"
    [ ! -e "$PROBE_PLUGIN/hooks-handlers/stray-old.sh" ] || fail "the unlisted file survived a good prune: $output"
    [ -f "$PROBE_PLUGIN/hooks-handlers/self-update.sh" ] || fail "$output"
    [ -f "$PROBE_PLUGIN/hooks-handlers/save-entry.sh" ] || fail "$output"
}

# One list per unsafe pattern; each entry matches that pattern and no other alternative.
@test "33033 refusal unsafe '': an empty entry is refused and nothing is removed" {
    _assert_unsafe_refused ""
}
@test "33033 refusal unsafe '/*': an absolute entry is refused and nothing is removed" {
    _assert_unsafe_refused "/abs/x"
}
@test "33033 refusal unsafe backslash: an entry holding a backslash is refused and nothing is removed" {
    _assert_unsafe_refused 'hooks-handlers\x'
}
@test "33033 refusal unsafe '.': an entry '.' is refused and nothing is removed" {
    _assert_unsafe_refused "."
}
@test "33033 refusal unsafe '..': an entry '..' is refused and nothing is removed" {
    _assert_unsafe_refused ".."
}
@test "33033 refusal unsafe './*': an entry './x' is refused and nothing is removed" {
    _assert_unsafe_refused "./x"
}
@test "33033 refusal unsafe '../*': an entry '../x' is refused and nothing is removed" {
    _assert_unsafe_refused "../x"
}
@test "33033 refusal unsafe '*/./*': an entry 'a/./b' is refused and nothing is removed" {
    _assert_unsafe_refused "a/./b"
}
@test "33033 refusal unsafe '*/../*': an entry 'a/../b' is refused and nothing is removed" {
    _assert_unsafe_refused "a/../b"
}
@test "33033 refusal unsafe '*/.': an entry 'a/.' is refused and nothing is removed" {
    _assert_unsafe_refused "a/."
}
@test "33033 refusal unsafe '*/..': an entry 'a/..' is refused and nothing is removed" {
    _assert_unsafe_refused "a/.."
}
@test "33033 refusal unsafe '*//*': an entry 'a//b' is refused and nothing is removed" {
    _assert_unsafe_refused "a//b"
}

# One list per core entry, each missing only that entry.
@test "33033 refusal core: a list missing only release-files.txt is refused and nothing is removed" {
    _assert_core_refused release-files.txt
}
@test "33033 refusal core: a list missing only hooks-handlers/self-update.sh is refused and nothing is removed" {
    _assert_core_refused hooks-handlers/self-update.sh
}
@test "33033 refusal core: a list missing only .claude-plugin/plugin.json is refused and nothing is removed" {
    _assert_core_refused .claude-plugin/plugin.json
}

# The compare fail-closed refusal in _su_prune: a sort or comm that fails is never trusted. The mock
# lives in a folder put first on PATH for the probe alone.
_compare_mock_bin() {
    COMPARE_MOCK_BIN="$TEST_TMPDIR/compare-mock-bin"
    mkdir -p "$COMPARE_MOCK_BIN"
    PROBE_PATH="$COMPARE_MOCK_BIN:$PATH"
}

# Fails unless the prune refused at the compare, returned 1 and removed nothing.
_assert_compare_refused() {
    [[ "$output" == *"LIST LOADED 9.9.9"* ]] || fail "precondition: the good list did not load: $output"
    [[ "$output" == *"could not compare ${PROBE_PLUGIN} with the release's file list; removing nothing"* ]] \
        || fail "the failed compare was not refused: $output"
    [[ "$output" == *"RC=1"* ]] || fail "the failed compare did not return 1: $output"
    _assert_probe_untouched
}

@test "33033 refusal compare: a comm that fails, printing every file it was given, removes nothing" {
    _list_probe
    _probe_list "${PROBE_GOOD_ENTRIES[@]}"
    _compare_mock_bin
    # Called as: comm -23 FOUND LIST. Prints every found file, as comm on unsorted input might
    # report them, then fails.
    printf '#!/usr/bin/env bash\ncat "$2"\nexit 1\n' > "$COMPARE_MOCK_BIN/comm"
    chmod +x "$COMPARE_MOCK_BIN/comm"
    _run_list_probe
    _assert_compare_refused
}

@test "33033 refusal compare: a sort that fails on the found-file list removes nothing" {
    _list_probe
    _probe_list "${PROBE_GOOD_ENTRIES[@]}"
    _compare_mock_bin
    local real_sort
    real_sort="$(command -v sort)"
    # Fails only for the found-file list. Every other sort (the list itself, the shipped folders)
    # is the real one, so the list still loads.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for a in "$@"; do case "$a" in */found) exit 1 ;; esac; done\n'
        printf 'exec "%s" "$@"\n' "$real_sort"
    } > "$COMPARE_MOCK_BIN/sort"
    chmod +x "$COMPARE_MOCK_BIN/sort"
    _run_list_probe
    _assert_compare_refused
}
