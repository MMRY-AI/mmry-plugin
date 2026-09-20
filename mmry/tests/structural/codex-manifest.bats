#!/usr/bin/env bats
# codex-manifest.bats — the Codex surface, checked against Codex's own declarations (#31245).
#
# WHERE THE EXPECTED VALUES COME FROM. Not from Codex's prose documentation, which barely mentions
# hooks: from the machine-readable declarations in openai/codex, read directly, each named beside
# the constant it produced. Prose about software is a hint; the software's own declaration is the
# answer.
#
#   HOOK_EVENT_NAMES                      codex-rs/hooks/src/lib.rs line 23
#   HOOK_EVENT_NAMES_WITH_MATCHERS        codex-rs/hooks/src/lib.rs line 43
#   HooksFile / HookHandlerConfig fields  codex-rs/config/src/hook_config.rs
#   discoverable manifest paths           codex-rs/exec-server-protocol/src/protocol.rs line 47
#   which events can return model text    codex-rs/hooks/schema/generated/*.output.schema.json
#   command->skill migration rules        codex-rs/core-plugins/src/command_migration.rs
#
# Read at openai/codex commit 5bf132c (2026-09-15) against the installed codex-cli 0.154.0.
#
# EVERY ASSERTION HERE WAS SEEN TO REFUSE under tests/structural/run-codex-mutations.sh. The
# mutation applied to each is recorded in tests/structural/CODEX-MUTATIONS.md, beside it.

load '../helpers/test-helper'

CODEX_MANIFEST=""
CODEX_HOOKS=""

setup() {
    CODEX_MANIFEST="$PLUGIN_ROOT/.codex-plugin/plugin.json"
    CODEX_HOOKS="$PLUGIN_ROOT/hooks/codex-hooks.json"
}

# ---------------------------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------------------------

@test "codex manifest: exists at .codex-plugin/plugin.json, the path Codex looks at FIRST" {
    # DISCOVERABLE_PLUGIN_MANIFEST_PATHS is [.codex-plugin, .claude-plugin, .cursor-plugin] in
    # that order. Being first is the whole mechanism: it is how the Codex surface is declared
    # without editing the Claude Code manifest.
    [[ -f "$CODEX_MANIFEST" ]]
}

@test "codex manifest: is valid JSON" {
    jq empty "$CODEX_MANIFEST"
}

@test "codex manifest: plugin name is mmry" {
    run jq -r '.name' "$CODEX_MANIFEST"
    assert_output "mmry"
}

@test "codex manifest: carries NO version, so no second copy of it can drift from the marketplace" {
    # RawPluginManifest.version is Option<String> and the crate's own tests parse manifests with
    # none, so omitting it is supported rather than merely tolerated. The marketplace entry is the
    # single place a version is stated.
    run jq -r 'has("version")' "$CODEX_MANIFEST"
    assert_output "false"
}

@test "codex manifest: every declared path uses the ./ form the parser requires" {
    local paths
    paths="$(jq -r '[.hooks, .skills, .commands] | .[] | select(. != null)' "$CODEX_MANIFEST" | tr -d '\r')"
    [[ -n "$paths" ]]
    while IFS= read -r p; do
        [[ "$p" == ./* ]] || { echo "manifest path does not start with ./ : $p"; return 1; }
    done <<< "$paths"
}

@test "codex manifest: every declared path exists on disk" {
    local p
    for p in $(jq -r '[.hooks, .skills, .commands] | .[] | select(. != null)' "$CODEX_MANIFEST" | tr -d '\r'); do
        local resolved="${PLUGIN_ROOT}/${p#./}"
        [[ -e "$resolved" ]] || { echo "declared path missing: $p -> $resolved"; return 1; }
    done
}

@test "codex manifest: points hooks at codex-hooks.json, NOT at the Claude Code hooks.json" {
    # Sharing hooks.json would register PreCompact (no channel on Codex), the ExitPlanMode matcher
    # (no such tool) and an asyncRewake Stop poller (a field Codex does not have) - and would make
    # every future Codex change a change to the Claude Code registration.
    run jq -r '.hooks' "$CODEX_MANIFEST"
    assert_output "./hooks/codex-hooks.json"
}

@test "codex manifest: points skills at its own directory, so Claude Code gains no skills" {
    run jq -r '.skills' "$CODEX_MANIFEST"
    assert_output "./skills-codex/"
}

@test "codex manifest: and that directory is a DIFFERENT document from the Claude Code skill" {
    # THE REFUTATION THIS REPLACES COULD NOT FAIL (#31245 QA round 3). It read
    # `refute_output "./skills/"` on the line after `assert_output "./skills-codex/"`, which had
    # already pinned the value to a different string - so the refutation restated a test that had
    # just been made and would have been satisfied by any manifest the assertion accepted.
    #
    # What it was reaching for is a real property, and this asserts that instead: the Codex skill
    # exists, it is not a copy of the Claude Code one, and it is the one that describes THIS
    # platform. Pointing the manifest at ./skills/ - or copying the Claude document into
    # skills-codex/ - fails here, and either would ship a Codex customer instructions telling them
    # to type slash commands Codex does not have.
    local codex_skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md"
    local claude_skill="$PLUGIN_ROOT/skills/memory-system/SKILL.md"
    [[ -f "$codex_skill" ]] || { echo "the declared Codex skill directory has no SKILL.md"; return 1; }
    [[ -f "$claude_skill" ]] || { echo "the Claude Code skill has moved; this test needs updating"; return 1; }
    cmp -s "$codex_skill" "$claude_skill" && { echo "the Codex skill is byte-identical to the Claude Code one"; return 1; }
    grep -qi 'codex' "$codex_skill" || { echo "the Codex skill never mentions the platform it is for"; return 1; }
    # And the Claude Code document is still the Claude Code document, unmentioning Codex - which is
    # requirement 4 stated about the file a Claude Code customer actually receives.
    run bash -c "grep -ci codex '$claude_skill' || true"
    assert_output "0"
}

@test "codex manifest: names a commands directory explicitly rather than inheriting the default" {
    # An omitted commands key defaults to <plugin-root>/commands
    # (command_migration/plugin.rs, PLUGIN_COMMANDS_DIR = "commands"), which is the Claude Code
    # command directory. Naming an empty one is how this says "no migrated commands" out loud.
    run jq -r '.commands' "$CODEX_MANIFEST"
    assert_output "./commands-codex/"
}

@test "codex manifest: the commands directory contains no file the migrator would convert" {
    # A .md whose stem is not README and which carries frontmatter would silently become a skill.
    local f
    for f in "$PLUGIN_ROOT"/commands-codex/*.md; do
        [[ -e "$f" ]] || continue
        local stem
        stem="$(basename "$f" .md)"
        [[ "$stem" == "README" ]] || { echo "migratable command file present: $f"; return 1; }
    done
}

@test "codex manifest: interface carries the fields the catalogue shows a customer" {
    run jq -r '[.interface.displayName, .interface.shortDescription, .interface.developerName, .interface.websiteURL] | map(select(. != null and . != "")) | length' "$CODEX_MANIFEST"
    assert_output "4"
}

# ---------------------------------------------------------------------------------------------
# The hook registration
# ---------------------------------------------------------------------------------------------

@test "codex hooks: is valid JSON" {
    jq empty "$CODEX_HOOKS"
}

@test "codex hooks: the top level carries only description and hooks" {
    # HooksFile is #[serde(deny_unknown_fields)] with exactly those two. Any third key is a parse
    # failure, and a hooks file that fails to parse registers NOTHING - silently, from a customer's
    # point of view.
    run jq -r '[keys[]] | sort | join(",")' "$CODEX_HOOKS"
    assert_output "description,hooks"
}

@test "codex hooks: every event name is one Codex declares" {
    local valid=" PreToolUse PermissionRequest PostToolUse PreCompact PostCompact SessionStart SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt "
    local e
    for e in $(jq -r '.hooks | keys[]' "$CODEX_HOOKS" | tr -d '\r'); do
        [[ "$valid" == *" $e "* ]] || { echo "unknown Codex hook event: $e"; return 1; }
    done
}

@test "codex hooks: every handler carries only fields HookHandlerConfig::Command declares" {
    # command, commandWindows, timeout, async, statusMessage, additionalContextLimit - plus the
    # "type" tag. asyncRewake and rewakeSummary, which the Claude Code hooks.json uses, are NOT
    # among them: Codex's own Claude-settings importer skips any handler carrying asyncRewake
    # (external-agent-migration/src/hooks_cla.rs line 158).
    local valid=" type command commandWindows timeout async statusMessage additionalContextLimit "
    local k
    for k in $(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | keys[]' "$CODEX_HOOKS" | tr -d '\r' | sort -u); do
        [[ "$valid" == *" $k "* ]] || { echo "field not in Codex's handler schema: $k"; return 1; }
    done
}

@test "codex hooks: no handler declares additionalContextLimit" {
    # Present in the current source but absent from shipped builds as recently as 0.144.5, and
    # HooksFile denies unknown fields, so emitting it risks a total parse failure on an older
    # client. The default spill threshold is fine for a payload that already points at a file.
    run jq -r '[.hooks | to_entries[] | .value[] | .hooks[] | select(has("additionalContextLimit"))] | length' "$CODEX_HOOKS"
    assert_output "0"
}

@test "codex hooks: every handler is synchronous, which is what exit 2 delivery requires" {
    # engine/mod.rs: can_apply_control_effects() is true only for Sync. An async handler's exit 2
    # is discarded, so an async Stop hook would deliver the save prompt to nobody.
    run jq -r '[.hooks | to_entries[] | .value[] | .hooks[] | select(.async == true)] | length' "$CODEX_HOOKS"
    assert_output "0"
}

@test "codex hooks: PreCompact is NOT registered, because it has no channel to the model" {
    # pre-compact.command.output.schema.json carries only continue/stopReason/suppressOutput/
    # systemMessage - no hookSpecificOutput, no decision - and compact.rs has no case for exit 2.
    # A PreCompact handler here would look installed and deliver nothing.
    run jq -r '.hooks | has("PreCompact")' "$CODEX_HOOKS"
    assert_output "false"
}

@test "codex hooks: no matcher targets ExitPlanMode, a tool Codex does not have" {
    run jq -r '[.hooks | to_entries[] | .value[] | select(.matcher == "ExitPlanMode")] | length' "$CODEX_HOOKS"
    assert_output "0"
}

@test "codex hooks: the formation poller is NOT registered on Stop" {
    # A synchronous Stop handler that polls for four minutes holds the end of every turn open. The
    # idle-delivery mechanism it implements depends on asyncRewake, which Codex does not have.
    run jq -r '[.hooks.Stop[]? | .hooks[] | .command | select(contains("formation-check"))] | length' "$CODEX_HOOKS"
    assert_output "0"
}

@test "codex hooks: the save prompt IS registered on Stop" {
    # The amended requirement on #31245: the prompt to save before the conversation is trimmed is
    # not optional and moves to the end of the session on this platform.
    run jq -r '[.hooks.Stop[]? | .hooks[] | .command | select(contains("stop-check"))] | length' "$CODEX_HOOKS"
    assert_output "1"
}

@test "codex hooks: memories are loaded on SessionStart" {
    run jq -r '[.hooks.SessionStart[]? | .hooks[] | .command | select(contains("session-init"))] | length' "$CODEX_HOOKS"
    assert_output "1"
}

@test "codex hooks: formation messages are delivered on PostToolUse" {
    run jq -r '[.hooks.PostToolUse[]? | .hooks[] | .command | select(contains("formation-check"))] | length' "$CODEX_HOOKS"
    assert_output "1"
}

@test "codex hooks: the PostToolUse formation group carries NO matcher, so it runs on every tool" {
    # matches_matcher(None, _) is true (events/common.rs). A matcher here would silence delivery
    # for every tool but one.
    run jq -r '[.hooks.PostToolUse[] | select(has("matcher"))] | length' "$CODEX_HOOKS"
    assert_output "0"
}

@test "codex hooks: Foundation re-injection is registered on UserPromptSubmit" {
    run jq -r '[.hooks.UserPromptSubmit[]? | .hooks[] | .command | select(contains("userpromptsubmit-foundation"))] | length' "$CODEX_HOOKS"
    assert_output "1"
}

@test "codex hooks: every handler routes through codex-hook.sh, never straight at a handler" {
    # The entry point is what sets MMRY_HOST. A command naming a handler directly would run it as
    # though this were Claude Code: it would read the Claude credential, write to the Claude state
    # directory, and register the session as claude-code.
    local n_total n_routed
    n_total="$(jq -r '[.hooks | to_entries[] | .value[] | .hooks[]] | length' "$CODEX_HOOKS")"
    n_routed="$(jq -r '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | contains("codex-hook.sh"))] | length' "$CODEX_HOOKS")"
    [[ "$n_total" -gt 0 ]]
    [[ "$n_total" == "$n_routed" ]] || { echo "$n_routed of $n_total handlers route through codex-hook.sh"; return 1; }
}

@test "codex hooks: NO handler declares commandWindows, because it silently eats the output" {
    # THIS TEST IS THE INVERSE OF THE ONE IT REPLACES, AND THE OLD ONE WAS WRONG (#31245, 2026-09-20).
    #
    # The old test required every handler to carry commandWindows, reasoning that Windows runs
    # COMSPEC /C and a POSIX command string would leave ${PLUGIN_ROOT} unexpanded. The reasoning was
    # plausible and the consequence was that the entire Codex feature did nothing on Windows.
    #
    # MEASURED on codex-cli 0.154.0, against a real session, with a batch file that echoes a valid
    # additionalContext payload carrying a unique token:
    #
    #   commandWindows declared      -> hook reports Completed, token appears 0 times in the
    #                                   transcript, and Codex injects THE COMMAND STRING ITSELF as
    #                                   hooks.additional_context. The handler output never arrives.
    #   commandWindows absent        -> token appears 4 times. Output is consumed correctly.
    #
    # A second, independent fault in the same field: commandWindows fails outright when it carries
    # an argument. One identical file invoked bare Completes; invoked as "<path>" session-init it
    # Fails, and so do the unquoted, `call` and `cmd /c` forms. Every MMRY hook passes a handler
    # name, which is why all six failed rather than misbehaved.
    local n_win
    n_win="$(jq -r '[.hooks | to_entries[] | .value[] | .hooks[] | select(.commandWindows != null)] | length' "$CODEX_HOOKS")"
    [[ "$n_win" == "0" ]] || {
        echo "$n_win handler(s) declare commandWindows; on Windows that stops Codex consuming their stdout"
        return 1
    }
}

@test "codex hooks: every command uses Codex own PLUGIN_ROOT token, not the other product alias" {
    # ${PLUGIN_ROOT} is expanded by Codex itself, on every platform, and was measured working:
    # the same token emitter referenced this way delivered its payload 4 times.
    #
    # It replaces %CLAUDE_PLUGIN_ROOT% and ${D}{CLAUDE_PLUGIN_ROOT}. Those name the OTHER product's
    # compatibility alias, which occurs exactly ONCE in codex.exe, immediately beside
    # CLAUDE_PLUGIN_DATA, which is what a legacy compat pair looks like. Building a Codex surface
    # on it was the original mistake and this test is what stops it coming back.
    local c
    while IFS= read -r c; do
        [[ "$c" == *'${PLUGIN_ROOT}'* ]] || { echo "command does not use Codex's own token: $c"; return 1; }
        [[ "$c" != *'CLAUDE_PLUGIN_ROOT'* ]] || { echo "command still names the other product's alias: $c"; return 1; }
    done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$CODEX_HOOKS")
}

@test "codex hooks: every handler named in the registration exists as a script" {
    # tr -d '\r': this repository checks out with CRLF on Windows, so the last token of a command
    # string carries a carriage return and a bare ${c##* } yields "session-init\r", which names no
    # file. Without this the check fails on every handler for a reason that has nothing to do with
    # the handlers.
    local c name
    while IFS= read -r c; do
        name="${c##* }"
        [[ -f "$PLUGIN_ROOT/hooks-handlers/${name}.sh" ]] || { echo "registered handler has no script: $name"; return 1; }
    done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$CODEX_HOOKS" | tr -d '\r')
}

# ---------------------------------------------------------------------------------------------
# The Claude Code surface is untouched. This is requirement 4, asserted rather than assumed.
# ---------------------------------------------------------------------------------------------

@test "req4: the Claude Code hooks.json still registers PreCompact" {
    run jq -r '.hooks | has("PreCompact")' "$PLUGIN_ROOT/hooks/hooks.json"
    assert_output "true"
}

@test "req4: the Claude Code hooks.json still registers the asyncRewake Stop poller" {
    run jq -r '[.hooks.Stop[] | .hooks[] | select(.asyncRewake == true)] | length' "$PLUGIN_ROOT/hooks/hooks.json"
    assert_output "1"
}

@test "req4: the Claude Code hooks.json still carries the ExitPlanMode matcher" {
    run jq -r '[.hooks.PostToolUse[] | select(.matcher == "ExitPlanMode")] | length' "$PLUGIN_ROOT/hooks/hooks.json"
    assert_output "1"
}

@test "req4: no Claude Code hook command mentions codex" {
    run jq -r '[.hooks | to_entries[] | .value[] | .hooks[] | .command | select(test("codex"; "i"))] | length' "$PLUGIN_ROOT/hooks/hooks.json"
    assert_output "0"
}

@test "req4: the Claude Code manifest names no Codex path" {
    run bash -c "grep -ci codex '$PLUGIN_ROOT/.claude-plugin/plugin.json' || true"
    assert_output "0"
}

@test "req4: the Claude Code commands directory still holds all nine command files" {
    run bash -c "ls '$PLUGIN_ROOT'/commands/*.md | wc -l | tr -d ' '"
    assert_output "9"
}

@test "req4: no Claude Code command file has gained YAML frontmatter" {
    # Adding frontmatter would have made them migrate on Codex - and would have changed what a
    # Claude Code customer sees in their command list. The Codex answer is skills instead.
    local f
    for f in "$PLUGIN_ROOT"/commands/*.md; do
        [[ "$(head -1 "$f")" != "---" ]] || { echo "command file gained frontmatter: $f"; return 1; }
    done
}

# ---------------------------------------------------------------------------------------------
# The fixture-drift check that would have caught the regression this task actually caused.
# ---------------------------------------------------------------------------------------------

@test "every hooks-handlers library mmry-setup.sh sources is mirrored by the e2e fixture" {
    # Introducing lib-host.sh broke all 31 tests in e2e/setup-join.bats at once, because that file
    # builds a curated copy of the plugin and copied only lib-jq.sh. The failure said
    # "No such file or directory" and named a temp path, which is a sentence about nothing.
    local setup_script="$PLUGIN_ROOT/setup/mmry-setup.sh"
    local fixture="$PLUGIN_ROOT/tests/e2e/setup-join.bats"
    # THE SEARCH IS ANCHORED ON AN ACTUAL cp COMMAND, NOT ON THE LIBRARY NAME ANYWHERE IN THE FILE.
    # The first version of this check looked for the bare name, and the explanatory comment in
    # setup-join.bats mentions lib-host.sh twice - so deleting the cp line left the check green.
    # Proven by deleting the line and watching this test pass: an assertion that cannot fail.
    # Comment lines are stripped before matching for the same reason.
    local lib
    for lib in $(grep -o 'hooks-handlers/lib-[a-z]*\.sh' "$setup_script" | sort -u); do
        grep -v '^[[:space:]]*#' "$fixture" | grep -q "^[[:space:]]*cp .*${lib}" || {
            echo "mmry-setup.sh sources $lib but tests/e2e/setup-join.bats has no cp line copying it into the isolated tree"
            return 1
        }
    done
}
