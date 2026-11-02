#!/usr/bin/env bats
# storage-wording-check.bats - the release check that keeps the storage technology out of what
# customers and assistants read in the plugin (#32944, MMRY feedback #43: the installed plugin
# described MMRY as a "SQL-backed" memory system).
#
# What these tests prove:
#   1. The check passes the real repository and says how many files it read.
#   2. "SQL-backed" planted into a copy of each kind of scanned file is refused (exit 1) and the
#      refusal names the file and line; the copy passes again once the plant is removed.
#   3. The other refused terms are refused, "AI database" is not, and a script's comment is not read.
#   4. A root with nothing to read is a failed read (exit 2), never a pass.
#   5. Every manifest description is non-empty and within a length limit (requirement 2).
#   6. CI runs the check.

load '../helpers/test-helper'

REPO_ROOT=""
CHECK=""
COPY=""

# The copy is built once per file (a full copy per test is slow on Windows); each test restores the
# files the previous test planted into, so every test starts from the clean copy.
setup_file() {
    local base="$BATS_FILE_TMPDIR/base"
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    mkdir -p "$base/mmry" "$base/docs" "$base/.claude-plugin"
    cp -R "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/skills-codex" "$PLUGIN_ROOT/commands"           "$PLUGIN_ROOT/commands-codex" "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/.claude-plugin"           "$PLUGIN_ROOT/.codex-plugin" "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/setup"           "$PLUGIN_ROOT/mcp" "$base/mmry/"
    cp "$PLUGIN_ROOT/README.md" "$PLUGIN_ROOT/codex-mcp.json" "$base/mmry/"
    cp "$REPO_ROOT/README.md" "$base/README.md"
    cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$base/.claude-plugin/"
    cp "$REPO_ROOT"/docs/*.md "$base/docs/"
    cp -R "$base" "$BATS_FILE_TMPDIR/work"
    : > "$BATS_FILE_TMPDIR/dirty"
}

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    CHECK="$REPO_ROOT/scripts/check-storage-wording.sh"
    COPY="$BATS_FILE_TMPDIR/work"
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && cp "$BATS_FILE_TMPDIR/base/$f" "$COPY/$f"
    done < "$BATS_FILE_TMPDIR/dirty"
    : > "$BATS_FILE_TMPDIR/dirty"
}

# Appends a line to a copied file and echoes the line number it landed on.
_plant() { printf '%s
' "$1" >> "$BATS_FILE_TMPDIR/dirty"; printf '%s
' "$2" >> "$COPY/$1"; wc -l < "$COPY/$1" | tr -d '[:space:]'; }
# Removes the last line of a copied file again (portable: no sed -i).
_unplant() { local f="$COPY/$1" n; n="$(wc -l < "$f" | tr -d '[:space:]')"; head -n "$((n - 1))" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

_refuses_then_passes() {
    local rel="$1" text="$2" line
    line="$(_plant "$rel" "$text")"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 1 ]] || { echo "check did not refuse: $text"; echo "$output"; return 1; }
    [[ "$output" == *"${rel}:${line}:"* ]] || { echo "refusal does not name ${rel}:${line}"; echo "$output"; return 1; }
    _unplant "$rel"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "clean copy refused after removing: $text"; echo "$output"; return 1; }
}

@test "the real repository passes and the check says how many files it read" {
    run bash "$CHECK"
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ ^OK:\ ([0-9]+)\ file\(s\)\ read ]]
    [[ "${BASH_REMATCH[1]}" -ge 50 ]]
}

@test "SQL-backed planted in the Claude Code manifest is refused" {
    _refuses_then_passes "mmry/.claude-plugin/plugin.json" '"description": "MMRY AI, a SQL-backed memory system."'
}
@test "SQL-backed planted in the Codex manifest is refused" {
    _refuses_then_passes "mmry/.codex-plugin/plugin.json" '"shortDescription": "SQL-backed memory."'
}
@test "SQL-backed planted in the marketplace listing is refused" {
    _refuses_then_passes ".claude-plugin/marketplace.json" '"description": "Persistent SQL-backed memory."'
}
@test "SQL-backed planted in the Codex MCP server file is refused" {
    _refuses_then_passes "mmry/codex-mcp.json" '"note": "SQL-backed"'
}
@test "SQL-backed planted in a skill is refused" {
    _refuses_then_passes "mmry/skills/memory-system/SKILL.md" 'MMRY is a SQL-backed memory system.'
}
@test "SQL-backed planted in a Codex skill is refused" {
    local f; f="$(cd "$COPY" && find mmry/skills-codex -name '*.md' | head -1)"
    _refuses_then_passes "$f" 'MMRY is a SQL-backed memory system.'
}
@test "SQL-backed planted in a command is refused" {
    _refuses_then_passes "mmry/commands/help.md" 'MMRY is a SQL-backed memory system.'
}
@test "SQL-backed planted in the plugin README is refused" {
    _refuses_then_passes "mmry/README.md" 'MMRY is a SQL-backed memory system.'
}
@test "SQL-backed planted in the repository README is refused" {
    _refuses_then_passes "README.md" 'MMRY is a SQL-backed memory system.'
}
@test "SQL-backed planted in a docs page is refused" {
    local f; f="$(cd "$COPY" && ls docs/*.md | head -1)"
    _refuses_then_passes "$f" 'MMRY is a SQL-backed memory system.'
}
@test "SQL-backed planted in what a script prints is refused" {
    _refuses_then_passes "mmry/hooks-handlers/session-start.sh" 'echo "MMRY is a SQL-backed memory system."'
}
@test "SQL-backed planted in a setup script is refused" {
    _refuses_then_passes "mmry/setup/install.sh" 'echo "Installing the SQL-backed memory system"'
}
@test "SQL-backed planted in a hook configuration is refused" {
    _refuses_then_passes "mmry/hooks/hooks.json" '"note": "SQL-backed"'
}

@test "the other refused terms are refused" {
    local t
    for t in 'Stored in Azure SQL.' 'Runs on SQL Server.' 'It calls a stored procedure.' 'A relational database.' \
             'Uses Dapper.' 'Uses Entity Framework.' 'Uses PostgreSQL.' 'T-SQL literal.' 'Reads dbo.Session.'; do
        _refuses_then_passes "mmry/README.md" "$t" || { echo "term not refused: $t"; return 1; }
    done
}

@test "the AI database product name is not refused" {
    _plant "mmry/README.md" "Your AI database remembers across sessions, computers and teams." >/dev/null
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]]
}

@test "a script comment naming SQL is not read" {
    _plant "mmry/hooks-handlers/session-start.sh" "# held as a T-SQL literal, never shown" >/dev/null
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]]
}

@test "a root with nothing to read is a failed read, never a pass" {
    mkdir -p "$TEST_TMPDIR/empty"
    run bash "$CHECK" "$TEST_TMPDIR/empty"
    [[ "$status" -eq 2 ]]
}

@test "every manifest description is non-empty and within the length limit" {
    command -v jq >/dev/null || skip "jq not available"
    local f d
    d="$(jq -r '.description' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
    [[ -n "$d" && "$d" != "null" ]] || { echo "empty plugin.json description"; return 1; }
    [[ "${#d}" -le 300 ]] || { echo "plugin.json description over 300 characters (${#d})"; return 1; }
    d="$(jq -r '.plugins[0].description' "$REPO_ROOT/.claude-plugin/marketplace.json")"
    [[ -n "$d" && "$d" != "null" ]] || { echo "empty marketplace description"; return 1; }
    [[ "${#d}" -le 300 ]] || { echo "marketplace description over 300 characters (${#d})"; return 1; }
    d="$(jq -r '.description' "$PLUGIN_ROOT/.codex-plugin/plugin.json")"
    [[ -n "$d" && "$d" != "null" && "${#d}" -le 300 ]]
    d="$(jq -r '.interface.shortDescription' "$PLUGIN_ROOT/.codex-plugin/plugin.json")"
    [[ -n "$d" && "$d" != "null" && "${#d}" -le 100 ]]
    d="$(jq -r '.interface.longDescription' "$PLUGIN_ROOT/.codex-plugin/plugin.json")"
    [[ -n "$d" && "$d" != "null" && "${#d}" -le 1200 ]]
}

@test "CI runs the check" {
    grep -q 'scripts/check-storage-wording.sh' "$REPO_ROOT/.github/workflows/test.yml"
}
