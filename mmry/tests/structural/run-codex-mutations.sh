#!/usr/bin/env bash
# run-codex-mutations.sh — prove that the #31245 assertions can refuse.
#
# A count of passing checks is not evidence. This applies one deliberate break at a time, runs the
# test file that is supposed to notice, and records whether it did. A mutation that leaves the
# suite green has found a check that cannot fail, which is the recurring defect on this project.
#
# Usage: bash tests/structural/run-codex-mutations.sh
# Requires a clean working tree: each mutation is reverted with `git checkout -- <file>`.
#
# This is a developer tool, not part of the suite. It is committed so the claim "every assertion
# was seen to refuse" is reproducible by whoever reviews it rather than taken on trust. The runs it
# has been put through are recorded in CODEX-MUTATIONS.md beside this file.
#
# ---------------------------------------------------------------------------------------------
# WHAT WENT WRONG WITH THE FIRST VERSION, AND WHY THIS ONE IS SHAPED THIS WAY (#31245 QA round 2)
#
# Three people ran it and got three different answers: 37 refused / 0 survived, 25 / 0, and
# 15 refused / 5 "survived" - where re-running those five ONE AT A TIME reproduced every one of
# them as REFUSED. The harness was telling a reviewer that a working assertion cannot fail, which
# is worse than telling them nothing. Four causes, all fixed here:
#
#   1. AN EXPERIMENT THAT COULD NOT BE PERFORMED WAS COUNTED AS A SURVIVING MUTANT. "NOT APPLIED"
#      incremented the same counter the summary printed as "survived". A harness fault and a dead
#      assertion are opposite findings and they were reported as the same number. They are now
#      three separate counters, and the summary refuses to collapse them.
#   2. THE INTERPRETER WAS UNPINNED. `python` on the machine this was written on is 2.7.2, while
#      `python3` is 3.12. Two reviewers ran two different languages. It now resolves an explicit
#      Python 3 and stops with a message if it cannot find one, instead of silently producing
#      "NOT APPLIED" for everything.
#   3. ANY PYTHON FAILURE LOOKED LIKE A MISSING PATTERN. Exit 3 means "the pattern is not in the
#      file"; every other non-zero exit means the experiment did not run at all. They were
#      conflated and the interpreter's own error message was discarded. Both are reported now.
#   4. LINE ENDINGS. .gitattributes pins LF for *.sh only. On a machine with core.autocrlf=true the
#      .json, .md and .bats files in the working tree are CRLF, and every mutation whose pattern
#      spans a newline silently failed to match. Demonstrated on one commit: the stop-check
#      mutations apply against an LF tree and report "MUTATION DID NOT APPLY" against a CRLF one.
#      The file is normalised to LF for matching and written back in its original form, so a
#      mutation now means the same thing on every machine.
#
# It also restores the file from an EXIT trap. A run killed by an impatient timeout used to leave a
# mutation applied in the working tree, which is how the next run starts from a state nobody chose.
# And it prints [i/N], so a truncated run is visibly truncated rather than looking like a smaller
# suite that passed.
# ---------------------------------------------------------------------------------------------

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLUGIN="$REPO_ROOT/mmry"
TESTS="$PLUGIN/tests"
BATS="${MMRY_BATS_BIN:-$TESTS/libs/bats-core/bin/bats}"

cd "$REPO_ROOT" || exit 1

# ---- Pin the interpreter, BY BEHAVIOUR AND NOT BY NAME. ---------------------------------------
#
# Three traps live in this six-line problem, and this harness fell into all of them:
#
#   `python`  on this machine is 2.7.2, a different language from the one these fragments are
#             written in.
#   `python3` on this machine is the Windows Store app execution alias in
#             %LOCALAPPDATA%/Microsoft/WindowsApps. It answers `-c` and reports version 3.12, so a
#             version probe passes - and then it IGNORES the `-` that means "read the program from
#             stdin" and runs argv[1] instead. argv[1] here is a .sh file, so it read the shebang
#             and tried to launch bash: "A shebang 'bash' was found ... treated as an arbitrary
#             command", exit 127, on all 50 experiments.
#   A launcher that forwards to a real interpreter reports the real one in sys.executable, which is
#             the path that actually works.
#
# So: find a candidate, ask it where the real interpreter is, and then PROVE the stdin form works
# by running it, before trusting it with fifty file edits. A harness that cannot verify its own
# tool has no business reporting on anyone else's.
PYBIN=""
_probe_stdin_form() {
    # Echoes nothing; returns 0 only if "$1" runs a program from stdin AND sees argv[1].
    printf 'import sys
sys.exit(0 if len(sys.argv) > 1 and sys.version_info[0] >= 3 else 1)
'         | "$1" - probe-argument >/dev/null 2>&1
}
for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    _real="$("$candidate" -c 'import sys; print(sys.executable)' 2>/dev/null)" || continue
    [[ -n "$_real" && -f "$_real" ]] || continue
    if _probe_stdin_form "$_real"; then
        PYBIN="$_real"
        break
    fi
done
if [[ -z "$PYBIN" ]]; then
    echo "REFUSING: no usable Python 3 found." >&2
    echo "Tried python3, python and py. A candidate has to be Python 3 AND has to run a program" >&2
    echo "from stdin with arguments - the Windows Store alias named 'python3' does neither, while" >&2
    echo "reporting version 3.12, which is how 50 experiments came back as exit 127." >&2
    exit 1
fi
echo "interpreter: $PYBIN  $("$PYBIN" -c 'import sys; print(sys.version.split()[0])')"

if [[ -n "$(git status --porcelain -- mmry docs)" ]]; then
    echo "REFUSING: the working tree under mmry/ or docs/ is dirty. Commit or stash first, because" >&2
    echo "each mutation is undone with 'git checkout -- <file>' and would discard your edits." >&2
    exit 1
fi

REFUSED=0
SURVIVED=0
ERRORS=0
RUN=0
SKIPPED=0
TOTAL=69
SURVIVOR_LIST=""
ERROR_LIST=""
CURRENT_FILE=""

# A run that is killed part-way must not leave a mutation behind.
# A file OUTSIDE mmry/ is named with a leading ../ - docs/codex.md is the customer-facing page and
# lives at the repository root. Normalising here keeps every call site spelled the same way.
_repo_path() {
    case "$1" in
        ../*) printf '%s' "${1#../}" ;;
        *)    printf 'mmry/%s' "$1" ;;
    esac
}

_restore() {
    if [[ -n "$CURRENT_FILE" ]]; then
        git checkout -- "$(_repo_path "$CURRENT_FILE")" 2>/dev/null
        CURRENT_FILE=""
    fi
}
trap _restore EXIT INT TERM

# mutate <label> <file> <python-expression-file-edit> <test-file> <expected-failing-test-substring>
mutate() {
    local label="$1" file="$2" pyfrag="$3" testfile="$4" expect="$5"

    # RUN ONE EXPERIMENT, OR A NAMED FEW. A full run is upwards of two hours on Windows, and a
    # reviewer who wants to check a single finding should not have to sit through the other
    # sixty-eight. MMRY_MUTATION_FILTER is a substring of the label; a filtered run says so in the
    # summary and does not pretend to be a complete one (#31245 QA round 3).
    if [[ -n "${MMRY_MUTATION_FILTER:-}" && "$label" != *"${MMRY_MUTATION_FILTER}"* ]]; then
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    RUN=$((RUN + 1))
    CURRENT_FILE="$file"

    # The interpreter is run as a plain statement with stderr to a file, NOT inside a command
    # substitution. `$( ... <<HEREDOC )` around a Windows python spawns unreliably under Git Bash
    # ("fatal error - couldn't create signal pipe") and every experiment came back as exit 127 -
    # another harness fault that looks like a finding.
    local pyerr applied
    local errfile="${TMPDIR:-/tmp}/mmry-mutation-stderr.$$"
    "$PYBIN" - "$PLUGIN/$file" 2>"$errfile" <<PY
import io, sys
p = sys.argv[1]

# Read as bytes and normalise to LF for matching. The patterns below are written with '\n', and a
# working tree with CRLF endings - which is what core.autocrlf=true produces for every file
# .gitattributes does not pin - would silently fail to match every multi-line pattern. The original
# form is restored on write, so the only change to the file is the mutation itself.
raw = io.open(p, 'rb').read().decode('utf-8')
was_crlf = '\r\n' in raw
s = raw.replace('\r\n', '\n')
before = s
$pyfrag
if s == before:
    sys.stderr.write("pattern not present in the file\n")
    sys.exit(3)
out = s.replace('\n', '\r\n') if was_crlf else s
io.open(p, 'wb').write(out.encode('utf-8'))
PY
    applied=$?
    pyerr="$(cat "$errfile" 2>/dev/null || true)"
    rm -f "$errfile" 2>/dev/null || true

    if [[ $applied -eq 3 ]]; then
        printf '[%2d/%2d] NOT APPLIED  %s\n' "$RUN" "$TOTAL" "$label"
        printf '                     the pattern is not in mmry/%s. The mutation is STALE and this\n' "$file"
        printf '                     assertion was NOT tested by this run. It is not a survivor.\n'
        ERRORS=$((ERRORS + 1))
        ERROR_LIST="${ERROR_LIST}
  stale pattern: ${label}"
        _restore
        return
    fi
    if [[ $applied -ne 0 ]]; then
        printf '[%2d/%2d] HARNESS ERROR %s\n' "$RUN" "$TOTAL" "$label"
        printf '                     %s failed (exit %s): %s\n' "$PYBIN" "$applied" "$pyerr"
        ERRORS=$((ERRORS + 1))
        ERROR_LIST="${ERROR_LIST}
  interpreter failure: ${label}"
        _restore
        return
    fi

    local out
    out="$("$BATS" "$TESTS/$testfile" 2>&1)"
    _restore

    if printf '%s' "$out" | grep -q "^not ok.*${expect}"; then
        printf '[%2d/%2d] REFUSED      %s\n' "$RUN" "$TOTAL" "$label"
        REFUSED=$((REFUSED + 1))
    else
        local n
        n="$(printf '%s' "$out" | grep -c '^not ok' || true)"
        if [[ "$n" -gt 0 ]]; then
            printf '[%2d/%2d] REFUSED(*)   %s   [%s test(s) failed, but not the named one]\n' "$RUN" "$TOTAL" "$label" "$n"
            printf '%s' "$out" | grep '^not ok' | sed 's/^/                     /'
            REFUSED=$((REFUSED + 1))
        else
            printf '[%2d/%2d] SURVIVED     %s   <-- THIS ASSERTION CANNOT FAIL\n' "$RUN" "$TOTAL" "$label"
            SURVIVED=$((SURVIVED + 1))
            SURVIVOR_LIST="${SURVIVOR_LIST}
  ${label}   (expected a failure matching: ${expect})"
        fi
    fi
}

echo "=== #31245 mutation run: $TOTAL experiments ==="

# ---- lib-host.sh: the requirement-4 literals -------------------------------------------------
mutate "claude config dir drifts" hooks-handlers/lib-host.sh \
  "s = s.replace('\"\${HOME}/.claude\"', '\"\${HOME}/.claude-v2\"')" \
  unit/lib-host.bats "Claude config dir"

mutate "claude client name becomes codex" hooks-handlers/lib-host.sh \
  "s = s.replace(\"printf 'claude-code'\", \"printf 'codex'\")" \
  unit/lib-host.bats "Claude client name"

mutate "claude script ref becomes absolute" hooks-handlers/lib-host.sh   's = s.replace("${CLAUDE_PLUGIN_ROOT}/hooks-handlers/%s", "/abs/%s")'   unit/lib-host.bats "unexpanded"

mutate "default host becomes codex" hooks-handlers/lib-host.sh \
  "s = s.replace('        *)     printf \\'claude\\' ;;', '        *)     printf \\'codex\\' ;;')" \
  unit/lib-host.bats "MMRY_HOST unset"

mutate "CODEX_HOME ignored" hooks-handlers/lib-host.sh \
  "s = s.replace('\"\${CODEX_HOME:-\${HOME}/.codex}\"', '\"\${HOME}/.codex\"')" \
  unit/lib-host.bats "CODEX_HOME wins"

mutate "codex script ref keeps the variable" hooks-handlers/lib-host.sh \
  "s = s.replace(\"printf '%s/hooks-handlers/%s' \\\"\$(mmry_host_state_dir)\\\" \\\"\$script\\\"\", \"printf '\\\\\${CLAUDE_PLUGIN_ROOT}/hooks-handlers/%s' \\\"\$script\\\"\")" \
  unit/lib-host.bats "ABSOLUTE path"

mutate "the double-source guard becomes a no-op" hooks-handlers/lib-host.sh   's = s.replace(chr(34) + "${_MMRY_LIB_HOST_SOURCED:-}" + chr(34) + " ]] && return 0", chr(34) + "${_MMRY_LIB_HOST_SOURCED:-}" + chr(34) + " ]] && true", 1)'   unit/lib-host.bats "clobber"

# ---- codex-hook.sh ---------------------------------------------------------------------------
mutate "shim stops declaring the host" hooks-handlers/codex-hook.sh \
  "s = s.replace('export MMRY_HOST=\"codex\"', 'MMRY_HOST_NOT_EXPORTED=1')" \
  handlers/codex-hook.bats "MMRY_HOST=codex"

mutate "shim drops the path-separator guard" hooks-handlers/codex-hook.sh \
  "s = s.replace('    *[/\\\\\\\\]*|.*|\"\") exit 0 ;;', '    \"\") exit 0 ;;')" \
  handlers/codex-hook.bats "path separator"

mutate "shim swallows the handler exit code" hooks-handlers/codex-hook.sh   's = s.replace("exec bash " + chr(34) + "$TARGET" + chr(34) + " " + chr(34) + "$@" + chr(34), "bash " + chr(34) + "$TARGET" + chr(34) + " " + chr(34) + "$@" + chr(34) + " || true", 1)'   handlers/codex-hook.bats "exit code is passed through"

# NOTE: there is no "shim stops setting MMRY_CONFIG_FILE" mutation any more. The shim used to
# repeat that export and the repetition was deleted precisely because this harness showed it could
# be removed with no test failing. The assertion is covered by "lib-host stops exporting
# MMRY_CONFIG_FILE" further down, which does refuse.

# ---- codex-hooks.json ------------------------------------------------------------------------
mutate "PreCompact gets registered" hooks/codex-hooks.json \
  "s = s.replace('    \"Stop\": [', '    \"PreCompact\": [{\"hooks\":[{\"type\":\"command\",\"command\":\"bash x\",\"commandWindows\":\"x\",\"timeout\":5}]}],\n    \"Stop\": [')" \
  structural/codex-manifest.bats "PreCompact is NOT registered"

mutate "a handler gains asyncRewake" hooks/codex-hooks.json \
  "s = s.replace('\"timeout\": 10', '\"asyncRewake\": true, \"timeout\": 10', 1)" \
  structural/codex-manifest.bats "fields HookHandlerConfig"

mutate "the PostToolUse group gains a matcher" hooks/codex-hooks.json   's = s.replace(chr(34)+"PostToolUse"+chr(34)+": [", chr(34)+"PostToolUse"+chr(34)+": [{"+chr(34)+"matcher"+chr(34)+":"+chr(34)+"Bash"+chr(34)+","+chr(34)+"hooks"+chr(34)+":[]},", 1)'   structural/codex-manifest.bats "NO matcher"

mutate "a handler loses commandWindows" hooks/codex-hooks.json \
  "import re; s = re.sub(r'\n *\"commandWindows\":[^\n]*\n', '\n', s, count=1)" \
  structural/codex-manifest.bats "commandWindows"

mutate "a command bypasses the codex entry point" hooks/codex-hooks.json \
  "s = s.replace('hooks-handlers/codex-hook.sh\\\\\" stop-check', 'hooks-handlers/stop-check.sh\\\\\"', 1)" \
  structural/codex-manifest.bats "routes through codex-hook.sh"

mutate "the formation poller is registered on Stop" hooks/codex-hooks.json \
  "s = s.replace('codex-hook.sh\\\\\" stop-check', 'codex-hook.sh\\\\\" formation-check', 1)" \
  structural/codex-manifest.bats "formation poller is NOT registered on Stop"

mutate "additionalContextLimit is emitted" hooks/codex-hooks.json \
  "s = s.replace('\"timeout\": 30', '\"additionalContextLimit\": 2500, \"timeout\": 30', 1)" \
  structural/codex-manifest.bats "additionalContextLimit"

mutate "Windows command uses POSIX expansion" hooks/codex-hooks.json \
  "s = s.replace('%CLAUDE_PLUGIN_ROOT%', '\${CLAUDE_PLUGIN_ROOT}')" \
  structural/codex-manifest.bats "%VAR%"

mutate "an unknown event name is registered" hooks/codex-hooks.json \
  "s = s.replace('\"SessionStart\": [', '\"SessionStarted\": [', 1)" \
  structural/codex-manifest.bats "event name is one Codex declares"

# ---- .codex-plugin/plugin.json ---------------------------------------------------------------
mutate "codex manifest points at the Claude skills dir" .codex-plugin/plugin.json \
  "s = s.replace('\"./skills-codex/\"', '\"./skills/\"')" \
  structural/codex-manifest.bats "own directory"

mutate "codex manifest points at the Claude hooks file" .codex-plugin/plugin.json \
  "s = s.replace('\"./hooks/codex-hooks.json\"', '\"./hooks/hooks.json\"')" \
  structural/codex-manifest.bats "NOT at the Claude Code hooks.json"

mutate "codex manifest hardcodes a version" .codex-plugin/plugin.json \
  "s = s.replace('\"name\": \"mmry\",', '\"name\": \"mmry\",\n  \"version\": \"2.9.1\",')" \
  structural/codex-manifest.bats "NO version"

mutate "a manifest path loses its ./ prefix" .codex-plugin/plugin.json \
  "s = s.replace('\"./commands-codex/\"', '\"commands-codex/\"')" \
  structural/codex-manifest.bats "./ form"

mutate "codex manifest inherits the default commands dir" .codex-plugin/plugin.json   's = s.replace(chr(34)+"commands"+chr(34)+":", chr(34)+"commandsX"+chr(34)+":", 1)'   structural/codex-manifest.bats "explicitly rather than inheriting"

# ---- stop-check.sh ---------------------------------------------------------------------------
mutate "the compaction sentence fires on Claude Code too" hooks-handlers/stop-check.sh \
  "s = s.replace('if [[ \"\$(mmry_host)\" == \"codex\" ]]; then\n    compaction_clause=', 'if true; then\n    compaction_clause=')" \
  handlers/codex-hook.bats "NO compaction sentence"

mutate "the compaction sentence never fires" hooks-handlers/stop-check.sh \
  "s = s.replace('if [[ \"\$(mmry_host)\" == \"codex\" ]]; then\n    compaction_clause=', 'if false; then\n    compaction_clause=')" \
  handlers/codex-hook.bats "compaction warning"

mutate "the save prompt stops exiting 2" hooks-handlers/stop-check.sh \
  "s = s.replace(\"printf '%s\\\\n' \\\"\$DIRECTIVE\\\" >&2\nexit 2\", \"printf '%s\\\\n' \\\"\$DIRECTIVE\\\" >&2\nexit 0\")" \
  handlers/codex-hook.bats "exits 2"

# ---- formation-check.sh ----------------------------------------------------------------------
mutate "codex tool delivery reverts to stderr+exit 2" hooks-handlers/formation-check.sh \
  "s = s.replace('        if [[ \"\$(mmry_host)\" == \"codex\" ]]; then\n            printf \\'%s\\' \"\$FORMATION_BLOCK\" | \"\$MMRY_JQ\" -Rsc', '        if false; then\n            printf \\'%s\\' \"\$FORMATION_BLOCK\" | \"\$MMRY_JQ\" -Rsc')" \
  structural/codex-formation-delivery.bats "PostToolUse additionalContext"

mutate "codex idle guard removed, so the poller waits" hooks-handlers/formation-check.sh \
  "s = s.replace('        if [[ \"\$(mmry_host)\" == \"codex\" ]]; then\n            _poll_once || exit 0\n            printf \\'%s\\\\n\\' \"\$FORMATION_BLOCK\" >&2\n            exit 2\n        fi\n', '')" \
  structural/codex-formation-delivery.bats "ONE pass"

mutate "formation-check stops guarding the credential, so a hot-path hook exits 1" hooks-handlers/formation-check.sh   's = s.replace("mmry_host_assert_own_credential 2>/dev/null || exit 0", "true", 1)'   structural/codex-formation-delivery.bats "no formation pays nothing"

# ---- requirement-4 guards on the Claude surface ----------------------------------------------
mutate "a Claude command file gains frontmatter" commands/setup.md \
  "s = '---\ndescription: x\n---\n' + s" \
  structural/codex-manifest.bats "gained YAML frontmatter"

mutate "the e2e fixture stops copying lib-host" tests/e2e/setup-join.bats   's = s.replace("cp "+chr(34)+chr(36)+"PLUGIN_ROOT/hooks-handlers/lib-host.sh"+chr(34), "true #", 1)'   structural/codex-manifest.bats "mirrored by the e2e fixture"

# ---- the model-invoked credential path, and the incomplete-copy fallbacks -------------------
mutate "lib-host stops reading the host off its own location" hooks-handlers/lib-host.sh   's = s.replace("*/.codex/*", "*/.no-such-marker/*", 1)'   handlers/codex-hook.bats "resolves the CODEX credential"

mutate "lib-host stops exporting MMRY_CONFIG_FILE" hooks-handlers/lib-host.sh   's = s.replace("export MMRY_CONFIG_FILE=", "_MMRY_UNUSED=", 1)'   handlers/codex-hook.bats "resolves the CODEX credential"

mutate "lib-jq stops sourcing the host resolver" hooks-handlers/lib-jq.sh   's = s.replace("source " + chr(34) + "${_mmry_libjq_dir}/lib-host.sh" + chr(34), "source " + chr(34) + "${_mmry_libjq_dir}/lib-host-absent.sh" + chr(34), 1)'   handlers/codex-hook.bats "resolves the CODEX credential"

mutate "location detection overreaches to any CODEX_HOME in the environment" hooks-handlers/lib-host.sh   's = s.replace("if [[ -z " + chr(34) + "${MMRY_HOST:-}" + chr(34) + " ]]; then", "if [[ -z " + chr(34) + "${MMRY_HOST:-}" + chr(34) + " ]]; then\n    [[ -n " + chr(34) + "${CODEX_HOME:-}" + chr(34) + " ]] && MMRY_HOST=codex", 1)'   handlers/codex-hook.bats "does NOT make a Claude install think it is Codex"

mutate "hook-guard loses its missing-resolver fallback" hooks-handlers/hook-guard.sh   's = s.replace("TARGET=" + chr(34) + "${HOME}/.claude/mmry/hooks-handlers/${SCRIPT_NAME}.sh" + chr(34), "TARGET=" + chr(34) + "/nonexistent/${SCRIPT_NAME}.sh" + chr(34), 1)'   handlers/codex-hook.bats "hook-guard with NO lib-host.sh"

mutate "stop-check loses its missing-resolver fallback" hooks-handlers/stop-check.sh   's = s.replace("    mmry_host_script_ref() { printf ", "    _unused_ref() { printf ", 1)'   handlers/codex-hook.bats "stop-check with NO lib-host.sh"

# ---- the refusal to borrow the other product's credential (QA round 2) -----------------------
mutate "lib-jq stops asserting, so the client walks on to the Claude file" hooks-handlers/lib-jq.sh   's = s.replace("    mmry_host_assert_own_credential || exit 1", "    true", 1)'   handlers/codex-hook.bats "REFUSES rather than resolving the Claude one"

mutate "the assertion always passes" hooks-handlers/lib-host.sh   's = s.replace("mmry_host_assert_own_credential() {", "mmry_host_assert_own_credential() {\n    return 0", 1)'   handlers/codex-hook.bats "REFUSES rather than resolving the Claude one"

mutate "the refusal goes quiet" hooks-handlers/lib-host.sh   's = s.replace("MMRY AI: no %s credential was found", "", 1)'   handlers/codex-hook.bats "SAYS SO"

mutate "the refusal fires on Claude Code too" hooks-handlers/lib-host.sh   's = s.replace(chr(34) + "$(mmry_host)" + chr(34) + " == " + chr(34) + "codex" + chr(34) + " ]] || return 0", chr(34) + "$(mmry_host)" + chr(34) + " != " + chr(34) + "no-such-host" + chr(34) + " ]] || return 0", 1)'   handlers/codex-hook.bats "Claude install with no credential at all is unaffected"

# ---- session-init.sh and session-start.sh, which had no mutation coverage at all -------------
mutate "session-init installs into the Claude directory on every host" hooks-handlers/session-init.sh   's = s.replace("MMRY_STATE_DIR=" + chr(34) + "$(mmry_host_state_dir)" + chr(34), "MMRY_STATE_DIR=" + chr(34) + "${HOME}/.claude/mmry" + chr(34), 1)'   handlers/codex-session.bats "installs the handlers under"

mutate "session-init stops copying the Windows entry point" hooks-handlers/session-init.sh   's = s.replace("cp " + chr(34) + "$P" + chr(34) + "/hooks-handlers/*.cmd", "true # cp " + chr(34) + "$P" + chr(34) + "/hooks-handlers/*.cmd", 1)'   handlers/codex-session.bats "copies the Windows entry point"

mutate "session-init loses the pipefail guard on the plugin-root search" hooks-handlers/session-init.sh   's = s.replace("|| true)" + chr(34), ")" + chr(34), 1)'   handlers/codex-session.bats "plugin root cannot be found"

mutate "session-start registers every session as claude-code" hooks-handlers/session-start.sh   's = s.replace(chr(34) + "$(mmry_host_client_name)" + chr(34), chr(34) + "claude-code" + chr(34), 1)'   handlers/codex-session.bats "registered as codex"

mutate "session-start sources the client before asking about the credential" hooks-handlers/session-start.sh   's = s.replace("if ! mmry_host_assert_own_credential 2>/dev/null; then", "if false; then", 1)'   handlers/codex-session.bats "told how to set up"

mutate "session-start stops reporting an absent session_id field" hooks-handlers/session-start.sh   's = s.replace("if [[ -z " + chr(34) + "$SESSION_ID" + chr(34) + " && " + chr(34) + "$HOOK_READ_STATUS" + chr(34) + " == " + chr(34) + "ok" + chr(34) + " ]]; then", "if false; then", 1)'   handlers/codex-session.bats "no session_id field"

# ---- the one command a new Codex customer runs -----------------------------------------------
mutate "setup forces the host to claude before resolving" setup/mmry-setup.sh   's = s.replace("[[ -n " + chr(34) + "${MMRY_HOST:-}" + chr(34) + " ]] && export MMRY_HOST", "export MMRY_HOST=" + chr(34) + "${MMRY_HOST:-claude}" + chr(34), 1)'   e2e/codex-setup.bats "writes ~/.codex/mmry-config.json"

mutate "setup loses its opt-out and can no longer run before a credential exists" setup/mmry-setup.sh   's = s.replace("MMRY_ALLOW_NO_CREDENTIAL=1", "true", 1)'   e2e/codex-setup.bats "writes ~/.codex/mmry-config.json"

# ---- QA ROUND 3: the uninstaller, the relocated home, the update path, the Windows guard,
# ---- the customer-facing page, and the three assertions that could not fail -------------------
mutate "the shell uninstaller stops refusing on Codex" setup/uninstall.sh   's = s.replace("if [[ "+chr(34)+"$MMRY_UNINSTALL_HOST"+chr(34)+" != "+chr(34)+"claude"+chr(34)+" ]]; then", "if false; then", 1)'   e2e/install-uninstall.bats "REFUSES"
mutate "the shell uninstaller destroys the other product's state dir again" setup/uninstall.sh   's = s.replace("if [[ "+chr(34)+"$MMRY_UNINSTALL_HOST"+chr(34)+" != "+chr(34)+"claude"+chr(34)+" ]]; then"+chr(10)+"    _mmry_codex_home", "if false; then"+chr(10)+"    _mmry_codex_home", 1)'   e2e/install-uninstall.bats "STATE DIRECTORY survives"
mutate "lib-host stops reading the install marker" hooks-handlers/lib-host.sh   's = s.replace("_mmry_marker="+chr(34)+"${_mmry_self_dir}/../.mmry-host"+chr(34), "_mmry_marker="+chr(34)+"/nonexistent/.mmry-host"+chr(34), 1)'   unit/lib-host.bats "install marker"
mutate "the marker names the host but not the place" hooks-handlers/lib-host.sh   's = s.replace("[[ -n "+chr(34)+"$_MMRY_HOST_DIR_FROM_MARKER"+chr(34)+" ]] && export _MMRY_HOST_DIR_FROM_MARKER", "_MMRY_HOST_DIR_FROM_MARKER="+chr(34)+chr(34), 1)'   unit/lib-host.bats "where the marker IS"
mutate "any marker content is read as codex" hooks-handlers/lib-host.sh   's = s.replace("if [[ "+chr(34)+"$_mmry_marker_host"+chr(34)+" == "+chr(34)+"codex"+chr(34)+" ]]; then", "if [[ -n "+chr(34)+"$_mmry_marker_host"+chr(34)+" ]]; then", 1)'   unit/lib-host.bats "marker reading claude"
mutate "the drive-letter spelling is no longer normalised" hooks-handlers/lib-host.sh   's = s.replace("if [[ "+chr(34)+"$p"+chr(34)+" =~ ^([A-Za-z]):(/.*)?$ ]]; then", "if false; then", 1)'   unit/lib-host.bats "Windows spelling"
mutate "session-init writes no host marker" hooks-handlers/session-init.sh   's = s.replace(chr(34) + "${MMRY_STATE_DIR}/.mmry-host" + chr(34), chr(34) + "/dev/null" + chr(34), 1)'   handlers/codex-session.bats "host marker"
mutate "self-update updates the Claude directory from a Codex session" hooks-handlers/self-update.sh   's = s.replace("INSTALLED_DIR="+chr(34)+"$(mmry_host_state_dir)"+chr(34), "INSTALLED_DIR="+chr(34)+"${HOME}/.claude/mmry"+chr(34), 1)'   handlers/self-update.bats "CODEX state directory"
mutate "self-update loses its credential opt-out and dies silently" hooks-handlers/self-update.sh   's = s.replace("MMRY_ALLOW_NO_CREDENTIAL=1", "true", 1)'   handlers/self-update.bats "update check"
mutate "the Windows guard forgets the install marker" setup/uninstall.bat   's = s.replace("if exist "+chr(34)+"%~dp0.."+chr(92)+".mmry-host"+chr(34)+" (", "if exist "+chr(34)+"%~dp0.."+chr(92)+".no-such-file"+chr(34)+" (", 1)'   structural/codex-docs-and-eol.bats "marker alone"
mutate "the Windows guard forgets CODEX_HOME" setup/uninstall.bat   's = s.replace("if defined CODEX_HOME (", "if defined NO_SUCH_VARIABLE (", 1)'   structural/codex-docs-and-eol.bats "CODEX_HOME alone"
mutate "the Windows guard refuses on any marker at all" setup/uninstall.bat   's = s.replace("findstr /i /l /c:"+chr(34)+"codex"+chr(34)+" "+chr(34)+"%~dp0.."+chr(92)+".mmry-host"+chr(34), "findstr /i /l /c:"+chr(34)+"c"+chr(34)+" "+chr(34)+"%~dp0.."+chr(92)+".mmry-host"+chr(34), 1)'   structural/codex-docs-and-eol.bats "does NOT make it refuse"
mutate "the customer-facing page goes back to a hard-coded path" ../docs/codex.md   's = s.replace("bash "+chr(34)+"${CODEX_HOME:-$HOME/.codex}/mmry/setup/mmry-setup.sh"+chr(34), "bash ~/.codex/mmry/setup/mmry-setup.sh", 1)'   structural/codex-docs-and-eol.bats "hard-codes"
mutate "the 401 reply names a slash command on Codex too" hooks-handlers/session-start.sh   's = s.replace("_mmry_reauth_hint="+chr(34)+"ask the assistant to run $(mmry_host_setup_hint)"+chr(34), "_mmry_reauth_hint="+chr(34)+"run /mmry:setup"+chr(34), 1)'   handlers/codex-session.bats "actually run"
mutate "formation-join registers every session as claude-code" hooks-handlers/formation-join.sh   's = s.replace("_mmry_client_name="+chr(34)+"$(mmry_host_client_name)"+chr(34), "_mmry_client_name="+chr(34)+"claude-code"+chr(34), 1)'   handlers/codex-session.bats "registers the session as codex"
mutate "formation-start registers every session as claude-code" hooks-handlers/formation-start.sh   's = s.replace("_mmry_client_name="+chr(34)+"$(mmry_host_client_name)"+chr(34), "_mmry_client_name="+chr(34)+"claude-code"+chr(34), 1)'   handlers/codex-session.bats "starting a formation"
mutate "setup exports its opt-out into everything it spawns" setup/mmry-setup.sh   's = s.replace("MMRY_ALLOW_NO_CREDENTIAL=1", "export MMRY_ALLOW_NO_CREDENTIAL=1", 1).replace(chr(10) + "unset MMRY_ALLOW_NO_CREDENTIAL", "", 1)'   e2e/codex-setup.bats "does not leak"
mutate "the tool-call delivery handler does nothing at all" hooks-handlers/formation-check.sh   's = s.replace("#!/usr/bin/env bash", "#!/usr/bin/env bash"+chr(10)+"exit 1", 1)'   structural/codex-formation-delivery.bats "never cancels a tool call"
mutate "the Codex skill becomes a byte-for-byte copy of the Claude Code one" skills-codex/memory-system/SKILL.md   's = io.open(p.replace("skills-codex", "skills"), encoding="utf-8").read().replace(chr(13) + chr(10), chr(10))'   structural/codex-manifest.bats "DIFFERENT document"

echo
echo "=== refused: $REFUSED   survived: $SURVIVED   experiments not performed: $ERRORS   (ran $RUN of $TOTAL) ==="
if [[ -n "${MMRY_MUTATION_FILTER:-}" ]]; then
    echo "FILTERED RUN: only labels containing '${MMRY_MUTATION_FILTER}' were run; $SKIPPED were" >&2
    echo "skipped. This is not a result about the suite, only about the experiments named." >&2
elif [[ "$RUN" -ne "$TOTAL" ]]; then
    echo "INCOMPLETE: this run stopped after $RUN of $TOTAL experiments. Do not report its counts" >&2
    echo "as a result - a truncated run says nothing about the mutations it never reached." >&2
fi
if [[ -n "$SURVIVOR_LIST" ]]; then
    echo "SURVIVING MUTANTS - these assertions cannot fail:${SURVIVOR_LIST}" >&2
fi
if [[ -n "$ERROR_LIST" ]]; then
    echo "EXPERIMENTS THAT DID NOT RUN. This is a fault in the harness, NOT a finding about a" >&2
    echo "test, and the counts above are incomplete until it is fixed:${ERROR_LIST}" >&2
fi
[[ "$SURVIVED" -eq 0 && "$ERRORS" -eq 0 && ( "$RUN" -eq "$TOTAL" || -n "${MMRY_MUTATION_FILTER:-}" ) ]]
