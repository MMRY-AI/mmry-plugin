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
#   4. Code identifiers that happen to contain a banned word (the handler file name) pass.
#   5. CI runs the check.

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
             "$COPY/mmry/.claude-plugin" "$COPY/mmry/.codex-plugin"
    cp -R "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/skills-codex" \
          "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/commands-codex" "$COPY/mmry/"
    cp "$PLUGIN_ROOT/README.md" "$COPY/mmry/README.md"
    cp "$REPO_ROOT/README.md" "$COPY/README.md"
    cp "$REPO_ROOT"/docs/*.md "$COPY/docs/"
    cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$COPY/.claude-plugin/"
    cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$COPY/mmry/.claude-plugin/"
    cp "$PLUGIN_ROOT/.codex-plugin/plugin.json" "$COPY/mmry/.codex-plugin/"
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

@test "handler and function names are code and pass" {
    local line
    line="$(_plant 'bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/reinforce-memory.sh" 42 and `mmry_reinforce_memory`')"
    run bash "$CHECK" "$COPY"
    [[ "$status" -eq 0 ]] || { echo "code identifier on line ${line} was refused"; echo "$output"; return 1; }
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

# Every handler, client function and flag the two skills named at develop c61f565, before the
# text was cleaned. Removing an explanation must not remove a step the assistant performs, and the
# one step that was explained by the mechanic (marking a used search result) is the one most at
# risk of being dropped with it.
CLAUDE_STEPS="save-memory.sh search-memories.sh reinforce-memory.sh deactivate-memory.sh
link-memories.sh list-groups.sh visibility.sh make-private.sh list-formats.sh create-format.sh
revise-format.sh save-record.sh query-records.sh record-history.sh mmry-client.sh
mmry_get_memories mmry_get_related mmry_delete_link mmry_reinforce_memory --ids --supersedes
--record-type --record-fields --visibility --permission-group-id"
CODEX_STEPS="save-memory.sh search-memories.sh reinforce-memory.sh deactivate-memory.sh
link-memories.sh list-groups.sh visibility.sh make-private.sh session-start.sh formation-list.sh
formation-start.sh formation-join.sh formation-say.sh formation-roster.sh formation-leave.sh
formation-assign.sh formation-progress.sh formation-claim.sh formation-report.sh
formation-debrief.sh submit-feedback.sh mmry-setup.sh --ids --supersedes"

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

@test "both skills still tell the assistant to mark a search result that guided the work" {
    # DD-140: search does not record use on the server, so this step stays with the assistant
    # until a server change makes it unnecessary. Removing it would shorten memory lifetimes.
    local f
    for f in "$PLUGIN_ROOT/skills/memory-system/SKILL.md" "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"; do
        grep -q 'search-memories.sh" --ids' "$f" || { echo "$f: no --ids search before marking"; return 1; }
        grep -q 'reinforce-memory.sh" 42' "$f" || { echo "$f: no step marking the used memory"; return 1; }
    done
}

@test "CI runs the check" {
    grep -q 'scripts/check-public-text.sh' "$REPO_ROOT/.github/workflows/test.yml"
}
