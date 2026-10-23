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
