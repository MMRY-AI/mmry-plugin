#!/usr/bin/env bats
# config-loading.bats — Test mmry_load_config with various scenarios.

load '../helpers/test-helper'
load '../helpers/mock-config'

# Reset globals before each test so mmry_load_config starts fresh
setup() {
    export MMRY_API_URL=""
    export MMRY_API_KEY=""
    export MMRY_AUTH_METHOD=""
    export MMRY_CONFIG_FILE="$TEST_TMPDIR/mmry-config.json"
    # Isolate from real ~/.claude/mmry-config.json
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude"
}

# Helper to source client fresh (it runs mmry_load_config on source)
_source_client() {
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}

@test "config: loads apiUrl from config file" {
    create_test_config "https://custom.example.com" "my-key" "apikey"
    _source_client
    [[ "$MMRY_API_URL" == "https://custom.example.com" ]]
}

@test "config: loads apiKey from config file" {
    create_test_config "http://localhost" "secret-key-42" "apikey"
    _source_client
    [[ "$MMRY_API_KEY" == "secret-key-42" ]]
}

@test "config: loads authMethod from config file" {
    create_test_config "http://localhost" "key" "apikey"
    _source_client
    [[ "$MMRY_AUTH_METHOD" == "apikey" ]]
}

@test "config: falls back to default URL when no config" {
    # No config file at $MMRY_CONFIG_FILE
    rm -f "$MMRY_CONFIG_FILE"
    _source_client
    [[ "$MMRY_API_URL" == "https://mmryai.com" ]]
}

@test "config: auto-detects apikey auth when apiKey is set" {
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiUrl": "http://localhost",
  "apiKey": "some-key"
}
EOF
    _source_client
    [[ "$MMRY_AUTH_METHOD" == "apikey" ]]
}

@test "config: env variables override config file values" {
    create_test_config "http://from-config" "config-key" "apikey"
    export MMRY_API_URL="http://from-env"
    export MMRY_API_KEY="env-key"
    export MMRY_AUTH_METHOD="apikey"
    _source_client
    [[ "$MMRY_API_URL" == "http://from-env" ]]
    [[ "$MMRY_API_KEY" == "env-key" ]]
}

@test "config: MMRY_CONFIG_FILE env var takes priority" {
    local alt_config="$TEST_TMPDIR/alt-config.json"
    cat > "$alt_config" <<'EOF'
{
  "apiUrl": "http://alt-server",
  "authMethod": "apikey",
  "apiKey": "alt-key"
}
EOF
    export MMRY_CONFIG_FILE="$alt_config"
    _source_client
    [[ "$MMRY_API_URL" == "http://alt-server" ]]
    [[ "$MMRY_API_KEY" == "alt-key" ]]
}

@test "config: handles missing config file gracefully" {
    export MMRY_CONFIG_FILE="$TEST_TMPDIR/nonexistent.json"
    _source_client
    # Should use defaults, not error
    [[ "$MMRY_API_URL" == "https://mmryai.com" ]]
}

@test "config: plugin root config takes priority over home dir config" {
    # Create config in plugin root
    cat > "$PLUGIN_ROOT/mmry-config.json" <<'EOF'
{
  "apiUrl": "http://plugin-root-server",
  "authMethod": "apikey",
  "apiKey": "plugin-root-key"
}
EOF
    # Remove MMRY_CONFIG_FILE so it falls through
    unset MMRY_CONFIG_FILE
    _source_client
    [[ "$MMRY_API_URL" == "http://plugin-root-server" ]]

    # Clean up
    rm -f "$PLUGIN_ROOT/mmry-config.json"
}

@test "config: loads without error when jq is unavailable and config lacks foundation keys (regression #30608)" {
    # Was the 2.1.0 silent-save-fail: a pre-2.1.0 config (no foundation* keys) parsed
    # on the grep fallback path when jq was absent. #30624 removed that fallback and
    # bundles jq, so config now loads via the bundled jq even with no system jq — the
    # scenario below. The whole class of grep-fallback bugs is gone with the fallback.
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiUrl": "http://localhost",
  "authMethod": "apikey",
  "apiKey": "some-key"
}
EOF
    # Force the grep fallback by making `command -v jq` report jq as missing.
    run bash -c '
        command() { [[ "$*" == "-v jq" ]] && return 1; builtin command "$@"; }
        export MMRY_CONFIG_FILE="'"$MMRY_CONFIG_FILE"'"
        export CLAUDE_PLUGIN_ROOT="'"$PLUGIN_ROOT"'"
        source "'"$PLUGIN_ROOT"'/hooks-handlers/mmry-client.sh"
        echo "LOADED_OK reinject=${MMRY_FOUNDATION_REINJECT:-} cap=${MMRY_FOUNDATION_TOKEN_CAP:-}"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"LOADED_OK"* ]]
    # Defaults still applied for the absent keys
    [[ "$output" == *"reinject=true"* ]]
}
