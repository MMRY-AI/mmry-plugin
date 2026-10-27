#!/usr/bin/env bash
# check-rename-damage.sh - two guards for a rename (#32957 fix round 3). The same file lives in
# MMRY-AI/mmry and MMRY-AI/mmry-plugin.
#
# Why this exists: round 1 of #32957 renamed "format" to "database" as a SUBSTRING, so the Formation
# names that contain it were damaged: mmry_create_formation became mmry_create_databaseion (plugin)
# and readMemoryFormationId became readMemoryDatabaseionId (API tests). Formation is a different
# feature and the ticket says it is not touched. Nothing caught it, because every check looked for
# old names and none looked for names that had gone missing or been mangled.
#
#   1. FORMATION KEPT. Every token on the base ref (default origin/develop) that contains formation
#      or Formation - function, script, route, type, test helper, file path - must still exist,
#      unchanged, in the working tree. One that is gone is reported with where it was.
#   2. DAMAGED WORDS. No token in a tracked file may join a letter onto database or entry where no
#      name means it: databaseion, entryion, mydatabase. A token is split at case changes, digits,
#      _ - . and /, and each piece holding database, entry or entries must be exactly database,
#      databases, entry or entries, or one of the intended joins listed in INTENDED below.
#
# Usage: bash scripts/check-rename-damage.sh [--base REF] [--root DIR]
#   --root DIR   a checkout to read (default: this repository); it must be a git work tree.
# Exit 0 clean, 1 with one line per finding, 2 when the base ref or the tree cannot be read.
# Portable to the bash 3.2, BSD awk and BSD sort macOS ships; git grep does the reading.

set -u
base="origin/develop"
root=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) base="${2:-}"; shift 2 ;;
        --root) root="${2:-}"; shift 2 ;;
        *) echo "check-rename-damage: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$root" ] || root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" 2>/dev/null || { echo "check-rename-damage: cannot read $root" >&2; exit 2; }
git rev-parse --is-inside-work-tree > /dev/null 2>&1 || { echo "check-rename-damage: $root is not a git work tree" >&2; exit 2; }
git rev-parse --verify --quiet "$base^{commit}" > /dev/null || { echo "check-rename-damage: no such base ref: $base (fetch it first)" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
findings=0
report() { findings=$((findings + 1)); printf '%s\n' "$1"; }

# Files outside the product: vendored libraries and recorded evidence are history, not names.
# The guard and its self-test name the damage they look for, so they are not read.
EXCLUDE=":(exclude)mmry/tests/libs/** :(exclude)docs/evidence/** :(exclude)**/node_modules/** :(exclude)scripts/check-rename-damage.sh :(exclude)scripts/testing_VerifyCheckRenameDamage.sh"

# ---- 1. Formation kept ---------------------------------------------------------------------------
# A name: letters, digits and _, joined by - . or / (formation-start.sh, /api/formations/{id}/close-out).
TOKEN='[A-Za-z0-9_][A-Za-z0-9_./-]*[Ff]ormation[A-Za-z0-9_./-]*|[Ff]ormation[A-Za-z0-9_./-]*'
# shellcheck disable=SC2086
git grep -h -o -I -E "$TOKEN" "$base" -- . $EXCLUDE 2>/dev/null | sed -e 's|[./-]*$||' | LC_ALL=C sort -u > "$tmp/base"
# shellcheck disable=SC2086
git grep -h -o -I -E "$TOKEN" -- . $EXCLUDE 2>/dev/null | sed -e 's|[./-]*$||' | LC_ALL=C sort -u > "$tmp/head"
nbase="$(wc -l < "$tmp/base" | tr -d ' ')"
if [ "$nbase" -lt 20 ]; then
    echo "check-rename-damage: found only $nbase Formation names on $base; refusing to call that a pass" >&2
    exit 2
fi
LC_ALL=C comm -23 "$tmp/base" "$tmp/head" > "$tmp/gone"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    where="$(git grep -l -w -F "$name" "$base" -- . 2>/dev/null | head -1 | sed "s|^$base:||")"
    report "formation name gone: $name (on $base in $where)"
done < "$tmp/gone"
# File paths with formation in them.
git ls-tree -r --name-only "$base" | grep -i 'formation' | grep -v '^mmry/tests/libs/' | grep -v '^docs/evidence/' | LC_ALL=C sort > "$tmp/pbase"
git ls-files | grep -i 'formation' | grep -v '^mmry/tests/libs/' | grep -v '^docs/evidence/' | LC_ALL=C sort > "$tmp/phead"
LC_ALL=C comm -23 "$tmp/pbase" "$tmp/phead" | while IFS= read -r p; do [ -n "$p" ] && echo "formation file gone: $p"; done > "$tmp/pgone"
while IFS= read -r line; do report "$line"; done < "$tmp/pgone"

# ---- 2. Damaged words ----------------------------------------------------------------------------
# Intended joins, each with why:
#   aidatabase/aidatabases: the lower-case form of AiDatabase (testing/aidatabases, "aidatabases" in
#     the 084 body verifier); databasez: a deliberately wrong address the link checks plant, so a
#     404 can be proven; apidatabasesidoff: a Markdown anchor GitHub builds from a heading.
#   entryrevision: the EntryRevision column written in capitals in SQL; databasepropertyex: the
#     SQL Server function DATABASEPROPERTYEX.
INTENDED=" aidatabase aidatabases databasez apidatabasesidoff entryrevision databasepropertyex "
# shellcheck disable=SC2086
git grep -n -o -I -i -E '[\]?[A-Za-z0-9_]*(database|entr(y|ies))[A-Za-z0-9_]*' -- . $EXCLUDE 2>/dev/null \
  | awk -v intended="$INTENDED" '
    BEGIN { bs = sprintf("%c", 92) }
    function pieces_bad(s,   out, i, c, prev, next1, n, piece, k, w, bad) {
        # split into pieces: a lower->upper change, an acronym ending, digits and _ start a new piece
        out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1); prev = (i > 1) ? substr(s, i - 1, 1) : ""
            next1 = (i < length(s)) ? substr(s, i + 1, 1) : ""
            if (c ~ /[A-Z]/ && prev ~ /[a-z0-9]/) out = out " "
            else if (c ~ /[A-Z]/ && prev ~ /[A-Z]/ && next1 ~ /[a-z]/) out = out " "
            if (c ~ /[0-9_]/) { out = out " "; continue }
            out = out c
        }
        n = split(tolower(out), piece, / +/)
        bad = ""
        for (k = 1; k <= n; k++) {
            w = piece[k]
            if (w !~ /database|entry|entries/) continue
            if (w == "database" || w == "databases" || w == "entry" || w == "entries") continue
            if (index(intended, " " w " ")) continue
            # an ordinary English word holding entry: sentry, gentry, reentry
            if (w ~ /^(sentry|sentries|gentry|reentry|reentries|reentrant|reentrancy)$/) continue
            bad = w
        }
        return bad
    }
    {
        # path:line:token
        p = index($0, ":"); rest = substr($0, p + 1); q = index(rest, ":")
        where = substr($0, 1, p + q - 1); tok = substr(rest, q + 1)
        if (substr(tok, 1, 1) == bs) {
            # After a backslash: a Windows path separator (the word follows whole) or a regex escape
            # such as a word boundary (one letter, then the word). Damaged only if neither reads clean.
            w = pieces_bad(substr(tok, 2))
            if (w != "" && pieces_bad(substr(tok, 3)) == "") w = ""
        } else w = pieces_bad(tok)
        if (w != "") printf "damaged word: %s in %s (%s)\n", w, tok, where
    }' > "$tmp/damaged"
while IFS= read -r line; do report "$line"; done < "$tmp/damaged"

if [ "$findings" -gt 0 ]; then
    echo "check-rename-damage: $findings finding(s). A Formation name changed or went missing, or a rename joined a letter onto database or entry." >&2
    exit 1
fi
echo "check-rename-damage: clean ($nbase Formation names on $base all present; no damaged database or entry word)"
exit 0
