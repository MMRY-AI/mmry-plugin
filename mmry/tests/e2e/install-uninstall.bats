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

@test "codex: uninstall removes the CODEX credential and leaves the Claude one alone" {
    # Spelled as ~/.claude/mmry-config.json, a Codex uninstall signed the customer out of the other
    # product and left the Codex credential exactly where it was.
    mkdir -p "$HOME/.codex"
    printf '%s' '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"codex-key"}'         > "$HOME/.codex/mmry-config.json"
    printf '%s' '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"claude-key"}'         > "$HOME/.claude/mmry-config.json"
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$HOME/.codex/mmry-config.json" ]]
    [[ -f "$HOME/.claude/mmry-config.json" ]]
}

@test "codex: uninstall does not touch Claude Code's settings.json either" {
    mkdir -p "$HOME/.codex"
    printf '%s' '{"autoMemoryEnabled": false, "otherSetting": true}' > "$HOME/.claude/settings.json"
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]]
    run jq '.autoMemoryEnabled' "$HOME/.claude/settings.json"
    assert_output "false"
}
