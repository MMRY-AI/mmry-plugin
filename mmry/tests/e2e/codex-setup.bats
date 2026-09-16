#!/usr/bin/env bats
# codex-setup.bats — the installer, RUN, on both hosts (#31245 requirement 3).
#
# WHY THIS FILE EXISTS RATHER THAN MORE UNIT TESTS. The first attempt at covering this asserted
# against a helper that reproduced mmry-setup.sh's host-resolution preamble. That helper passed
# happily while the real script was broken, because a replica of the code under test is not the
# code under test. These tests execute mmry-setup.sh itself, through the same mocked
# device-authorization flow tests/e2e/setup-join.bats uses, and then look at where the credential
# file actually landed on disk.
#
# The defect they exist to prevent, found on 2026-09-15: session-init.sh copies this script into
# ~/.codex/mmry/setup/, docs/codex.md tells a Codex customer to run it from there with no
# arguments, and the script defaulted MMRY_HOST to "claude" before consulting the resolver. The one
# command a new Codex customer runs wrote the credential into a directory belonging to a product
# they may not even have installed.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    export MMRY_NO_BROWSER=1
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"

    # mmry-setup.sh resolves its jq from the vendored binaries rather than the machine's.
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"

    # No real sleeping, and no real browser.
    local mock_dir="$TEST_TMPDIR/mock-bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/sleep"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/open"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/xdg-open"
    chmod +x "$mock_dir/sleep" "$mock_dir/open" "$mock_dir/xdg-open"

    # The environment must carry nothing that could answer the host question for the script.
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE || true
}

# Stage the plugin exactly as session-init.sh does for one host, and return the setup script path.
_stage() {
    local state_dir="$1"
    mkdir -p "$state_dir/setup" "$state_dir/hooks-handlers"
    cp "$PLUGIN_ROOT/setup/mmry-setup.sh" "$state_dir/setup/"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$state_dir/hooks-handlers/"
    cp -r "$PLUGIN_ROOT/vendor" "$state_dir/" 2>/dev/null || true
    printf '%s/setup/mmry-setup.sh' "$state_dir"
}

# ---------------------------------------------------------------------------------------------

@test "req3 codex: running the published command with NO arguments writes ~/.codex/mmry-config.json" {
    local script
    script="$(_stage "$HOME/.codex/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [ -f "$HOME/.codex/mmry-config.json" ]
}

@test "req3 codex: and it does NOT write a Claude credential as a side effect" {
    # The half that matters on a machine with both products: a Codex setup must not overwrite the
    # customer's existing Claude credential, nor invent one where there was none.
    local script
    script="$(_stage "$HOME/.codex/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.claude/mmry-config.json" ]
}

@test "req3 codex: it does not write Claude Code's settings.json either" {
    # That file is Claude Code's permission configuration. Editing it during a Codex install would
    # silently change an unrelated product's behaviour.
    local script
    script="$(_stage "$HOME/.codex/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.claude/settings.json" ]
}

@test "req4 control: the same command from a Claude install still writes ~/.claude/mmry-config.json" {
    # Without this control the three tests above are satisfied by any change that sends every host
    # to the Codex directory.
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/mmry-config.json" ]
    [ ! -f "$HOME/.codex/mmry-config.json" ]
}

@test "req4 control: a Claude install still writes Claude Code's settings.json permissions" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/settings.json" ]
    grep -q 'save-memory.sh' "$HOME/.claude/settings.json"
}

@test "codex: --host codex from a Claude-staged copy still targets the Codex directory" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script" --host codex

    [ "$status" -eq 0 ]
    [ -f "$HOME/.codex/mmry-config.json" ]
}

@test "req3 codex: the closing instructions name Codex and do not tell the customer to type a command" {
    local script
    script="$(_stage "$HOME/.codex/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Restart Codex"* ]]
    [[ "$output" == *"Trust all and continue"* ]]
    [[ "$output" != *"/mmry:help"* ]]
}

@test "req4 control: a Claude install still closes by pointing at /mmry:help" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Restart Claude Code"* ]]
    [[ "$output" == *"/mmry:help"* ]]
}
