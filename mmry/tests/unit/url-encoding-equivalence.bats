#!/usr/bin/env bats
# url-encoding-equivalence.bats - _mmry_urlencode encodes in the shell, exactly as the sed program it
# replaced did (#31976).
#
# The per-prompt formation check encodes two values on every prompt. Until #31976 each was
# `printf | sed` inside a command substitution: two processes apiece, 1 to 2 s of a 15 s budget on a
# loaded Windows machine. The replacement is parameter expansion and starts nothing. These tests hold
# it to the old program, character for character, and prove the no-process claim with PATH emptied.

load '../helpers/test-helper'

setup() {
    export MMRY_API_KEY="test-key"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}

# The program _mmry_urlencode was before #31976, verbatim.
_sed_encode() {
    printf '%s' "$1" | sed \
        -e 's|%|%25|g' \
        -e 's| |%20|g' \
        -e 's|:|%3A|g' \
        -e 's|\\|%5C|g' \
        -e 's|#|%23|g' \
        -e 's|?|%3F|g' \
        -e 's|&|%26|g' \
        -e 's|=|%3D|g' \
        -e 's|+|%2B|g' \
        -e 's|@|%40|g'
}

@test "urlencode equivalence: every value gives what the sed program gave" {
    local -a cases=(
        'sess-measure'
        '2026-10-09T23:00:00.000'
        'a b:c\d#e?f&g=h+i@j%k'
        '%25'
        '%%%'
        '&&&'
        '\\\\'
        '*?[a]'
        '~!$^()|<>'
        'a/b/c'
        'C:\Users\eric\project'
        "it's \"quoted\""
        $'tab\there'
        $'line1\nline2'
        $'trailing\n'
        $'trailing2\n\n'
        $'unicode-\xc3\xbcn\xc3\xaf-\xe6\x97\xa5\xe6\x9c\xac'
        ' '
        ''
        '0a8c7b1e-2f3d-4e5f-9a8b-7c6d5e4f3a2b'
    )
    local s old new bad=0
    for s in "${cases[@]}"; do
        old="$(_sed_encode "$s")"
        new="$(_mmry_urlencode "$s")"
        if [[ "$old" != "$new" ]]; then
            printf 'differs for [%s]: sed [%s], shell [%s]\n' "$s" "$old" "$new"
            bad=1
        fi
        _mmry_urlencode_v "$s"
        if [[ "$old" != "$_MMRY_URLENC" ]]; then
            printf 'the variable form differs for [%s]: sed [%s], shell [%s]\n' "$s" "$old" "$_MMRY_URLENC"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ]
}

@test "urlencode equivalence: the variable form starts no process (PATH emptied)" {
    local saved="$PATH"
    PATH=""
    _mmry_urlencode_v 'a b:c\d#e?f&g=h+i@j%k'
    PATH="$saved"
    [[ "$_MMRY_URLENC" == 'a%20b%3Ac%5Cd%23e%3Ff%26g%3Dh%2Bi%40j%25k' ]]
}

@test "urlencode equivalence: the transmissions request encodes without a process" {
    # The hot path's request is built with the variable form: the URL is right with PATH emptied up to
    # the moment curl would run.
    local saved="$PATH" seen=""
    _mmry_request() { seen="$2"; return 0; }
    PATH=""
    mmry_get_formation_transmissions 42 'sess one' '2026-10-09T23:00:00.000' '7,8'
    PATH="$saved"
    [[ "$seen" == '/api/formations/42/transmissions?sessionId=sess%20one&since=2026-10-09T23%3A00%3A00.000&shownIds=7,8' ]] \
        || { echo "path was: $seen"; return 1; }
}
