#!/usr/bin/env bats
# cross-platform.bats — Verify cross-platform compatibility safeguards.

load '../helpers/test-helper'

# ── install.bat (Windows CMD wrapper) ──

@test "install.bat exists" {
    [[ -f "$PLUGIN_ROOT/setup/install.bat" ]]
}

@test "install.bat delegates to install.ps1" {
    grep -q 'install.ps1' "$PLUGIN_ROOT/setup/install.bat"
}

# ── install.ps1 (Windows PowerShell) ──

@test "install.ps1 exists" {
    [[ -f "$PLUGIN_ROOT/setup/install.ps1" ]]
}

@test "install.ps1 checks for bash in PATH" {
    grep -q 'Get-Command bash' "$PLUGIN_ROOT/setup/install.ps1"
}

@test "install.ps1 uses git --exec-path to locate Git bash" {
    grep -q 'git --exec-path' "$PLUGIN_ROOT/setup/install.ps1"
}

@test "install.ps1 checks common Git install paths as fallback" {
    grep -q 'Program Files\\Git\\bin\\bash.exe' "$PLUGIN_ROOT/setup/install.ps1"
}

@test "install.ps1 adds Git bin to user PATH when bash not found" {
    grep -q 'SetEnvironmentVariable' "$PLUGIN_ROOT/setup/install.ps1"
}

@test "install.ps1 aborts with error if bash not found anywhere" {
    grep -q 'bash.exe not found' "$PLUGIN_ROOT/setup/install.ps1"
}

# ── install.sh (macOS/Linux) ──

@test "install.sh exists" {
    [[ -f "$PLUGIN_ROOT/setup/install.sh" ]]
}

@test "install.sh guarantees jq via the resolver" {
    grep -q 'lib-jq.sh' "$PLUGIN_ROOT/setup/install.sh"
    grep -q 'mmry_resolve_jq' "$PLUGIN_ROOT/setup/install.sh"
}

@test "install.sh warns about bash version below 4" {
    grep -q 'BASH_VERSINFO' "$PLUGIN_ROOT/setup/install.sh"
}

# ── mmry-setup.sh platform dispatch ──

@test "mmry-setup.sh dispatches to install.ps1 on Windows (MINGW/MSYS/CYGWIN)" {
    grep -q 'MINGW\|MSYS\|CYGWIN' "$PLUGIN_ROOT/setup/mmry-setup.sh"
    grep -q 'install.ps1' "$PLUGIN_ROOT/setup/mmry-setup.sh"
}

@test "mmry-setup.sh dispatches to install.sh on non-Windows" {
    grep -q 'install.sh' "$PLUGIN_ROOT/setup/mmry-setup.sh"
}

@test "mmry-setup.sh uses uname -s for platform detection" {
    grep -q 'uname -s' "$PLUGIN_ROOT/setup/mmry-setup.sh"
}

# ── hooks.json Windows compatibility ──

@test "hooks.json SessionStart uses CLAUDE_PLUGIN_ROOT (no bash -c)" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    local session_cmd
    session_cmd="$(grep -A10 '"SessionStart"' "$hooks_file" | grep '"command"')"
    ! echo "$session_cmd" | grep -q 'bash -c'
    [[ "$session_cmd" == *'CLAUDE_PLUGIN_ROOT'* ]]
}

@test "hooks.json guard-based hooks use existence check pattern" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    # Stop, PreCompact, PostToolUse use bash -c with guard pattern:
    #   bash -c "[ -f ... ] && bash ... || true"
    # This is intentional — these hooks must be resilient when the stable copy isn't installed yet
    for hook in Stop PreCompact PostToolUse; do
        local cmd
        cmd="$(grep -A10 "\"$hook\"" "$hooks_file" | grep '"command"')"
        [[ "$cmd" == *'bash -c'* ]]
        [[ "$cmd" == *'hook-guard.sh'* ]]
        [[ "$cmd" == *'|| true'* ]]
    done
}

@test "hooks.json contains no single quotes in hook commands" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    # Extract only command lines and check for single quotes
    local commands
    commands="$(grep '"command"' "$hooks_file")"
    ! echo "$commands" | grep -q "'"
}

@test "SessionStart hook uses CLAUDE_PLUGIN_ROOT variable" {
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"
    local session_cmd
    session_cmd="$(grep -A10 '"SessionStart"' "$hooks_file" | grep '"command"')"
    [[ "$session_cmd" == *'CLAUDE_PLUGIN_ROOT'* ]]
}

# ── session-init.sh syncs all platforms ──

@test "session-init.sh copies .bat setup files for Windows" {
    grep -q 'setup/\*\.bat' "$PLUGIN_ROOT/hooks-handlers/session-init.sh"
}

@test "session-init.sh copies .ps1 setup files for Windows" {
    grep -q 'setup/\*\.ps1' "$PLUGIN_ROOT/hooks-handlers/session-init.sh"
}

@test "session-init.sh copies .sh setup files" {
    grep -q 'setup/\*\.sh' "$PLUGIN_ROOT/hooks-handlers/session-init.sh"
}

# ── mmry-client.sh portability ──

@test "mmry-client.sh uses portable shebang (env bash)" {
    local first_line
    first_line="$(head -1 "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh")"
    [[ "$first_line" == "#!/usr/bin/env bash" ]]
}

@test "mmry-client.sh error messages reference slash commands not file paths" {
    # No error message should tell users to run 'bash /path/to/script.sh'
    ! grep -q 'Run setup: bash' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}
