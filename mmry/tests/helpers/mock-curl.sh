#!/usr/bin/env bash
# mock-curl.sh — Drop-in curl replacement for testing.
# Prepend the directory containing this script to PATH to intercept curl calls.
# Returns canned responses based on URL patterns.
# Logs all calls to $TEST_TMPDIR/curl-log.txt (or /tmp/curl-log.txt).

LOG_FILE="${TEST_TMPDIR:-/tmp}/curl-log.txt"

# Parse curl arguments to extract URL, method, body, and output file
URL=""
METHOD="GET"
BODY=""
OUTPUT_FILE=""
WRITE_OUT=""

args=("$@")
i=0
while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
        -X) (( i++ )); METHOD="${args[$i]}" ;;
        -d) (( i++ )); BODY="${args[$i]}" ;;
        --data-binary)
            (( i++ ))
            _dbarg="${args[$i]}"
            if [[ "$_dbarg" == @* ]]; then
                # Read body from file (--data-binary @filename)
                _bodyfile="${_dbarg:1}"
                if [[ -f "$_bodyfile" ]]; then
                    BODY="$(cat "$_bodyfile")"
                fi
            else
                BODY="$_dbarg"
            fi
            ;;
        -o) (( i++ )); OUTPUT_FILE="${args[$i]}" ;;
        -w) (( i++ )); WRITE_OUT="${args[$i]}" ;;
        -s|-S) ;; # silent flags, ignore
        -H) (( i++ )) ;; # headers, skip
        --connect-timeout|--max-time) (( i++ )) ;; # timeouts, skip
        -*) ;; # other flags, ignore
        *)
            # Positional argument = URL
            if [[ -z "$URL" ]]; then
                URL="${args[$i]}"
            fi
            ;;
    esac
    (( i++ ))
done

# Log the call
echo "${METHOD} ${URL} ${BODY}" >> "$LOG_FILE"

# Determine response based on URL pattern
HTTP_CODE="500"
RESPONSE_BODY='{"error":"Unexpected request"}'

    # Per-URL override files: write HTTP_CODE to $TEST_TMPDIR/mock-override-<endpoint>-code
    # and RESPONSE_BODY to $TEST_TMPDIR/mock-override-<endpoint>-body
    # Supported endpoint slugs: login, apikey, device, device-status

case "$URL" in
    */api/health/db)
        HTTP_CODE="200"
        RESPONSE_BODY='{"status":"Healthy","database":"Connected"}'
        ;;
    */api/health)
        HTTP_CODE="200"
        RESPONSE_BODY='{"status":"Healthy"}'
        ;;
    */api/auth/device/*/status)
        if [[ -f "${TEST_TMPDIR:-/tmp}/mock-override-device-status-code" ]]; then
            HTTP_CODE="$(cat "${TEST_TMPDIR}/mock-override-device-status-code")"
            RESPONSE_BODY="$(cat "${TEST_TMPDIR}/mock-override-device-status-body" 2>/dev/null || echo '')"
        else
            HTTP_CODE="200"
            RESPONSE_BODY='{"status":"authorized","apiKey":"mock-device-auth-key-xyz789"}'
        fi
        ;;
    */api/auth/device)
        if [[ -f "${TEST_TMPDIR:-/tmp}/mock-override-device-code" ]]; then
            HTTP_CODE="$(cat "${TEST_TMPDIR}/mock-override-device-code")"
            RESPONSE_BODY="$(cat "${TEST_TMPDIR}/mock-override-device-body" 2>/dev/null || echo '')"
        else
            HTTP_CODE="200"
            RESPONSE_BODY='{"deviceCode":"TESTCODE","verificationUrl":"https://mmryai.com/authorize","expiresIn":600,"interval":2}'
        fi
        ;;
    */api/auth/login)
        if [[ -f "${TEST_TMPDIR:-/tmp}/mock-override-login-code" ]]; then
            HTTP_CODE="$(cat "${TEST_TMPDIR}/mock-override-login-code")"
            RESPONSE_BODY="$(cat "${TEST_TMPDIR}/mock-override-login-body" 2>/dev/null || echo '')"
        else
            HTTP_CODE="200"
            RESPONSE_BODY='{"token":"mock-jwt-token","expiresAt":"2099-01-01T00:00:00Z"}'
        fi
        ;;
    */api/auth/apikey)
        if [[ -f "${TEST_TMPDIR:-/tmp}/mock-override-apikey-code" ]]; then
            HTTP_CODE="$(cat "${TEST_TMPDIR}/mock-override-apikey-code")"
            RESPONSE_BODY="$(cat "${TEST_TMPDIR}/mock-override-apikey-body" 2>/dev/null || echo '')"
        else
            HTTP_CODE="201"
            RESPONSE_BODY='{"id":1,"apiKey":"mock-generated-key-abc123","keyPrefix":"abcd1234","label":"test"}'
        fi
        ;;
    */api/groups/mine)
        HTTP_CODE="200"
        RESPONSE_BODY='[{"id":1,"groupName":"Finance Team","ownerUserId":10},{"id":2,"groupName":"Engineering","ownerUserId":10}]'
        ;;
    */api/memories/search*)
        HTTP_CODE="200"
        RESPONSE_BODY='[{"id":1,"topic":"Test Result","content":"Found via search","memoryTier":"Operational","scope":"global","category":"Fact"}]'
        ;;
    */api/memories/startup*)
        HTTP_CODE="200"
        RESPONSE_BODY='[{"id":1,"topic":"Test Memory","content":"Test content","memoryTier":"Foundation","scope":"global","category":"Fact"}]'
        ;;
    */api/memories/*/visibility)
        HTTP_CODE="204"
        RESPONSE_BODY=''
        ;;
    */api/memories/*/reinforce)
        HTTP_CODE="204"
        RESPONSE_BODY=''
        ;;
    */api/memories/*/links/*)
        if [[ "$METHOD" == "DELETE" ]]; then
            HTTP_CODE="204"
            RESPONSE_BODY=''
        fi
        ;;
    */api/memories/*/links)
        HTTP_CODE="201"
        RESPONSE_BODY='{"id":1}'
        ;;
    */api/memories/*/related)
        HTTP_CODE="200"
        RESPONSE_BODY='[{"id":2,"topic":"Related Memory","content":"Related content","memoryTier":"Operational","scope":"global","linkType":"related"}]'
        ;;
    */api/memories/*)
        if [[ "$METHOD" == "DELETE" ]]; then
            HTTP_CODE="204"
            RESPONSE_BODY=''
        else
            HTTP_CODE="200"
            RESPONSE_BODY='{"id":1,"topic":"Test Memory","content":"Test content","memoryTier":"Foundation","scope":"global","category":"Fact"}'
        fi
        ;;
    */api/memories)
        if [[ "$METHOD" == "POST" ]]; then
            HTTP_CODE="201"
            RESPONSE_BODY='{"id":99}'
        else
            HTTP_CODE="200"
            RESPONSE_BODY='[{"id":1,"topic":"Test Memory","content":"Test content","memoryTier":"Foundation","scope":"global","category":"Fact"}]'
        fi
        ;;
    */api/users/me/default-visibility)
        if [[ "$METHOD" == "PUT" ]]; then
            HTTP_CODE="204"
            RESPONSE_BODY=''
        else
            HTTP_CODE="200"
            # Tests can vary the stored default with MOCK_DEFAULT_VISIBILITY_BODY.
            RESPONSE_BODY="${MOCK_DEFAULT_VISIBILITY_BODY:-{\"visibility\":\"Global\",\"permissionGroupID\":null\}}"
        fi
        ;;
    */api/sessions/active)
        HTTP_CODE="200"
        RESPONSE_BODY='[{"sessionId":"test-session","clientName":"claude-code","isActive":true}]'
        ;;
    */api/sessions)
        HTTP_CODE="201"
        RESPONSE_BODY=''
        ;;
esac

# Check for special test overrides via environment
if [[ -n "${MOCK_CURL_HTTP_CODE:-}" ]]; then
    HTTP_CODE="$MOCK_CURL_HTTP_CODE"
fi
if [[ -n "${MOCK_CURL_RESPONSE:-}" ]]; then
    RESPONSE_BODY="$MOCK_CURL_RESPONSE"
fi

# Write response body to output file if specified
if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s' "$RESPONSE_BODY" > "$OUTPUT_FILE"
fi

# Write HTTP code to stdout if -w format requested
if [[ "$WRITE_OUT" == "%{http_code}" ]]; then
    printf '%s' "$HTTP_CODE"
fi

exit 0
