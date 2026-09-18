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

# ---------------------------------------------------------------------------------------------
# THE CUSTOMER-FACING PAGE, CHECKED ON ITS COMMANDS RATHER THAN ITS VOCABULARY
#
# The check this replaces asserted that docs/codex.md mentions CODEX_HOME AT LEAST ONCE, in two
# lines of which the second could not fail: `grep -c` already exits non-zero when the count is
# zero, so `[ "$output" -ge 1 ]` was re-stating a test that had just been made. It passed happily
# while the page carried four hard-coded ~/.codex paths, two of them commands a customer is told to
# run - which on a relocated Codex home name a directory that does not exist. A mention is not a
# property of the instructions; these tests are about the instructions (#31245 QA round 3).
# ---------------------------------------------------------------------------------------------

_codex_doc() { printf '%s' "$(cd "$PLUGIN_ROOT/.." && pwd)/docs/codex.md"; }

# Every line of the document a customer could paste into a shell. Fenced blocks whose content is a
# shell command, and inline `code` after the word "Run".
_runnable_lines() {
    local doc; doc="$(_codex_doc)"
    grep -nE '(^[[:space:]]*bash |Run `)' "$doc" || true
}

@test "docs: the customer-facing page has runnable commands at all" {
    # Without this the two tests below are satisfied by a page with no commands in it.
    local n; n="$(_runnable_lines | wc -l | tr -d ' ')"
    [ "$n" -ge 2 ] || { echo "found $n runnable lines; the page is supposed to tell people what to run"; return 1; }
}

@test "docs: no runnable command on the page hard-codes ~/.codex" {
    # A customer who set CODEX_HOME gets "No such file or directory", which names nothing.
    local bad
    bad="$(_runnable_lines | grep -F '~/.codex' || true)"
    [[ -z "$bad" ]] || {
        echo "these runnable commands name a path that does not exist on a relocated Codex home:"
        printf '%s\n' "$bad"
        return 1
    }
}

@test "docs: every runnable command on the page uses the relocatable form" {
    local line missing=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *'.codex'* ]] || continue    # commands that name no Codex path are fine
        [[ "$line" == *'CODEX_HOME:-$HOME/.codex'* ]] || missing="${missing}
  ${line}"
    done < <(_runnable_lines)
    [[ -z "$missing" ]] || {
        echo "these runnable commands are not written in the form that survives a moved home:${missing}"
        return 1
    }
}

@test "docs: and the page still explains WHY the commands are written that way" {
    # The form is unusual enough that a customer will wonder. Losing the explanation would leave
    # the commands looking like a typo.
    run grep -c 'CODEX_HOME' "$(_codex_doc)"
    [ "$output" -ge 3 ]
}

# ---------------------------------------------------------------------------------------------
# THE WINDOWS UNINSTALLER IS CLAUDE CODE'S, AND SAYS SO (#31245 QA round 2)
#
# session-init.sh copies setup/*.bat into the host's MMRY directory, so on Windows Codex a copy of
# uninstall.bat lands under the Codex home. Everything in that file names ~/.claude - the
# credential, the state directory, the plugin cache, the settings file - so running the Codex copy
# would uninstall the OTHER product and leave the Codex install exactly where it was.
# ---------------------------------------------------------------------------------------------

@test "codex: the Windows uninstaller carries all three guard clauses" {
    local f="$PLUGIN_ROOT/setup/uninstall.bat"
    grep -q 'goto :codex_install' "$f"
    grep -q ':codex_install' "$f"
    grep -q 'uninstalls the CLAUDE CODE installation' "$f"
    # 1. The install marker, which is the only signal that survives a relocated home with nothing
    #    exported - the hole QA found in round 2's guard.
    grep -qF '.mmry-host' "$f"
    # 2. CODEX_HOME, guarded by `if defined` because findstr with an empty pattern matches
    #    everything and would refuse on every machine on earth. The value is COPIED and its
    #    trailing separator stripped before it reaches findstr (#31245 QA round 4) - passing
    #    %CODEX_HOME% straight through is the defect, not the fix, so the raw variable must NOT
    #    appear inside a findstr pattern anywhere in this file.
    grep -qF 'set "MMRY_CODEX_HOME=%CODEX_HOME%"' "$f"
    grep -qF 'if defined MMRY_CODEX_HOME' "$f"
    run grep -cF 'findstr /i /l /c:"%CODEX_HOME%"' "$f"
    assert_output "0"
    # 3. The literal segment. The pattern must not end in a backslash: in a cmd string \" escapes
    #    the quote and findstr then gets a pattern that never matches, which is how the first
    #    version of this guard silently did nothing.
    run grep -cF 'findstr /i /l /c:"\.codex"' "$f"
    assert_output "1"
}

# EXECUTED, NOT READ - AND SAFE TO EXECUTE (#31245 QA round 3).
#
# Round 2 left this as a source check because running cmd.exe from bats under Git Bash dropped into
# an INTERACTIVE cmd and hung the suite. The cause was path conversion mangling the /c switch;
# MSYS_NO_PATHCONV=1 with stdin closed runs it properly, which was established on 2026-09-16.
#
# Only the REFUSAL cases are executed, and USERPROFILE is pointed at a temporary directory for the
# run. So a guard that failed to fire would uninstall from an empty temp profile - visible in the
# assertions, harmless to the developer's own machine - rather than from their real one.
# THE PLATFORM CHECK IS ITS OWN FUNCTION AND IS CALLED FROM THE TEST BODY, NOT FROM INSIDE _run_bat.
# `skip` inside a function invoked through `run` does not skip anything - run captures it as a
# failed command - so a Linux box reported three failures here instead of three skips. Found on a
# Debian container on 2026-09-16 while re-measuring the Linux count.
_require_windows_shell() {
    command -v cmd.exe >/dev/null 2>&1 || skip "cmd.exe is not available on this platform"
    command -v cygpath >/dev/null 2>&1 || skip "cygpath is needed to hand cmd.exe a Windows path"
}

_run_bat() {
    local batdir="$1"; shift
    local profile="$TEST_TMPDIR/winprofile"
    mkdir -p "$profile/.claude"
    MSYS_NO_PATHCONV=1 env USERPROFILE="$(cygpath -w "$profile")" "$@" \
        cmd.exe /c "$(cygpath -w "$batdir/uninstall.bat")" </dev/null 2>&1
}

_codex_tree() {
    local root="$1" marker="$2"
    mkdir -p "$root/setup"
    cp "$PLUGIN_ROOT/setup/uninstall.bat" "$root/setup/uninstall.bat"
    [[ -z "$marker" ]] || printf '%s\r\n' "$marker" > "$root/.mmry-host"
    printf '%s' "$root/setup"
}

@test "codex: executed - the marker alone makes the Windows uninstaller refuse" {
    _require_windows_shell
    local d; d="$(_codex_tree "$TEST_TMPDIR/relocated-marker" "codex")"
    run _run_bat "$d" env
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed nothing"* ]]
}

@test "codex: executed - CODEX_HOME alone makes it refuse, with no .codex in the path" {
    _require_windows_shell
    local d; d="$(_codex_tree "$TEST_TMPDIR/relocated-envvar" "")"
    run _run_bat "$d" env CODEX_HOME="$(cygpath -w "$TEST_TMPDIR/relocated-envvar")"
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed nothing"* ]]
}

@test "codex: executed - a literal .codex segment still refuses, as it did before" {
    _require_windows_shell
    local d; d="$(_codex_tree "$TEST_TMPDIR/.codex/mmry" "")"
    run _run_bat "$d" env
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed nothing"* ]]
}

@test "req4: executed - a marker reading claude does NOT make it refuse" {
    _require_windows_shell
    # The control for the marker clause. Without it, a guard that refused on the mere presence of
    # a marker file would pass every test above and break every Windows Claude Code uninstall.
    local d; d="$(_codex_tree "$TEST_TMPDIR/claude-marker" "claude")"
    run _run_bat "$d" env
    [ "$status" -eq 0 ]
    [[ "$output" != *"changed nothing"* ]]
}

@test "req4: the Claude Code uninstall path in that file is untouched by the guard" {
    # The guard is a branch taken before anything else; everything the Claude uninstall does must
    # still be there, and the file must still end by telling the customer to restart Claude Code.
    local f="$PLUGIN_ROOT/setup/uninstall.bat"
    grep -q "Remove-Item \$configPath -Force" "$f"
    grep -q 'Restart Claude Code to take effect' "$f"
    grep -q "Join-Path \$env:USERPROFILE '.claude" "$f"
}

# ---------------------------------------------------------------------------------------------
# THE TRAILING BACKSLASH, EXECUTED (#31245 QA round 4).
#
# CODEX_HOME=C:\Users\x\.codex\ expands inside the findstr pattern as ...\.codex\", where the \"
# escapes the closing quote and findstr receives a pattern that can never match. The guard
# silently did nothing and the full CLAUDE uninstall proceeded on a Codex machine.
#
# This is the exact failure mode the comment above clause 3 of that file already documented for
# the literal pattern, which was never applied to the variable one. A trailing backslash is what
# tab-completion in cmd hands you, so it is the common spelling rather than an exotic one.
#
# Executed rather than read, through the same MSYS_NO_PATHCONV harness as the four cases above,
# and only on the REFUSAL path with USERPROFILE pointed at a temporary directory.

@test "codex: executed - a CODEX_HOME with a trailing backslash still makes it refuse" {
    _require_windows_shell
    local d; d="$(_codex_tree "$TEST_TMPDIR/relocated-trailing" "")"
    # cygpath -w gives no trailing separator, so one is appended deliberately - this is the
    # spelling under test, not an accident of the harness.
    run _run_bat "$d" env CODEX_HOME="$(cygpath -w "$TEST_TMPDIR/relocated-trailing")\\"
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed nothing"* ]]
}

@test "codex: executed - and a trailing forward slash too" {
    _require_windows_shell
    local d; d="$(_codex_tree "$TEST_TMPDIR/relocated-trailing-fwd" "")"
    run _run_bat "$d" env CODEX_HOME="$(cygpath -w "$TEST_TMPDIR/relocated-trailing-fwd")/"
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed nothing"* ]]
}

# ---------------------------------------------------------------------------------------------
# REACHABILITY (#31245 QA round 4).
#
# A platform nobody can find is not shipped. At round 3 the marketplace manifest still described
# the product as being for Claude Code, so the first sentence a Codex customer read named the
# other product; neither README contained the word Codex; docs/codex.md claimed "everything the
# memory system can do" while six of thirteen formation operations have no Codex surface; and
# uninstall appeared zero times across all three Codex customer surfaces while both uninstallers
# tell the customer to remove the plugin through Codex.
#
# THE SIX-MISSING-OPERATIONS ASSERTIONS ARE NOW PARITY ASSERTIONS (#31245 QA round 6). Those six
# were held back for one reason: the messages they printed named typed slash commands. That is
# fixed, so the operations are documented and the pages that said otherwise were made accurate.
# The invariant worth keeping is not "six are missing" - it is that THE PAGES AND THE CODE AGREE
# about what a Codex customer can run, in both directions, which is what the pair below asserts.

@test "reach: the marketplace description names Codex, not only the other product" {
    local f="$PLUGIN_ROOT/../.claude-plugin/marketplace.json"
    [[ -f "$f" ]]
    local desc
    desc="$(jq -r '.plugins[0].description' "$f")"
    [[ -n "$desc" && "$desc" != "null" ]]
    [[ "$desc" == *"Codex"* ]]
}

@test "reach: both READMEs point a Codex customer somewhere before the Claude instructions" {
    grep -qi 'codex' "$PLUGIN_ROOT/README.md"
    grep -qi 'codex' "$PLUGIN_ROOT/../README.md"
    # And not merely a passing mention - they must route to the page that has the real
    # instructions, because the Claude setup command writes the wrong account's credential.
    grep -q 'docs/codex.md' "$PLUGIN_ROOT/README.md"
    grep -q 'docs/codex.md' "$PLUGIN_ROOT/../README.md"
}

@test "reach: the customer page does not claim the whole feature set" {
    # The exact overclaim, asserted as absent by its own words.
    run grep -c 'Everything the memory system can do' "$PLUGIN_ROOT/../docs/codex.md"
    assert_output "0"
}

@test "reach: the customer page no longer claims formation operations are missing that are not" {
    local f="$PLUGIN_ROOT/../docs/codex.md"
    # The exact overclaim in the other direction, asserted as absent by its own words. A page that
    # under-promises sends a customer looking for a Claude Code machine they do not need.
    run grep -c 'have no Codex surface yet' "$f"
    assert_output "0"
    run grep -c 'Formations work, for six operations' "$f"
    assert_output "0"
    # And the four things that ARE genuinely unavailable are still named, so the section did not
    # get emptied out along with the stale claim.
    grep -qi 'no slash commands' "$f"
    grep -qi 'before your conversation is trimmed' "$f"
    grep -qi 'not wake an idle session' "$f"
    grep -qi 'no plan-accepted prompt' "$f"
}

@test "reach: every customer formation operation is documented on the Codex surface" {
    # PARITY, DERIVED FROM THE FILESYSTEM RATHER THAN FROM A LIST SOMEBODY MAINTAINS. Every
    # formation-*.sh in hooks-handlers/ is copied to a Codex install by session-init.sh and is
    # runnable there, so every one of them that is a CUSTOMER operation has to appear in the
    # skill. A hardcoded list here is how the doc and the code drift apart again.
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    local f base op missing=""
    for f in "$PLUGIN_ROOT"/hooks-handlers/formation-*.sh; do
        base="$(basename "$f")"
        op="${base#formation-}"; op="${op%.sh}"
        # state and check are internal: state is the local session-to-formation record that the
        # other handlers read and write, and check is the delivery hook. Neither is an operation
        # a customer performs, on either host - commands/formation.md names neither.
        case "$op" in state|check) continue ;; esac
        grep -q "formation-${op}.sh" "$skill" || missing="${missing} ${op}"
    done
    [ -z "$missing" ] || {
        echo "these formation operations run on Codex but are not documented in the skill:${missing}" >&2
        return 1
    }
}

@test "reach: and the internal formation scripts are NOT presented to customers as operations" {
    # The other half of the parity. Without it the test above is satisfied by a skill that lists
    # every file in the directory, including the two that are not operations.
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" op
    for op in state check; do
        run grep -c "formation-${op}.sh" "$skill"
        assert_output "0"
    done
}

@test "reach: uninstall is documented on the Codex surfaces that customers actually reach" {
    # Both uninstaller scripts refuse on Codex and tell the customer to remove the plugin
    # through Codex - advice that appeared in no Codex-facing document at all.
    grep -qi 'removing mmry from codex' "$PLUGIN_ROOT/../docs/codex.md"
    grep -qi 'removing mmry from codex' "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    # And the step that actually disconnects the machine is named in both.
    grep -q 'mmry-config.json' "$PLUGIN_ROOT/../docs/codex.md"
    grep -q 'mmry-config.json' "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
}

@test "reach: the skill steers off the uninstallers that would remove the OTHER product" {
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    grep -qi 'do NOT point them at uninstall' "$skill"
}
