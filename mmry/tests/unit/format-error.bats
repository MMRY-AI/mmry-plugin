#!/usr/bin/env bats
# format-error.bats — _mmry_format_error messaging by HTTP status. #30321
# The command scripts (save, search, list-groups, etc.) all surface failures via
# _mmry_format_error, so a clear 401 message here reaches every memory command.

load '../helpers/test-helper'

setup() {
    export MMRY_API_KEY="test-key"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}

@test "format-error: 401 warns invalid/expired credential and points to setup (#30321)" {
    export MMRY_HTTP_CODE="401"
    export MMRY_RESPONSE='{"error":"unauthorized"}'
    run _mmry_format_error "save"
    [[ "$output" == *"invalid or expired"* ]]
    [[ "$output" == *"Memories may not be saved or loaded"* ]]
    [[ "$output" == *"/mmry:setup"* ]]
    [[ "$output" != *"Error (HTTP 401)"* ]]
}

@test "format-error: 402 credits-exhausted stays distinct and is not swallowed by 401" {
    export MMRY_HTTP_CODE="402"
    export MMRY_RESPONSE='{"error":"no credits"}'
    run _mmry_format_error
    [[ "$output" == *"Credits exhausted"* ]]
    [[ "$output" != *"/mmry:setup"* ]]
}

@test "format-error: other statuses keep the generic message with the server response" {
    export MMRY_HTTP_CODE="500"
    export MMRY_RESPONSE="server down"
    run _mmry_format_error
    [[ "$output" == *"Error (HTTP 500)"* ]]
    [[ "$output" == *"server down"* ]]
}
