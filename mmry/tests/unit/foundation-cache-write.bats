#!/usr/bin/env bats
# foundation-cache-write.bats — mmry_write_foundation_cache (#31583, #31411, #31597).
#
# This function had no test of its own, and it is the one that decides what the account's
# standing directives ARE. Its previous form was a single pipeline:
#
#     printf '%s' "$resp" | jq -r '...' > "$cache" 2>/dev/null || true
#
# Three separate faults in one line. The redirect truncated the customer's good cache before
# jq had produced anything, so any jq failure destroyed the set. The 2>/dev/null hid why.
# The || true told every caller it had worked. Nothing recorded what had been written, so the
# reader on the other end had no way to tell the result from a stray file with the same name
# - which is exactly how four bytes came to be served as an account's authoritative guidance
# on 2026-09-18.
#
# #31597: it now writes ONE file, mmry-foundation-set.md - the record line, the set, a trailer -
# and puts it in place with one rename, so no reader can see a new record beside an old set.

load '../helpers/test-helper'
load '../helpers/foundation-set'

setup() {
    export MMRY_API_KEY="test-key"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    # The path the hook reads, so a set written here is the one it delivers.
    CACHE="$(mmry_foundation_set_path "$TEST_TMPDIR")"
}

# Two Foundation memories and one of another tier, so tier filtering is exercised too.
_resp() {
    cat <<'JSON'
[
  {"memoryTier":"Foundation","topic":"Identity","content":"Eric builds MMRY."},
  {"memoryTier":"Strategic","topic":"Ignored","content":"Not a Foundation memory."},
  {"memoryTier":"Foundation","topic":"Value","content":"Clarity over cleverness."}
]
JSON
}

# The set the file holds, with any carriage returns a native Windows jq wrote removed, so line
# assertions compare text rather than line endings.
_body() { fnd_set_body "$CACHE" | tr -d '\r'; }

@test "write_foundation_cache: writes the set, under its record, in one file" {
    run mmry_write_foundation_cache "$(_resp)" "$CACHE"
    [ "$status" -eq 0 ]
    [ -f "$CACHE" ]
    [[ "$(fnd_set_record "$CACHE")" == 'mmry-foundation v2 entries=2 '* ]] || return 1
    _body | grep -q 'Eric builds MMRY.' || return 1
    _body | grep -q 'Clarity over cleverness.' || return 1
    # Tier filtering still holds.
    #
    # NOT written as `! grep -q ...`. That form bites only while it is the LAST statement in
    # the test, because bash exempts a negated command from errexit everywhere else, so
    # appending any assertion after it silently turns it off. This repo has found 16 or more
    # assertions disabled that way, so the shape is avoided even where it currently works.
    run grep -c 'Not a Foundation memory.' "$CACHE"
    [ "$output" = "0" ]
}

@test "write_foundation_cache: #31597 the layout is exactly record line, set, trailer, and nothing else" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"
    local first last
    first="$(fnd_set_record "$CACHE")"
    [[ "$first" =~ ^mmry-foundation\ v2\ entries=[0-9]+\ bytes=[0-9]+\ cksum=[0-9]+$ ]] || { echo "record: [$first]"; return 1; }
    # The trailer is the last thing in the file, with no newline after it: $(<file) drops trailing
    # newlines, and the trailer is what keeps the set's own last byte from being one of them.
    last="$(tail -c 21 "$CACHE")"
    [ "$last" = 'END OF FOUNDATION SET' ] || { echo "ends with: [$last]"; return 1; }
    # No second file: the manifest the pair used to need is not written.
    [ ! -e "${CACHE}.manifest" ]
}

@test "write_foundation_cache: every non-empty set it produces contains a colon-space (#31583 req 1)" {
    # CORRECTED TWICE. Round 2 disproved "every LINE carries a topic and a colon": content
    # containing a newline followed by "- x" produces exactly that as a later line. The
    # replacement asserted it of the FIRST line, and round 3 disproved that too, by the same
    # mechanism one field across: a TOPIC containing a newline puts "- x" on line 1 with no
    # colon on it at all.
    #
    # The writer works in entries, not lines: the filter is "- \(.topic): \(.content)", so the
    # literal colon-space appears in every entry it emits, wherever newlines fall inside either
    # field. So any non-empty set it writes contains ": " somewhere. The observed artefact, a
    # four-byte "- x" and a newline, contains none, so it cannot be writer output for any input.
    local resp

    # Round 2's counter-example: the newline is in the CONTENT.
    resp='[{"memoryTier":"Foundation","topic":"Notes","content":"first line\n- x"}]'
    mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$(_body | sed -n '2p')" = "- x" ] || return 1     # it really is produced
    _body | grep -q ': ' || return 1                       # and the set still carries a colon-space

    # Round 3's counter-example: the newline is in the TOPIC, so line 1 has no colon.
    resp='[{"memoryTier":"Foundation","topic":"x\nNotes","content":"hello"}]'
    mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$(_body | head -1)" = "- x" ] || return 1         # the first-line claim really is false
    _body | grep -q ': ' || return 1                       # the whole-set claim still holds

    # The artefact itself: not producible, on either count.
    [ "$(_body | wc -c | tr -d ' ')" -ne 4 ] || return 1

    # And the case that produces no colon at all produces no set at all, so it is not the
    # artefact either. This is the only way out of the claim and it is closed here.
    resp='[]'
    mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$(fnd_set_body "$CACHE" | wc -c | tr -d ' ')" -eq 0 ]
}

@test "write_foundation_cache: the record's byte count and checksum match the set it wrote" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"

    local sum count rec
    read -r sum count < <(fnd_set_body "$CACHE" | cksum)
    rec="$(fnd_set_record "$CACHE")"

    # PRESENCE of the right numbers, not merely that a record exists. A record holding zeroes
    # would satisfy "a record was written" and protect nothing.
    [[ "$rec" == *"bytes=$count"* ]] || return 1
    [[ "$rec" == *"cksum=$sum"* ]] || return 1
    [[ "$rec" == mmry-foundation\ v2\ * ]]
}

@test "write_foundation_cache: entries are counted from the RESPONSE, not by counting lines" {
    # A single Foundation memory whose CONTENT contains lines beginning "- ". A line count
    # would call this four memories. On the account that surfaced #31583 this is not
    # hypothetical: its cache holds 15 such lines for 12 memories.
    local resp
    resp='[{"memoryTier":"Foundation","topic":"Values","content":"Our values:\n- Justice\n- Joy\n- Service"}]'
    run mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$status" -eq 0 ]

    [ "$(_body | grep -c '^- ')" -eq 4 ] || return 1          # what a line count would see
    [[ "$(fnd_set_record "$CACHE")" == *'entries=1 '* ]]      # what is actually true
}

@test "write_foundation_cache: a jq failure leaves the EXISTING set untouched, byte for byte" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"
    cp "$CACHE" "$TEST_TMPDIR/before"

    # Not JSON. The old pipeline truncated the cache to zero before discovering that.
    run mmry_write_foundation_cache 'this is not json at all' "$CACHE"
    [ "$status" -ne 0 ]

    cmp -s "$CACHE" "$TEST_TMPDIR/before"
}

@test "write_foundation_cache: a failed write reports failure instead of claiming success" {
    # The old form ended in || true, so every caller was told it had worked.
    run mmry_write_foundation_cache 'not json' "$CACHE"
    [ "$status" -ne 0 ]
}

@test "write_foundation_cache: leaves no temporary file behind, on success or on failure" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"
    run bash -c "ls '$TEST_TMPDIR'/mmry-foundation-set.md.* 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]

    mmry_write_foundation_cache 'not json' "$CACHE" || true
    run bash -c "ls '$TEST_TMPDIR'/mmry-foundation-set.md.* 2>/dev/null | wc -l | tr -d ' '"
    [ "$output" = "0" ]
}

@test "write_foundation_cache: an account with no Foundation memories is recorded as a VALID empty set" {
    # Distinct from damage, and it must be, or every such account is warned on every prompt.
    run mmry_write_foundation_cache '[{"memoryTier":"Strategic","topic":"T","content":"C"}]' "$CACHE"
    [ "$status" -eq 0 ]
    [[ "$(fnd_set_record "$CACHE")" == 'mmry-foundation v2 entries=0 bytes=0 '* ]] || return 1
    [ "$(fnd_set_body "$CACHE" | wc -c | tr -d ' ')" -eq 0 ]
}

@test "write_foundation_cache: #31597 a NUL inside a memory is dropped, so the set still verifies" {
    # bash cannot hold a NUL in a variable, so a set containing one could never pass the single
    # read: it would be refused on every prompt for as long as the memory existed. The old reader
    # dropped NULs at delivery, so the assistant receives what it always did.
    local resp='[{"memoryTier":"Foundation","topic":"Odd","content":"before\u0000after"}]'
    run mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$status" -eq 0 ]
    mmry_read_foundation_set "$CACHE" || { echo "refused: $MMRY_FND_VERDICT"; return 1; }
    [[ "$MMRY_FND_SET" == *'beforeafter'* ]]
}

# ============================================================================
# #31411 test case 5 - the two paths must agree.
#
# What the write path stores and what the read path delivers are the same set, at a size far
# beyond the budget that used to cut it.
# ============================================================================

@test "write_foundation_cache: a set far beyond the old cap round-trips whole to the re-injection handler" {
    local resp big
    big="$(printf 'y%.0s' $(seq 1 7000))"
    resp="$(printf '[{"memoryTier":"Foundation","topic":"Huge","content":"%s"},{"memoryTier":"Foundation","topic":"Last","content":"tail marker intact"}]' "$big")"

    run mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$status" -eq 0 ]
    [ "$(fnd_set_body "$CACHE" | wc -c | tr -d ' ')" -gt 7000 ]

    # Now read it back through the handler the customer actually gets.
    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Huge'* ]] || return 1
    [[ "$output" == *'tail marker intact'* ]] || return 1
    [[ "$output" != *'truncated'* ]] || return 1
    [[ "$output" != *'could not verify'* ]]
}

@test "write_foundation_cache: what this writes is accepted by the reader, so the pair is not merely self-consistent" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY.'* ]] || return 1
    [[ "$output" != *'could not verify'* ]]
}
