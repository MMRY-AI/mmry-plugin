#!/usr/bin/env bats
# The commands the MODEL runs on Windows Codex (#31245 QA round 9).
#
# Codex runs the model's commands in PowerShell, where a bare `bash` is the Linux subsystem's and
# fails with execvpe(/bin/bash). QA found sessions improvising round it. The skill and the setup
# message now give one PowerShell block that hands the command to Git Bash in a file. These tests
# take that block out of the shipped text, swap in a probe command, and run it the way Codex does,
# with -Command, under each PowerShell present and both PATH layouts Git for Windows produces.
#
# Two traps the block exists to avoid, both measured on 2026-10-03:
# - Windows PowerShell 5.1 strips embedded double quotes from arguments to another program, so
#   `bash.exe -c '... "..." ...'` arrived broken there while PowerShell 7.6 passed it intact.
# - Splitting the path of `git.exe` twice finds Git's root only for Git\cmd\git.exe; with
#   Git\mingw64\bin on PATH it lands in Git\mingw64, which has no bash.exe. `git --exec-path`
#   points into the install whichever git.exe answers.

load '../helpers/test-helper'
load '../helpers/mock-config'

# session-start.sh runs self-update.sh, which downloads the released plugin and copies it over the
# directory it runs from. Run against the real tree with a real curl, that overwrote this
# checkout's hooks with master's while this file was being written. So: curl is mocked, the update
# check's debounce marker is fresh, and session-start runs from a throwaway copy of the plugin.
setup() {
    setup_mock_curl
    touch "${TMPDIR:-/tmp}/.mmry-update-checked"
    COPY="$BATS_TEST_TMPDIR/plugin"
    mkdir -p "$COPY"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/vendor" "$PLUGIN_ROOT/.claude-plugin" "$COPY/"
}

PROBE='printf '"'"'[%s]\n'"'"' "it'"'"'s \"quoted\", costs \$5"'
EXPECT='[it'"'"'s "quoted", costs $5]'

_windows_only() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "Windows only: needs PowerShell" ;; esac
    command -v cygpath >/dev/null 2>&1 || skip "no cygpath"
    command -v git >/dev/null 2>&1 || skip "no git"
}

# Every PowerShell on this machine, one per line.
_powershells() {
    command -v powershell.exe 2>/dev/null || true
    local p7="/c/Program Files/PowerShell/7/pwsh.exe"
    [[ -x "$p7" ]] && printf '%s\n' "$p7"
    return 0
}

# Both PATH layouts a Git for Windows install produces, as MSYS paths, one per line.
_path_layouts() {
    local root sysroot
    root="$(cd "$(git --exec-path)/../../.." && pwd)"
    root="${root%/}"   # Git Bash mounts the Git install at /, so the root can be "/" itself
    sysroot="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")"
    local base="$sysroot/System32:$sysroot:$sysroot/System32/WindowsPowerShell/v1.0"
    printf '%s\n' "$base:$root/cmd"
    printf '%s\n' "$base:$root/mingw64/bin:$root/usr/bin:$root/cmd"
}

# The block between the @' line and the line that runs it, with the command inside replaced.
_with_probe() {
    local block="$1" out="" line inside=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"= @'" ]]; then out="${out}${line}"$'\n'; inside=1; continue; fi
        if [[ $inside -eq 1 && "$line" != "'@"* ]]; then continue; fi
        if [[ $inside -eq 1 ]]; then out="${out}${PROBE}"$'\n'; inside=0; fi
        out="${out}${line}"$'\n'
    done <<< "$block"
    printf '%s' "$out"
}

_run_everywhere() {
    local block="$1" ps layout n=0
    while IFS= read -r ps; do
        [[ -n "$ps" ]] || continue
        while IFS= read -r layout; do
            n=$((n + 1))
            run env PATH="$layout" "$ps" -NoProfile -Command "$block"
            [[ "$output" == *"$EXPECT"* ]] || {
                echo "under $ps with PATH=$layout the command did not arrive intact:"
                echo "$output"
                return 1
            }
        done < <(_path_layouts)
    done < <(_powershells)
    [[ $n -gt 0 ]] || skip "no PowerShell found"
}

@test "skill: the Windows block hands a command to Git Bash intact, in every PowerShell and PATH layout" {
    _windows_only
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    local block
    block="$(awk '/^```powershell/{f=1;next} f&&/^```/{exit} f' "$skill" | tr -d '\r')"
    [[ "$block" == *"git --exec-path"* ]] || { echo "the skill's block does not find Git from git --exec-path"; return 1; }
    [[ "$block" == *"WriteAllText"* ]] || { echo "the skill's block does not pass the command in a file"; return 1; }
    _run_everywhere "$(_with_probe "$block")"
}

@test "setup message: on Windows Codex it carries the same block, and the block runs" {
    _windows_only
    local home="$BATS_TEST_TMPDIR/h"
    mkdir -p "$home/.codex"
    local ctx
    ctx="$(env -u MMRY_CONFIG_FILE -u CLAUDE_PLUGIN_ROOT HOME="$home" CODEX_HOME="$home/.codex" MMRY_HOST=codex \
        bash "$COPY/hooks-handlers/session-start.sh" < /dev/null | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"do NOT type bash at the PowerShell prompt"* ]] || { echo "no Windows guidance in: $ctx"; return 1; }
    local block
    block="$(printf '%s\n' "$ctx" | awk '/= @'"'"'$/{f=1} f{print} f&&/Remove-Item/{exit}')"
    [[ "$block" == *"mmry-setup.sh"* ]] || { echo "the block does not name the setup script: $block"; return 1; }
    _run_everywhere "$(_with_probe "$block")"
}

@test "req4: on Claude Code the setup message carries no PowerShell block" {
    local home="$BATS_TEST_TMPDIR/h"
    mkdir -p "$home/.claude"
    local ctx
    ctx="$(env -u MMRY_HOST -u MMRY_CONFIG_FILE -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME -u MMRY_API_KEY HOME="$home" \
        MMRY_CONFIG_FILE="$home/none.json" \
        bash "$COPY/hooks-handlers/session-start.sh" < /dev/null | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"mmry-setup.sh"* ]] || { echo "not the setup message: $ctx"; return 1; }
    [[ "$ctx" != *"PowerShell"* && "$ctx" != *"@'"* ]] || { echo "Claude Code's setup message changed: $ctx"; return 1; }
}

@test "docs: the PowerShell setup command finds Git from git --exec-path, not from the git.exe path" {
    local doc; doc="$(cd "$PLUGIN_ROOT/.." && pwd)/docs/codex.md"
    grep -q "git --exec-path" "$doc" || { echo "the page's PowerShell command does not use git --exec-path"; return 1; }
    ! grep -q "(Get-Command git).Source" "$doc" || { echo "the page still derives Git from the git.exe path"; return 1; }
}
