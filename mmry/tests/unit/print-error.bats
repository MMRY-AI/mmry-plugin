#!/usr/bin/env bats
# print-error.bats — _mmry_print_error messaging by HTTP status. #30321 (renamed from format-error by #32957)
# The command scripts (save, search, list-groups, etc.) all surface failures via
# _mmry_print_error, so a clear 401 message here reaches every memory command.

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
    run _mmry_print_error "save"
    [[ "$output" == *"invalid or expired"* ]]
    [[ "$output" == *"Memories may not be saved or loaded"* ]]
    [[ "$output" == *"/mmry:setup"* ]]
    [[ "$output" != *"Error (HTTP 401)"* ]]
}

@test "format-error: 402 credits-exhausted stays distinct and is not swallowed by 401" {
    # #33716: a 402 whose body carries the server's own words prints them; with no readable error
    # it prints the plugin's fixed sentence. Either way it is not the 401 setup direction.
    export MMRY_HTTP_CODE="402"
    export MMRY_RESPONSE='{"error":"no credits"}'
    run _mmry_print_error
    [[ "$output" == "no credits" ]] || { echo "$output"; return 1; }
    [[ "$output" != *"/mmry:setup"* ]] || return 1
    export MMRY_RESPONSE=''
    run _mmry_print_error
    [[ "$output" == *"Credits exhausted"* ]] || return 1
    [[ "$output" != *"/mmry:setup"* ]]
}

# ---- #33716: the server's own sentence for a 402 ------------------------------------------------
RENEWING_33716="MMRY AI is renewing your credits right now. Try your request again in a minute."
FIXED_402=$'Credits exhausted. Your MMRY AI subscription has run out of API credits.\nVisit https://mmryai.com or contact your admin to add more credits.'

@test "33716 client: a 402 carrying the renewal sentence prints it word for word, and nothing else" {
    export MMRY_HTTP_CODE="402"
    export MMRY_RESPONSE="{\"error\":\"${RENEWING_33716}\",\"code\":\"credits_exhausted\"}"
    run _mmry_print_error "save"
    [[ "$output" == "$RENEWING_33716" ]] || { echo "got: $output"; return 1; }
}

@test "33716 client: a 402 with an empty, non-JSON or error-less body prints today's fixed text" {
    export MMRY_HTTP_CODE="402"
    local body
    for body in '' '<html><body>Payment Required</body></html>' 'credits exhausted' '{"code":"credits_exhausted"}' '{"error":""}' '{"error":null}' '{"error":42}' '[1,2]' '{"error":"   "}'; do
        export MMRY_RESPONSE="$body"
        run _mmry_print_error
        [[ "$output" == "$FIXED_402" ]] || { echo "body [$body] got: $output"; return 1; }
    done
}

@test "33716 client: control characters in a 402 error are removed, escaped or raw, C0 and C1" {
    export MMRY_HTTP_CODE="402"
    # JSON escapes for ESC, BEL, CSI (U+009B) and a newline, a raw UTF-8 CSI and a raw DEL, and an
    # escaped e-acute that must arrive as the letter.
    export MMRY_RESPONSE=$'{"error":"Renewing \\u001b[31mnow\\u0007\\u009b2J.\\nTry\xc2\x9b again\x7f soon \\u00e9t\\u00e9.","code":"credits_exhausted"}'
    run _mmry_print_error
    [[ "$output" != *$'\033'* ]] || { echo "ESC reached the terminal"; return 1; }
    [[ "$output" != *$'\a'* ]] || { echo "BEL reached the terminal"; return 1; }
    [[ "$output" != *$'\xc2\x9b'* ]] || { echo "C1 CSI reached the terminal"; return 1; }
    [[ "$output" != *$'\x7f'* ]] || { echo "DEL reached the terminal"; return 1; }
    [[ "$output" == "Renewing [31mnow2J. Try again soon "$'\xc3\xa9'"t"$'\xc3\xa9'"." ]] || { echo "got: $output"; return 1; }
}

@test "33716 client: raw C1 controls are removed where printf gives the first byte, as bash 3.2 does" {
    # macOS's /bin/bash 3.2 answers printf '%d' "'c" with the character's first byte (C2 for every
    # C1 control), not its code point; CI run 43394385462 showed a raw CSI passing there. This
    # stands in that answer on any bash, so Linux and Windows guard it too. The answers come from a
    # table of the characters below (bash 3.2's signed first byte: C2 is -62, C3 is -61), never from
    # switching locale inside the stand-in: bash 3.2 restores a function's local LC_ALL to the wrong
    # value on return, which flipped the cleaner's locale mid-walk (CI run 43414669546, macOS, LC_ALL=C).
    printf() {
        if [[ "$1" == "-v" && "$3" == "%d" && "$4" == "'"* ]]; then
            local ch="${4:1}" v
            case "$ch" in
                $'\xc2\x80'*|$'\xc2\x85'*|$'\xc2\x9b'*|$'\xc2\x9f'*|$'\xc2\xa9'*) v=-62 ;;
                $'\xc3\xa9'*) v=-61 ;;
                *) builtin printf -v v '%d' "'$ch" ;;
            esac
            eval "$2=\$v"
            return 0
        fi
        builtin printf "$@"
    }
    local loc
    for loc in C.UTF-8 en_US.UTF-8 C; do
        LC_ALL="$loc" _mmry_server_text_clean_v $'Try\xc2\x9b again \xc2\x85now \xc2\x80\xc2\x9f\xc3\xa9t\xc3\xa9 \xc2\xa9 ok'
        [[ "$_MMRY_SERVER_TEXT" == "Try again now "$'\xc3\xa9t\xc3\xa9 \xc2\xa9'" ok" ]] || { echo "[$loc] got: $_MMRY_SERVER_TEXT"; unset -f printf; return 1; }
    done
    unset -f printf
}

@test "33716 client: a very long 402 error is capped at 300 characters" {
    export MMRY_HTTP_CODE="402"
    local long; long="$(printf 'A%.0s' $(seq 1 5000))"
    export MMRY_RESPONSE="{\"error\":\"${long}\"}"
    run _mmry_print_error
    [[ "${#lines[@]}" -eq 1 ]] || { echo "lines: ${#lines[@]}"; return 1; }
    [[ "$output" == "$(printf 'A%.0s' $(seq 1 300))..." ]] || { echo "length ${#output}"; return 1; }
}

@test "format-error: other statuses keep the generic message with the server response" {
    export MMRY_HTTP_CODE="500"
    export MMRY_RESPONSE="server down"
    run _mmry_print_error
    [[ "$output" == *"Error (HTTP 500)"* ]]
    [[ "$output" == *"server down"* ]]
}
