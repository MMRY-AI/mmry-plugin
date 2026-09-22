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

@test "windows: the dead .cmd wrapper is gone, and nothing has quietly reintroduced it" {
    # codex-hook.cmd used to be the Windows entry point and this test used to pin its CRLF bytes.
    # It was deleted in #31245 QA round 7. Every registration in hooks/codex-hooks.json launches
    # with `sh`, which on Windows can only be Git's because Windows ships no sh.exe, and NOTHING
    # referenced the wrapper any more: not a registration, not the installer, not a handler.
    #
    # It still shipped to every customer, CRLF-pinned, with a header describing a mechanism the
    # branch had removed, and the customer page sent people to an MMRY_BASH override that only that
    # orphaned file read. QA found the remedy inert.
    #
    # So the invariant is inverted: the file must NOT exist, and if a Windows entry point is ever
    # reintroduced it has to arrive with a registration that uses it, in the same change.
    [[ ! -e "$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" ]] || {
        echo "codex-hook.cmd is back. If that is deliberate, it needs a registration in"
        echo "hooks/codex-hooks.json that actually launches it, and this test updated to match."
        return 1
    }
    # Only EXECUTABLE lines. A comment explaining why the wrapper was deleted names it, and a raw
    # grep would report the deletion as a reintroduction forever after. Same convention as the
    # absence checks in structural/formation-delivery.bats.
    local named="" f
    for f in "$PLUGIN_ROOT"/hooks/*.json "$PLUGIN_ROOT"/hooks-handlers/*.sh; do
        [[ -f "$f" ]] || continue
        if sed 's/#.*$//' "$f" | grep -q 'codex-hook\.cmd'; then
            named="${named} ${f##*/}"
        fi
    done
    [[ -z "$named" ]] || {
        echo "something still names the deleted wrapper in executable code:${named}"
        return 1
    }
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
    grep -q "Git.bin.bash.exe" "$doc" || { echo "no explicit interpreter form for PowerShell users"; return 1; }
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
    local f bad=""
    local -a _lines

    # Codex-only surfaces must never make the promise at all.
    local codex_only=(
        "$REPO_ROOT/docs/codex.md"
        "$PLUGIN_ROOT/.codex-plugin/plugin.json"
        "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
        "$PLUGIN_ROOT/hooks/codex-hooks.json"
    )
    # Shared surfaces may, because on Claude Code it is TRUE, but the same sentence or cell has to
    # say which host it is talking about.
    local shared=(
        "$REPO_ROOT/README.md"
        "$PLUGIN_ROOT/README.md"
    )

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
            *"plan accepted"*)             return 0 ;;
        esac
        return 1
    }

    _is_disclosure() {
        local l; l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
        case "$l" in
            *"claude code only"*)          return 0 ;;
            *"on claude code"*)            return 0 ;;
            *"claude code |"*)             return 0 ;;
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

    for f in "${codex_only[@]}" "${shared[@]}"; do
        [[ -f "$f" ]] || { echo "a surface this test must sweep is missing: $f"; return 1; }

        # THE UNIT OF JUDGEMENT IS WHAT A READER TAKES IN AT ONCE, which is not a line.
        #
        # A markdown TABLE ROW is read against its header, so "| A prompt to save | at session end
        # | on your next message |" is not a promise about Codex: the header says which column is
        # which. Those are tested as header plus row, together.
        #
        # Everything else is tested a SENTENCE at a time, because the storefront listing is a
        # single JSON value forty words long, and an earlier line-based version of this test let a
        # deliberate re-introduction of the bad string through: the same line carried an unrelated
        # "not available" further along and read as a disclosure.
        mapfile -t _lines < <(tr -d '\r' < "$f")
        local i n subject header="" frag
        n=${#_lines[@]}
        for ((i = 0; i < n; i++)); do
            # A separator row means the line before it was the header of this table.
            if [[ "${_lines[$i]}" =~ ^[[:space:]]*\|[-:[:space:]|]+$ ]]; then
                [[ $i -gt 0 ]] && header="${_lines[$((i - 1))]}"
                continue
            fi
            if [[ "${_lines[$i]}" == *"|"* && -n "$header" ]]; then
                subject="${header} ${_lines[$i]}"
                _promises_a_missing_moment "$subject" || continue
                _is_disclosure "$subject" && continue
                bad="${bad}
  ${f#$REPO_ROOT/}: ${_lines[$i]}"
                continue
            fi
            while IFS= read -r frag; do
                [[ -n "$frag" ]] || continue
                _promises_a_missing_moment "$frag" || continue
                _is_disclosure "$frag" && continue
                bad="${bad}
  ${f#$REPO_ROOT/}: ${frag}"
                # printf '%s\n', NOT '%s': with no trailing newline `read` returns non-zero on the
                # last fragment and the loop body never runs for it, so any line that is a SINGLE
                # sentence was never examined at all. Caught by mutation: a bullet re-introducing
                # "Session end: Prompts to save decisions..." into the root README SURVIVED this
                # sweep, while the storefront JSON was correctly refused, because that value
                # happens to hold several sentences and only its last one was being dropped.
            done < <(printf '%s\n' "${_lines[$i]}" | sed 's/\. /.\n/g')
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
    while IFS= read -r var; do
        [[ -n "$var" ]] || continue
        # Where could it be read? Any shipped shell file, the manifests, or the installers.
        if grep -rqs "$var" \
            "$PLUGIN_ROOT"/hooks-handlers/*.sh \
            "$PLUGIN_ROOT"/setup/* \
            "$PLUGIN_ROOT"/hooks/*.json; then
            continue
        fi
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
