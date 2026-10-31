# self-update-release.bash - a fabricated release and an old install for the self-update suites
# (#32957 fix round 4; moved here from self-update-cleanup.bats in #33033 round 10, unchanged, when
# that file reached the 64000-byte limit structural/test-file-size.bats sets for bats on Windows).
# Used by self-update-cleanup.bats and self-update-finish.bats. Each suite's setup puts
# $TEST_TMPDIR/mock-bin first on PATH and gives HOME and TMPDIR the test's own folders.

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
