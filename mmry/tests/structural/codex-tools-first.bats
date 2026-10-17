#!/usr/bin/env bats
# codex-tools-first.bats - on Codex, nothing a model reads names a SCRIPT for an operation MMRY's own
# tools cover (#31743, fix round 1).
#
# WHY. MMRY's tool server (codex-mcp.json, server mmry_plugin) is started by Codex outside its
# sandbox, so memory_save, memory_search, memory_reinforce, memory_link, memory_retire,
# memory_load, formation_join, formation_say, formation_progress, formation_roster and
# formation_leave reach MMRY AI with no Internet access prompt. The script for the same operation,
# run by the model itself, is inside the sandbox and fails with HTTP 000 until the customer
# approves Internet access for the conversation.
#
# In the first live run in the real Codex CLI (0.162.1, macOS, 2026-10-10) the model was asked
# "Remember this: ..." in two fresh conversations, read the skill, ran save-memory.sh first (exit
# 1, HTTP 000), and only then called memory_save. The skill's "Saving a memory" section opened with
# a bash save-memory.sh block, and its tool table had an "Instead of" column naming every script.
#
# This file pins the STATIC surfaces a Codex model reads: the skill, the customer page, the Codex
# manifest and the other Codex-only files, and what the tool server itself says in tools/list,
# initialize and its refusals. tests/handlers/codex-tools-first-output.bats pins what the hooks and
# handlers PRINT on Codex.
#
# Claude Code is not touched by any of this: its skill (skills/memory-system) and commands keep
# naming the scripts, because Claude Code has no tool server here. One test below asserts that too.

load '../helpers/test-helper'

# The scripts of the eleven operations the tool server covers. A name here on a Codex surface is
# an instruction to run the sandboxed script.
TOOL_COVERED_SCRIPTS_RE='(save-memory|search-memories|reinforce-memory|link-memories|deactivate-memory|session-start|formation-(join|say|progress|roster|leave))\.sh'

# The same thing said in prose, which is how docs/codex.md said it before this round.
TOOL_COVERED_PROSE_RE='(the save script|formation join script|run the save|the search script|the join script)'

setup() {
    SKILL="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
    PAGE="$REPO_ROOT/docs/codex.md"
    SERVER="$PLUGIN_ROOT/hooks-handlers/mcp-server.sh"
}

# The tool names the server offers, from its own tools/list table.
_server_tools() {
    grep -o '"name": "[a-z_]*"' "$SERVER" | sed 's/"name": "//; s/"$//' | sort -u
}

# Print every line of $1 naming a tool-covered script, with its number.
_script_hits() {
    tr -d '\r' < "$1" | grep -nE "$TOOL_COVERED_SCRIPTS_RE" || true
}

# ---------------------------------------------------------------------------------------------
# the Codex skill
# ---------------------------------------------------------------------------------------------

@test "skill: names no script for an operation one of MMRY's tools covers" {
    local hits; hits="$(_script_hits "$SKILL")"
    [ -z "$hits" ] || { echo "the Codex skill names tool-covered scripts:"; echo "$hits"; return 1; }
    # The table that mapped each tool to its script ("Instead of") is gone too.
    ! tr -d '\r' < "$SKILL" | grep -qi 'instead of |' || { echo "the 'Instead of' column is back"; return 1; }
}

@test "skill: names every tool the server offers, and no tool it does not" {
    local t missing="" extra=""
    while IFS= read -r t; do
        grep -qF "\`$t\`" "$SKILL" || missing="${missing} $t"
    done < <(_server_tools)
    [ "$(_server_tools | grep -c .)" -eq 11 ] || { echo "expected 11 server tools: $(_server_tools | tr '\n' ' ')"; return 1; }
    # Any memory_* or formation_* name in backticks must be one the server offers. The connector's
    # mmry_formation_* tools are a different, warned-about thing and are excluded by the prefix,
    # and an argument such as formation_id is not a tool.
    while IFS= read -r t; do
        _server_tools | grep -qx "$t" || extra="${extra} $t"
    done < <(grep -oE '`(memory|formation)_[a-z]+`' "$SKILL" | tr -d '`' | grep -v '_id$' | sort -u)
    [ -z "$missing" ] || { echo "the skill does not name:${missing}"; return 1; }
    [ -z "$extra" ] || { echo "the skill names tools the server does not offer:${extra}"; return 1; }
}

@test "skill: tells the model to call the tool first, before any script appears" {
    local tools_line first_bash
    tools_line="$(tr -d '\r' < "$SKILL" | grep -n "^## Call MMRY's tools" | head -1 | cut -d: -f1)"
    first_bash="$(tr -d '\r' < "$SKILL" | grep -n '^```bash' | head -1 | cut -d: -f1)"
    [ -n "$tools_line" ] || { echo "no 'Call MMRY's tools' section"; return 1; }
    [ -n "$first_bash" ] || { echo "no bash block at all; the scripts with no tool must still be documented"; return 1; }
    [ "$tools_line" -lt "$first_bash" ] || { echo "a bash block (line $first_bash) comes before the tools (line $tools_line)"; return 1; }
    tr -d '\r' < "$SKILL" | grep -q 'Do not run a script first' || { echo "the skill does not forbid trying the script first"; return 1; }
}

@test "skill: every script it still shows sits under the section marked as having no tool" {
    local marker; marker="$(tr -d '\r' < "$SKILL" | grep -n '^## Operations with no tool' | head -1 | cut -d: -f1)"
    [ -n "$marker" ] || { echo "no 'Operations with no tool' section"; return 1; }
    tr -d '\r' < "$SKILL" | sed -n "${marker},\$p" | grep -q 'has no mmry_plugin tool' || { echo "the section does not say it has no tool"; return 1; }
    local early
    early="$(tr -d '\r' < "$SKILL" | head -n "$marker" | grep -nE 'mmry/(hooks-handlers|setup)/[A-Za-z0-9_-]+\.sh' || true)"
    [ -z "$early" ] || { echo "scripts named before the no-tool section:"; echo "$early"; return 1; }
}

@test "skill: when the tools are missing it does not fall back to a script" {
    local para
    para="$(tr -d '\r' < "$SKILL" | awk '/If the mmry_plugin tools are not offered at all/{on=1} on{print} on && /^$/{exit}')"
    [ -n "$para" ] || { echo "no 'tools not offered' guidance"; return 1; }
    [[ "$para" == *"Do not substitute a script"* ]] || { echo "$para"; return 1; }
    [[ "$para" != *".sh"* ]] || { echo "$para"; return 1; }
}

@test "skill: its description, which Codex shows before the body, sends tool-covered operations to the tools" {
    local desc; desc="$(tr -d '\r' < "$SKILL" | sed -n '2,4p' | grep '^description:')"
    [[ "$desc" == *"mmry_plugin tools, never scripts"* ]] || { echo "$desc"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# the customer page and the other Codex-only files
# ---------------------------------------------------------------------------------------------

@test "docs/codex.md: names no script, in a path or in prose, for an operation a tool covers" {
    [ -f "$PAGE" ]
    local hits prose
    hits="$(_script_hits "$PAGE")"
    prose="$(tr -d '\r' < "$PAGE" | grep -niE "$TOOL_COVERED_PROSE_RE" || true)"
    [ -z "$hits$prose" ] || { echo "docs/codex.md points at a script:"; echo "$hits"; echo "$prose"; return 1; }
    # And it names the tools where it used to name the scripts.
    grep -q '`memory_save`' "$PAGE"
    grep -q '`memory_load`' "$PAGE"
    grep -q '`formation_join`' "$PAGE"
}

@test "Codex-only files and the shared READMEs name no tool-covered script" {
    local f hits all=""
    for f in \
        "$PLUGIN_ROOT/.codex-plugin/plugin.json" \
        "$PLUGIN_ROOT/codex-mcp.json" \
        "$PLUGIN_ROOT/hooks/codex-hooks.json" \
        "$PLUGIN_ROOT/commands-codex/README.md" \
        "$REPO_ROOT/README.md" \
        "$PLUGIN_ROOT/README.md"; do
        [ -f "$f" ] || { echo "missing surface: $f"; return 1; }
        hits="$(_script_hits "$f")"
        [ -z "$hits" ] || all="${all}
${f#$REPO_ROOT/}: ${hits}"
    done
    [ -z "$all" ] || { echo "tool-covered scripts named on a Codex surface:${all}"; return 1; }
}

@test "the scanner is real: it finds every tool-covered script name in a line built to contain them" {
    # A regex that matches nothing makes every test above green. Feed it the eleven names.
    local f="$BATS_TEST_TMPDIR/probe.md" n
    printf '%s\n' save-memory.sh search-memories.sh reinforce-memory.sh link-memories.sh \
        deactivate-memory.sh session-start.sh formation-join.sh formation-say.sh \
        formation-progress.sh formation-roster.sh formation-leave.sh > "$f"
    n="$(_script_hits "$f" | grep -c .)"
    [ "$n" -eq 11 ]
    # And it leaves alone the scripts no tool covers.
    printf '%s\n' list-groups.sh visibility.sh formation-list.sh formation-start.sh submit-feedback.sh mmry-setup.sh > "$f"
    [ -z "$(_script_hits "$f")" ]
}

# ---------------------------------------------------------------------------------------------
# what the tool server itself says
# ---------------------------------------------------------------------------------------------

_server_say() {
    local codex="$BATS_TEST_TMPDIR/codexhome"
    mkdir -p "$codex"
    printf '%s\n' "$@" | env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$codex" \
        MMRY_API_KEY=fake-key MMRY_API_URL=http://fake.invalid MMRY_AUTH_METHOD=apikey MMRY_NO_SELF_UPDATE=1 \
        bash "$SERVER"
}

@test "server: tools/list, its instructions and its refusals name no script" {
    local out
    out="$(_server_say \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"formation_roster","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"memory_load","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"memory_save","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"memory_link","arguments":{"source_id":1,"target_id":2,"link_type":"x"}}}')"
    # All six answered, so the scan below has something to scan.
    [ "$(printf '%s\n' "$out" | grep -c '"id":[1-6]')" -eq 6 ] || { echo "$out"; return 1; }
    # 3 and 4 are the no-conversation refusal, 5 and 6 argument refusals.
    [[ "$out" == *"did not say which conversation"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"content is required"* ]] || { echo "$out"; return 1; }
    local text
    text="$(printf '%s\n' "$out" | jq -r '.. | strings')"
    [[ "$text" != *".sh"* ]] || { echo "the server's own words name a script:"; printf '%s\n' "$text" | grep -n '\.sh'; return 1; }
    # "Use these instead of running MMRY's bash scripts" is the instruction this server exists to
    # give. Sending the model TO a script is what is refused.
    [[ "$text" != *"skill's bash script"* && "$text" != *"script instead"* ]] || { echo "the server's own words send the model to a script"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# requirement 4: Claude Code keeps its scripts
# ---------------------------------------------------------------------------------------------

@test "req4: the Claude Code skill still names the scripts, because Claude Code has no tool server" {
    local claude_skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    [ -f "$claude_skill" ]
    grep -q 'save-memory.sh' "$claude_skill"
    grep -q 'search-memories.sh' "$claude_skill"
    ! grep -q 'mmry_plugin' "$claude_skill"
}
