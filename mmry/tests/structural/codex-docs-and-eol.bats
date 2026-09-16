#!/usr/bin/env bats
# codex-docs-and-eol.bats — two things a customer receives that nothing was checking (#31245 QA
# round 2): the BYTES of the Windows entry point, and whether the documentation tells them to run a
# path that exists on their machine.
#
# WHY THE BYTES. codex-hook.cmd is committed LF. .gitattributes pinned *.sh and nothing else, and
# core.autocrlf decides the rest - so the file a customer executed was CRLF on one machine and LF
# on another, from the same commit, and only the CRLF form had ever been run. That was tolerable
# while the only Windows scripts were installers that run once. It is not tolerable now: every MMRY
# hook on Windows Codex routes through this .cmd, four registrations deep.
#
# WHY THE DOCUMENTATION. lib-host.sh honours CODEX_HOME, Codex's own documented override, and
# tests/handlers/codex-hook.bats asserts that a relocated home is resolved. The skill document then
# spelled ~/.codex/mmry/hooks-handlers/ twenty times and never mentioned the variable, so a
# customer who had moved their Codex home was handed twenty instructions naming a directory that
# does not exist on their machine - and the failure reads as "No such file or directory", which
# names nothing.

load '../helpers/test-helper'

REPO_ROOT=""

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
}

_require_git() {
    command -v git >/dev/null 2>&1 || skip "git is not on PATH; the attribute checks need it"
    git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
}

# ---------------------------------------------------------------------------------------------
# The bytes a customer receives
# ---------------------------------------------------------------------------------------------

@test "eol: every Windows script resolves to eol=crlf, so one commit is one file everywhere" {
    _require_git
    local f attr missing=""
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        attr="$(git -C "$REPO_ROOT" check-attr eol -- "$f" | sed 's/.*: //')"
        [[ "$attr" == "crlf" ]] || missing="${missing} ${f}(${attr})"
    done < <(git -C "$REPO_ROOT" ls-files '*.cmd' '*.bat' '*.ps1')
    [[ -z "$missing" ]] || {
        echo "these Windows scripts are not pinned to CRLF:${missing}"
        return 1
    }
}

@test "eol: every shell script and test file resolves to eol=lf, which is what the shebang needs" {
    # A .bats or .bash file with CRLF fails at `load` on Linux and macOS with an error that names a
    # carriage return. Found running this suite in a Linux container on 2026-09-16.
    _require_git
    local f attr wrong=""
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        attr="$(git -C "$REPO_ROOT" check-attr eol -- "$f" | sed 's/.*: //')"
        [[ "$attr" == "lf" ]] || wrong="${wrong} ${f}(${attr})"
    done < <(git -C "$REPO_ROOT" ls-files '*.sh' '*.bats' '*.bash')
    [[ -z "$wrong" ]] || {
        echo "these shell files are not pinned to LF:${wrong}"
        return 1
    }
}

@test "eol: the checked-out codex-hook.cmd really does carry CRLF, not just a rule saying so" {
    # The attribute is the instruction; this is the result. They come apart when a file was
    # committed before the rule existed and nobody re-normalised it.
    local cr lf
    cr="$(tr -cd '\r' < "$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" | wc -c | tr -d ' ')"
    lf="$(tr -cd '\n' < "$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" | wc -c | tr -d ' ')"
    [ "$lf" -gt 0 ]
    [ "$cr" -eq "$lf" ]
}

@test "eol: and the shell entry point beside it carries none, because Git Bash would choke on them" {
    local cr
    cr="$(tr -cd '\r' < "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" | wc -c | tr -d ' ')"
    [ "$cr" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------
# The paths the documentation hands a customer
# ---------------------------------------------------------------------------------------------

SKILL="mmry/skills-codex/memory-system/SKILL.md"

@test "docs: the Codex skill never tells the model to RUN a hard-coded ~/.codex path" {
    # Saying "~/.codex/mmry/..." in prose is fine. Putting it after `bash ` is an instruction to
    # execute it, and on a relocated Codex home that path does not exist.
    run grep -n 'bash ~/\.codex/' "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    [ "$status" -ne 0 ]
}

@test "docs: the Codex skill uses the form that survives a relocated Codex home" {
    run grep -c 'CODEX_HOME:-\$HOME/\.codex' "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 15 ]
}

@test "docs: every handler the skill tells the model to run actually exists" {
    # An instruction naming a script that is not there fails as "No such file or directory", which
    # tells the customer nothing about what went wrong.
    local name missing=""
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ -f "$PLUGIN_ROOT/hooks-handlers/$name" ]] || missing="${missing} ${name}"
    done < <(grep -o 'hooks-handlers/[A-Za-z0-9._-]*\.sh' "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" | sed 's|hooks-handlers/||' | sort -u)
    [[ -z "$missing" ]] || {
        echo "the skill names handlers that do not exist:${missing}"
        return 1
    }
}

@test "docs: the customer-facing Codex document says what happens if the Codex home was moved" {
    run grep -c 'CODEX_HOME' "$(cd "$PLUGIN_ROOT/.." && pwd)/docs/codex.md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------------------------
# THE WINDOWS UNINSTALLER IS CLAUDE CODE'S, AND SAYS SO (#31245 QA round 2)
#
# session-init.sh copies setup/*.bat into the host's MMRY directory, so on Windows Codex a copy of
# uninstall.bat lands under the Codex home. Everything in that file names ~/.claude - the
# credential, the state directory, the plugin cache, the settings file - so running the Codex copy
# would uninstall the OTHER product and leave the Codex install exactly where it was.
# ---------------------------------------------------------------------------------------------

@test "codex: the Windows uninstaller carries the guard that makes it refuse a Codex copy" {
    # A SOURCE CHECK, AND HONEST ABOUT IT. The behaviour was verified by EXECUTION on 2026-09-16 -
    # the Codex copy printed "uninstalls the CLAUDE CODE installation" and exited 1; the Claude copy
    # went on into the PowerShell block exactly as the pristine file does - but running cmd.exe from
    # bats under Git Bash mangles the /c switch and leaves an INTERACTIVE cmd waiting for input,
    # which hangs the suite. A test that can hang CI is worse than one that reads the file.
    local f="$PLUGIN_ROOT/setup/uninstall.bat"
    grep -q 'goto :codex_install' "$f"
    grep -q ':codex_install' "$f"
    grep -q 'uninstalls the CLAUDE CODE installation' "$f"
    # The pattern must not end in a backslash: in a cmd string \" escapes the quote and findstr
    # then gets a pattern that never matches. That is how the first version of this guard silently
    # did nothing, and only executing it showed that.
    run grep -cF 'findstr /i /l /c:"\.codex"' "$f"
    assert_output "1"
}

@test "req4: the Claude Code uninstall path in that file is untouched by the guard" {
    # The guard is a branch taken before anything else; everything the Claude uninstall does must
    # still be there, and the file must still end by telling the customer to restart Claude Code.
    local f="$PLUGIN_ROOT/setup/uninstall.bat"
    grep -q "Remove-Item \$configPath -Force" "$f"
    grep -q 'Restart Claude Code to take effect' "$f"
    grep -q "Join-Path \$env:USERPROFILE '.claude" "$f"
}
