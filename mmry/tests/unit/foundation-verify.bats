#!/usr/bin/env bats
# mmry_read_foundation_set / mmry_verify_foundation_cache - a DIRECT test of the routine both
# readers depend on.
#
# #31583 QA round 2: "the consolidated verifier has no direct test of any kind, so the routine
# R2 and R3 now rest on is exercised only incidentally through two callers and its written
# contract is pinned by nothing."
#
# THE CONTRACT, asserted here rather than described in a comment somewhere:
#   0  "ok <entries> <bytes>"            and MMRY_FND_SET / MMRY_FND_SETID hold the verified copy
#   1  "absent" | "empty"
#   3  "<state>|<customer prose>"
#
# Every state token is asserted, because the status command maps them to labels and a typo in
# one degrades silently to its catch-all.
#
# #31597: the record is the first line of the ONE set file now, so each test seals a staged set
# and then breaks one thing in that file. no-manifest and missing are no longer states of the
# reader: there is no second file to be absent. A removed set reads as absent here, and the hook
# and the status command report it as missing from the marker SessionStart leaves (tested there).

load '../helpers/test-helper'
load '../helpers/foundation-set'

setup() {
    export MMRY_API_KEY="test-key" MMRY_AUTH_METHOD="apikey" MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    CACHE="$TEST_TMPDIR/staged.md"
    SET="$TEST_TMPDIR/mmry-foundation-set.md"
}

_state()  { printf '%s' "${1%%|*}"; }

@test "verify: a healthy set returns 0 and reports the entries and bytes" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    fnd_seal "$CACHE" 1

    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 0 ]
    [[ "$output" == "ok 1 "* ]] || return 1
    # The byte count is the file's, not an echo of the manifest's claim, and the checksum that
    # follows it names this version of the set (#31583 QA round 2, R4: every part is tied to it).
    local s b
    read -r s b < <(cksum < "$CACHE")
    [ "$output" = "ok 1 $b $s" ]
}

@test "verify: #31597 the reader hands back the copy it verified, and names its version" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity.\n' > "$CACHE"
    fnd_seal "$CACHE" 2
    local want_sum
    read -r want_sum _ < <(cksum < "$CACHE")

    mmry_read_foundation_set "$SET" || return 1
    # Four fields since #31411 QA round 2: the checksum names the version every part carries.
    [ "$MMRY_FND_VERDICT" = "ok 2 $(wc -c < "$CACHE" | tr -d ' ') $want_sum" ] || { echo "verdict: [$MMRY_FND_VERDICT]"; return 1; }
    # Exactly what $(<file) of the staged set gives: trailing newline removed, nothing else.
    [ "$MMRY_FND_SET" = "$(<"$CACHE")" ] || return 1
    [ "$MMRY_FND_SETID" = "$want_sum" ]
}

@test "verify: #31597 a refusal never leaves an earlier verified set behind in the globals" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    fnd_seal "$CACHE" 1
    mmry_read_foundation_set "$SET" || return 1
    [ -n "$MMRY_FND_SET" ] || return 1
    # Now damage it and read again in the same shell, as one worker would.
    printf -- '- x\n' > "$SET"
    if mmry_read_foundation_set "$SET"; then echo "a stub verified"; return 1; fi
    [ -z "$MMRY_FND_SET" ] || { echo "the earlier set survived a refusal"; return 1; }
    [ -z "$MMRY_FND_SETID" ]
}

@test "verify: nothing on disk at all returns 1 absent, which is not damage" {
    rm -f "$SET"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 1 ]
    [ "$output" = "absent" ]
}

@test "verify: a genuinely empty set returns 1 empty, which is not damage either" {
    : > "$CACHE"
    fnd_seal "$CACHE" 0
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 1 ]
    [ "$output" = "empty" ]
}

@test "verify: state bad-manifest, a set file whose first line is not a record" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$SET"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "bad-manifest" ]
}

@test "verify: state bad-manifest, a record line present but unparseable" {
    fnd_set_with 'mmry-foundation v2 garbage' $'- Identity: Eric builds MMRY.\n'
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "bad-manifest" ]
}

@test "verify: #31597 a version 1 record is not accepted as a version 2 one" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    fnd_set_with "mmry-foundation v1 entries=1 bytes=${b} cksum=${s}" "$(cat "$CACHE")"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "bad-manifest" ]
}

@test "verify: state inconsistent, entries=0 beside a set holding directives" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    fnd_set_with "mmry-foundation v2 entries=0 bytes=${b} cksum=${s}" "$(cat "$CACHE")"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "inconsistent" ]
}

@test "verify: state size, the right content at the wrong length" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    fnd_seal "$CACHE" 1
    fnd_set_with "$(fnd_set_record)" $'- Identity: Eric builds MMRY, and more besides.\n'
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "size" ]
}

@test "verify: #31597 a set cut short, losing its trailer, fails on length" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity over cleverness.\n' > "$CACHE"
    fnd_seal "$CACHE" 2
    local whole; whole="$(wc -c < "$SET" | tr -d ' ')"
    head -c $(( whole - 40 )) "$SET" > "$SET.cut" && mv -f "$SET.cut" "$SET"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "size" ]
}

@test "verify: state contents, the right length with the wrong bytes" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    fnd_seal "$CACHE" 1
    local n; n="$(wc -c < "$CACHE" | tr -d ' ')"
    fnd_set_with "$(fnd_set_record)" "$(head -c "$n" /dev/zero | tr '\0' 'z')"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "contents" ]
    # size and contents must be DISTINCT states, or the status command prints that 28 bytes
    # does not match 28 bytes, which is what QA saw.
    [ "$(_state "$output")" != "size" ]
}

@test "verify: state blank, verified bytes that are only whitespace" {
    printf '  \n \n  ' > "$CACHE"
    fnd_seal "$CACHE" 2
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "blank" ]
}

@test "verify: #31597 state unreadable, something that exists but cannot be read as a file" {
    mkdir -p "$SET"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ]
    [ "$(_state "$output")" = "unreadable" ]
}

@test "verify: every refusal carries prose after the state token, not just a token" {
    printf '  \n \n  ' > "$CACHE"
    fnd_seal "$CACHE" 2
    run mmry_verify_foundation_cache "$SET"
    local prose="${output#*|}"
    [ -n "$prose" ]
    [ "$prose" != "$output" ]
    # Customer-facing, so it must read as a sentence rather than a token.
    [ "${#prose}" -gt 20 ]
}

# ============================================================================
# #31597 round 2, TC6: checks QA named that no test could see broken.
# ============================================================================

# The record pattern is anchored at its end. Without the anchor a record line carrying anything after
# its checksum would be believed, and the extra text with it.
@test "verify: #31597 a record line with anything after its checksum is not a record" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    local s b
    read -r s b < <(cksum < "$CACHE")
    { printf 'mmry-foundation v2 entries=1 bytes=%s cksum=%s trailing\n' "$b" "$s"; cat "$CACHE"; printf 'END OF FOUNDATION SET'; } > "$SET"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ] || { echo "accepted: $output"; return 1; }
    [ "$(_state "$output")" = "bad-manifest" ]
}

# A file that is ONE line, a well-formed record with no newline after it, has no set at all. It is
# refused as an unreadable record, not read as a record whose set is the record itself.
@test "verify: #31597 a lone record line with no newline is refused as bad-manifest" {
    printf 'mmry-foundation v2 entries=0 bytes=0 cksum=4294967295' > "$SET"
    run mmry_verify_foundation_cache "$SET"
    [ "$status" -eq 3 ] || { echo "accepted: $output"; return 1; }
    [ "$(_state "$output")" = "bad-manifest" ]
}

# An open that fails during a replacement is tried again, up to three times in all, and no more. The
# open is its own function so a test can make it fail on purpose; a real rename window cannot be
# summoned on demand.
@test "verify: #31597 an open that fails twice and then works is retried and verifies" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    fnd_seal "$CACHE" 1
    _OPENS=0
    eval "_real_open() $(declare -f _mmry_fnd_open | tail -n +2)"
    _mmry_fnd_open() { _OPENS=$(( _OPENS + 1 )); (( _OPENS < 3 )) && return 1; _real_open "$@"; }
    mmry_read_foundation_set "$SET" || { echo "refused after $_OPENS opens: $MMRY_FND_VERDICT"; return 1; }
    [ "$_OPENS" -eq 3 ]
}

@test "verify: #31597 an open that never works is tried three times, then reported, not looped on" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"
    fnd_seal "$CACHE" 1
    _OPENS=0
    _mmry_fnd_open() { _OPENS=$(( _OPENS + 1 )); return 1; }
    local rc=0
    mmry_read_foundation_set "$SET" || rc=$?
    [ "$rc" -eq 3 ] || { echo "rc $rc: $MMRY_FND_VERDICT"; return 1; }
    [ "$(_state "$MMRY_FND_VERDICT")" = "unreadable" ] || return 1
    [ "$_OPENS" -eq 3 ]
}

# The stored marker is believed only when it is digits.
@test "verify: #31597 a stored marker that is not digits is no marker" {
    local m
    for m in '1+1' 'abc' '2 3' '-4' 'x[0]' ''; do
        printf '%s' "$m" > "$TEST_TMPDIR/mmry-foundation.stored.sidx"
        run mmry_foundation_stored_entries "$TEST_TMPDIR" sidx
        [ "$status" -eq 1 ] || { echo "believed [$m] as [$output]"; return 1; }
    done
    printf '%s' '7' > "$TEST_TMPDIR/mmry-foundation.stored.sidx"
    run mmry_foundation_stored_entries "$TEST_TMPDIR" sidx
    [ "$status" -eq 0 ] && [ "$output" = "7" ]
}

# TC5: the reader removes ONE trailing newline, the one the writer puts after the last directive, and
# keeps any the directive itself ends with.
@test "verify: #31597 a set whose last directive ends in newlines keeps them, less the writer's one" {
    printf -- '- A: one\n- B: two\n\n\n' > "$CACHE"
    fnd_seal "$CACHE" 2
    mmry_read_foundation_set "$SET" || return 1
    [ "$MMRY_FND_SET" = $'- A: one\n- B: two\n\n' ] || { echo "got: $(printf '%s' "$MMRY_FND_SET" | od -c)"; return 1; }
}
