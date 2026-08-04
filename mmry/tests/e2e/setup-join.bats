#!/usr/bin/env bats
# setup-join.bats — End-to-end tests for joining an existing organization.
# Tests both device authorization (default) and credential fallback paths.

load '../helpers/test-helper'
load '../helpers/mock-config'

SETUP_SCRIPT=""

setup() {
    setup_mock_curl

    # Never launch a real browser from a test run. curl is mocked, but open_browser
    # is not: without this the device-auth tests opened real tabs against the live
    # authorize page. mmry-setup.sh honors MMRY_NO_BROWSER and falls back to telling
    # the user to open the URL themselves.
    export MMRY_NO_BROWSER=1

    # Isolate HOME so setup doesn't touch real config
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude"

    # Copy setup script to a marketplace-like path so it skips install.sh
    # (the script checks if its path contains /.claude/mmry/)
    mkdir -p "$HOME/.claude/mmry/setup"
    cp "$PLUGIN_ROOT/setup/mmry-setup.sh" "$HOME/.claude/mmry/setup/"
    chmod +x "$HOME/.claude/mmry/setup/mmry-setup.sh"
    SETUP_SCRIPT="$HOME/.claude/mmry/setup/mmry-setup.sh"

    # mmry-setup.sh resolves jq via hooks-handlers/lib-jq.sh (#30624); mirror it into
    # the isolated plugin and point the resolver at the real vendored jq binaries.
    mkdir -p "$HOME/.claude/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/lib-jq.sh" "$HOME/.claude/mmry/hooks-handlers/"
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"

    # Mock sleep (no-op) to prevent polling delays in device auth tests
    local mock_dir="$TEST_TMPDIR/mock-bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/sleep"
    chmod +x "$mock_dir/sleep"

    # Mock browser openers (no-op) to prevent actual browser opening
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/open"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_dir/xdg-open"
    chmod +x "$mock_dir/open" "$mock_dir/xdg-open"
}

# Helper to set per-endpoint mock overrides
_mock_endpoint() {
    local endpoint="$1" code="$2" body="${3:-}"
    echo "$code" > "$TEST_TMPDIR/mock-override-${endpoint}-code"
    echo "$body" > "$TEST_TMPDIR/mock-override-${endpoint}-body"
}

# ══════════════════════════════════════════════
# Device Authorization (default join path)
# ══════════════════════════════════════════════

@test "join: device auth succeeds with --join only" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Authorized!"* ]]
    [[ "$output" == *"You're all set"* ]]
}

@test "join: device auth creates config with poll API key" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    [[ -f "$config" ]]
    grep -q '"apiKey"' "$config"
    grep -q 'mock-device-auth-key-xyz789' "$config"
}

@test "join: device auth calls correct endpoints" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291" 2>&1

    grep -q 'POST.*auth/device' "$TEST_TMPDIR/curl-log.txt"
    grep -q 'GET.*auth/device/.*/status' "$TEST_TMPDIR/curl-log.txt"
    # Should NOT call login or register
    ! grep -q 'auth/login' "$TEST_TMPDIR/curl-log.txt"
    ! grep -q 'auth/register' "$TEST_TMPDIR/curl-log.txt"
}

@test "join: device auth shows browser URL" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291"
    [[ "$output" == *"mmryai.com/authorize?code=TESTCODE"* ]]
}

@test "join: device auth does not call apikey endpoint" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291" 2>&1

    ! grep -q 'auth/apikey' "$TEST_TMPDIR/curl-log.txt"
}

@test "join: device auth config has correct API URL" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    grep -q 'localhost:5291' "$config"
}

@test "join: device auth config has authMethod = apikey" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    grep -q '"authMethod"' "$config"
    grep -q 'apikey' "$config"
}

@test "join: device auth fails when device code request fails" {
    _mock_endpoint "device" "500" '{"error":"Internal server error"}'
    run bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Could not start device authorization"* ]]
}

@test "join: device auth fails when code expires" {
    _mock_endpoint "device-status" "200" '{"status":"expired"}'
    run bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Device code expired"* ]]
}

@test "join: device auth fails when status check returns error" {
    _mock_endpoint "device-status" "500" '{"error":"Server error"}'
    run bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Status check failed"* ]]
}

@test "join: partial credentials (email only) falls back to device auth" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Both --email and --password are required"* ]]
    [[ "$output" == *"Authorized!"* ]]
}

@test "join: partial credentials (password only) falls back to device auth" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Both --email and --password are required"* ]]
    [[ "$output" == *"Authorized!"* ]]
}

# ══════════════════════════════════════════════
# Credential Fallback (--email + --password)
# ══════════════════════════════════════════════

@test "join: credential fallback succeeds with email and password" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Logged in successfully"* ]]
    [[ "$output" == *"API key generated"* ]]
    [[ "$output" == *"You're all set"* ]]
}

@test "join: credential fallback creates config file with API key" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    [[ -f "$config" ]]
    grep -q '"apiKey"' "$config"
    grep -q 'mock-generated-key-abc123' "$config"
}

@test "join: credential fallback config has correct API URL" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    grep -q 'localhost:5291' "$config"
}

@test "join: credential fallback config has authMethod = apikey" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    grep -q '"authMethod"' "$config"
    grep -q 'apikey' "$config"
}

@test "join: credential fallback creates settings.json with script permissions" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291" 2>&1

    local settings="$HOME/.claude/settings.json"
    [[ -f "$settings" ]]
    grep -q 'save-memory.sh' "$settings"
    grep -q 'reinforce-memory.sh' "$settings"
    grep -q 'deactivate-memory.sh' "$settings"
    grep -q 'link-memories.sh' "$settings"
    grep -q 'search-memories.sh' "$settings"
    grep -q 'mmry-client.sh' "$settings"
}

@test "join: credential fallback calls login API then apikey API" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291" 2>&1

    grep -q 'POST.*auth/login' "$TEST_TMPDIR/curl-log.txt"
    grep -q 'POST.*auth/apikey' "$TEST_TMPDIR/curl-log.txt"
    # Should NOT call register or device
    ! grep -q 'auth/register' "$TEST_TMPDIR/curl-log.txt"
    ! grep -q 'auth/device' "$TEST_TMPDIR/curl-log.txt"
}

@test "join: credential fallback login is called before apikey generation" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291" 2>&1

    local login_line
    login_line="$(grep -n 'auth/login' "$TEST_TMPDIR/curl-log.txt" | head -1 | cut -d: -f1)"
    local apikey_line
    apikey_line="$(grep -n 'auth/apikey' "$TEST_TMPDIR/curl-log.txt" | head -1 | cut -d: -f1)"
    (( login_line < apikey_line ))
}

@test "join: credential fallback fails on invalid credentials (401)" {
    _mock_endpoint "login" "401" '{"error":"Invalid credentials"}'
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "wrong@testcorp.com" \
        --password "WrongPass1!" \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid email or password"* ]]
}

@test "join: credential fallback fails on server error (500)" {
    _mock_endpoint "login" "500" '{"error":"Internal server error"}'
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Login failed"* ]]
}

@test "join: credential fallback fails when API key generation fails" {
    _mock_endpoint "apikey" "500" '{"error":"Could not generate key"}'
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"API key generation failed"* ]]
}

@test "join: does NOT show first-session guidance" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291"
    [[ "$output" != *"first session"* ]]
}

# ══════════════════════════════════════════════
# Edge Cases
# ══════════════════════════════════════════════

@test "join: credential fallback handles special characters in email" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user+test@test-corp.com" \
        --password "SecurePass1!" \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
    grep -q 'POST.*auth/login' "$TEST_TMPDIR/curl-log.txt"
}

@test "join: credential fallback handles special characters in password" {
    run bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password 'P@$$w0rd!#%^&*' \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
}

@test "join: custom --api-url is used in device auth API calls" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://custom-server:9999" 2>&1

    grep -q 'custom-server:9999' "$TEST_TMPDIR/curl-log.txt"
}

@test "join: custom --api-url is used in credential fallback API calls" {
    bash "$SETUP_SCRIPT" \
        --join \
        --email "user@testcorp.com" \
        --password "SecurePass1!" \
        --api-url "http://custom-server:9999" 2>&1

    grep -q 'custom-server:9999' "$TEST_TMPDIR/curl-log.txt"
}

@test "join: config file written to ~/.claude/mmry-config.json" {
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://localhost:5291" 2>&1

    [[ -f "$HOME/.claude/mmry-config.json" ]]
}

@test "setup: device auth works without --join flag" {
    run bash "$SETUP_SCRIPT" \
        --api-url "http://localhost:5291"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Authorized!"* ]]
    [[ "$output" == *"You're all set"* ]]
    grep -q 'POST.*auth/device' "$TEST_TMPDIR/curl-log.txt"
}

@test "setup: --help does not mention register or organization creation" {
    run bash "$SETUP_SCRIPT" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Register"* ]]
    [[ "$output" != *"new org"* ]]
    [[ "$output" != *"--name"* ]]
    [[ "$output" != *"--first-name"* ]]
    [[ "$output" != *"--last-name"* ]]
}

@test "setup: device auth times out when server always returns pending" {
    # Return a short expiresIn (4 seconds) with interval of 2 so it loops twice then times out
    _mock_endpoint "device" "200" '{"deviceCode":"TIMEOUT-TEST","verificationUrl":"https://mmryai.com/authorize","expiresIn":4,"interval":2}'
    _mock_endpoint "device-status" "200" '{"status":"pending"}'
    run bash "$SETUP_SCRIPT" \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Authorization timed out"* ]]
}

@test "setup: device auth fails when authorized but no API key returned" {
    _mock_endpoint "device-status" "200" '{"status":"authorized"}'
    run bash "$SETUP_SCRIPT" \
        --api-url "http://localhost:5291"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Authorization succeeded but no API key returned"* ]]
}

@test "join: re-running setup overwrites previous config" {
    # First setup (device auth)
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://server-one:5291" 2>&1

    # Second setup with different URL
    bash "$SETUP_SCRIPT" \
        --join \
        --api-url "http://server-two:5291" 2>&1

    local config="$HOME/.claude/mmry-config.json"
    grep -q 'server-two' "$config"
    ! grep -q 'server-one' "$config"
}
