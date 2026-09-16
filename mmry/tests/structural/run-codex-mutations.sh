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
# was seen to refuse" is reproducible by whoever reviews it rather than taken on trust.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLUGIN="$REPO_ROOT/mmry"
TESTS="$PLUGIN/tests"
BATS="$TESTS/libs/bats-core/bin/bats"

cd "$REPO_ROOT" || exit 1

if [[ -n "$(git status --porcelain -- mmry)" ]]; then
    echo "REFUSING: the working tree under mmry/ is dirty. Commit or stash first, because each" >&2
    echo "mutation is undone with 'git checkout -- <file>' and would discard your edits." >&2
    exit 1
fi

PASS=0
FAIL=0

# mutate <label> <file> <python-expression-file-edit> <test-file> <expected-failing-test-substring>
mutate() {
    local label="$1" file="$2" pyfrag="$3" testfile="$4" expect="$5"

    python - "$PLUGIN/$file" <<PY
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
before = s
$pyfrag
if s == before:
    sys.stderr.write("MUTATION DID NOT APPLY\n")
    sys.exit(3)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
PY
    local applied=$?
    if [[ $applied -ne 0 ]]; then
        printf 'NOT APPLIED  %s\n' "$label"
        FAIL=$((FAIL + 1))
        git checkout -- "mmry/$file" 2>/dev/null
        return
    fi

    local out
    out="$("$BATS" "$TESTS/$testfile" 2>&1)"
    git checkout -- "mmry/$file"

    if printf '%s' "$out" | grep -q "^not ok.*${expect}"; then
        printf 'REFUSED      %s\n' "$label"
        PASS=$((PASS + 1))
    else
        local n
        n="$(printf '%s' "$out" | grep -c '^not ok' || true)"
        if [[ "$n" -gt 0 ]]; then
            printf 'REFUSED(*)   %s   [%s test(s) failed, but not the named one]\n' "$label" "$n"
            printf '%s' "$out" | grep '^not ok' | sed 's/^/                 /'
            PASS=$((PASS + 1))
        else
            printf 'SURVIVED     %s   <-- THIS ASSERTION CANNOT FAIL\n' "$label"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "=== #31245 mutation run ==="

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

# ---- requirement-4 guards on the Claude surface ----------------------------------------------
mutate "a Claude command file gains frontmatter" commands/setup.md \
  "s = '---\ndescription: x\n---\n' + s" \
  structural/codex-manifest.bats "gained YAML frontmatter"

mutate "the e2e fixture stops copying lib-host" tests/e2e/setup-join.bats   's = s.replace("cp "+chr(34)+chr(36)+"PLUGIN_ROOT/hooks-handlers/lib-host.sh"+chr(34), "true #", 1)'   structural/codex-manifest.bats "mirrored by the e2e fixture"
# ---- the model-invoked credential path, and the incomplete-copy fallbacks -------------------
mutate "lib-host stops reading the host off its own location" hooks-handlers/lib-host.sh   's = s.replace("*/.codex/*", "*/.no-such-marker/*", 1)'   handlers/codex-hook.bats "resolves the CODEX credential"

mutate "lib-host stops exporting MMRY_CONFIG_FILE" hooks-handlers/lib-host.sh   's = s.replace("export MMRY_CONFIG_FILE=", "_MMRY_UNUSED=", 1)'   handlers/codex-hook.bats "resolves the CODEX credential"

mutate "lib-jq stops sourcing the host resolver" hooks-handlers/lib-jq.sh   's = s.replace("/lib-host.sh" + chr(34) + " 2>/dev/null || true", "/lib-host-absent.sh" + chr(34) + " 2>/dev/null || true", 1)'   handlers/codex-hook.bats "resolves the CODEX credential"

mutate "location detection overreaches to any CODEX_HOME in the environment" hooks-handlers/lib-host.sh   's = s.replace("if [[ -z " + chr(34) + "${MMRY_HOST:-}" + chr(34) + " ]]; then", "if [[ -z " + chr(34) + "${MMRY_HOST:-}" + chr(34) + " ]]; then\n    [[ -n " + chr(34) + "${CODEX_HOME:-}" + chr(34) + " ]] && MMRY_HOST=codex", 1)'   handlers/codex-hook.bats "does NOT make a Claude install think it is Codex"

mutate "hook-guard loses its missing-resolver fallback" hooks-handlers/hook-guard.sh   's = s.replace("TARGET=" + chr(34) + "${HOME}/.claude/mmry/hooks-handlers/${SCRIPT_NAME}.sh" + chr(34), "TARGET=" + chr(34) + "/nonexistent/${SCRIPT_NAME}.sh" + chr(34), 1)'   handlers/codex-hook.bats "hook-guard with NO lib-host.sh"

mutate "stop-check loses its missing-resolver fallback" hooks-handlers/stop-check.sh   's = s.replace("    mmry_host_script_ref() { printf ", "    _unused_ref() { printf ", 1)'   handlers/codex-hook.bats "stop-check with NO lib-host.sh"

# ---- the one command a new Codex customer runs -----------------------------------------------
mutate "setup forces the host to claude before resolving" setup/mmry-setup.sh   's = s.replace("[[ -n " + chr(34) + "${MMRY_HOST:-}" + chr(34) + " ]] && export MMRY_HOST", "export MMRY_HOST=" + chr(34) + "${MMRY_HOST:-claude}" + chr(34), 1)'   e2e/codex-setup.bats "writes ~/.codex/mmry-config.json"

echo "=== refused: $PASS   survived: $FAIL ==="
[[ "$FAIL" -eq 0 ]]
