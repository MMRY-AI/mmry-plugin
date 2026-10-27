#!/usr/bin/env bats
# public-text-check.bats - the release check that keeps internal memory mechanics out of the
# plugin's customer-readable text (#32272, DD-140 in the mmry repository).
#
# Why this exists:
# The skills, commands, docs and README of a published plugin are readable by every customer,
# and until #32272 they carried how long each kind of memory lasts, how memories are kept alive
# and a table of server routes. Connected assistants already hide all of that by design (DD-48).
# A rewrite alone would drift back the next time somebody documents a feature, so the rule is
# enforced by scripts/check-public-text.sh, which CI and the release steps run.
#
# What these tests prove:
#   1. The check passes the real repository and names no file.
#   2. Each banned term, planted into a copy of a skill file, is refused, and the refusal names
#      that file and the planted line.
#   3. The same copy passes again once the planted line is gone, so a refusal is caused by the
#      planted term and nothing else.
#   4. Nothing is allow-listed (#32640): a handler, function or tool name carrying a banned word is
#      refused like any other text, and so is describing how memories are connected or marked used.
#   5. The Codex MCP server's tool titles, tool descriptions and server instructions are read,
#      and the rest of that file (code) is not.
#   6. CI runs the check.

load '../helpers/test-helper'

REPO_ROOT=""
CHECK=""
COPY=""

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    CHECK="$REPO_ROOT/scripts/check-public-text.sh"
    COPY="$TEST_TMPDIR/repo-copy"
    # A copy of every surface the check reads, so planting a term never touches the real files.
    mkdir -p "$COPY/mmry" "$COPY/docs" "$COPY/.claude-plugin" \
             "$COPY/mmry/.claude-plugin" "$COPY/mmry/.codex-plugin" "$COPY/mmry/hooks-handlers"
    cp -R "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/skills-codex" \
          "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/commands-codex" "$COPY/mmry/"
    cp "$PLUGIN_ROOT/README.md" "$COPY/mmry/README.md"
    cp "$REPO_ROOT/README.md" "$COPY/README.md"
    cp "$REPO_ROOT"/docs/*.md "$COPY/docs/"
    cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$COPY/.claude-plugin/"
    cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$COPY/mmry/.claude-plugin/"
    cp "$PLUGIN_ROOT/.codex-plugin/plugin.json" "$COPY/mmry/.codex-plugin/"
    cp "$PLUGIN_ROOT/hooks-handlers/mcp-server.sh" "$COPY/mmry/hooks-handlers/"
}

# Inserts one line into the copied MCP server straight after the line that opens the tool list,
# so it sits inside the list, and echoes its line number. Portable: awk, no sed -i.
_plant_in_tools() {
    local f="$COPY/mmry/hooks-handlers/mcp-server.sh"
    awk -v ins="$1" '{ print } /^MMRY_MCP_TOOLS=/ { print ins }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    awk '/^MMRY_MCP_TOOLS=/ { print NR + 1; exit }' "$f"
}

# Appends one line to the copied Claude Code skill and echoes the line number it landed on.
_plant() {
    local f="$COPY/mmry/skills/memory-system/SKILL.md"
    printf '%s\n' "$1" >> "$f"
    wc -l < "$f" | tr -d '[:space:]'
}

# Removes the last line of the copied skill again (portable: no sed -i, which differs on macOS).
_unplant() {
    local f="$COPY/mmry/skills/memory-system/SKILL.md"
    local n
    n="$(wc -l < "$f" | tr -d '[:space:]')"
    head -n "$((n - 1))" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# Plants a term, expects a refusal naming the file and line, removes it, expects a pass.
_refuses_then_passes() {
    local text="$1" line
    line="$(_plant "$text")"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 ]] || { echo "check passed a planted term: $text"; return 1; }
    [[ "$output" == *"mmry/skills/memory-system/SKILL.md:${line}:"* ]] \
        || { echo "refusal does not name SKILL.md line ${line} for: $text"; echo "$output"; return 1; }
    _unplant
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "clean copy refused after removing: $text"; echo "$output"; return 1; }
}

@test "the check script exists" {
    [[ -f "$CHECK" ]]
}

@test "the real repository passes and the output names no file" {
    run bash "$CHECK" "$REPO_ROOT"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" != *".md:"* && "$output" != *".json:"* ]] || { echo "$output"; return 1; }
}

@test "it runs with no argument against its own repository" {
    run bash "$CHECK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "the unchanged copy passes" {
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "refuses 'reinforce'" {
    _refuses_then_passes "When a search result guides the work, reinforce it."
}

@test "refuses 'reinforcement'" {
    _refuses_then_passes "## Reinforcement"
}

@test "refuses 'expiration clock'" {
    _refuses_then_passes "The expiration clock resets each time a memory is read."
}

@test "refuses 'tier clock'" {
    _refuses_then_passes "A record is durable against the tier clock."
}

@test "refuses 'access count'" {
    _refuses_then_passes "Reading a memory increments its access count."
}

@test "refuses a server route" {
    _refuses_then_passes '| GET | `/api/memories/search?q=` | Keyword search |'
}

@test "refuses a duration tied to a memory kind (digits)" {
    _refuses_then_passes "| Operational | Active working knowledge | 3 months from last access |"
}

@test "refuses a duration tied to a memory kind (words)" {
    _refuses_then_passes "Tactical memories last seven days."
}

@test "refuses a memory kind said never to expire" {
    _refuses_then_passes "Foundation memories never expire."
}

@test "refuses a memory kind said to last forever" {
    _refuses_then_passes "| **Foundation** | Forever | Who you are |"
}

@test "refuses 'aged out of normal loading'" {
    _refuses_then_passes "Search finds a memory that has aged out of normal loading."
}

@test "refuses 'stay alive'" {
    _refuses_then_passes "Memories that get accessed regularly stay alive longer."
}

@test "refuses a planted term in a Codex skill, a command and the docs too" {
    local f
    for f in mmry/skills-codex/memory-system/SKILL.md mmry/commands/help.md docs/codex.md; do
        cp "$COPY/$f" "$COPY/$f.orig"
        printf '%s\n' "Tiers and reinforcement are the same." >> "$COPY/$f"
        run bash "$CHECK" "$COPY"
        [[ "$status" -ne 0 && "$output" == *"$f:"* ]] || { echo "not refused in $f"; echo "$output"; return 1; }
        mv "$COPY/$f.orig" "$COPY/$f"
    done
}

@test "refuses a banned term in a plugin manifest description" {
    local f="$COPY/.claude-plugin/marketplace.json"
    printf '%s\n' '"description": "Auto-loads, auto-saves, auto-reinforces."' >> "$f"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *".claude-plugin/marketplace.json:"* ]] || { echo "$output"; return 1; }
}

@test "refuses 'regardless of age'" {
    _refuses_then_passes "Search memories by keyword, regardless of age."
}

@test "refuses a banned term in a Codex MCP tool title" {
    local line
    line="$(_plant_in_tools '    "title": "Reinforce a memory",')"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:${line}:"* ]]         || { echo "title on line ${line} not refused"; echo "$output"; return 1; }
}

@test "refuses a banned term in a Codex MCP tool description" {
    local line
    line="$(_plant_in_tools '    "description": "Reset a memory expiry. Operational, Tactical and Momentary memories only.",')"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:${line}:"* ]]         || { echo "description on line ${line} not refused"; echo "$output"; return 1; }
}

@test "refuses an age mechanic in a Codex MCP tool description" {
    local line
    line="$(_plant_in_tools '    "description": "Search memories by keyword, regardless of age.",')"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:${line}:"* ]]         || { echo "description on line ${line} not refused"; echo "$output"; return 1; }
}

@test "refuses a banned term in the Codex MCP server instructions" {
    local f="$COPY/mmry/hooks-handlers/mcp-server.sh"
    printf '%s
' 'MMRY_MCP_INSTRUCTIONS="Use these tools for saving, searching and reinforcing memories."' >> "$f"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:"* ]] || { echo "$output"; return 1; }
}

@test "code in the Codex MCP server outside the tool text is not read" {
    local f="$COPY/mmry/hooks-handlers/mcp-server.sh"
    printf '%s\n' '# memory_retire sends DELETE /api/memories/{id}' \
        'elif $n == "memory_retire" then ["deactivate-memory.sh"]' >> "$f"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "32640 req2: a tool name carrying a banned word in a Codex MCP tool description is refused" {
    local line
    line="$(_plant_in_tools '    "description": "Use the id with memory_rein''force.",')"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:${line}:"* ]] \
        || { echo "description on line ${line} not refused"; echo "$output"; return 1; }
}

@test "32640 req2: refuses linking in a Codex MCP tool description" {
    local line
    line="$(_plant_in_tools '    "description": "Record a relationship between two memories, then link them.",')"
    run bash "$CHECK" "$COPY"
    [[ "$status" -ne 0 && "$output" == *"mmry/hooks-handlers/mcp-server.sh:${line}:"* ]] \
        || { echo "description on line ${line} not refused"; echo "$output"; return 1; }
}

@test "32640 req2: a handler name carrying a banned word is refused" {
    _refuses_then_passes 'bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/rein''force-memory.sh" 42'
}

@test "32640 req2: a client function name carrying a banned word is refused" {
    _refuses_then_passes 'Available functions: `mmry_save`, `mmry_rein''force_memory`.'
}

@test "32640 req2: refuses a heading about linking" {
    _refuses_then_passes "## Linking"
}

@test "32640 req2: refuses linking two memories" {
    _refuses_then_passes "| Link two memories |"
}

@test "32640 req2: refuses memories linked to each other" {
    _refuses_then_passes "Memories can be linked to each other to form a network."
}

@test "32640 req2: refuses a link type" {
    _refuses_then_passes "Call it with source_id, target_id and link_type."
}

@test "32640 req2: refuses reading related memories" {
    _refuses_then_passes "# Get related memories"
}

@test "32640 req2: refuses the related-memories function" {
    _refuses_then_passes "mmry_get_related 42"
}

@test "32640 req2: refuses a link-memory handler name" {
    _refuses_then_passes 'bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/li''nk-memories.sh" 42 87'
}

@test "32640 req2: refuses marking a memory as used" {
    _refuses_then_passes "| Mark a memory as used, after it guided your work |"
}

@test "32640 req2: refuses marking a memory useful" {
    _refuses_then_passes "Saving, searching, marking useful, retiring and reloading memories."
}

@test "32640 req2: refuses saying a memory was useful" {
    _refuses_then_passes "It records that the memory was useful."
}

@test "32640 req2: refuses a link or reinforce word planted in a Codex skill, a command, a README and the docs" {
    local f t
    for f in mmry/skills-codex/memory-system/SKILL.md mmry/commands/save.md mmry/README.md README.md docs/codex.md; do
        for t in "Link two memories with the tool." "Reinforce the memory that helped."; do
            cp "$COPY/$f" "$COPY/$f.orig"
            printf '%s\n' "$t" >> "$COPY/$f"
            run bash "$CHECK" "$COPY"
            [[ "$status" -ne 0 && "$output" == *"$f:"* ]] || { echo "not refused in $f: $t"; echo "$output"; return 1; }
            mv "$COPY/$f.orig" "$COPY/$f"
        done
    done
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "32640: a link that is not about memories passes (an email link)" {
    _plant "Open the link in the email to finish signing in." >/dev/null
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "32640: a task the memory came from passes" {
    _plant "When a memory comes from a task, pass --task-id to record which task it came from." >/dev/null
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "a duration unrelated to a memory kind passes (formation listening)" {
    _plant "By default a session listens for 24 hours of quiet after its last turn." >/dev/null
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "a root holding none of the surfaces is an error, not a pass" {
    mkdir -p "$TEST_TMPDIR/empty"
    run bash "$CHECK" "$TEST_TMPDIR/empty"
    [[ "$status" -ne 0 ]]
}

# Every handler, client function and flag the Claude Code skill named at develop c61f565, before
# the text was cleaned, and every handler and MMRY tool the Codex skill names at develop 79d2211
# (#88 moved the Codex skill's everyday operations from scripts to MMRY's MCP tools), less the two
# handlers, three client functions and two tools #32640 removed. Removing an explanation must not
# remove a step the assistant performs.
CLAUDE_STEPS="save-memory.sh search-memories.sh deactivate-memory.sh
list-groups.sh visibility.sh make-private.sh list-databases.sh create-database.sh
revise-database.sh save-entry.sh query-entries.sh entry-history.sh mmry-client.sh
mmry_get_memories --ids --supersedes
--database-name --entry-fields --visibility --permission-group-id"
CODEX_STEPS="list-groups.sh visibility.sh make-private.sh formation-list.sh formation-claim.sh
submit-feedback.sh mmry-setup.sh memory_save memory_search
memory_retire memory_load formation_join formation_say formation_progress formation_roster
formation_start formation_assign formation_report formation_debrief formation_leave supersedes"

@test "the Claude Code skill still names every step it named before #32272" {
    local skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md" s missing=""
    for s in $CLAUDE_STEPS; do grep -q -- "$s" "$skill" || missing="$missing $s"; done
    [[ -z "$missing" ]] || { echo "no longer named:$missing"; return 1; }
}

@test "the Codex skill still names every step it named before #32272" {
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" s missing=""
    for s in $CODEX_STEPS; do grep -q -- "$s" "$skill" || missing="$missing $s"; done
    [[ -z "$missing" ]] || { echo "no longer named:$missing"; return 1; }
}

@test "32640 req3: both skills still correct a memory by saving a replacement" {
    local f="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    grep -q '^## Correcting a Memory' "$f" || { echo "$f: no correction section"; return 1; }
    grep -q -- '--supersedes 42 --working-dir' "$f" || { echo "$f: no save with --supersedes"; return 1; }
    grep -q 'search-memories.sh" --ids' "$f" || { echo "$f: no --ids search for the id"; return 1; }
    f="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    grep -q '^## Correcting a memory' "$f" || { echo "$f: no correction section"; return 1; }
    grep -q 'call `memory_save`' "$f" || { echo "$f: no memory_save call"; return 1; }
    grep -q '`supersedes` set to the id of the wrong one' "$f" || { echo "$f: no supersedes"; return 1; }
    # And the save command points at the section that still exists.
    grep -q 'skill'"'"'s "Correcting a Memory" section' "$PLUGIN_ROOT/commands/save.md" \
        || { echo "save.md does not point at the correction section"; return 1; }
}

@test "CI runs the check" {
    grep -q 'scripts/check-public-text.sh' "$REPO_ROOT/.github/workflows/test.yml"
}
