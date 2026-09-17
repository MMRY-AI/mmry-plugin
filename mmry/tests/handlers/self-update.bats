#!/usr/bin/env bats
# self-update.bats — Test plugin auto-update local-version fallback chain (#29966).
#
# These tests verify the *version-detection* refactor that prevents silent bails on
# legacy installs (~/.claude/mmry/ without a .claude-plugin/ subdirectory).
#
# Strategy: substitute curl with a deterministic mock that fails on the remote
# fetch. If the script reaches the curl call, we see the "failed to fetch" message
# on stderr — that proves version detection did NOT silently bail at step 1.

load '../helpers/test-helper'

TEST_PLUGIN_DIR=""

setup() {
    TEST_PLUGIN_DIR="$TEST_TMPDIR/test-plugin/mmry"
    mkdir -p "$TEST_PLUGIN_DIR/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/self-update.sh" "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    chmod +x "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    # self-update now resolves jq via lib-jq.sh (#30624); ship it alongside and
    # point the resolver at the real vendored binaries (this isolated plugin has none).
    cp "$PLUGIN_ROOT/hooks-handlers/lib-jq.sh" "$TEST_PLUGIN_DIR/hooks-handlers/lib-jq.sh"
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"

    # Override curl with a mock that fails on marketplace.json fetches.
    # This forces the script to reach the curl call (proving version detection succeeded)
    # without actually downloading anything.
    local mock_dir="$TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/curl" <<'EOF'
#!/usr/bin/env bash
# Force-fail any curl call. The script's || branches treat this as "remote unreachable".
exit 22
EOF
    chmod +x "$mock_dir/curl"
    export PATH="$mock_dir:$PATH"

    # Isolate HOME so we do not touch the developer's real ~/.claude/mmry/
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"

    # Stamp the debounce marker file in the future so it does not pre-exist.
    rm -f "$TMPDIR/.mmry-update-checked"
}

@test "self-update: marketplace install (plugin.json present) reaches network fetch" {
    mkdir -p "$TEST_PLUGIN_DIR/.claude-plugin"
    cat > "$TEST_PLUGIN_DIR/.claude-plugin/plugin.json" <<'EOF'
{ "name": "mmry", "version": "1.2.11" }
EOF

    run bash "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    # Must reach the marketplace fetch (which our mock force-fails). Seeing this
    # message proves the version detection did NOT bail at step 1.
    [[ "$output" == *"failed to fetch marketplace.json"* ]]
    # Must NOT show the bootstrap message because plugin.json exists.
    [[ "$output" != *"no local version anchor"* ]]
}

@test "self-update: sentinel-only install (no plugin.json) reaches network fetch" {
    # Legacy install that has already been updated once and has a sentinel.
    echo "1.2.10" > "$TEST_PLUGIN_DIR/.last-self-update"

    run bash "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"failed to fetch marketplace.json"* ]]
    # Sentinel is the local-version source; not the bootstrap fallback.
    [[ "$output" != *"no local version anchor"* ]]
}

@test "self-update: fresh legacy install (neither plugin.json nor sentinel) bootstraps and reaches network" {
    # Empty plugin dir — the exact state of a manual pre-marketplace install on first run.
    # Without the fallback chain, the script silently bailed here. With the fix it
    # bootstraps to "0.0.0" and proceeds to the network fetch.
    run bash "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"no local version anchor found"* ]]
    [[ "$output" == *"failed to fetch marketplace.json"* ]]
}

@test "self-update: stderr messages replace the old silent-exit behavior" {
    # No plugin.json — would previously exit 0 with no output (silent bail).
    # Now produces a discoverable stderr line.
    run bash "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    # Output must include the "mmry self-update:" prefix from the log() function.
    [[ "$output" == *"mmry self-update:"* ]]
}

@test "self-update: debounce marker prevents repeated checks within 1 hour" {
    mkdir -p "$TEST_PLUGIN_DIR/.claude-plugin"
    cat > "$TEST_PLUGIN_DIR/.claude-plugin/plugin.json" <<'EOF'
{ "name": "mmry", "version": "1.2.11" }
EOF
    # Pre-stamp the marker file as fresh.
    touch "$TMPDIR/.mmry-update-checked"

    run bash "$TEST_PLUGIN_DIR/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    # Within the debounce window we should NOT reach the network fetch at all.
    [[ "$output" != *"failed to fetch marketplace.json"* ]]
}

# ---------------------------------------------------------------------------------------------
# WHICH INSTALLED COPY IT UPDATES (#31245 QA round 3)
#
# self-update.sh runs from session-start.sh on EVERY host, and the second destination it writes to
# was spelled ${HOME}/.claude/mmry outright. On a Codex session that reached across and overwrote
# the OTHER product's installed handlers mid-run, while the Codex copy was never updated at all -
# so a Codex customer would have stayed on whatever version they first installed, forever.
#
# These run the real copy path with a fabricated remote archive rather than asserting on the source
# text, because the defect was in what the script DID, not in what it said.
# ---------------------------------------------------------------------------------------------

# A plugin tree with the libraries the resolver needs, and a version behind the "remote" one.
_updatable_plugin() {
    local root="$1"
    mkdir -p "$root/hooks-handlers" "$root/.claude-plugin"
    cp "$PLUGIN_ROOT/hooks-handlers/self-update.sh" "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-jq.sh" "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$root/hooks-handlers/"
    printf '%s' '{ "name": "mmry", "version": "0.0.1" }' > "$root/.claude-plugin/plugin.json"
}

# curl that answers the marketplace with a newer version and hands back a real archive.
_mock_remote() {
    local stage="$TEST_TMPDIR/remote/mmry-plugin-master/mmry/hooks-handlers"
    mkdir -p "$stage"
    printf 'delivered by the update\n' > "$stage/updated-marker.txt"
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
    cat > "$TEST_TMPDIR/mock-bin/curl" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for arg in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$arg"; prev="\$arg"; done
if [[ -n "\$out" ]]; then cp "$TEST_TMPDIR/remote.tar.gz" "\$out"; exit 0; fi
printf '%s' '{"plugins":[{"name":"mmry","version":"9.9.9"}]}'
EOF
    chmod +x "$TEST_TMPDIR/mock-bin/curl"
}

@test "codex: self-update writes into the CODEX state directory, not the Claude one" {
    _mock_remote
    mkdir -p "$HOME/.codex/mmry/hooks-handlers" "$HOME/.claude/mmry/hooks-handlers"
    local root="$TEST_TMPDIR/codex-cache/mmry"
    _updatable_plugin "$root"

    run env MMRY_HOST=codex HOME="$HOME" bash "$root/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    [ -f "$HOME/.codex/mmry/hooks-handlers/updated-marker.txt" ]
    [ ! -f "$HOME/.claude/mmry/hooks-handlers/updated-marker.txt" ]
}

@test "req4: on Claude Code self-update still writes into ~/.claude/mmry, as it always did" {
    _mock_remote
    mkdir -p "$HOME/.codex/mmry/hooks-handlers" "$HOME/.claude/mmry/hooks-handlers"
    local root="$TEST_TMPDIR/claude-cache/mmry"
    _updatable_plugin "$root"

    run env -u MMRY_HOST -u CODEX_HOME HOME="$HOME" bash "$root/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    [ -f "$HOME/.claude/mmry/hooks-handlers/updated-marker.txt" ]
    [ ! -f "$HOME/.codex/mmry/hooks-handlers/updated-marker.txt" ]
}

@test "codex: an unconfigured Codex install still gets its update check, it does not die silently" {
    # lib-jq.sh refuses when a Codex install has no credential of its own. An update check needs no
    # credential - it reads a public file - and before the opt-out it exited 1 saying nothing,
    # which is how a Codex install would have stopped receiving updates entirely.
    _mock_remote
    mkdir -p "$HOME/.codex/mmry/hooks-handlers"
    [ ! -f "$HOME/.codex/mmry-config.json" ]
    local root="$TEST_TMPDIR/nocred/mmry"
    _updatable_plugin "$root"

    run env -u MMRY_CONFIG_FILE -u MMRY_API_KEY MMRY_HOST=codex HOME="$HOME" \
        bash "$root/hooks-handlers/self-update.sh"
    [[ "$status" -eq 0 ]]
    [ -f "$HOME/.codex/mmry/hooks-handlers/updated-marker.txt" ]
}
