#!/usr/bin/env bats
# install-uninstall.bats — Tests for install.sh and uninstall.sh settings.json changes.

load '../helpers/test-helper'

INSTALL_SCRIPT=""
UNINSTALL_SCRIPT=""

setup() {
    # Isolate HOME so scripts don't touch real config
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude"

    INSTALL_SCRIPT="$PLUGIN_ROOT/setup/install.sh"
    UNINSTALL_SCRIPT="$PLUGIN_ROOT/setup/uninstall.sh"
}

# ══════════════════════════════════════════════
# install.sh — autoMemoryEnabled
# ══════════════════════════════════════════════

@test "install: sets autoMemoryEnabled to false on fresh install" {
    run bash "$INSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]

    local settings="$HOME/.claude/settings.json"
    [[ -f "$settings" ]]
    run jq '.autoMemoryEnabled' "$settings"
    assert_output "false"
}

@test "install: sets autoMemoryEnabled to false when previously true" {
    echo '{"autoMemoryEnabled": true}' > "$HOME/.claude/settings.json"

    run bash "$INSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]

    run jq '.autoMemoryEnabled' "$HOME/.claude/settings.json"
    assert_output "false"
}

@test "install: preserves existing settings when adding autoMemoryEnabled" {
    echo '{"someOtherSetting": "keep-me"}' > "$HOME/.claude/settings.json"

    run bash "$INSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]

    run jq '.someOtherSetting' "$HOME/.claude/settings.json"
    assert_output '"keep-me"'

    run jq '.autoMemoryEnabled' "$HOME/.claude/settings.json"
    assert_output "false"
}

# ══════════════════════════════════════════════
# uninstall.sh — autoMemoryEnabled cleanup
# ══════════════════════════════════════════════

@test "uninstall: removes autoMemoryEnabled from settings.json" {
    echo '{"autoMemoryEnabled": false, "otherSetting": true}' > "$HOME/.claude/settings.json"

    run bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]

    run jq 'has("autoMemoryEnabled")' "$HOME/.claude/settings.json"
    assert_output "false"

    run jq '.otherSetting' "$HOME/.claude/settings.json"
    assert_output "true"
}

@test "uninstall: succeeds when autoMemoryEnabled is not present" {
    echo '{"otherSetting": true}' > "$HOME/.claude/settings.json"

    run bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]

    run jq 'has("autoMemoryEnabled")' "$HOME/.claude/settings.json"
    assert_output "false"
}

# ══════════════════════════════════════════════
# uninstall.sh — WHOSE credential it removes (#31245 QA round 2)
# ══════════════════════════════════════════════

@test "req4: uninstall removes the Claude credential on a Claude install, as it always did" {
    printf '%s' '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"claude-key"}'         > "$HOME/.claude/mmry-config.json"
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$HOME/.claude/mmry-config.json" ]]
}

# ---------------------------------------------------------------------------------------------
# THE CODEX COPY REFUSES, AND THE CLAUDE INSTALLATION SURVIVES IT INTACT (#31245 QA round 3)
#
# session-init.sh copies setup/*.sh into the host state directory, so this script sits at
# ${CODEX_HOME:-~/.codex}/mmry/setup/uninstall.sh on every Codex install. Round 2 made only Steps 1
# and 2 host-aware; Steps 3, 4 and the closing message still named ~/.claude, so running the Codex
# copy DELETED ~/.claude/mmry/, cleared the Claude plugin cache, left the Codex install untouched
# and told the customer to restart the wrong product. Reproduced in an isolated home on 2026-09-16.
#
# Nothing asserted that the OTHER product's directories survive, which is exactly why it shipped.
# These tests assert the survival, not just the refusal: a future edit that re-introduces a partial
# uninstall fails here even if it still prints a refusal.
# ---------------------------------------------------------------------------------------------

# Build a home with BOTH products fully present. Returns nothing; sets the paths as globals.
_both_products_installed() {
    mkdir -p "$HOME/.claude/mmry/hooks-handlers"              "$HOME/.claude/plugins/cache/mmry-plugin/mmry"              "$HOME/.claude/plugins/cache/internal-plugins/mmry"              "$HOME/.codex/mmry/setup"
    printf '%s' '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"codex-key"}'         > "$HOME/.codex/mmry-config.json"
    printf '%s' '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"claude-key"}'         > "$HOME/.claude/mmry-config.json"
    printf '%s' '{"autoMemoryEnabled": false, "otherSetting": true}' > "$HOME/.claude/settings.json"
    echo "claude handler" > "$HOME/.claude/mmry/hooks-handlers/save-memory.sh"
    echo "cached" > "$HOME/.claude/plugins/cache/mmry-plugin/mmry/plugin.json"
}

# Every file the Claude Code installation consists of, still there, byte for byte where it matters.
_assert_claude_installation_intact() {
    [[ -f "$HOME/.claude/mmry-config.json" ]]        || { echo "the Claude credential was removed"; return 1; }
    [[ -d "$HOME/.claude/mmry" ]]                    || { echo "~/.claude/mmry/ was removed"; return 1; }
    [[ -f "$HOME/.claude/mmry/hooks-handlers/save-memory.sh" ]]         || { echo "the Claude handlers were removed"; return 1; }
    [[ -d "$HOME/.claude/plugins/cache/mmry-plugin/mmry" ]]         || { echo "the Claude plugin cache was cleared"; return 1; }
    run jq '.autoMemoryEnabled' "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]] || { echo "Claude settings.json was edited"; return 1; }
}

@test "codex: the Codex copy of uninstall.sh REFUSES, exits 1, and removes nothing at all" {
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"uninstalls the CLAUDE CODE installation"* ]]
    [[ "$output" == *"changed nothing"* ]]
    # And the Codex side is untouched too - a refusal that deleted the Codex credential on the way
    # out would still be a half-uninstall, just of the other product.
    [[ -f "$HOME/.codex/mmry-config.json" ]]
}

@test "codex: the Claude Code STATE DIRECTORY survives a Codex uninstall" {
    # The specific destruction reported in QA round 2: rm -rf "${HOME}/.claude/mmry" ran
    # unconditionally, forty lines below a host-aware Step 1.
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ -d "$HOME/.claude/mmry" ]]
    [[ -f "$HOME/.claude/mmry/hooks-handlers/save-memory.sh" ]]
}

@test "codex: the Claude Code PLUGIN CACHE survives a Codex uninstall" {
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ -d "$HOME/.claude/plugins/cache/mmry-plugin/mmry" ]]
    [[ -f "$HOME/.claude/plugins/cache/mmry-plugin/mmry/plugin.json" ]]
}

@test "codex: the whole Claude Code installation survives, asserted as one thing" {
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    _assert_claude_installation_intact
}

@test "codex: the refusal tells the customer where the Codex install actually is" {
    # A refusal that leaves the customer with no way to finish the job is a dead end. The path is
    # the RELOCATED one when CODEX_HOME is set, because that is where their files are.
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$HOME/moved-codex" HOME="$HOME"         bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"$HOME/moved-codex/mmry-config.json"* ]]
    [[ "$output" == *"$HOME/moved-codex/mmry"* ]]
}

@test "codex: the refusal fires on LOCATION too, with no MMRY_HOST declared at all" {
    # This is how it is really run: the customer (or the model) types the path to the copy in their
    # Codex home, in a shell where MMRY_HOST was never set. Detection has to come off the install.
    _both_products_installed
    mkdir -p "$HOME/.codex/mmry/hooks-handlers" "$HOME/.codex/mmry/setup"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$HOME/.codex/mmry/hooks-handlers/"
    cp "$PLUGIN_ROOT/setup/uninstall.sh" "$HOME/.codex/mmry/setup/"
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$HOME"         bash "$HOME/.codex/mmry/setup/uninstall.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"changed nothing"* ]]
    _assert_claude_installation_intact
}

# ---------------------------------------------------------------------------------------------
# THE CONTROL, IN BOTH DIRECTIONS. Without these the refusals above are satisfied by a script that
# refuses under every condition and by one that never touches anything.
# ---------------------------------------------------------------------------------------------

@test "req4: a CLAUDE uninstall still removes the Claude state directory and plugin cache" {
    _both_products_installed
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$HOME/.claude/mmry-config.json" ]]
    [[ ! -d "$HOME/.claude/mmry" ]]
    [[ ! -d "$HOME/.claude/plugins/cache/mmry-plugin/mmry" ]]
    [[ "$output" == *"Restart Claude Code"* ]]
}

@test "req4: and a Claude uninstall leaves the CODEX installation alone" {
    _both_products_installed
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$HOME/.codex/mmry-config.json" ]]
    [[ -d "$HOME/.codex/mmry" ]]
}
