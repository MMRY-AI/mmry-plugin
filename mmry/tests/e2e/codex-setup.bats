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

# ---------------------------------------------------------------------------------------------
# THE CREDENTIAL-CHECK OPT-OUT LIVES FOR ONE LINE, NOT FOR THE WHOLE RUN (#31245 QA round 3)
#
# mmry-setup.sh has to be able to run before a credential exists - it is the program that creates
# one - so it turns off lib-jq.sh's refusal while it sources the resolver. Round 2 did that with
# `export`, which handed the override to every process the script spawns for the rest of the run,
# including the installers it calls at the end. An opt-out that outlives its reason is a hole
# nobody is looking at.
#
# This observes a REAL child process rather than reading the source: curl is spawned by the
# device-authorization flow, and the wrapper below records whether the variable reached it.
# ---------------------------------------------------------------------------------------------

@test "codex: the setup opt-out does not leak into the processes setup spawns" {
    local real_curl; real_curl="$(command -v curl)"
    local spy="$TEST_TMPDIR/spy-bin"
    mkdir -p "$spy"
    cat > "$spy/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${MMRY_ALLOW_NO_CREDENTIAL:-<unset>}" >> "$TEST_TMPDIR/child-env.log"
exec "$real_curl" "\$@"
EOF
    chmod +x "$spy/curl"

    local script; script="$(_stage "$HOME/.codex/mmry")"
    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$spy:$PATH" \
        bash "$script"
    [ "$status" -eq 0 ]

    # The spy must actually have run, or this test proves nothing.
    [ -s "$TEST_TMPDIR/child-env.log" ] || { echo "no child process was observed"; return 1; }
    run grep -c '^1$' "$TEST_TMPDIR/child-env.log"
    [ "$output" -eq 0 ] || {
        echo "the credential-check opt-out was inherited by $output spawned process(es)"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# --host IS VALIDATED, BECAUSE THE FALLBACK FOR AN UNRECOGNISED VALUE WAS ANOTHER PRODUCT'S
# ACCOUNT FILE (#31245 QA round 4).
#
# mmry_host() maps anything that is not exactly "codex" to "claude", and --host was handed
# straight to it. So the capitalisation a customer reading prose would naturally type wrote the
# Codex credential into ${HOME}/.claude/mmry-config.json and said nothing at all about it.
#
# These four assert the two halves separately: a case variant is HONOURED (it is unambiguous),
# and a value that is neither host is REFUSED rather than defaulted.

@test "codex: --host Codex - the capitalisation a customer types - targets the CODEX directory" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script" --host Codex

    [ "$status" -eq 0 ]
    [ -f "$HOME/.codex/mmry-config.json" ]
}

@test "codex: and --host Codex writes NO credential into the other product's account file" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script" --host Codex

    [ "$status" -eq 0 ]
    # THIS IS THE ASSERTION THE DEFECT FAILED. Before the fix this file existed and held the
    # credential the customer meant for Codex.
    [ ! -f "$HOME/.claude/mmry-config.json" ]
}

@test "codex: an unrecognised --host is REFUSED, not quietly resolved to claude" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script" --host codx

    [ "$status" -eq 1 ]
    [[ "$output" == *"Unrecognised --host value: codx"* ]]
}

@test "codex: and a refused --host writes no credential anywhere at all" {
    local script
    script="$(_stage "$HOME/.claude/mmry")"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script" --host codx

    [ ! -f "$HOME/.claude/mmry-config.json" ]
    [ ! -f "$HOME/.codex/mmry-config.json" ]
}

# ---------------------------------------------------------------------------------------------
# THE CREDENTIAL FILE IS NOT WORLD-READABLE (#31245 QA round 4).
#
# mmry-config.json holds a long-lived API key that can read and write every memory on the
# account. It was created with whatever umask the caller happened to have - commonly 022, which
# is world-readable - and nothing ever narrowed it.
#
# TWO TESTS, BECAUSE ONE OF THEM CANNOT RUN EVERYWHERE AND SAYING SO IS THE POINT. Git Bash on
# Windows does not implement POSIX modes: chmod 600 there is a no-op and stat reports 644
# regardless, which was confirmed on this machine before these were written. So the mode is
# asserted where it is observable and SKIPPED where it is not, and the ORDER - private before
# the secret is written - is asserted from the source, where it is checkable everywhere.

@test "codex: the credential file is created private BEFORE the key is written into it" {
    # A SOURCE-ORDER CHECK, deliberately. Setting the mode after writing leaves a window in
    # which the key is on disk world-readable, and a window is all a credential leak needs.
    # This is checkable on every platform; the mode itself is not.
    local f="$PLUGIN_ROOT/setup/mmry-setup.sh"
    local create_line chmod_line write_line
    # The three steps, in the order they must happen: create empty, narrow the mode, THEN write
    # the key. Anchored on the jq invocation rather than on a redirect, because the empty-file
    # creation is a redirect to the same path and would otherwise match first.
    create_line="$(grep -n ': > "$CONFIG_FILE"' "$f" | head -1 | cut -d: -f1)"
    chmod_line="$(grep -n 'chmod 600 "$CONFIG_FILE"' "$f" | head -1 | cut -d: -f1)"
    write_line="$(grep -n 'MMRY_JQ" -n --arg url' "$f" | head -1 | cut -d: -f1)"

    # SAMPLE SIZE: an extraction that found nothing must fail, not compare empty strings.
    [[ "$create_line" =~ ^[0-9]+$ ]]
    [[ "$chmod_line" =~ ^[0-9]+$ ]]
    [[ "$write_line" =~ ^[0-9]+$ ]]
    (( create_line < chmod_line ))
    (( chmod_line < write_line ))
}

@test "codex: and the written credential really is mode 600 where the platform has modes" {
    # Establish that this filesystem honours modes AT ALL before asserting anything about them.
    # Without this the test passes vacuously on Windows, reporting success for a guarantee the
    # platform never provided.
    local probe="$TEST_TMPDIR/modeprobe"
    : > "$probe"
    chmod 600 "$probe"
    local probemode
    probemode="$(stat -c %a "$probe" 2>/dev/null || stat -f %Lp "$probe" 2>/dev/null)"
    [[ "$probemode" == "600" ]] || skip "this filesystem does not implement POSIX modes (probe reported ${probemode:-unknown})"

    local script
    script="$(_stage "$HOME/.codex/mmry")"
    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE HOME="$HOME" \
        MMRY_NO_BROWSER=1 MMRY_JQ_VENDOR_DIR="$MMRY_JQ_VENDOR_DIR" PATH="$PATH" \
        bash "$script"

    [ "$status" -eq 0 ]
    [ -f "$HOME/.codex/mmry-config.json" ]
    local mode
    mode="$(stat -c %a "$HOME/.codex/mmry-config.json" 2>/dev/null || stat -f %Lp "$HOME/.codex/mmry-config.json" 2>/dev/null)"
    [[ "$mode" == "600" ]]
}
