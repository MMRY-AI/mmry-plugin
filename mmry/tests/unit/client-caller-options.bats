#!/usr/bin/env bats
# client-caller-options.bats - sourcing mmry-client.sh leaves the caller's shell options alone (#34252).
#
# SKILL.md tells a customer's assistant to source the client for a custom call and then "check
# $MMRY_HTTP_CODE and $MMRY_RESPONSE". The client carries the repository's set -euo pipefail line, and
# until #34252 it left errexit on in the shell that sourced it. A refused call (any non-2xx) then ended
# that shell at the call, before the caller could read the reason the server gave: the Journey Catalog
# writer reported an empty reply for a save the API had refused with a readable 400 (feedback 84).
#
# The client now puts errexit, nounset and pipefail back the way the caller had them, as
# lib-foundation-key.sh already does (foundation-isolation.bats). Plugin handlers set -euo pipefail
# themselves before sourcing, so for them nothing changes; the last test proves a failure still stops one.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey"
    CLIENT="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}

@test "caller options: sourcing the client leaves errexit, nounset and pipefail as the caller had them" {
    local o got want
    for o in "" "-e" "-u" "-o pipefail" "-e -u" "-e -o pipefail" "-u -o pipefail" "-e -u -o pipefail"; do
        got="$(bash -c "set +e +u +o pipefail; set $o -o noglob; set +o noglob
            source '$CLIENT' >/dev/null 2>&1
            r=''; [[ \$- == *e* ]] && r+=e; [[ \$- == *u* ]] && r+=u; [[ -o pipefail ]] && r+=p; printf '%s' \"\$r\"" 2>&1)"
        want=""
        [[ "$o" == *-e* ]] && want+=e
        [[ "$o" == *-u* ]] && want+=u
        [[ "$o" == *pipefail* ]] && want+=p
        [[ "$got" == "$want" ]] || { echo "caller set '$o': options after sourcing are '$got', want '$want'"; return 1; }
    done
}

@test "caller options: a script without errexit reads the reason a refused entry save came back with" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"error":"The value of '"'"'pending_version'"'"' is longer than 4000 characters, which is more than a field holds. Save it as ordinary text instead.","detail":null}'
    run bash -c "source '$CLIENT' >/dev/null 2>&1
        mmry_save_entry 9 'note' '{\"pending_version\":\"x\"}' >/dev/null 2>&1
        echo \"rc=\$? code=\$MMRY_HTTP_CODE\"
        printf '%s\n' \"\$MMRY_RESPONSE\""
    [[ "$output" == *"rc=1 code=400"* ]] || { echo "the call's result was not readable after it: $output"; return 1; }
    [[ "$output" == *"longer than 4000 characters"* ]] || { echo "the server's reason was lost: $output"; return 1; }
}

@test "caller options: a script without errexit reads a refused entries read and carries on" {
    export MOCK_CURL_HTTP_CODE="429"
    export MOCK_CURL_RESPONSE='{"error":"Too many requests","retryAfterSeconds":60}'
    run bash -c "source '$CLIENT' >/dev/null 2>&1
        mmry_get_entries 9 '' '' 1 100 >/dev/null 2>&1
        echo \"code=\$MMRY_HTTP_CODE body=\$MMRY_RESPONSE\"
        echo after"
    [[ "$output" == *"code=429 body="*"retryAfterSeconds"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"after"* ]] || { echo "the script stopped at the refused read: $output"; return 1; }
}

@test "caller options: a caller that set errexit itself still stops at a refused call (handlers unchanged)" {
    export MOCK_CURL_HTTP_CODE="400"
    export MOCK_CURL_RESPONSE='{"error":"refused"}'
    run bash -c "set -euo pipefail
        source '$CLIENT' >/dev/null 2>&1
        mmry_save_entry 9 'note' '{}' >/dev/null 2>&1
        echo reached"
    [[ "$status" -ne 0 ]] || { echo "status $status"; return 1; }
    [[ "$output" != *"reached"* ]] || { echo "errexit was dropped for a caller that asked for it: $output"; return 1; }
}
