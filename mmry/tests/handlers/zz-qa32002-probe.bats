#!/usr/bin/env bats
load '../helpers/test-helper'
load '../helpers/mock-config'
setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
}
@test "QA probe: a refused PLAIN save does not print the record-save refusal line" {
    export MOCK_CURL_HTTP_CODE=400
    export MOCK_CURL_RESPONSE='{"error":"Request body is required.","detail":null}'
    run bash "$HANDLERS/save-memory.sh" --context "Spent 40 dollars on lunch."
    echo "status=$status output=$output"
    [[ "$status" -eq 1 ]] || return 1
    [[ "$output" == *"Error (HTTP 400)"* ]] || return 1
    [[ "$output" != *"Nothing was saved. Check that --record-fields"* ]] || return 1
}
@test "QA probe: the TC2 assertion against the REAL server body shape" {
    export MOCK_CURL_HTTP_CODE=400
    export MOCK_CURL_RESPONSE='{"error":"Request body is required.","detail":null}'
    run bash "$HANDLERS/save-memory.sh" --tier Operational --category Fact --scope finance --topic "Lunch" --content "Spent 40." --record-type "Expenses" --record-fields '{"amount":'
    echo "status=$status output=$output"
    [[ "$output" == *"Nothing was saved."* ]] || return 1
    [[ "$output" == *"Error (HTTP 400): Request body is required."* ]] || return 1
}
