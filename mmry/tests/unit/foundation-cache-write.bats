#!/usr/bin/env bats
# foundation-cache-write.bats — mmry_write_foundation_cache (#31583, #31411).
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

load '../helpers/test-helper'

setup() {
    export MMRY_API_KEY="test-key"
    export MMRY_AUTH_METHOD="apikey"
    export MMRY_API_URL="http://localhost:5291"
    source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    MANIFEST="$CACHE.manifest"
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

@test "write_foundation_cache: writes the cache and a manifest describing it" {
    run mmry_write_foundation_cache "$(_resp)" "$CACHE"
    [ "$status" -eq 0 ]
    [ -f "$CACHE" ]
    [ -f "$MANIFEST" ]
    grep -q 'Eric builds MMRY.' "$CACHE"
    grep -q 'Clarity over cleverness.' "$CACHE"
    # Tier filtering still holds.
    #
    # NOT written as `! grep -q ...`. That form bites only while it is the LAST statement in
    # the test, because bash exempts a negated command from errexit everywhere else, so
    # appending any assertion after it silently turns it off. Measured, rather than taken on
    # faith, with a three-test probe against this repo's own bats: `! true` as the last
    # statement -> not ok; `! true` followed by any other statement -> ok. This repo has
    # found 16 or more assertions disabled that way, so the shape is avoided even where it
    # currently works.
    run grep -c 'Not a Foundation memory.' "$CACHE"
    [ "$output" = "0" ]
}

@test "write_foundation_cache: every line it writes carries a topic and a colon (#31583 requirement 1)" {
    # This is the property that let requirement 1 rule the writer out as the source of the
    # four-byte stub. The renderer is "- \(.topic): \(.content)", so a line without a colon
    # cannot be this plugin's output for ANY account content. The observed fragment was
    # `- x`, which has none. If the render format ever changes, that finding stops holding,
    # and this test is what says so.
    mmry_write_foundation_cache "$(_resp)" "$CACHE"

    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == '- '*': '* ]] || { echo "line without topic and colon: [$line]"; return 1; }
    done < "$CACHE"

    # And the premise: something was actually read, so an empty cache cannot pass by vacuum.
    [ "$(grep -c '^- ' "$CACHE")" -eq 2 ]
}

@test "write_foundation_cache: the manifest's byte count and checksum match the file it wrote" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"

    local sum count man
    read -r sum count < <(cksum < "$CACHE")
    man="$(cat "$MANIFEST")"

    # PRESENCE of the right numbers, not merely that a manifest exists. A manifest holding
    # zeroes would satisfy "a manifest was written" and protect nothing.
    [[ "$man" == *"bytes=$count"* ]]
    [[ "$man" == *"cksum=$sum"* ]]
    [[ "$man" == mmry-foundation\ v1\ * ]]
}

@test "write_foundation_cache: entries are counted from the RESPONSE, not by counting lines" {
    # A single Foundation memory whose CONTENT contains lines beginning "- ". A line count
    # would call this four memories. On the account that surfaced #31583 this is not
    # hypothetical: its cache holds 15 such lines for 12 memories.
    local resp
    resp='[{"memoryTier":"Foundation","topic":"Values","content":"Our values:\n- Justice\n- Joy\n- Service"}]'
    run mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$status" -eq 0 ]

    [ "$(grep -c '^- ' "$CACHE")" -eq 4 ]      # what a line count would see
    grep -q 'entries=1' "$MANIFEST"            # what is actually true
}

@test "write_foundation_cache: a jq failure leaves the EXISTING cache and manifest untouched" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"
    local before_cache before_manifest
    before_cache="$(cat "$CACHE")"
    before_manifest="$(cat "$MANIFEST")"
    [ -n "$before_cache" ]

    # Not JSON. The old pipeline truncated the cache to zero before discovering that.
    run mmry_write_foundation_cache 'this is not json at all' "$CACHE"
    [ "$status" -ne 0 ]

    [ "$(cat "$CACHE")" = "$before_cache" ]
    [ "$(cat "$MANIFEST")" = "$before_manifest" ]
}

@test "write_foundation_cache: a failed write reports failure instead of claiming success" {
    # The old form ended in || true, so every caller was told it had worked.
    run mmry_write_foundation_cache 'not json' "$CACHE"
    [ "$status" -ne 0 ]
}

@test "write_foundation_cache: leaves no temporary file behind, on success or on failure" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"
    run bash -c "ls '$TEST_TMPDIR'/mmry-foundation.md.new.* 2>/dev/null | wc -l"
    [ "$output" = "0" ]

    mmry_write_foundation_cache 'not json' "$CACHE" || true
    run bash -c "ls '$TEST_TMPDIR'/mmry-foundation.md.new.* 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

@test "write_foundation_cache: an account with no Foundation memories is recorded as a VALID empty set" {
    # Distinct from damage, and it must be, or every such account is warned on every prompt.
    run mmry_write_foundation_cache '[{"memoryTier":"Strategic","topic":"T","content":"C"}]' "$CACHE"
    [ "$status" -eq 0 ]
    grep -q 'entries=0' "$MANIFEST"
    [ ! -s "$CACHE" ]
}

# ============================================================================
# #31411 test case 5 - the two paths must agree.
#
# The ticket left open whether the session-start path applied the same budget as the
# per-prompt re-injection. It never did: the cut lived only in the re-injection worker, and
# session-start.sh writes the cache through this function with no ceiling of any kind
# (verified by reading both files). This asserts the consequence that matters - what the
# write path stores and what the read path delivers are the same set, at a size far beyond
# the budget that used to cut it.
# ============================================================================

@test "write_foundation_cache: a set far beyond the old cap round-trips whole to the re-injection handler" {
    local resp big
    big="$(printf 'y%.0s' $(seq 1 7000))"
    resp="$(printf '[{"memoryTier":"Foundation","topic":"Huge","content":"%s"},{"memoryTier":"Foundation","topic":"Last","content":"tail marker intact"}]' "$big")"

    run mmry_write_foundation_cache "$resp" "$CACHE"
    [ "$status" -eq 0 ]
    [ "$(wc -c < "$CACHE")" -gt 7000 ]

    # Now read it back through the handler the customer actually gets.
    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Huge'* ]]
    [[ "$output" == *'tail marker intact'* ]]
    [[ "$output" != *'truncated'* ]]
    [[ "$output" != *'could not verify'* ]]
}

@test "write_foundation_cache: what this writes is accepted by the reader, so the pair is not merely self-consistent" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"

    run bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Eric builds MMRY.'* ]]
    [[ "$output" != *'could not verify'* ]]
}

@test "write_foundation_cache: the manifest lands by rename from a PID-scoped temp (#31583 QA)" {
    # Two sessions sharing a temp directory could interleave into a permanently inconsistent
    # pair, because the cache temp was PID-scoped and the manifest name was not: one session's
    # manifest describing another session's cache, with nothing to repair it until the next
    # successful write. Both temps are PID-scoped now and both files arrive by rename.
    grep -q 'local mtmp="${manifest}.new.\$\$"' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    grep -q 'mv -f "$mtmp" "$manifest"' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"

    # Nothing may write the manifest by redirecting at its final name any more.
    run grep -c '> "\$manifest"' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
    [ "$output" = "0" ]
}

@test "write_foundation_cache: no temp files survive, manifest or cache, on success or failure" {
    mmry_write_foundation_cache "$(_resp)" "$CACHE"
    run bash -c "ls '$TEST_TMPDIR'/mmry-foundation.md*.new.* 2>/dev/null | wc -l"
    [ "$output" = "0" ]

    mmry_write_foundation_cache 'not json' "$CACHE" || true
    run bash -c "ls '$TEST_TMPDIR'/mmry-foundation.md*.new.* 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}
