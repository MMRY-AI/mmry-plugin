#!/usr/bin/env bats
# database-names-check.bats - the release check that keeps the AI database's internal names out of
# what customers and assistants read in the plugin (#32457, DD-150 in the mmry repository).
#
# Why this exists:
# The AI database is marketed as a database the assistant builds while you talk, made of entries.
# Until #32457 the skills, the help command and what the database's scripts print called the same
# thing a record type, a format and records, so an assistant repeated those words to customers. A
# rewrite alone would drift back the next time somebody documents the feature, so the rule is
# enforced by scripts/check-database-names.sh, which CI and this suite run.
#
# What these tests prove:
#   1. The check passes the real repository and names no file.
#   2. Each internal name, planted into a copy of a surface, is refused, and the refusal names the
#      file and the planted line; the copy passes again once the line is gone.
#   3. Identifiers that contain the old words (script names, flags, tool names, RecordedAs) pass,
#      so no script, flag or tool had to be renamed (requirement 3).
#   4. "record" outside the database (a Formation's close-out record) is not refused, while
#      "record type" is refused everywhere.
#   5. A script's comment is not read; what it prints is.
#   6. The check reads the Codex skill, the help command, the docs and the Codex MCP server.
#   7. CI runs the check.

load '../helpers/test-helper'

REPO_ROOT=""
CHECK=""
COPY=""

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    CHECK="$REPO_ROOT/scripts/check-database-names.sh"
    COPY="$TEST_TMPDIR/repo-copy"
    mkdir -p "$COPY/mmry" "$COPY/docs" "$COPY/mmry/hooks-handlers"
    cp -R "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/skills-codex" \
          "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/commands-codex" "$COPY/mmry/"
    cp "$PLUGIN_ROOT/README.md" "$COPY/mmry/README.md"
    cp "$REPO_ROOT/README.md" "$COPY/README.md"
    cp "$REPO_ROOT"/docs/*.md "$COPY/docs/"
    local f
    for f in mcp-server.sh create-format.sh list-formats.sh revise-format.sh save-record.sh \
             query-records.sh record-history.sh save-memory.sh; do
        cp "$PLUGIN_ROOT/hooks-handlers/$f" "$COPY/mmry/hooks-handlers/"
    done
}

# Appends one line to a copied file and echoes the line number it landed on.
_plant() {
    local f="$COPY/$1"
    printf '%s\n' "$2" >> "$f"
    wc -l < "$f" | tr -d '[:space:]'
}

# Removes the last line of a copied file again (portable: no sed -i).
_unplant() {
    local f="$COPY/$1" n
    n="$(wc -l < "$f" | tr -d '[:space:]')"
    head -n "$((n - 1))" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

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

_passes() {
    local rel="$1" text="$2"
    _plant "$rel" "$text" > /dev/null
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "refused: $text"; echo "$output"; return 1; }
    _unplant "$rel"
}

SKILL="mmry/skills/memory-system/SKILL.md"

@test "the check script exists" {
    [[ -f "$CHECK" ]]
}

@test "the real repository passes and the output names no file" {
    run bash "$CHECK" "$REPO_ROOT"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == "check-database-names: clean ("* ]] || { echo "$output"; return 1; }
}

@test "the unchanged copy passes" {
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "an empty root is a failure to read, never a pass" {
    mkdir -p "$TEST_TMPDIR/empty"
    run bash "$CHECK" "$TEST_TMPDIR/empty"
    [[ "$status" -eq 2 ]] || { echo "$output"; return 1; }
}

@test "refuses 'record type' anywhere in a skill" {
    _refuses_then_passes "$SKILL" "Define a record type when the user tracks expenses."
}

@test "refuses 'structured record' anywhere in a skill" {
    _refuses_then_passes "$SKILL" "Search also finds structured records."
}

@test "refuses 'data format' anywhere in a skill" {
    _refuses_then_passes "$SKILL" "Every data format has fields."
}

@test "refuses 'record' and 'format' on a line about the database" {
    _refuses_then_passes "$SKILL" "Each record in the database keeps its words."
    _refuses_then_passes "$SKILL" "Run list-formats.sh to see each format."
}

@test "refuses 'record' inside the database section of the skill" {
    # Planted inside the section, on a line that names no script and does not say database.
    local f="$COPY/$SKILL" line
    awk '{ print } /^### Correcting an entry/ { print "A record is corrected here." }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    line="$(awk '/^A record is corrected here\./ { print NR; exit }' "$f")"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 1 && "$output" == *"${SKILL}:${line}:"* ]] || { echo "$output"; return 1; }
}

@test "identifiers carrying the old words pass, so nothing had to be renamed" {
    _passes "$SKILL" 'The database: `save-record.sh --format-id 42 --record-id 9 --record-type X`, `mmry_record`, `mmry_format_list`, `RecordedAs:`, `recordName`, mmryai.com/records.'
}

@test "'record' outside the database is ordinary English and passes; 'record type' never does" {
    _passes "$SKILL" "The formation's close-out record is kept as a memory."
    _refuses_then_passes "$SKILL" "The formation's close-out record type is kept as a memory."
}

@test "a script's comment is not read; what it prints is" {
    local rel="mmry/hooks-handlers/query-records.sh"
    _passes "$rel" "# a comment about a record type is code, not copy"
    _refuses_then_passes "$rel" 'echo "No records yet."'
}

@test "reads the Codex skill, the help command and the docs" {
    local f
    for f in mmry/skills-codex/memory-system/SKILL.md mmry/commands/help.md docs/codex.md; do
        _refuses_then_passes "$f" "Ask your assistant to define a record type."
    done
}

@test "reads the Codex MCP server's descriptions and nothing else of that file" {
    local f="$COPY/mmry/hooks-handlers/mcp-server.sh" line
    awk '{ print } /^MMRY_MCP_TOOLS=/ { print "    \"description\": \"Save a structured record.\"," }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    line="$(awk '/Save a structured record/ { print NR; exit }' "$f")"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 1 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:${line}:"* ]] || { echo "$output"; return 1; }
    cp "$PLUGIN_ROOT/hooks-handlers/mcp-server.sh" "$f"
    printf '%s\n' '_unused() { echo "a record type in code that is not a description"; }' >> "$f"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "CI runs the check" {
    grep -q 'bash scripts/check-database-names.sh' "$REPO_ROOT/.github/workflows/test.yml"
}
