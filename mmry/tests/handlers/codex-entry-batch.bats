#!/usr/bin/env bats
# codex-entry-batch.bats - several entries in one request on the Codex host (#33317 requirement 2).
#
# Codex runs the same plugin scripts as Claude Code, installed by session-init.sh under
# ~/.codex/mmry and invoked there by the model. This proves the batch script reaches that install
# and, run from it exactly as the Codex skill shows, uses the CODEX credential (never the Claude
# Code one) to send one batch request and print each entry's outcome in the order sent. The live
# proof, a recorded Codex session on Integration, is test case 3 of the ticket and is run there.

load '../helpers/test-helper'
load '../helpers/mock-config'

LOG=""

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.codex" "$HOME/.claude"
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE MMRY_API_URL MMRY_API_KEY MMRY_AUTH_METHOD || true
    LOG="$TEST_TMPDIR/curl-log.txt"
    # Two credentials, told apart by their address: only the Codex one may be used.
    printf '{"apiUrl":"http://localhost:5299","authMethod":"apikey","apiKey":"codex-key"}' > "$HOME/.codex/mmry-config.json"
    printf '{"apiUrl":"http://localhost:5298","authMethod":"apikey","apiKey":"claude-key"}' > "$HOME/.claude/mmry-config.json"
}

# Install the plugin for Codex the way a Codex session does: session-init.sh with the host declared,
# its delegate replaced by a probe (loading memories is not under test here).
_install_for_codex() {
    local root="$TEST_TMPDIR/plugin"
    mkdir -p "$root/hooks-handlers" "$root/setup"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.awk "$root/hooks-handlers/" 2>/dev/null || true
    cp "$PLUGIN_ROOT"/setup/*.sh "$root/setup/"
    printf '#!/usr/bin/env bash\necho "DELEGATE RAN"\n' > "$root/hooks-handlers/session-start.sh"
    run env MMRY_HOST=codex HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" bash "$root/hooks-handlers/session-init.sh"
    [[ "$status" -eq 0 ]] || { echo "session-init failed: $output"; return 1; }
}

_reply() {
    printf '%s' '{"databaseId":42,"entries":3,"saved":2,"refused":1,"notSaved":0,"summary":"2 of 3 entries were saved; 1 was refused, each with its reason. Tell the user what happened to each entry.","results":[{"position":1,"status":"saved","entry":{"MemoryId":61,"Outcome":"structured.created","Visibility":"Private"}},{"position":2,"status":"refused","reason":"This entry has no content. Send the user'"'"'s own words as content."},{"position":3,"status":"saved","entry":{"MemoryId":63,"Outcome":"structured.created","Visibility":"Private"}}]}'
}

@test "codex: session-init installs save-entries.sh beside save-entry.sh under ~/.codex" {
    _install_for_codex
    [ -f "$HOME/.codex/mmry/hooks-handlers/save-entries.sh" ]
    [ -f "$HOME/.codex/mmry/hooks-handlers/save-entry.sh" ]
}

@test "codex: the installed save-entries.sh sends ONE batch with the Codex credential and reports each entry in order" {
    _install_for_codex
    : > "$LOG"
    export MOCK_CURL_HTTP_CODE=200
    MOCK_CURL_RESPONSE="$(_reply)"; export MOCK_CURL_RESPONSE
    # Run as the Codex skill runs it: from the Codex install, with no host variable set, so the host
    # is recognised from where the script lives.
    run env -u MMRY_HOST HOME="$HOME" bash "$HOME/.codex/mmry/hooks-handlers/save-entries.sh" --database-id 42 \
        --entries '[{"content":"one","fields":{"n":1}},{"fields":{"n":2}},{"content":"three","fields":{"n":3}}]'
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$(grep -c '' "$LOG")" -eq 1 ]] || { cat "$LOG"; return 1; }
    grep -q "^POST http://localhost:5299/api/databases/42/entries/batch " "$LOG" || { cat "$LOG"; return 1; }
    ! grep -q "localhost:5298" "$LOG" || { echo "the Claude Code credential was used"; cat "$LOG"; return 1; }
    local order
    order="$(printf '%s\n' "$output" | sed -n 's/^Entry \([0-9]*\): .*/\1/p' | tr '\n' ' ')"
    [[ "$order" == "1 2 3 " ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Entry 2: refused. Reason: This entry has no content."* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"2 of 3 entries were saved; 1 was refused"* ]] || { echo "$output"; return 1; }
}

@test "codex: with no Codex credential the installed script sends nothing, rather than using the Claude Code one" {
    _install_for_codex
    rm -f "$HOME/.codex/mmry-config.json"
    : > "$LOG"
    run env -u MMRY_HOST HOME="$HOME" bash "$HOME/.codex/mmry/hooks-handlers/save-entries.sh" --database-id 42 \
        --entries '[{"content":"one"}]'
    [[ "$status" -ne 0 ]] || { echo "$output"; return 1; }
    ! grep -q "localhost:5298" "$LOG" || { echo "the Claude Code credential was used"; cat "$LOG"; return 1; }
}
