#!/usr/bin/env bash
# check-storage-wording.sh - refuse customer-readable plugin text that names the storage technology
# behind MMRY (#32944, from MMRY feedback #43: the installed plugin's description called MMRY a
# "SQL-backed" memory system). Eric, 2026-10-24: "People don't need to know about our technology."
# The API half of the same scan is scripts/check-storage-wording.mjs in MMRY-AI/mmry.
#
# Usage: bash scripts/check-storage-wording.sh [REPO_ROOT]
#   REPO_ROOT defaults to the repository this script lives in. The BATS test passes a copy.
#
# Exit 0 and a one-line summary when clean. Exit 1 and one line per finding,
# "path:line: term: text". Exit 2 when the root holds none of the surfaces, because a check that
# read nothing must not report a pass.
#
# THE REFUSED TERMS (case-insensitive): SQL and everything joined to it (SQL-backed, SQL Server,
# Azure SQL, T-SQL, MSSQL, NoSQL, SQLite), Azure, stored procedure, database engine, relational
# database, Dapper, ADO.NET, Entity Framework, PostgreSQL, Cosmos DB, and the dbo. schema prefix.
# "AI database" is a product name and is not refused.
#
# WHAT IS READ (what a customer or their assistant can read or hear):
#   manifests   .claude-plugin/marketplace.json, mmry/.claude-plugin/plugin.json,
#               mmry/.codex-plugin/plugin.json, mmry/codex-mcp.json, mmry/hooks/*.json: whole file.
#   documents   the skills, Codex skills, commands and Codex commands (*.md), both READMEs and the
#               top-level docs/*.md pages: whole file. docs/evidence/ is engineering evidence, not read.
#   scripts     every non-comment line of mmry/hooks-handlers and mmry/setup, because what they print
#               and what they tell the assistant is what a customer reads; mcp-server.sh is read the
#               same way, so its tool titles, descriptions and instructions are covered.
# NOT READ: tests, the vendored libraries, comments in scripts, docs/evidence and the repository's own
# workflow files (a build description is not something a customer reads).
#
# Portable to the bash 3.2 and BSD awk macOS ships: no mapfile, no GNU-only flags.

set -u

if [ "$#" -ge 1 ]; then ROOT="$1"; else ROOT="$(cd "$(dirname "$0")/.." && pwd)"; fi
ROOT="${ROOT%/}"
[ -d "$ROOT" ] || { echo "check-storage-wording: no such directory: $ROOT" >&2; exit 2; }

# The surfaces, one path per line, in two lists: "whole" (every line is read) and "code" (comment
# lines are skipped). Few process starts on purpose: each one is slow on Windows.
_existing() { # the directories among the arguments that exist under ROOT, as full paths
    local d
    for d in "$@"; do [ -d "$ROOT/$d" ] && printf '%s\n' "$ROOT/$d"; done
}
_whole() {
    local f
    for f in .claude-plugin/marketplace.json mmry/.claude-plugin/plugin.json mmry/.codex-plugin/plugin.json \
             mmry/codex-mcp.json README.md mmry/README.md; do
        [ -f "$ROOT/$f" ] && printf '%s\n' "$ROOT/$f"
    done
    local dirs; dirs="$(_existing mmry/hooks mmry/skills mmry/skills-codex mmry/commands mmry/commands-codex)"
    if [ -n "$dirs" ]; then
        printf '%s\n' "$dirs" | tr '\n' '\000' | xargs -0 -I{} find {} -type f \( -name '*.md' -o -name '*.json' \) -print
    fi
    [ -d "$ROOT/docs" ] && find "$ROOT/docs" -maxdepth 1 -type f -name '*.md' -print
}
_code() {
    local dirs; dirs="$(_existing mmry/hooks-handlers mmry/setup mmry/mcp)"
    if [ -n "$dirs" ]; then
        printf '%s\n' "$dirs" | tr '\n' '\000' | xargs -0 -I{} find {} -type f ! -name '*.awk' -print
    fi
}

# One awk run per kind over every file of that kind, not one per file: process starts dominate the
# cost on Windows, and the structural test runs this check dozens of times.
AWKPROG='
        BEGIN {
            n = 0
            lab[++n] = "SQL";                re[n] = "(^|[^a-z])(t-|ms|my|no|postgre|pg)?sql(ite|server)?([^a-z]|$)"
            lab[++n] = "Azure";              re[n] = "azure"
            lab[++n] = "stored procedure";   re[n] = "stored[ _-]+proc"
            lab[++n] = "database engine";    re[n] = "database[ -]+engine"
            lab[++n] = "relational database"; re[n] = "relational[ -]+(database|data[ -]?store)"
            lab[++n] = "Dapper";             re[n] = "(^|[^a-z])dapper([^a-z]|$)"
            lab[++n] = "ADO.NET";            re[n] = "ado[.]net"
            lab[++n] = "Entity Framework";   re[n] = "entity[ -]*framework"
            lab[++n] = "PostgreSQL";         re[n] = "postgres"
            lab[++n] = "Cosmos DB";          re[n] = "cosmos[ -]*db"
            lab[++n] = "dbo schema";         re[n] = "(^|[^a-z0-9_])dbo[.][a-z_]"
        }
        {
            raw = $0; sub(/\r$/, "", raw)
            if (kind == "code" && raw ~ /^[ \t]*(#|::|[Rr][Ee][Mm]([ \t]|$)|\/\/)/) next
            low = tolower(raw)
            rel = FILENAME; if (index(rel, root) == 1) rel = substr(rel, length(root) + 1)
            for (i = 1; i <= n; i++) if (low ~ re[i]) {
                text = raw; gsub(/^[ \t]+/, "", text)
                if (length(text) > 140) text = substr(text, 1, 137) "..."
                printf "%s:%d: %s: %s\n", rel, FNR, lab[i], text
            }
        }'

files=0; findings=0; report=""
for kind in whole code; do
    if [ "$kind" = whole ]; then paths="$(_whole)"; else paths="$(_code)"; fi
    [ -n "$paths" ] || continue
    files=$((files + $(printf '%s\n' "$paths" | wc -l)))
    # xargs may split a very long list into several awk runs; FILENAME and FNR keep each line's name.
    out="$(printf '%s\n' "$paths" | tr '\n' '\000' | xargs -0 awk -v root="$ROOT/" -v kind="$kind" "$AWKPROG")"
    if [ -n "$out" ]; then
        c="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
        findings=$((findings + c)); report="${report}${out}
"
    fi
done

if [ "$files" -eq 0 ]; then
    echo "check-storage-wording: ROOT holds none of the surfaces (read 0 files): $ROOT" >&2
    exit 2
fi
if [ "$findings" -gt 0 ]; then
    printf '%s' "$report"
    echo "FAILED: $findings storage technology wording hit(s) in $files file(s) read."
    exit 1
fi
echo "OK: $files file(s) read; no storage technology wording."
