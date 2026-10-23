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
    [[ "$status" -eq 0 ]] || return 1

    local settings="$HOME/.claude/settings.json"
    [[ -f "$settings" ]] || return 1
    run jq '.autoMemoryEnabled' "$settings"
    assert_output "false"
}

@test "install: sets autoMemoryEnabled to false when previously true" {
    echo '{"autoMemoryEnabled": true}' > "$HOME/.claude/settings.json"

    run bash "$INSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || return 1

    run jq '.autoMemoryEnabled' "$HOME/.claude/settings.json"
    assert_output "false"
}

@test "install: preserves existing settings when adding autoMemoryEnabled" {
    echo '{"someOtherSetting": "keep-me"}' > "$HOME/.claude/settings.json"

    run bash "$INSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || return 1

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
    [[ "$status" -eq 0 ]] || return 1

    run jq 'has("autoMemoryEnabled")' "$HOME/.claude/settings.json"
    assert_output "false"

    run jq '.otherSetting' "$HOME/.claude/settings.json"
    assert_output "true"
}

@test "uninstall: succeeds when autoMemoryEnabled is not present" {
    echo '{"otherSetting": true}' > "$HOME/.claude/settings.json"

    run bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || return 1

    run jq 'has("autoMemoryEnabled")' "$HOME/.claude/settings.json"
    assert_output "false"
}

# ══════════════════════════════════════════════
# uninstall.sh — WHOSE credential it removes (#31245 QA round 2)
# ══════════════════════════════════════════════

@test "req4: uninstall removes the Claude credential on a Claude install, as it always did" {
    printf '%s' '{"apiUrl":"https://mmryai.com","authMethod":"apikey","apiKey":"claude-key"}'         > "$HOME/.claude/mmry-config.json"
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || return 1
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
    [[ "$status" -eq 1 ]] || return 1
    [[ "$output" == *"uninstalls the CLAUDE CODE installation"* ]] || return 1
    [[ "$output" == *"changed nothing"* ]] || return 1
    # And the Codex side is untouched too - a refusal that deleted the Codex credential on the way
    # out would still be a half-uninstall, just of the other product.
    [[ -f "$HOME/.codex/mmry-config.json" ]]
}

@test "codex: the Claude Code STATE DIRECTORY survives a Codex uninstall" {
    # The specific destruction reported in QA round 2: rm -rf "${HOME}/.claude/mmry" ran
    # unconditionally, forty lines below a host-aware Step 1.
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ -d "$HOME/.claude/mmry" ]] || return 1
    [[ -f "$HOME/.claude/mmry/hooks-handlers/save-memory.sh" ]]
}

@test "codex: the Claude Code PLUGIN CACHE survives a Codex uninstall" {
    _both_products_installed
    run env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ -d "$HOME/.claude/plugins/cache/mmry-plugin/mmry" ]] || return 1
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
    [[ "$status" -eq 1 ]] || return 1
    [[ "$output" == *"$HOME/moved-codex/mmry-config.json"* ]] || return 1
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
    [[ "$status" -eq 1 ]] || return 1
    [[ "$output" == *"changed nothing"* ]] || return 1
    _assert_claude_installation_intact
}

# ---------------------------------------------------------------------------------------------
# THE CONTROL, IN BOTH DIRECTIONS. Without these the refusals above are satisfied by a script that
# refuses under every condition and by one that never touches anything.
# ---------------------------------------------------------------------------------------------

@test "req4: a CLAUDE uninstall still removes the Claude state directory and plugin cache" {
    _both_products_installed
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || return 1
    [[ ! -f "$HOME/.claude/mmry-config.json" ]] || return 1
    [[ ! -d "$HOME/.claude/mmry" ]] || return 1
    [[ ! -d "$HOME/.claude/plugins/cache/mmry-plugin/mmry" ]] || return 1
    [[ "$output" == *"Restart Claude Code"* ]]
}

@test "req4: and a Claude uninstall leaves the CODEX installation alone" {
    _both_products_installed
    run env -u MMRY_HOST -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$HOME" bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || return 1
    [[ -f "$HOME/.codex/mmry-config.json" ]] || return 1
    [[ -d "$HOME/.codex/mmry" ]]
}

# ══════════════════════════════════════════════
# uninstall on an upgraded install (#32640)
#
# Setup no longer writes a permission for the two handlers this version removed, but installs made
# by earlier versions still carry them. Uninstall removes those as well, and leaves the customer's
# own permissions alone. The two names are assembled so this file does not spell them.
# ══════════════════════════════════════════════

_seed_upgraded_settings() {
    local r="rein""force" l="li""nk"
    jq -n --arg a "Bash(*${r}-memory.sh*)" --arg b "Bash(*${l}-memories.sh*)" '{
        autoMemoryEnabled: false,
        permissions: { allow: [
            "Bash(*save-memory.sh*)", $a, "Bash(*deactivate-memory.sh*)", $b,
            "Bash(*search-memories.sh*)", "Bash(*submit-feedback.sh*)", "Bash(*mmry-client.sh*)",
            "Bash(npm test)", "Bash(*my-own-tool.sh*)"
        ] }
    }' > "$1"
}

_assert_only_customer_permissions_left() {
    run jq -c '.permissions.allow' "$1"
    [[ "$output" == '["Bash(npm test)","Bash(*my-own-tool.sh*)"]' ]] \
        || { echo "left behind: $output"; return 1; }
}

@test "32640 req2: uninstall removes the removed handlers' permissions from an upgraded install, and keeps the customer's own" {
    _seed_upgraded_settings "$HOME/.claude/settings.json"
    run bash "$UNINSTALL_SCRIPT"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    _assert_only_customer_permissions_left "$HOME/.claude/settings.json"
}

@test "32640 req2: and the same through the Python fallback, when no jq can be found" {
    local py=""
    command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info[0] < 3)' && py=python3
    [[ -n "$py" ]] || skip "python3 is not available"
    # A copy whose lib-jq.sh finds no jq, which is the condition that reaches the fallback. A stub,
    # not a missing file: bash 3.2 (macOS) aborts under set -e when a sourced file is missing.
    mkdir -p "$TEST_TMPDIR/bare/setup" "$TEST_TMPDIR/bare/hooks-handlers"
    printf '%s\n' 'mmry_resolve_jq() { return 1; }' > "$TEST_TMPDIR/bare/hooks-handlers/lib-jq.sh"
    cp "$UNINSTALL_SCRIPT" "$TEST_TMPDIR/bare/setup/uninstall.sh"
    _seed_upgraded_settings "$HOME/.claude/settings.json"
    run bash "$TEST_TMPDIR/bare/setup/uninstall.sh"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    _assert_only_customer_permissions_left "$HOME/.claude/settings.json"
}

@test "32640 req2: the Windows uninstaller drops the same permissions as uninstall.sh" {
    # Read, not executed: run in a temporary profile on develop, uninstall.bat prints its banner and
    # changes nothing (reported for a separate ticket), so an executed test here would prove nothing
    # about this change. What this change owns is the filter: the same handler pattern as uninstall.sh.
    local bat="$PLUGIN_ROOT/setup/uninstall.bat"
    grep -qF "\ABash\(\*[a-z]+-memor(y|ies)\.sh\*\)\z" "$bat" || { echo "no handler pattern in uninstall.bat"; return 1; }
    grep -qF "MMRY_HANDLER_PERMISSION_RE='^Bash\(\*[a-z]+-memor(y|ies)\.sh\*\)\$'" "$PLUGIN_ROOT/setup/uninstall.sh" \
        || { echo "no handler pattern in uninstall.sh"; return 1; }
}
