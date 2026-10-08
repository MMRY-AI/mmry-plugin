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

@test "hooks.json: no hook command carries a cmd.exe operator outside double quotes" {
    # This test used to forbid single quotes outright (c4fba61, February 2026). Its reason was that
    # Claude Code then ran hook commands through cmd.exe on Windows, and cmd split a line like
    # bash -c '[ -f x ] && y' at the && before bash ever saw it. What broke those lines was the
    # operator cmd acted on, never the quote character itself.
    #
    # The formation membership gate (#31746) needs single quotes: it is an `sh -c '...'` whose
    # $f must reach sh unexpanded, and a double-quoted form would hand $f to the host's shell. So the
    # rule is now the property the old one stood for: nothing cmd.exe acts on (& | < > ^) may sit
    # outside a double-quoted span. Current Claude Code runs hooks with Git Bash, where this does
    # not matter; it is kept so an older Windows client still runs every line in one piece.
    local hooks_file="$PLUGIN_ROOT/hooks/hooks.json" bad
    bad="$(node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const out = [];
        for (const gs of Object.values(d.hooks)) for (const g of gs) for (const h of g.hooks) {
            const bare = h.command.replace(/"[^"]*"/g, "");
            if (/[&|<>^]/.test(bare)) out.push(h.command);
        }
        console.log(out.join("\n"));
    ' "$hooks_file")"
    [[ -z "$bad" ]] || { echo "cmd.exe would split these:"; echo "$bad"; return 1; }
    # CONTROL: the check finds the shape c4fba61 removed, so a pass above is not a check that
    # cannot fail.
    local probe="${BATS_TEST_TMPDIR}/probe-hooks.json"
    printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash -c '"'"'[ -f x ] && y'"'"'"}]}]}}' > "$probe"
    bad="$(node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const gs of Object.values(d.hooks)) for (const g of gs) for (const h of g.hooks)
            if (/[&|<>^]/.test(h.command.replace(/"[^"]*"/g, ""))) console.log(h.command);
    ' "$probe")"
    [[ -n "$bad" ]] || { echo "control: the old single-quoted && shape was not caught"; return 1; }
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
