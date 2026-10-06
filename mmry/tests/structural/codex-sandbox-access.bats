#!/usr/bin/env bats
# =============================================================================================
# WHEN CODEX'S SANDBOX BLOCKS MMRY, THE ASSISTANT IS TOLD EXACTLY WHAT TO ASK FOR (#31245 A').
#
# Mac live run, 2026-10-04: in the Codex desktop app's default sandbox, every MMRY command the
# assistant ran (setup, save, search, join) failed with HTTP 000 or curl exit 6, while the hooks,
# which Codex runs itself, worked. The desktop app does not offer the escalation the CLI does, but
# it does offer request_permissions, which grants network access and named folders for the
# conversation (codex-rs core/src/tools/handlers/shell_spec.rs, rust-v0.154.0).
#
# So the client and setup print the request to make, with this machine's paths, and the skill says
# when and how. These check the request is valid JSON in the shape Codex accepts, names the right
# folders, and that Claude Code's output is untouched.
# =============================================================================================

load '../helpers/test-helper'

CODEX_DIR=""

setup() {
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$CODEX_DIR/mmry"
    printf '%s' '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"k"}' > "$CODEX_DIR/mmry-config.json"
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE || true
}

# The format_error output for a given host, HTTP code and response.
_format_error() {
    local host="$1" code="$2" resp="$3"
    env ${host:+MMRY_HOST=$host} CODEX_HOME="$CODEX_DIR" bash -c '
        source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1 || exit 9
        MMRY_HTTP_CODE="$2" MMRY_RESPONSE="$3"
        _mmry_format_error save
    ' _ "$PLUGIN_ROOT" "$code" "$resp" 2>&1
}

# The request line the hint prints, as JSON.
_request_json() { printf '%s\n' "$1" | grep -m1 '^ *{"permissions"' | sed 's/^ *//'; }

@test "access: a curl failure on Codex says exactly what to request, as valid JSON" {
    run _format_error codex 000 "curl failed"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Error (HTTP 000): curl failed"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"request_permissions"* ]] || { echo "$output"; return 1; }
    local req; req="$(_request_json "$output")"
    [[ -n "$req" ]] || { echo "no request line: $output"; return 1; }
    printf '%s' "$req" | jq -e '.permissions.network.enabled == true' >/dev/null || { echo "$req"; return 1; }
    printf '%s' "$req" | jq -e '(.permissions.file_system.write | length) == 1' >/dev/null || { echo "$req"; return 1; }
    # Only the two keys Codex's schema accepts, under permissions.
    printf '%s' "$req" | jq -e '(.permissions | keys) == ["file_system","network"]' >/dev/null || { echo "$req"; return 1; }
    # The folder is the Codex home's mmry folder, written absolute.
    printf '%s' "$req" | jq -er '.permissions.file_system.write[0]' | grep -qE '[/\\]codexhome[/\\]mmry$' || { echo "$req"; return 1; }
}

@test "access: req4 - on Claude Code the same error prints exactly what it always did" {
    run _format_error "" 000 "curl failed"
    [ "$output" = "Error (HTTP 000): curl failed" ] || { echo "[$output]"; return 1; }
}

@test "access: a missing credential, also HTTP 000, is not mistaken for the sandbox" {
    run _format_error codex 000 "No API key configured."
    [[ "$output" != *"request_permissions"* ]] || { echo "$output"; return 1; }
}

@test "access: setup on Codex that cannot reach MMRY AI asks for the folder AND the credential file" {
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nprintf 000\nexit 6\n' > "$bin/curl"
    chmod +x "$bin/curl"
    rm -f "$CODEX_DIR/mmry-config.json"
    run env CODEX_HOME="$CODEX_DIR" HOME="$TEST_TMPDIR/fakehome" MMRY_NO_BROWSER=1 PATH="$bin:$PATH" \
        bash "$PLUGIN_ROOT/setup/mmry-setup.sh" --host codex
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    local req; req="$(_request_json "$output")"
    [[ -n "$req" ]] || { echo "no request line: $output"; return 1; }
    printf '%s' "$req" | jq -e '(.permissions.file_system.write | length) == 2' >/dev/null || { echo "$req"; return 1; }
    printf '%s' "$req" | jq -er '.permissions.file_system.write[1]' | grep -qE '[/\\]codexhome[/\\]mmry-config\.json$' || { echo "$req"; return 1; }
    [ ! -e "$CODEX_DIR/mmry-config.json" ]
}

@test "access: req4 - setup on Claude Code prints no request_permissions" {
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nprintf 000\nexit 6\n' > "$bin/curl"
    chmod +x "$bin/curl"
    run env HOME="$TEST_TMPDIR/fakehome" MMRY_NO_BROWSER=1 PATH="$bin:$PATH" \
        bash "$PLUGIN_ROOT/setup/mmry-setup.sh" --host claude
    [ "$status" -eq 1 ] || return 1
    [[ "$output" != *"request_permissions"* ]]
}

@test "skill: the request in the Codex skill is valid JSON in Codex's shape" {
    local skill="$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" block
    block="$(tr -d '\r' < "$skill" | awk '/^## If an MMRY command cannot reach MMRY AI/{s=1} s && /^```json$/{j=1; next} j && /^```$/{exit} j{print}')"
    [[ -n "$block" ]] || { echo "no json block in the section"; return 1; }
    printf '%s' "$block" | jq -e '.permissions.network.enabled == true' >/dev/null || { echo "$block"; return 1; }
    printf '%s' "$block" | jq -e '(.permissions.file_system.write | type) == "array"' >/dev/null || return 1
    printf '%s' "$block" | jq -e '(keys - ["permissions","reason"]) == []' >/dev/null || { echo "$block"; return 1; }
    # And the section says when to ask, how long it lasts, and what to do if declined.
    local section; section="$(tr -d '\r' < "$skill" | awk '/^## If an MMRY command cannot reach MMRY AI/{s=1; print; next} s && /^## /{exit} s{print}')"
    [[ "$section" == *"for this conversation"* ]] || return 1
    [[ "$section" == *"run the same MMRY command again"* ]] || return 1
    [[ "$section" == *"declines"* ]] || return 1
    [[ "$section" == *"mmry-config.json"* ]]
}

@test "docs: the permanent alternative names the two Codex settings" {
    local doc; doc="$(cd "$PLUGIN_ROOT/.." && pwd)/docs/codex.md"
    tr -d '\r' < "$doc" | grep -q '^\[sandbox_workspace_write\]$' || return 1
    tr -d '\r' < "$doc" | grep -q '^network_access = true$' || return 1
    tr -d '\r' < "$doc" | grep -q '^writable_roots = \[' || return 1
    tr -d '\r' < "$doc" | tr '\n' ' ' | grep -q 'Approve it for the conversation'
}
