#!/usr/bin/env bash
# Requirement 1 of #31583: can the OLD writer produce a four-byte "- x" cache?
# The old form, recovered from b19a25b^:
#     printf '%s' "$resp" | jq -r '...' > "$cache" 2>/dev/null || true
set -uo pipefail
W="$(mktemp -d)"
CACHE="$W/mmry-foundation.md"
GOOD='- Cite Task Title with Task #: include the title as well.
- Tell the Truth: only assert what you have observed.
- File Download Path: give the full path.'

old_writer() {  # $1 = the jq stand-in
    local jqcmd="$1"
    printf '%s' '[{"memoryTier":"Foundation","topic":"T","content":"C"}]' | $jqcmd > "$CACHE" 2>/dev/null || true
}

echo "== H1: jq fails immediately (bad input, missing binary, killed at start) =="
printf '%s\n' "$GOOD" > "$CACHE"
old_writer "false"
printf 'cache is now %s bytes: [%s]\n' "$(wc -c < "$CACHE")" "$(cat "$CACHE")"

echo
echo "== H2: jq writes part of the first line, then dies =="
printf '%s\n' "$GOOD" > "$CACHE"
SHIM="$W/partial.sh"; printf '#!/usr/bin/env bash\nprintf -- %s\nkill -9 $$\n' "'- Cite Task Tit'" > "$SHIM"; chmod +x "$SHIM"
old_writer "$SHIM"
printf 'cache is now %s bytes: [%s]\n' "$(wc -c < "$CACHE")" "$(cat "$CACHE")"

echo
echo "== H3: could either path produce the observed 4 bytes '- x'? =="
printf 'The account first directive begins: %s\n' "$(printf '%s\n' "$GOOD" | head -1 | cut -c1-20)"
printf "A truncated write is a PREFIX of that. '- x' is not a prefix of it.\n"
rm -rf "$W"
