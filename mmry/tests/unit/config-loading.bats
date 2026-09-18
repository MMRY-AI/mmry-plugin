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

# The plugin-root-priority test below writes a config INTO THE REPOSITORY WORKING TREE, and
# removed it only on its own success path - so any failing assertion left a stray
# mmry/mmry-config.json behind. That file is the HIGHEST-priority config source, so it then
# silently fed every later run in that checkout, including other suites. It did exactly that
# during review. Cleanup belongs in a teardown, which runs whether the test passes or not.
teardown() {
    rm -f "$PLUGIN_ROOT/mmry-config.json"
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

# ============================================================================
# #31434 — the config is parsed ONCE per process, in ONE jq.
#
# Why this is a correctness test and not a micro-optimisation test: every entry-point
# handler sources mmry-client.sh (whose AUTO-INIT loads the config) and then calls
# mmry_load_config again. That was twelve jq process spawns per hook firing. On Windows
# it consumed most of the UserPromptSubmit hook's five-second budget, the harness killed
# the hook, and the turn ran with none of the account's Foundation directives.
#
# The counter shim wraps the resolved jq and records only REAL parses - the resolver
# probes jq with --version, and counting that would measure the wrong thing.
# ============================================================================

_jq_counting_shim() {
    local shim="$TEST_TMPDIR/counting-jq.sh"
    : > "$TEST_TMPDIR/jq-calls"
    cat > "$shim" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "--version" ]] && exec jq "\$@"; done
echo call >> "$TEST_TMPDIR/jq-calls"
exec jq "\$@"
EOF
    chmod +x "$shim"
    printf '%s' "$shim"
}

_jq_call_count() {
    grep -c call "$TEST_TMPDIR/jq-calls" 2>/dev/null || echo 0
}

@test "config: sourcing the client then calling mmry_load_config again parses the file exactly once (#31434)" {
    create_test_config "https://custom.example.com" "my-key" "apikey"
    local shim; shim="$(_jq_counting_shim)"

    run bash -c "
        export MMRY_JQ='$shim'
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        mmry_load_config
        echo \"url=\$MMRY_API_URL key=\$MMRY_API_KEY auth=\$MMRY_AUTH_METHOD\"
    "
    [ "$status" -eq 0 ]
    # Correctness is not sacrificed for the saving — every field still arrives.
    [[ "$output" == *"url=https://custom.example.com"* ]]
    [[ "$output" == *"key=my-key"* ]]
    [[ "$output" == *"auth=apikey"* ]]
    # SAMPLE: exactly one parse across a source plus an explicit reload call. Before
    # #31434 this was twelve (six fields x two loads).
    [ "$(_jq_call_count)" -eq 1 ]
}

@test "config: MMRY_CONFIG_RELOAD=1 forces a genuine re-read (#31434)" {
    create_test_config "https://custom.example.com" "my-key" "apikey"
    local shim; shim="$(_jq_counting_shim)"

    run bash -c "
        export MMRY_JQ='$shim'
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        MMRY_CONFIG_RELOAD=1 mmry_load_config
    "
    [ "$status" -eq 0 ]
    # The escape hatch must actually escape, or the idempotence guard is a one-way door.
    [ "$(_jq_call_count)" -eq 2 ]
}

@test "config: the load-once guard is not inherited by a child process (#31434)" {
    create_test_config "https://custom.example.com" "my-key" "apikey"
    local shim; shim="$(_jq_counting_shim)"

    # A child process is a NEW process and must load its own config. If the guard were
    # exported, the child would silently run with no configuration at all.
    run bash -c "
        export MMRY_JQ='$shim'
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        env -u MMRY_API_URL -u MMRY_API_KEY -u MMRY_AUTH_METHOD bash -c '
            source \"\$CLAUDE_PLUGIN_ROOT/hooks-handlers/mmry-client.sh\"
            echo \"child_url=\$MMRY_API_URL\"
        '
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"child_url=https://custom.example.com"* ]]
    # Parent parsed once, child parsed once.
    [ "$(_jq_call_count)" -eq 2 ]
}

@test "config: a config file that is not valid JSON falls back to defaults instead of killing the shell (#31434)" {
    # mmry-client.sh runs under `set -e`. The single-jq parse reads six fields with six
    # `read` calls; on unparseable input jq emits nothing and the first read returns 1.
    # Unguarded, that would take the whole sourcing shell down mid-hook.
    printf 'this is not json' > "$MMRY_CONFIG_FILE"
    run bash -c "
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        echo \"SURVIVED url=\$MMRY_API_URL\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED url=https://mmryai.com"* ]]
}

@test "config: fields keep their positions when earlier ones are absent (#31434)" {
    # The single-jq parse emits six lines in a fixed order and relies on an absent field
    # producing an EMPTY LINE. If it produced no line at all, every later field would shift
    # up one and the API key would be read into the auth method.
    cat > "$MMRY_CONFIG_FILE" <<'EOF'
{
  "apiKey": "positional-key",
  "foundationRefreshSeconds": 77
}
EOF
    run bash -c "
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        unset MMRY_FOUNDATION_REINJECT MMRY_FOUNDATION_TOKEN_CAP MMRY_FOUNDATION_REFRESH_SECONDS
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        echo \"key=\$MMRY_API_KEY refresh=\$MMRY_FOUNDATION_REFRESH_SECONDS cap=\$MMRY_FOUNDATION_TOKEN_CAP\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"key=positional-key"* ]]
    [[ "$output" == *"refresh=77"* ]]
    # Absent, so the default applies — not some neighbouring field's value.
    [[ "$output" == *"cap=1500"* ]]
}

@test "config: parsed values carry no trailing carriage return (#31434)" {
    # jq.exe on Windows opens stdout in TEXT mode and emits CRLF. `read` consumes only the
    # LF, so every parsed value kept a trailing CR. It is invisible in an echo and breaks
    # every string comparison downstream. This is not hypothetical: the first cut of the
    # single-jq parse shipped exactly this bug, the values LOOKED perfect when printed, and
    # it was ten pre-existing tests in this file that caught it.
    #
    # Asserted on LENGTH as well as equality, because an equality assertion alone is the
    # thing a reader dismisses as redundant and deletes.
    create_test_config "https://custom.example.com" "secret-key-42" "apikey"
    run bash -c "
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        printf 'urllen=%s keylen=%s authlen=%s\n' \
            \"\${#MMRY_API_URL}\" \"\${#MMRY_API_KEY}\" \"\${#MMRY_AUTH_METHOD}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"urllen=26"* ]]    # https://custom.example.com
    [[ "$output" == *"keylen=13"* ]]    # secret-key-42
    [[ "$output" == *"authlen=6"* ]]    # apikey
}

@test "config: a value containing a newline does not shear every field after it (#31434 QA)" {
    # THE REGRESSION THIS FILE EXISTS TO CATCH, and it was introduced by #31434 itself.
    #
    # The first cut of the single-jq parse emitted one field per LINE. A value containing a
    # newline produced more lines than fields, so every later field shifted up one - and
    # nothing anywhere said so. Measured against this exact config before the fix:
    #
    #     key=line-one   reinject=5   cap=true   refresh=1500
    #
    # foundationRefreshSeconds inherited "1500", which PASSES the `^[0-9]+$` guard in
    # userpromptsubmit-foundation.sh and silently turns a daily background refresh into one
    # every 25 minutes. A wrong-but-numeric value that clears its own validation is precisely
    # the silent-failure shape #31434 exists to eliminate.
    #
    # NUL-delimiting the jq output fixes it: no JSON string value can contain a NUL, so no
    # value can forge the delimiter.
    printf '%s\n' \
        '{' \
        '  "apiUrl": "https://mmryai.com",' \
        '  "authMethod": "apikey",' \
        '  "apiKey": "line-one\n5",' \
        '  "foundationReinject": "true",' \
        '  "foundationReinjectTokenCap": 1500,' \
        '  "foundationRefreshSeconds": 86400' \
        '}' > "$MMRY_CONFIG_FILE"

    run bash -c "
        export MMRY_CONFIG_FILE='$MMRY_CONFIG_FILE'
        export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
        export MMRY_API_URL='' MMRY_API_KEY='' MMRY_AUTH_METHOD=''
        unset MMRY_FOUNDATION_REINJECT MMRY_FOUNDATION_TOKEN_CAP MMRY_FOUNDATION_REFRESH_SECONDS
        source '$PLUGIN_ROOT/hooks-handlers/mmry-client.sh'
        echo \"url=\$MMRY_API_URL\"
        echo \"auth=\$MMRY_AUTH_METHOD\"
        echo \"reinject=\$MMRY_FOUNDATION_REINJECT\"
        echo \"cap=\$MMRY_FOUNDATION_TOKEN_CAP\"
        echo \"refresh=\$MMRY_FOUNDATION_REFRESH_SECONDS\"
        # The key is multi-line by construction, so report it as a single flattened token
        # rather than letting it break the line-oriented assertions below.
        printf 'keyflat=%s\n' \"\$(printf '%s' \"\$MMRY_API_KEY\" | tr -d '\r' | tr '\n' '~')\"
    "
    [ "$status" -eq 0 ]

    # Every field after the multi-line value still holds ITS OWN value.
    [[ "$output" == *"url=https://mmryai.com"* ]]
    [[ "$output" == *"auth=apikey"* ]]
    [[ "$output" == *"reinject=true"* ]]
    [[ "$output" == *"cap=1500"* ]]
    [[ "$output" == *"refresh=86400"* ]]

    # Named explicitly, because these are the exact wrong values the line-based parse
    # produced. Asserting the right value alone would still pass if a future change made
    # reinject empty and the default filled it back in.
    [[ "$output" != *"reinject=5"* ]]
    [[ "$output" != *"refresh=1500"* ]]
    [[ "$output" != *"cap=true"* ]]

    # And the multi-line value itself survives whole rather than being cut at its newline.
    # CRs are stripped for the comparison ONLY because jq.exe on Windows opens stdout in
    # TEXT mode and turns the LF inside the value into CRLF. That is documented in
    # mmry_load_config; it does not shear anything, and asserting on it would make this a
    # platform test instead of a shearing test.
    [[ "$output" == *"keyflat=line-one~5"* ]]
}
