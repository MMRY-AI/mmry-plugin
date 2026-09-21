#!/usr/bin/env bats
# codex-hook.bats — the Codex entry point and the two delivery routes that differ by host (#31245).
#
# These exercise behaviour, not shape. The structural file checks that the registration says the
# right thing; this one checks that running it does the right thing.
#
# EVERY ASSERTION HERE WAS SEEN TO REFUSE under tests/structural/run-codex-mutations.sh.
# The mutation applied to each, and the run it was observed in, are recorded in
# tests/structural/CODEX-MUTATIONS.md, which is committed beside the harness.

load '../helpers/test-helper'

SHIM=""

setup() {
    SHIM="$PLUGIN_ROOT/hooks-handlers/codex-hook.sh"
    export TEST_HOME="$TEST_TMPDIR/home"
    mkdir -p "$TEST_HOME"
}

# ---------------------------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------------------------

@test "shim: dispatches to the named handler and passes its arguments through" {
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "PROBE ran with: $*"\n' > "$dir/probe.sh"
    run bash "$dir/codex-hook.sh" probe alpha beta
    assert_success
    assert_output "PROBE ran with: alpha beta"
}

@test "shim: declares MMRY_HOST=codex to the handler it runs" {
    # This is the entire point of the file. Without it every handler behaves as though this were
    # Claude Code: Claude credential, Claude state directory, session registered as claude-code.
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "host=${MMRY_HOST:-UNSET}"\n' > "$dir/probe.sh"
    run bash "$dir/codex-hook.sh" probe
    assert_output "host=codex"
}

@test "shim: points MMRY_CONFIG_FILE at the Codex credential, which is why mmry-client.sh is untouched" {
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "cfg=${MMRY_CONFIG_FILE:-UNSET}"\n' > "$dir/probe.sh"
    run env -u MMRY_CONFIG_FILE -u CODEX_HOME HOME="$TEST_HOME" bash "$dir/codex-hook.sh" probe
    assert_output "cfg=${TEST_HOME}/.codex/mmry-config.json"
}

@test "shim: an MMRY_CONFIG_FILE already set is left alone, because it is the documented override" {
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "cfg=${MMRY_CONFIG_FILE}"\n' > "$dir/probe.sh"
    run env MMRY_CONFIG_FILE=/tmp/explicit.json bash "$dir/codex-hook.sh" probe
    assert_output "cfg=/tmp/explicit.json"
}

@test "shim: derives CLAUDE_PLUGIN_ROOT from its own location rather than trusting the environment" {
    # It is also reachable from a hand-written hooks.json, from config.toml and from this suite,
    # none of which set it. A trusted-but-wrong value would send every handler to another install.
    local dir="$TEST_TMPDIR/plug/hooks-handlers"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "root=${CLAUDE_PLUGIN_ROOT}"\n' > "$dir/probe.sh"
    run env CLAUDE_PLUGIN_ROOT=/somewhere/else bash "$dir/codex-hook.sh" probe
    assert_output "root=$(cd "$TEST_TMPDIR/plug" && pwd)"
}

# ---------------------------------------------------------------------------------------------
# Refusals and fail-open
# ---------------------------------------------------------------------------------------------

@test "shim: a handler name carrying a path separator is refused, not resolved" {
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir/sub"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "ESCAPED"\n' > "$dir/sub/probe.sh"
    run bash "$dir/codex-hook.sh" "sub/probe"
    assert_success
    refute_output --partial "ESCAPED"
}

@test "shim: a traversing handler name is refused" {
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "ESCAPED"\n' > "$TEST_TMPDIR/probe.sh"
    run bash "$dir/codex-hook.sh" "../probe"
    assert_success
    refute_output --partial "ESCAPED"
}

@test "shim: an unknown handler exits 0 silently rather than failing the session" {
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    run bash "$dir/codex-hook.sh" no-such-handler
    assert_success
    assert_output ""
}

@test "shim: no handler name at all exits 0 silently" {
    run bash "$SHIM"
    assert_success
    assert_output ""
}

@test "shim: a handler's non-zero exit is NOT passed through, because it only breaks the session" {
    # THIS TEST IS THE INVERSE OF THE ONE IT REPLACES, AND THE OLD ONE WAS WRONG (2026-09-20).
    #
    # The old test required the shim to propagate exit 2, reasoning that exit 2 IS the delivery
    # channel and that swallowing it would silently disable the save prompt and formation
    # delivery. That was read from the platform's source and never run.
    #
    # MEASURED against real sessions: an emitter exiting 2 is reported Failed on EVERY event,
    # including SessionStart and Stop, and delivers nothing at all. The same emitter exiting 0 is
    # reported Completed. So propagating 2 bought a visible "hook exited with code 1" in front of
    # the customer, every turn, and no delivery whatsoever. Codex handlers deliver with
    # additionalContext on stdout and exit 0, which formation-check.sh already does.
    local dir="$TEST_TMPDIR/hh"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "to the model" >&2\nexit 2\n' > "$dir/probe.sh"
    run bash "$dir/codex-hook.sh" probe
    [[ "$status" -eq 0 ]] || { echo "shim exited $status; Codex renders any non-zero as a failed hook"; return 1; }
}

@test "failopen: an ordinary handler failure also leaves the hook reporting success" {
    local dir="$TEST_TMPDIR/hh2"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 7\n' > "$dir/probe.sh"
    run bash "$dir/codex-hook.sh" probe
    [[ "$status" -eq 0 ]] || { echo "shim exited $status"; return 1; }
}

@test "failopen: the entry point survives having no resolvable home at all" {
    # The defect that took the feature down on Windows: with HOME unset, "${HOME}/.codex" aborted
    # the hook under set -u with exit 1 and no output, before any of our code ran.
    local dir="$TEST_TMPDIR/hh3"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/probe.sh"
    run env -u HOME -u USERPROFILE -u HOMEDRIVE -u HOMEPATH -u CODEX_HOME \
        MMRY_HOST=codex bash "$dir/codex-hook.sh" probe
    [[ "$status" -eq 0 ]] || { echo "shim exited $status with no home resolvable"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# stop-check: the save prompt, and the amended requirement that it also covers compaction on Codex
# ---------------------------------------------------------------------------------------------

stop_run() {
    # Usage: stop_run <host>   -- returns stderr on stdout, and sets $status
    local host="$1"
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-count" "$TMPDIR/.mmry-last-save"
    if [[ "$host" == "codex" ]]; then
        MMRY_HOST=codex HOME="$TEST_HOME" bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" 2>&1 >/dev/null
    else
        env -u MMRY_HOST HOME="$TEST_HOME" bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" 2>&1 >/dev/null
    fi
}

@test "req4: on Claude Code the save directive still names \${CLAUDE_PLUGIN_ROOT} unexpanded" {
    run stop_run claude
    assert_output --partial '"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh"'
}

@test "req4: on Claude Code the save directive carries NO compaction sentence" {
    # precompact-check.sh still owns that job there. Adding it would be a second nag about the same
    # thing, and a behaviour change to a surface this task must not change.
    run stop_run claude
    refute_output --partial "trimmed"
}

@test "req4: on Claude Code the Stop hook still exits 2, which is how the directive is delivered" {
    run stop_run claude
    [[ "$status" -eq 2 ]]
}

@test "amended req: on Codex the save directive carries the compaction warning" {
    # Codex has no PreCompact channel at all, so this sentence is the only warning a customer's
    # assistant ever gets that unsaved work can vanish.
    run stop_run codex
    assert_output --partial "before this conversation may be trimmed"
}

@test "amended req: on Codex the save prompt is otherwise the same prompt Claude Code produces" {
    run stop_run codex
    assert_output --partial "Save what is new since the last memory"
    assert_output --partial "If nothing new is worth keeping, skip and proceed."
}

@test "amended req: on Codex the Stop hook exits 2, which is what makes stderr the continuation prompt" {
    # events/stop.rs line 343: Some(2) with non-empty stderr sets continuation_prompt. Exit 0 would
    # deliver nothing at all.
    run stop_run codex
    [[ "$status" -eq 2 ]]
}

@test "codex: the save directive names an absolute path, never \${CLAUDE_PLUGIN_ROOT}" {
    run stop_run codex
    refute_output --partial 'CLAUDE_PLUGIN_ROOT'
    assert_output --partial "/.codex/mmry/hooks-handlers/save-memory.sh"
}

@test "codex: the Stop hook writes the directive to stderr and nothing to stdout" {
    # stop.command.output.schema.json has no hookSpecificOutput, and on exit 2 stdout is discarded.
    # Anything printed there is invisible at best.
    local out
    out="$(rm -f "$TMPDIR/.mmry-stop-checked"; MMRY_HOST=codex HOME="$TEST_HOME" bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" 2>/dev/null || true)"
    [[ -z "$out" ]]
}

# ---------------------------------------------------------------------------------------------
# hook-guard: the installed-handler directory it looks in
# ---------------------------------------------------------------------------------------------

@test "req4: hook-guard still looks in ~/.claude/mmry/hooks-handlers by default" {
    local dir="$TEST_TMPDIR/g"
    mkdir -p "$dir" "$TEST_HOME/.claude/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/hook-guard.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    printf '#!/usr/bin/env bash\necho "CLAUDE TARGET"\n' > "$TEST_HOME/.claude/mmry/hooks-handlers/probe.sh"
    run env -u MMRY_HOST HOME="$TEST_HOME" bash "$dir/hook-guard.sh" probe
    assert_output "CLAUDE TARGET"
}

@test "codex: hook-guard looks in the Codex directory, not the Claude one" {
    local dir="$TEST_TMPDIR/g"
    mkdir -p "$dir" "$TEST_HOME/.claude/mmry/hooks-handlers" "$TEST_HOME/.codex/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/hook-guard.sh" "$dir/"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    # Both exist and say different things, so "it found one" is not the same as "it found the
    # right one". A guard that fell back to the Claude tree would pass a test with only one.
    printf '#!/usr/bin/env bash\necho "CLAUDE TARGET"\n' > "$TEST_HOME/.claude/mmry/hooks-handlers/probe.sh"
    printf '#!/usr/bin/env bash\necho "CODEX TARGET"\n' > "$TEST_HOME/.codex/mmry/hooks-handlers/probe.sh"
    run env -u CODEX_HOME MMRY_HOST=codex HOME="$TEST_HOME" bash "$dir/hook-guard.sh" probe
    assert_output "CODEX TARGET"
}

# ---------------------------------------------------------------------------------------------
# The installer must not touch the other product's configuration
# ---------------------------------------------------------------------------------------------

@test "req4: setup --host codex does NOT write Claude Code's settings.json" {
    # A Codex setup that edited ~/.claude/settings.json would silently modify a customer's Claude
    # Code permissions during an install that has nothing to do with Claude Code. Checked by
    # reading the script's control flow rather than by running the whole browser flow: the write
    # is guarded by the host test, and the guard is what this asserts.
    run grep -c 'if \[\[ "$(mmry_host)" == "claude" \]\]' "$PLUGIN_ROOT/setup/mmry-setup.sh"
    assert_output "1"
}

# "setup with no --host still writes the Claude credential to ~/.claude" USED TO BE HERE AND WAS
# DEAD (#31245 QA round 2). It never invoked the installer: it sourced lib-host.sh and applied
# `MMRY_HOST=${MMRY_HOST:-claude}` itself, which is precisely the defect pattern commit ab7c5ab
# deleted FROM the installer - so the test reproduced the bug it claimed to guard against, and
# deleting mmry-setup.sh entirely left it green.
#
# The behaviour it claimed is now asserted where it can fail, by running the real script:
# tests/e2e/codex-setup.bats, "req4 control: the same command from a Claude install still writes
# ~/.claude/mmry-config.json" - which stages the installer, runs it with MMRY_HOST unset through
# the mocked device flow, and looks at the file on disk.

@test "codex: setup --host codex is accepted by the argument parser" {
    run bash "$PLUGIN_ROOT/setup/mmry-setup.sh" --host codex --help
    assert_success
    assert_output --partial "--host claude|codex"
}

@test "codex: an unknown argument is still rejected, so --host did not loosen the parser" {
    # A BARE non-zero status is not evidence here (#31245 QA round 2): deleting mmry-setup.sh
    # produces exit 127, which is also non-zero, so the assertion passed on a file that no longer
    # existed. The script must exist, must refuse the flag by name, and must say so.
    [[ -f "$PLUGIN_ROOT/setup/mmry-setup.sh" ]]
    run bash "$PLUGIN_ROOT/setup/mmry-setup.sh" --not-a-real-flag
    [[ "$status" -eq 1 ]]
    assert_output --partial "Unknown argument: --not-a-real-flag"
}

# ---------------------------------------------------------------------------------------------
# The model-invoked path: a handler the assistant runs itself, with nothing declared.
#
# These scripts are NOT run through codex-hook.sh. session-init.sh copies them into the host's MMRY
# directory and the model invokes them in a shell of its own, where MMRY_HOST is unset and always
# will be. Reproduced on 2026-09-15, before the fix: the Codex copy resolved
# ${HOME}/.claude/mmry-config.json, the other product's credential.
# ---------------------------------------------------------------------------------------------

_install_two_hosts() {
    # Builds a machine with BOTH products installed and a DIFFERENT credential under each, so
    # "it found a credential" cannot be mistaken for "it found the right one".
    mkdir -p "$TEST_HOME/.codex/mmry/hooks-handlers" "$TEST_HOME/.claude/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$TEST_HOME/.codex/mmry/hooks-handlers/"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$TEST_HOME/.claude/mmry/hooks-handlers/"
    cp -r "$PLUGIN_ROOT/vendor" "$TEST_HOME/.codex/mmry/" 2>/dev/null || true
    cp -r "$PLUGIN_ROOT/vendor" "$TEST_HOME/.claude/mmry/" 2>/dev/null || true
    printf '{"apiUrl":"https://claude.example","authMethod":"apikey","apiKey":"claude-key"}' \
        > "$TEST_HOME/.claude/mmry-config.json"
    printf '{"apiUrl":"https://codex.example","authMethod":"apikey","apiKey":"codex-key"}' \
        > "$TEST_HOME/.codex/mmry-config.json"
}

_resolve_from() {
    # Source the client from one install with nothing declared, and report what it resolved.
    local dir="$1"
    env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME HOME="$TEST_HOME" \
        bash -c "source '${dir}/mmry-client.sh' >/dev/null 2>&1; printf '%s' \"\$MMRY_API_KEY\""
}

@test "codex: a model-invoked handler resolves the CODEX credential, not the Claude one" {
    _install_two_hosts
    run _resolve_from "$TEST_HOME/.codex/mmry/hooks-handlers"
    assert_output "codex-key"
}

@test "req4: the same machine's Claude install still resolves the Claude credential" {
    # The control. Without it the test above is satisfied by any change that breaks both.
    _install_two_hosts
    run _resolve_from "$TEST_HOME/.claude/mmry/hooks-handlers"
    assert_output "claude-key"
}

@test "codex: a Codex install with no Claude config at all still resolves, rather than failing" {
    # The worse half of the original defect: on a Codex-only machine there is no
    # ${HOME}/.claude/mmry-config.json, so every model-invoked save failed with "No API key
    # configured. Run /mmry:setup" - naming a command Codex customers cannot type.
    mkdir -p "$TEST_HOME/.codex/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$TEST_HOME/.codex/mmry/hooks-handlers/"
    cp -r "$PLUGIN_ROOT/vendor" "$TEST_HOME/.codex/mmry/" 2>/dev/null || true
    printf '{"apiUrl":"https://codex.example","authMethod":"apikey","apiKey":"codex-only-key"}' \
        > "$TEST_HOME/.codex/mmry-config.json"
    [[ ! -f "$TEST_HOME/.claude/mmry-config.json" ]]
    run _resolve_from "$TEST_HOME/.codex/mmry/hooks-handlers"
    assert_output "codex-only-key"
}

@test "codex: CODEX_HOME in the environment alone does NOT make a Claude install think it is Codex" {
    # The sniffing failure this deliberately avoids: a developer who installs Codex should not have
    # their Claude Code sessions silently repointed at a different config directory.
    _install_two_hosts
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT \
        CODEX_HOME="$TEST_HOME/.codex" HOME="$TEST_HOME" \
        bash -c "source '$TEST_HOME/.claude/mmry/hooks-handlers/mmry-client.sh' >/dev/null 2>&1; printf '%s' \"\$MMRY_API_KEY\""
    assert_output "claude-key"
}

@test "codex: a relocated CODEX_HOME is recognised by location" {
    local ch="$TEST_TMPDIR/custom-codex"
    mkdir -p "$ch/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$ch/mmry/hooks-handlers/"
    cp -r "$PLUGIN_ROOT/vendor" "$ch/mmry/" 2>/dev/null || true
    mkdir -p "$TEST_HOME/.claude"
    printf '{"apiUrl":"https://codex.example","authMethod":"apikey","apiKey":"relocated-key"}' \
        > "$ch/mmry-config.json"
    printf '{"apiUrl":"https://claude.example","authMethod":"apikey","apiKey":"claude-key"}' \
        > "$TEST_HOME/.claude/mmry-config.json"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT \
        CODEX_HOME="$ch" HOME="$TEST_HOME" \
        bash -c "source '$ch/mmry/hooks-handlers/mmry-client.sh' >/dev/null 2>&1; printf '%s' \"\$MMRY_API_KEY\""
    assert_output "relocated-key"
}

# ---------------------------------------------------------------------------------------------
# AND WHEN THE CODEX CREDENTIAL IS MISSING, NOTHING MAY BORROW THE CLAUDE ONE (#31245 QA round 2).
#
# Setting MMRY_CONFIG_FILE was only half the fix. mmry-client.sh's first branch tests that the file
# EXISTS; on a Codex install that has not been set up, that test is false and the chain walks on to
# ${HOME}/.claude/mmry-config.json. A sentinel key proved it on 2026-09-16. These assert the
# refusal, with a sentinel that makes "it found a credential" impossible to mistake for "it found
# the right one".
# ---------------------------------------------------------------------------------------------

_install_codex_only_unconfigured() {
    # A Codex install with NO Codex credential, on a machine that has a Claude credential.
    mkdir -p "$TEST_HOME/.codex/mmry/hooks-handlers" "$TEST_HOME/.claude"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$TEST_HOME/.codex/mmry/hooks-handlers/"
    cp -r "$PLUGIN_ROOT/vendor" "$TEST_HOME/.codex/mmry/" 2>/dev/null || true
    printf '{"apiUrl":"https://claude.example","authMethod":"apikey","apiKey":"claude-sentinel"}'         > "$TEST_HOME/.claude/mmry-config.json"
    [[ ! -f "$TEST_HOME/.codex/mmry-config.json" ]]
}

@test "codex: with no Codex credential the client REFUSES rather than resolving the Claude one" {
    _install_codex_only_unconfigured
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME HOME="$TEST_HOME"         bash -c "source '$TEST_HOME/.codex/mmry/hooks-handlers/mmry-client.sh' 2>/dev/null; printf 'RESOLVED:%s' \"\$MMRY_API_KEY\""
    [[ "$status" -ne 0 ]]
    refute_output --partial "claude-sentinel"
    refute_output --partial "RESOLVED:"
}

@test "codex: the refusal SAYS SO, naming the file it wanted and the command that makes it" {
    # Silence here would be the same failure in a different costume: an install that appears to
    # work and quietly does nothing.
    _install_codex_only_unconfigured
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME HOME="$TEST_HOME"         bash -c "source '$TEST_HOME/.codex/mmry/hooks-handlers/mmry-client.sh' 2>&1 >/dev/null"
    assert_output --partial "no Codex credential was found"
    assert_output --partial "${TEST_HOME}/.codex/mmry-config.json"
    assert_output --partial "bash ~/.codex/mmry/setup/mmry-setup.sh"
}

@test "req4: a Claude install with no credential at all is unaffected, as it always was" {
    # The control. The refusal is Codex-only; on Claude Code an absent credential still produces
    # the client's own "No API key configured" path, not an exit from sourcing.
    mkdir -p "$TEST_HOME/.claude/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$TEST_HOME/.claude/mmry/hooks-handlers/"
    cp -r "$PLUGIN_ROOT/vendor" "$TEST_HOME/.claude/mmry/" 2>/dev/null || true
    [[ ! -f "$TEST_HOME/.claude/mmry-config.json" ]]
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME HOME="$TEST_HOME"         bash -c "source '$TEST_HOME/.claude/mmry/hooks-handlers/mmry-client.sh' 2>/dev/null; printf 'SOURCED-OK'"
    assert_success
    assert_output --partial "SOURCED-OK"
}

@test "codex: the installer itself still runs with no credential, or setup would be impossible" {
    # The opt-out is load-bearing: mmry-setup.sh is the program that CREATES the credential, and
    # lib-jq.sh refuses when there is none. Without MMRY_ALLOW_NO_CREDENTIAL the fix above would
    # make a first install unreachable. --help exercises the same preamble without a browser.
    _install_codex_only_unconfigured
    cp "$PLUGIN_ROOT/setup/mmry-setup.sh" "$TEST_HOME/.codex/mmry/setup-copy.sh" 2>/dev/null || {
        mkdir -p "$TEST_HOME/.codex/mmry/setup"
        cp "$PLUGIN_ROOT/setup/mmry-setup.sh" "$TEST_HOME/.codex/mmry/setup/mmry-setup.sh"
    }
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME HOME="$TEST_HOME"         MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"         bash "$PLUGIN_ROOT/setup/mmry-setup.sh" --host codex --help
    assert_success
    assert_output --partial "--host claude|codex"
}

@test "req4: an explicit MMRY_CONFIG_FILE still outranks everything, on both hosts" {
    _install_two_hosts
    printf '{"apiUrl":"https://explicit.example","authMethod":"apikey","apiKey":"explicit-key"}' \
        > "$TEST_TMPDIR/explicit.json"
    run env -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u CODEX_HOME HOME="$TEST_HOME" \
        MMRY_CONFIG_FILE="$TEST_TMPDIR/explicit.json" \
        bash -c "source '$TEST_HOME/.codex/mmry/hooks-handlers/mmry-client.sh' >/dev/null 2>&1; printf '%s' \"\$MMRY_API_KEY\""
    assert_output "explicit-key"
}

# ---------------------------------------------------------------------------------------------
# A CURATED COPY THAT LACKS lib-host.sh MUST STILL BEHAVE EXACTLY AS IT DID BEFORE #31245.
#
# hook-guard.sh and stop-check.sh both run from the COPIED handler directory, which is assembled
# by whoever did the copying. session-init.sh copies hooks-handlers/*.sh, so a real install always
# has the resolver - but a curated copy may not, and one exists in this suite today. Before these
# guards an incomplete copy killed the hook with "No such file or directory" on a line number.
# ---------------------------------------------------------------------------------------------

@test "req4: hook-guard with NO lib-host.sh falls back to the Claude path it always used" {
    local dir="$TEST_TMPDIR/nolib"
    mkdir -p "$dir" "$TEST_HOME/.claude/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/hook-guard.sh" "$dir/"
    [[ ! -f "$dir/lib-host.sh" ]]
    printf '#!/usr/bin/env bash\necho "FALLBACK TARGET"\n' > "$TEST_HOME/.claude/mmry/hooks-handlers/probe.sh"
    run env -u MMRY_HOST HOME="$TEST_HOME" bash "$dir/hook-guard.sh" probe
    assert_success
    assert_output "FALLBACK TARGET"
}

@test "req4: stop-check with NO lib-host.sh still produces the Claude Code directive" {
    local dir="$TEST_TMPDIR/nolib2"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" "$dir/"
    [[ ! -f "$dir/lib-host.sh" ]]
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-count" "$TMPDIR/.mmry-last-save"
    run env -u MMRY_HOST HOME="$TEST_HOME" bash -c "bash '$dir/stop-check.sh' 2>&1 >/dev/null"
    assert_output --partial '"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh"'
    refute_output --partial "trimmed"
}

@test "control: with lib-host.sh present the same stop-check call still works" {
    # Without this the test above is satisfied by a stop-check that is broken in both cases.
    local dir="$TEST_TMPDIR/withlib"
    mkdir -p "$dir"
    cp "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" "$PLUGIN_ROOT/hooks-handlers/lib-host.sh" "$dir/"
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-count" "$TMPDIR/.mmry-last-save"
    run env -u MMRY_HOST HOME="$TEST_HOME" bash -c "bash '$dir/stop-check.sh' 2>&1 >/dev/null"
    assert_output --partial '"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh"'
}

# ---------------------------------------------------------------------------------------------
# THE ONE COMMAND A NEW CODEX CUSTOMER RUNS is covered in tests/e2e/codex-setup.bats, which RUNS
# mmry-setup.sh through the mocked device-authorization flow and looks at where the credential
# file actually landed.
#
# It is not covered here any more. The first version of these tests asserted against a helper that
# reproduced the script's host-resolution preamble, and that helper passed while the real script
# was broken - a replica of the code under test is not the code under test. The one check kept
# below reads the script's source, and is honest about being a source check.
# ---------------------------------------------------------------------------------------------

@test "req4: mmry-setup.sh does not force MMRY_HOST before sourcing the resolver" {
    # The defect in source form, because the behavioural tests above depend on the staging helper
    # reproducing the script's control flow rather than running the script's browser flow.
    run grep -c 'export MMRY_HOST="${MMRY_HOST:-claude}"' "$PLUGIN_ROOT/setup/mmry-setup.sh"
    assert_output "0"
}
