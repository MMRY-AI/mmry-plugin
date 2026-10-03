#!/usr/bin/env bash
# foundation-set.bash - write and read the Foundation set file the way the plugin does (#31597).
#
# The set is ONE file: a record line, the set, a trailer (see mmry-client.sh). Tests that put a set
# in place by hand stage the directives in a plain file first and then SEAL it, which writes the
# record exactly as mmry_write_foundation_cache would. A test that skips the seal is testing the
# refusal path by accident.
#
#   fnd_seal [staged-body] [entries] [set-file]
#       Defaults: $CACHE (the staged body), entries = lines beginning "- ", $SET.
#       Entries default to a line count, which is good enough for fixtures; the production writer
#       counts from the API response instead, because memory content can contain such lines.
#   fnd_set_body [set-file]
#       Prints the set held in the file: the bytes after the record line, without the trailer.
#   fnd_set_record [set-file]
#       Prints the record line.

FND_TRAILER='END OF FOUNDATION SET'

fnd_seal() {
    local body="${1:-$CACHE}" n="${2:-}" set="${3:-$SET}" s b
    read -r s b < <(cksum < "$body")
    if [[ -z "$n" ]]; then
        n="$(grep -c '^- ' "$body" 2>/dev/null || true)"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
    fi
    { printf 'mmry-foundation v2 entries=%s bytes=%s cksum=%s\n' "$n" "$b" "$s"
      cat "$body"
      printf '%s' "$FND_TRAILER"; } > "${set}.seal.$$" && mv -f "${set}.seal.$$" "$set"
}

fnd_set_body() {
    local set="${1:-$SET}" raw
    raw="$(cat "$set"; printf .)"; raw="${raw%.}"
    raw="${raw#*$'\n'}"
    printf '%s' "${raw%"$FND_TRAILER"}"
}

fnd_set_record() {
    local set="${1:-$SET}" line=""
    IFS= read -r line < "$set"
    printf '%s' "$line"
}

# Write a set file with any record line and body, for tests that build a damaged or foreign set.
#   fnd_set_with "<record line>" "<body>" [set-file]
fnd_set_with() {
    printf '%s\n%s%s' "$1" "$2" "$FND_TRAILER" > "${3:-$SET}"
}
