#!/usr/bin/env bats
# search-command.bats — Verify the first-class /mmry:search command (#30317).
#
# Why this exists:
# A working search hook (hooks-handlers/search-memories.sh) already ships, but until
# v1.15 it was not surfaced as a discoverable slash command. This test locks in the
# wiring: the command file exists, invokes the existing hook (no reimplementation),
# and is advertised in help so users can find it.

load '../helpers/test-helper'

SEARCH_CMD=""
HELP_CMD=""

setup() {
    SEARCH_CMD="$PLUGIN_ROOT/commands/search.md"
    HELP_CMD="$PLUGIN_ROOT/commands/help.md"
}

@test "commands/search.md exists" {
    [[ -f "$SEARCH_CMD" ]]
}

@test "search.md invokes the existing search-memories.sh hook (no reimplementation)" {
    grep -q 'search-memories.sh' "$SEARCH_CMD"
}

@test "search.md references CLAUDE_PLUGIN_ROOT for the hook path" {
    grep -q 'CLAUDE_PLUGIN_ROOT' "$SEARCH_CMD"
}

@test "search.md documents the keywords and optional scope arguments" {
    grep -qi 'keyword' "$SEARCH_CMD"
    grep -qi 'scope' "$SEARCH_CMD"
}

@test "help.md advertises the /mmry:search command so it is discoverable" {
    grep -q '/mmry:search' "$HELP_CMD"
}

@test "memory-system skill cross-references the search command" {
    grep -q '/mmry:search' "$PLUGIN_ROOT/skills/memory-system/SKILL.md"
}
