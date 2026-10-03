#!/usr/bin/env bats
# codex-docs-and-eol.bats — two things a customer receives that nothing was checking (#31245 QA
# round 2): the BYTES of the Windows entry point, and whether the documentation tells them to run a
# path that exists on their machine.
#
# WHY THE BYTES. codex-hook.cmd was once committed LF. .gitattributes pinned *.sh and nothing else,
# and core.autocrlf decided the rest - so the file a customer executed was CRLF on one machine and
# LF on another, from the same commit. Tolerable while the only Windows scripts were installers
# that run once; not for a launcher every MMRY hook on Windows Codex starts through (all six
# registrations, since #31245 QA round 8).
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

@test "windows: the launcher every commandWindows names is shipped, and in CRLF bytes" {
    # HISTORY, so the next reader does not repeat it. codex-hook.cmd was the Windows entry point,
    # was deleted in #31245 QA round 7 as unreferenced, and is back since QA round 8: on a stock
    # Windows machine `sh` is not on PATH, so the `sh` registrations never ran, and the deletion of
    # commandWindows that left them as the only route was a misdiagnosis (PowerShell, not cmd, runs
    # Codex hooks on Windows; see structural/codex-manifest.bats). This test used to require the
    # file to be ABSENT. It now requires the opposite, and requires it to be the file that is named.
    local f="$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd"
    [[ -f "$f" ]] || { echo "commandWindows names codex-hook.cmd and it is not shipped"; return 1; }
    local named
    named="$(jq -r '[.hooks[][] .hooks[] | select((.commandWindows // "") | contains("codex-hook.cmd"))] | length' "$PLUGIN_ROOT/hooks/codex-hooks.json")"
    [[ "$named" -gt 0 ]] || { echo "the launcher ships but no registration names it"; return 1; }
    # cmd.exe runs LF-only batch files, mostly; "mostly" is not good enough for a file on the hot path
    # of every hook. Every line must end CRLF in the file as it sits in this tree.
    local total crlf
    total="$(wc -l < "$f" | tr -d '[:space:]')"
    crlf="$(grep -c $'\r$' "$f" || true)"
    [[ "$total" -gt 0 && "$total" == "$crlf" ]] || { echo "$crlf of $total lines end CRLF"; return 1; }
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
    # PowerShell lines too (#31245 QA round 8): the page's one PowerShell command hardcoded a Git
    # path and ignored CODEX_HOME while the page said every command was relocatable, and this helper
    # never saw it because it only matched lines starting with bash.
    grep -nE '(^[[:space:]]*bash |^[[:space:]]*& |Run `)' "$doc" || true
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
        [[ "$line" == *'CODEX_HOME:-$HOME/.codex'* || "$line" == *'$env:CODEX_HOME'* ]] || missing="${missing}
  ${line}"
    done < <(_runnable_lines)
    [[ -z "$missing" ]] || {
        echo "these runnable commands are not written in the form that survives a moved home:${missing}"
        return 1
    }
}

@test "docs: the reinstall a stuck customer is told to run is the one this page documents" {
    # session-init.sh prints mmry_host_plugin_recovery_ref when it cannot find the plugin files.
    # On Codex that is an install command, and an install command stated in two places is an
    # install command that will disagree with itself. The handler's answer must appear verbatim
    # on the page a customer is sent to.
    local ref
    ref="$(env -u MMRY_CONFIG_FILE MMRY_HOST=codex CODEX_HOME="$BATS_TEST_TMPDIR/ch" HOME="$BATS_TEST_TMPDIR/h" \
        bash -c "source '$PLUGIN_ROOT/hooks-handlers/lib-host.sh'; mmry_host_plugin_recovery_ref")"
    [[ -n "$ref" ]] || { echo "the handler printed no remedy at all"; return 1; }
    grep -Fq "$ref" "$(_codex_doc)" || {
        echo "the handler tells a stuck customer to run:"
        echo "  $ref"
        echo "and docs/codex.md does not contain that command anywhere."
        return 1
    }
}

@test "req4: and on Claude that remedy is a command, not an instruction to reinstall anything" {
    # The Claude half is pinned here as well, because the test above is satisfied on Claude by any
    # string that happens to appear in a Codex document.
    local ref
    ref="$(env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$BATS_TEST_TMPDIR/h2" \
        bash -c "source '$PLUGIN_ROOT/hooks-handlers/lib-host.sh'; mmry_host_plugin_recovery_ref")"
    [ "$ref" = "/mmry:setup" ]
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
    [[ -f "$f" ]] || return 1
    local desc
    desc="$(jq -r '.plugins[0].description' "$f")"
    [[ -n "$desc" && "$desc" != "null" ]] || return 1
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

@test "docs: Windows customers are steered off the shell that silently resolves to WSL" {
    # Eric hit this live: pasting the documented command into PowerShell on a machine with WSL
    # started the Linux bash, which cannot see Windows paths, and failed with "Failed to translate"
    # and execvpe(/bin/bash). Requirement 3 says install without hand-editing; that needed a
    # hand-edit to get past.
    local doc; doc="$(_codex_doc)"
    grep -q "Git Bash window" "$doc" || { echo "the page does not say which shell to use on Windows"; return 1; }
    grep -qi "Windows Subsystem for Linux" "$doc" || { echo "the page does not name the trap"; return 1; }
    grep -q "Failed to translate" "$doc" || { echo "the page does not name the error a customer will actually see"; return 1; }
}

@test "docs: the page offers a Windows invocation that cannot pick the wrong shell" {
    local doc; doc="$(_codex_doc)"
    # Git for Windows' own bash from its bin folder, located from the git on PATH rather than from a typed-in
    # install folder (#31245 QA round 8: the old line hardcoded C:\Program Files\Git and ignored
    # CODEX_HOME, on a page that said every command was relocatable).
    grep -q "bin.bash.exe" "$doc" || { echo "no explicit interpreter form for PowerShell users"; return 1; }
    # Round 9: from git --exec-path, not by splitting the path of git.exe, which lands in Git\mingw64
    # when that folder is on PATH. structural/codex-windows-commands.bats runs the derivation.
    grep -q "git --exec-path" "$doc" || { echo "the PowerShell form does not locate Git from git --exec-path"; return 1; }
    ! grep -q "Program Files.Git.bin.bash.exe" "$doc" || { echo "the PowerShell form hardcodes an install folder"; return 1; }
}

@test "docs: every documentation URL the installer prints names a file that exists in this repo" {
    # The installer's closing line sends customers to the capability page. If that path is ever
    # renamed, the link rots silently and the customer meets a 404 at the exact moment they are
    # being told what is and is not available.
    local repo; repo="$(cd "$PLUGIN_ROOT/.." && pwd)"
    local url rel missing=""
    while IFS= read -r url; do
        rel="${url#*github.com/MMRY-AI/mmry-plugin/blob/master/}"
        [[ -n "$rel" && "$rel" != "$url" ]] || continue
        [[ -f "$repo/$rel" ]] || missing="${missing} $rel"
    done < <(grep -ohE 'https://github.com/MMRY-AI/mmry-plugin/blob/master/[A-Za-z0-9_./-]+' \
             "$PLUGIN_ROOT"/setup/*.sh "$PLUGIN_ROOT"/hooks-handlers/*.sh 2>/dev/null | sort -u)
    [[ -z "$missing" ]] || { echo "the installer links to files this repo does not contain:${missing}"; return 1; }
}

@test "skill: joining a formation is steered away from the connector tools" {
    # THE DEFECT THIS PREVENTS, observed twice on a real machine 2026-09-21. Asked in plain words
    # to join a formation, a Codex session reaches for the mmry_formation_* connector tools,
    # because they are native and right in front of it. The connector enrols the member under ITS
    # identity; the PostToolUse hook polls for the identity Codex gave the session. They never
    # match, so the session appears on the roster, reports inFormation true, and NEVER receives a
    # pushed message. Nothing errors and nothing warns.
    #
    # Two directed messages were lost to this before the handler path was forced by hand.
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    grep -q "mmry_formation_\*" "$skill" || { echo "the skill never names the connector tools"; return 1; }
    grep -qi "not the .mmry_formation" "$skill" || { echo "the skill does not steer joins away from them"; return 1; }
    grep -qi "will ever arrive" "$skill" || { echo "the skill does not say what goes wrong"; return 1; }
    grep -qi "Nothing errors" "$skill" || { echo "the skill does not warn that the failure is silent"; return 1; }
}

@test "docs: no customer surface promises a moment Codex does not have" {
    # THE DRIFT THIS PREVENTS, and the two ways an earlier version of it failed to (#31245).
    #
    # The save prompt was designed to fire on Stop. The customer page, the Codex skill and the hook
    # manifest all said so in customer-facing words: "at the end of each turn", "before the session
    # ends". It then moved to UserPromptSubmit, which is the customer's NEXT message, with a
    # suppression gate. Three texts were corrected and a guard written over THOSE THREE FILES for
    # THOSE TWO PHRASES.
    #
    # ROUND 7 FOUND THREE MORE AT THE SAME COMMIT, on surfaces that guard never looked at: the
    # Codex storefront listing in .codex-plugin/plugin.json, which is the one text a customer reads
    # BEFORE they can check anything; a summary row on docs/codex.md that contradicted the prose
    # eleven lines further down the same page; and both READMEs, which name Codex and then list
    # saving at session end, at context compression and on plan acceptance, three behaviours the
    # Codex page documents as unavailable. A guard keyed to the files somebody happened to edit
    # only ever proves they edited them.
    #
    # THEN THE FIRST REWRITE OF THIS TEST, swept over every surface but compared LINE BY LINE, and
    # a deliberate re-introduction of the storefront string SURVIVED it. That JSON value is one
    # very long line carrying both the bad promise and, forty words later, an unrelated sentence
    # containing "not available". The line looked like a disclosure and was skipped. So the unit
    # here is a SENTENCE or a TABLE CELL, never a line: a qualification has to sit next to the
    # claim it qualifies, which is also the only version a customer reads correctly.
    #
    # ROUND 8 FOUND THE TABLE EXEMPTION. A table row was judged as header plus row, and a header
    # containing "claude code |" counted as a disclosure, so the comparison table added to the root
    # README to FIX this defect exempted every row in both columns: rewriting its Codex column to
    # promise a save prompt at session end passed. A row is now judged one CELL at a time, each cell
    # read with the row's label and against ITS OWN column header. A cell under a column headed
    # Claude Code only may describe Claude Code; any other cell is judged on what it says.
    #
    # ROUND 8 ALSO FOUND THIS TEST COULD NOT RUN ON macOS. It used mapfile, a bash 4 builtin, and the
    # floor this product documents is the bash 3.2 macOS ships; and it split sentences with a sed
    # expression whose newline-in-the-replacement is a GNU extension BSD sed does not honour. Lines
    # are now read with a plain while-read loop and sentences are split by parameter expansion,
    # both bash 3.2.
    #
    # AND THE SURFACE LIST IS DISCOVERED, NOT TYPED IN. Six hardcoded paths meant a new customer
    # document that names Codex escaped the guard silently. Every shipped .md and .json outside the
    # tests, the vendored tools, the internal design notes and the captured test evidence that mentions Codex is swept; a path
    # that itself names Codex is a Codex-only surface. The six original paths are asserted to be in
    # the discovered set, so the discovery cannot quietly lose one.
    local f bad="" nl
    nl='
'
    local -a _lines _codex_only _shared

    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        grep -qi "codex" "$f" || continue
        case "$(printf '%s' "${f#$REPO_ROOT/}" | tr 'A-Z' 'a-z')" in
            *codex*) _codex_only[${#_codex_only[@]}]="$f" ;;
            *)       _shared[${#_shared[@]}]="$f" ;;
        esac
    done < <(find "$REPO_ROOT" \
                \( -name .git -o -name tests -o -name vendor -o -name node_modules -o -name superpowers -o -name evidence \) -prune \
                -o -type f \( -name '*.md' -o -name '*.json' \) -print | sort)

    local must _found
    for must in \
        "$REPO_ROOT/docs/codex.md" \
        "$PLUGIN_ROOT/.codex-plugin/plugin.json" \
        "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" \
        "$PLUGIN_ROOT/hooks/codex-hooks.json" \
        "$REPO_ROOT/README.md" \
        "$PLUGIN_ROOT/README.md"; do
        [[ -f "$must" ]] || { echo "a surface this test must sweep is missing: $must"; return 1; }
        _found=""
        for f in "${_codex_only[@]}" "${_shared[@]}"; do
            [[ "$f" -ef "$must" ]] && { _found=1; break; }
        done
        [[ -n "$_found" ]] || { echo "surface discovery lost a known customer surface: $must"; return 1; }
    done

    _promises_a_missing_moment() {
        local l; l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
        case "$l" in
            *"before the session ends"*)   return 0 ;;
            *"save at session end"*)       return 0 ;;
            *"at the end of a turn"*)      return 0 ;;
            *"at the end of each turn"*)   return 0 ;;
            *"end of a turn"*prompt*)      return 0 ;;
            *"session end"*prompt*)        return 0 ;;
            *prompt*"session end"*)        return 0 ;;
            *"context compression"*)       return 0 ;;
            # Round 9: a Codex cell saying "yes" beside these two README rows survived, because
            # the rows are worded "the context is compressed" and "an accepted plan".
            *"context is compressed"*)     return 0 ;;
            *"context compresses"*)        return 0 ;;
            *"accepted plan"*)             return 0 ;;
            *"plan accepted"*)             return 0 ;;
        esac
        return 1
    }

    # No table-syntax entry any more: a pipe is never part of what is judged, only cell text is.
    _is_disclosure() {
        local l; l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
        case "$l" in
            *"claude code only"*)          return 0 ;;
            *"on claude code"*)            return 0 ;;
            *"not available"*)             return 0 ;;
            *"no channel"*)                return 0 ;;
            *"do not exist"*)              return 0 ;;
            *"there is no"*)               return 0 ;;
            *"has no"*)                    return 0 ;;
            *"gives a plugin no"*)         return 0 ;;
            *cannot*)                      return 0 ;;
        esac
        return 1
    }

    # A header cell that names Claude Code and not Codex: the column is ABOUT Claude Code, so what a
    # cell under it says is true of Claude Code and is not a promise to a Codex customer.
    _is_claude_column() {
        local l; l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
        [[ "$l" == *"claude code"* && "$l" != *codex* ]] || return 1
    }

    # Print a markdown table row as one cell per line, outer pipes dropped. bash 3.2.
    _cells() {
        local row="$1"
        row="${row#"${row%%[![:space:]]*}"}"
        row="${row#|}"
        row="${row%"${row##*[![:space:]]}"}"
        row="${row%|}"
        printf '%s\n' "${row//|/$nl}"
    }

    local i j n subject header="" frag label cell hcell line
    local -a _h _r
    for f in "${_codex_only[@]}" "${_shared[@]}"; do
        # THE UNIT OF JUDGEMENT IS WHAT A READER TAKES IN AT ONCE, which is not a line: a sentence,
        # or a table cell read with its row label and its column header.
        _lines=()
        header=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            _lines[${#_lines[@]}]="${line%$'\r'}"
        done < "$f"
        n=${#_lines[@]}
        for ((i = 0; i < n; i++)); do
            # A separator row means the line before it was the header of this table.
            if [[ "${_lines[$i]}" =~ ^[[:space:]]*\|[-:[:space:]|]+$ ]]; then
                header=""
                [[ $i -gt 0 ]] && header="${_lines[$((i - 1))]}"
                continue
            fi
            if [[ "${_lines[$i]}" == *"|"* && -n "$header" ]]; then
                _h=(); _r=()
                while IFS= read -r cell; do _h[${#_h[@]}]="$cell"; done < <(_cells "$header")
                while IFS= read -r cell; do _r[${#_r[@]}]="$cell"; done < <(_cells "${_lines[$i]}")
                # The first cell is the row's LABEL. It is never judged alone, because a reader never
                # reads it alone: it is read with each cell beside it. A one-cell row has only a label.
                label="${_r[0]:-}"
                j=1
                [[ ${#_r[@]} -gt 1 ]] || j=0
                for ((; j < ${#_r[@]}; j++)); do
                    cell="${_r[$j]}"
                    hcell="${_h[$j]:-}"
                    _is_claude_column "$hcell" && continue
                    if [[ $j -eq 0 ]]; then subject="$cell"; else subject="${label} ${cell}"; fi
                    _promises_a_missing_moment "$subject" || continue
                    _is_disclosure "$subject" && continue
                    bad="${bad}${nl}  ${f#$REPO_ROOT/}: [${hcell}] ${subject}"
                done
                continue
            fi
            # A line with no pipe ends any table that was open.
            [[ "${_lines[$i]}" == *"|"* ]] || header=""
            # One sentence per line: ". " becomes ".<newline>". Parameter expansion, not sed.
            line="${_lines[$i]}"
            line="${line//. /.$nl}"
            # The "|| -n" keeps the last fragment, which has no trailing newline when the
            # here-string below is the only source; without it a single-sentence line was never
            # examined (caught by mutation in round 7).
            while IFS= read -r frag || [[ -n "$frag" ]]; do
                [[ -n "$frag" ]] || continue
                _promises_a_missing_moment "$frag" || continue
                _is_disclosure "$frag" && continue
                bad="${bad}${nl}  ${f#$REPO_ROOT/}: ${frag}"
            done < <(printf '%s\n' "$line")
        done
    done

    [ -z "$bad" ] || {
        echo "these customer-facing sentences promise a moment Codex has no channel at, without" >&2
        echo "saying in the same breath that it is Claude Code only:${bad}" >&2
        return 1
    }

    # And the positive statement has to be present, or the sweep above passes on a page that says
    # nothing at all about when the prompt actually arrives.
    local doc="$REPO_ROOT/docs/codex.md"
    grep -qi "save prompt arrives with your next message" "$doc"         || { echo "the page does not say when the save prompt actually arrives"; return 1; }
    grep -qi "if you have just saved, it stays quiet" "$doc"         || { echo "the page does not mention the suppression gate, so it overstates how often it fires"; return 1; }
    grep -qi "NEXT message" "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"         || { echo "the skill does not tell the assistant when the prompt actually lands"; return 1; }
    return 0
}

@test "docs: no published remedy names a setting the shipped code never reads" {
    # THE DEFECT THIS PREVENTS (#31245 QA round 7). docs/codex.md told a Windows customer whose
    # bash was in an unusual place to set MMRY_BASH, and the troubleshooting table repeated it as
    # the first thing to try for "nothing happens at all", which is the highest-severity Windows
    # failure there is.
    #
    # MMRY_BASH was read in exactly one file, hooks-handlers/codex-hook.cmd, and once the
    # registrations moved to `sh` NOTHING launched that file. So the only self-serve remedy
    # published for the worst Windows symptom could not take effect, and support reading the same
    # table would have handed the customer the same inert advice.
    #
    # A remedy nobody can carry out is worse than no remedy: it ends the conversation.
    local doc="$REPO_ROOT/docs/codex.md"
    [[ -f "$doc" ]] || skip "customer page not found from this test root"

    local var unread=""
    # Every MMRY_* setting the page tells a customer to set.
    #
    # A READ, NOT A MENTION (#31245 QA round 8). This used to grep for the name anywhere in a
    # shipped file, so a commented-out reference, or a comment explaining that a setting had been
    # removed, satisfied it. Comment lines are dropped first: '#' in shell, 'rem' and '::' in batch.
    _code_lines() {
        local f
        for f in "$PLUGIN_ROOT"/hooks-handlers/*.sh "$PLUGIN_ROOT"/hooks-handlers/*.cmd \
                 "$PLUGIN_ROOT"/setup/* "$PLUGIN_ROOT"/hooks/*.json; do
            [[ -f "$f" ]] || continue
            grep -v -E '^[[:space:]]*(#|rem([[:space:]]|$)|REM([[:space:]]|$)|::)' "$f" || true
        done
    }
    local code; code="$(_code_lines)"
    while IFS= read -r var; do
        [[ -n "$var" ]] || continue
        grep -q "$var" <<< "$code" && continue
        unread="${unread} ${var}"
    done < <(grep -o 'MMRY_[A-Z0-9_]*' "$doc" | sort -u)

    [[ -z "$unread" ]] || {
        echo "the customer page names these settings, and no shipped file reads any of them:${unread}" >&2
        echo "Either wire them up or stop publishing them as a remedy." >&2
        return 1
    }
}

@test "docs: the page says which Codex surfaces this does and does not reach" {
    # THE ESTIMATE MADE THIS A CONDITION OF APPROVAL (#31245, QA round 7). The approved estimate
    # said: "It is not yet known whether session events fire in that platform's desktop
    # application and cloud product. If they do not, the reachable audience shrinks and this
    # estimate should be redone before approval rather than absorbed."
    #
    # Ninety-four commits later the branch still did not mention the cloud product anywhere, and
    # the customer page did not tell a customer on an unsupported surface that this is not for
    # them. A customer who installs into a surface that cannot run it gets silence, which is the
    # failure mode this whole feature was built to avoid.
    #
    # OpenAI's plugin documentation settles two of the four: plugins run in Codex CLI and in Codex
    # in the ChatGPT desktop app, and "the IDE extension doesn't support plugins". Cloud tasks are
    # not addressed there and we have not run one, so the page says so rather than guessing.
    local doc="$REPO_ROOT/docs/codex.md"
    [[ -f "$doc" ]] || skip "customer page not found from this test root"

    grep -qi "^## Where this works" "$doc" \
        || { echo "the page does not say which surfaces this reaches"; return 1; }

    local surface
    for surface in "Codex CLI" "desktop app" "IDE extension" "cloud"; do
        grep -qi "$surface" "$doc" \
            || { echo "the surface table does not mention: $surface"; return 1; }
    done

    # The unsupported ones have to be named as unsupported, not merely listed.
    grep -qi "doesn't support plugins\|does not support plugins" "$doc" \
        || { echo "the page lists the IDE extension without saying plugins do not run there"; return 1; }
    grep -qi "not established\|treat it as unsupported" "$doc" \
        || { echo "the page does not admit the cloud surface is unestablished"; return 1; }
}

@test "docs: the README table says typed slash commands are not available on Codex" {
    # Round 9 added this row because QA found the comparison table silent about the first gap a
    # Codex customer meets. The moment sweep above does not cover it (it is not a moment), so the
    # row is pinned here: its Codex cell must say it is not available.
    local readme; readme="$(cd "$PLUGIN_ROOT/.." && pwd)/README.md"
    local row; row="$(grep -i '^| *typed slash commands' "$readme" | tr -d '\r')"
    [[ -n "$row" ]] || { echo "the README table has no slash-command row"; return 1; }
    local codex; codex="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
    [[ "$codex" == *"not available"* ]] || { echo "the Codex cell does not say not available: $codex"; return 1; }
}
