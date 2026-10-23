#!/usr/bin/env bats
# help-complete.bats - /mmry:help names every command and every Formation and database subcommand
# (#32381 req 2, 4; #32443 req 3).
#
# Three lists are derived from the shipped files, never hardcoded, so a command added without a help
# line fails here before release:
#   1. every commands/*.md file is a slash command, /mmry:<file stem>;
#   2. every "### word" heading in commands/formation.md is a Formation subcommand;
#   3. every "### word" heading in commands/database.md is a database subcommand (#32443).
#
# "Reporting to the lead" is a section, not a subcommand. It is excluded by rule, not by name: a
# subcommand heading is a single lowercase word (^### [a-z]+$), and that heading has capitals and
# spaces. The "#### say to one member" heading is a fourth-level heading and never matches "### ".
# A control test below proves the rule drops the section and keeps all twelve subcommands.

load '../helpers/test-helper'

# Set DIR to the plugin root under test (overridable so the red runs can use a scratch copy).
_root() { printf '%s' "${HELP_CHECK_ROOT:-$PLUGIN_ROOT}"; }

# Subcommands of /mmry:<command>, one per line, read from the command's own page. The command
# defaults to formation so the Formation tests below read as they always have.
_subcommands() { tr -d '\r' < "$1/commands/${2:-formation}.md" | grep -E '^### [a-z]+$' | sed 's/^### //'; }

# Print every name the help text does not carry. Empty output means complete.
_missing() {
    local root="$1" help="$1/commands/help.md" f name sub
    for f in "$root"/commands/*.md; do
        name="$(basename "$f" .md)"
        grep -Eq "/mmry:${name}([^a-z-]|\$)" "$help" || echo "command /mmry:${name} (commands/${name}.md)"
    done
    for sub in $(_subcommands "$root"); do
        grep -Eq "/mmry:formation ${sub}([^a-z]|\$)" "$help" || echo "formation subcommand ${sub} (commands/formation.md)"
    done
    for sub in $(_subcommands "$root" database); do
        grep -Eq "/mmry:database ${sub}([^a-z]|\$)" "$help" || echo "database subcommand ${sub} (commands/database.md)"
    done
}

@test "help: names every command in commands/ and every Formation and database subcommand" {
    local root; root="$(_root)"
    run _missing "$root"
    [ -z "$output" ] || { echo "help.md does not name:"; echo "$output"; return 1; }
}

@test "help: the lists being checked are not empty (a derivation that finds nothing proves nothing)" {
    local root n; root="$(_root)"
    n="$(ls "$root"/commands/*.md | wc -l)"
    [ "$n" -ge 10 ] || { echo "only $n command files found"; return 1; }
    n="$(_subcommands "$root" | wc -l)"
    [ "$n" -ge 12 ] || { echo "only $n formation subcommands found"; return 1; }
    n="$(_subcommands "$root" database | wc -l)"
    [ "$n" -ge 8 ] || { echo "only $n database subcommands found"; return 1; }
}

@test "help: the heading rule keeps the twelve subcommands and drops the Reporting section" {
    local root list; root="$(_root)"
    list="$(_subcommands "$root" | tr '\n' ' ')"
    for s in start join roster say assign progress report claim debrief leave remove status; do
        [[ " $list" == *" $s "* ]] || { echo "missing $s in: $list"; return 1; }
    done
    [[ "$list" != *"eporting"* ]] || { echo "section leaked in: $list"; return 1; }
}

@test "help: a command file with no help line is refused, naming the file" {
    local root copy; root="$(_root)"
    copy="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$copy"
    cp -R "$root/commands" "$copy/commands"
    printf 'Does a thing.\n' > "$copy/commands/zz-fake.md"
    run _missing "$copy"
    [[ "$output" == *"zz-fake.md"* ]] || { echo "not named: $output"; return 1; }
}

@test "help: a Formation subcommand heading with no help line is refused, naming it" {
    local root copy; root="$(_root)"
    copy="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$copy"
    cp -R "$root/commands" "$copy/commands"
    printf '\n### zzfake\n\nA new subcommand.\n' >> "$copy/commands/formation.md"
    run _missing "$copy"
    [[ "$output" == *"formation subcommand zzfake"* ]] || { echo "not named: $output"; return 1; }
}

@test "help: the database page's headings are exactly its eight subcommands (#32443)" {
    local root list; root="$(_root)"
    list="$(_subcommands "$root" database | tr '\n' ' ')"
    [ "$list" = "create list add find correct history retire restore " ] || { echo "got: $list"; return 1; }
}

@test "help: every database subcommand on the page is one database.sh accepts, and no other (#32443)" {
    # The page and the script are two lists of the same thing. A heading the script refuses, or a
    # script branch no heading documents, fails here. A branch is a four-space "word)" line.
    local root arms; root="$(_root)"
    arms="$(tr -d '\r' < "$root/hooks-handlers/database.sh" | grep -oE '^    [a-z]+\)' | tr -d ' )' | sort | tr '\n' ' ')"
    [ "$arms" = "$(_subcommands "$root" database | sort | tr '\n' ' ')" ] || { echo "script: $arms"; return 1; }
}

@test "help: a database subcommand heading with no help line is refused, naming it (#32443)" {
    local root copy; root="$(_root)"
    copy="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$copy"
    cp -R "$root/commands" "$copy/commands"
    printf '\n### zzfake\n\nA new subcommand.\n' >> "$copy/commands/database.md"
    run _missing "$copy"
    [[ "$output" == *"database subcommand zzfake"* ]] || { echo "not named: $output"; return 1; }
}

# The database how-to (#32442 req 3): its own "## Your AI database" section in /mmry:help, the same
# steps as the help page at mmryai.com/help#databases, each with an example request in the
# customer's own words, and every /mmry:database subcommand shown inside the section. The step
# labels are the contract with the help page; the subcommands are derived from commands/database.md
# like the lists above, so a new subcommand without an example in the section fails here.
DB_STEPS=("Start a database" "Add an entry" "Ask about your entries" "Correct an entry" "See an entry's history" "Stop a database" "Start it again")

# The text of the "## Your AI database" section, up to the next "## " heading. Empty when absent.
_db_section() { tr -d '\r' < "$1/commands/help.md" | awk '/^## /{on = ($0 == "## Your AI database")} on'; }

# Print every part of the database how-to the help text does not carry. Empty output means complete.
_db_missing() {
    local root="$1" sec step sub
    sec="$(_db_section "$root")"
    [ -n "$sec" ] || { echo 'section "## Your AI database"'; return; }
    for step in "${DB_STEPS[@]}"; do
        # One bullet per step: "- **<step>:**" followed by an example request in double quotes.
        printf '%s\n' "$sec" | grep -Fq -- "- **${step}:** \"" || echo "step \"${step}\" with an example request"
    done
    for sub in $(_subcommands "$root" database); do
        printf '%s\n' "$sec" | grep -Eq "/mmry:database ${sub}([^a-z]|\$)" || echo "database subcommand ${sub} in the section"
    done
}

@test "help: carries the database how-to as its own section, each step with an example request (#32442)" {
    local root; root="$(_root)"
    run _db_missing "$root"
    [ -z "$output" ] || { echo "help.md database section does not carry:"; echo "$output"; return 1; }
}

@test "help: a database how-to missing its section or a step is refused, naming it (#32442)" {
    local root copy; root="$(_root)"
    copy="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$copy"
    cp -R "$root/commands" "$copy/commands"
    # A step with no example request is named.
    sed -i.bak 's/^- \*\*Correct an entry:\*\* "/- **Correct an entry:** /' "$copy/commands/help.md"
    run _db_missing "$copy"
    [[ "$output" == *'step "Correct an entry"'* ]] || { echo "step not named: $output"; return 1; }
    # A help with no database section at all is named.
    sed -i.bak 's/^## Your AI database$/## Something else/' "$copy/commands/help.md"
    run _db_missing "$copy"
    [[ "$output" == *'section "## Your AI database"'* ]] || { echo "section not named: $output"; return 1; }
}

@test "help: carries no Memory types section" {
    local help; help="$(_root)/commands/help.md"
    run grep -inE 'memory types|strategic|momentary' "$help"
    [ "$status" -eq 1 ] || { echo "found: $output"; return 1; }
}

@test "help: opens with the instruction to show the text verbatim" {
    local help; help="$(_root)/commands/help.md"
    run grep -inE 'verbatim' <(head -5 "$help")
    [ "$status" -eq 0 ] || { echo "no verbatim instruction in the first lines"; return 1; }
}

# ------------------------------------------------------------------------------------------------
# #32606 (DD-159): one help source per platform, each held complete against that platform's real
# surface. The Claude Code checks above are unchanged. Below, the Codex help skill and the
# connector's help.
#
# CODEX. The one help text is skills-codex/help/SKILL.md (Codex lists it as mmry:help). Three lists
# are derived from shipped files, never typed here:
#   1. every tool hooks-handlers/mcp-server.sh publishes: a four-space "name": "word" line in its
#      tool list (a parameter's "name" is indented deeper, so it never matches);
#   2. every script the Codex memory skill tells the assistant to run, as hooks-handlers/x.sh or
#      setup/x.sh;
#   3. the Foundation status check, hooks-handlers/foundation-status.sh.
#
# CONNECTOR. The one help text is src/Mnemo.Api/Mcp/ConnectorHelp.md in the API repository, which
# is private, so plugin CI cannot read it. These tests run against an API checkout named by
# MMRY_API_ROOT and are skipped, saying so, without one. The API's own CI gate is
# ConnectorHelpTests (dotnet test), which checks the same text against the tools and prompts by
# reflection.
# ------------------------------------------------------------------------------------------------

# The tools mcp-server.sh publishes to Codex, one per line.
_codex_tools() { tr -d '\r' < "$1/hooks-handlers/mcp-server.sh" | grep -oE '^    "name": "[a-z_]+"' | sed -E 's/.*"([a-z_]+)"$/\1/'; }

# The scripts the Codex memory skill runs, by file name, one per line.
_codex_scripts() {
    tr -d '\r' < "$1/skills-codex/memory-system/SKILL.md" \
        | grep -oE '(hooks-handlers|setup)/[a-z-]+\.sh' | sed 's#.*/##' | sort -u
}

# Print everything the Codex help skill does not name. Empty output means complete.
_codex_missing() {
    local root="$1" help="$1/skills-codex/help/SKILL.md" t s
    [ -f "$help" ] || { echo "skills-codex/help/SKILL.md (no Codex help skill)"; return 0; }
    for t in $(_codex_tools "$root"); do
        grep -Eq "(^|[^a-z_])${t}([^a-z_]|\$)" "$help" || echo "codex tool ${t} (hooks-handlers/mcp-server.sh)"
    done
    for s in $(_codex_scripts "$root"); do
        grep -Fq "$s" "$help" || echo "codex script ${s} (skills-codex/memory-system/SKILL.md)"
    done
    grep -Fq "foundation-status.sh" "$help" || echo "codex Foundation check foundation-status.sh"
}

@test "help (codex): the help skill is packaged where the Codex manifest finds skills, named help" {
    local root skills help; root="$(_root)"
    skills="$(jq -r '.skills' "$root/.codex-plugin/plugin.json" | tr -d '\r')"
    [ "$skills" = "./skills-codex/" ] || { echo "Codex skills path is $skills"; return 1; }
    help="$root/skills-codex/help/SKILL.md"
    [ -f "$help" ] || { echo "no $help"; return 1; }
    # A direct child of the skills folder, with frontmatter naming it "help": Codex lists a
    # plugin's skills prefixed with the plugin's name, so the customer calls it mmry:help.
    [ "$(tr -d '\r' < "$help" | head -1)" = "---" ] || { echo "no frontmatter"; return 1; }
    tr -d '\r' < "$help" | sed -n '2,6p' | grep -qx 'name: help' || { echo "frontmatter does not say name: help"; return 1; }
    tr -d '\r' < "$help" | sed -n '2,6p' | grep -q '^description: ' || { echo "no description"; return 1; }
    # Claude Code has /mmry:help; its skills folder does not get a second help.
    [ ! -e "$root/skills/help" ] || { echo "skills/help exists for Claude Code"; return 1; }
}

@test "help (codex): names every Codex tool, every script operation and the Foundation check" {
    local root; root="$(_root)"
    run _codex_missing "$root"
    [ -z "$output" ] || { echo "skills-codex/help/SKILL.md does not name:"; echo "$output"; return 1; }
}

@test "help (codex): the derived lists are not empty and hold the known members" {
    local root tools scripts t s; root="$(_root)"
    tools="$(_codex_tools "$root" | tr '\n' ' ')"
    [ "$(_codex_tools "$root" | wc -l)" -ge 15 ] || { echo "only: $tools"; return 1; }
    for t in memory_save memory_search memory_retire memory_load formation_start formation_status formation_leave; do
        [[ " $tools" == *" $t "* ]] || { echo "missing $t in: $tools"; return 1; }
    done
    # A parameter's "name" never leaks in as a tool.
    [[ " $tools" != *" name "* ]] || { echo "parameter leaked: $tools"; return 1; }
    scripts="$(_codex_scripts "$root" | tr '\n' ' ')"
    [ "$(_codex_scripts "$root" | wc -l)" -ge 10 ] || { echo "only: $scripts"; return 1; }
    for s in visibility.sh submit-feedback.sh mmry-setup.sh save-record.sh tools-check.sh; do
        [[ " $scripts" == *" $s "* ]] || { echo "missing $s in: $scripts"; return 1; }
    done
}

@test "help (codex): a tool added to the Codex tool server with no help line is refused, naming it" {
    local root copy; root="$(_root)"
    copy="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$copy/hooks-handlers"
    cp -R "$root/skills-codex" "$copy/skills-codex"
    { cat "$root/hooks-handlers/mcp-server.sh"; printf '    "name": "zz_fake_tool",\n'; } > "$copy/hooks-handlers/mcp-server.sh"
    run _codex_missing "$copy"
    [[ "$output" == *"codex tool zz_fake_tool"* ]] || { echo "not named: $output"; return 1; }
}

@test "help (codex): a help skill that leaves a capability out is refused, naming it" {
    local root copy; root="$(_root)"
    copy="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$copy/hooks-handlers"
    cp -R "$root/skills-codex" "$copy/skills-codex"
    cp "$root/hooks-handlers/mcp-server.sh" "$copy/hooks-handlers/"
    sed -i.bak -e 's/formation_report/the close-out tool/g' -e 's/foundation-status\.sh/the status script/g' \
        "$copy/skills-codex/help/SKILL.md"
    run _codex_missing "$copy"
    [[ "$output" == *"codex tool formation_report"* ]] || { echo "tool not named: $output"; return 1; }
    [[ "$output" == *"foundation-status.sh"* ]] || { echo "Foundation check not named: $output"; return 1; }
}

@test "help (codex): opens, after its frontmatter, with the instruction to show the text verbatim" {
    local help; help="$(_root)/skills-codex/help/SKILL.md"
    run grep -inE 'verbatim' <(tr -d '\r' < "$help" | awk 'n>=2 {print} /^---$/ {n++}' | head -6)
    [ "$status" -eq 0 ] || { echo "no verbatim instruction after the frontmatter"; return 1; }
}

# The connector's tools and prompts, read from the [McpServerTool] and [McpServerPrompt] attributes
# the API's tools/list and prompts/list are built from. A prompt named by a constant (Name = Name)
# is resolved to that file's `const string Name = "..."`.
_connector_names() {
    local mcp="$1/src/Mnemo.Api/Mcp" f
    cat "$mcp"/*.cs | tr -d '\r' | grep -oE 'McpServer(Tool|Prompt)\(Name = "[a-z_-]+"' | sed -E 's/.*"([a-z_-]+)"$/\1/'
    for f in "$mcp"/*.cs; do
        if tr -d '\r' < "$f" | grep -q 'McpServerPrompt(Name = Name'; then
            tr -d '\r' < "$f" | grep -oE 'const string Name = "[a-z_-]+"' | sed -E 's/.*"([a-z_-]+)"$/\1/'
        fi
    done
}

_connector_missing() {
    local api="$1" help="$1/src/Mnemo.Api/Mcp/ConnectorHelp.md" n
    [ -f "$help" ] || { echo "src/Mnemo.Api/Mcp/ConnectorHelp.md (no connector help)"; return 0; }
    for n in $(_connector_names "$api" | sort -u); do
        tr -d '\r' < "$help" | grep -Eq "(^|[^A-Za-z0-9_-])${n}([^A-Za-z0-9_-]|\$)" || echo "connector ${n}"
    done
}

_api_root() {
    [ -n "${MMRY_API_ROOT:-}" ] && [ -d "$MMRY_API_ROOT/src/Mnemo.Api/Mcp" ] && return 0
    skip "MMRY_API_ROOT is not set to an MMRY API checkout. The API repository is private; its CI gate for the connector help is ConnectorHelpTests (dotnet test)."
}

@test "help (connector): names every tool and prompt the connector publishes" {
    _api_root
    local n; n="$(_connector_names "$MMRY_API_ROOT" | sort -u | wc -l)"
    [ "$n" -ge 34 ] || { echo "only $n connector tools and prompts found"; return 1; }
    run _connector_missing "$MMRY_API_ROOT"
    [ -z "$output" ] || { echo "ConnectorHelp.md does not name:"; echo "$output"; return 1; }
}

@test "help (connector): a help text that leaves a tool out is refused, naming it" {
    _api_root
    local copy="$BATS_TEST_TMPDIR/api/src/Mnemo.Api/Mcp"; mkdir -p "$copy"
    cp "$MMRY_API_ROOT"/src/Mnemo.Api/Mcp/*.cs "$MMRY_API_ROOT"/src/Mnemo.Api/Mcp/ConnectorHelp.md "$copy/"
    sed -i.bak 's/mmry_forget/the forget tool/g' "$copy/ConnectorHelp.md"
    run _connector_missing "$BATS_TEST_TMPDIR/api"
    [ "$output" = "connector mmry_forget" ] || { echo "got: $output"; return 1; }
}
