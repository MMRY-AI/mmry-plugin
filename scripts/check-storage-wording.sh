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

# One path and its kind per line: "whole" (read every line) or "code" (skip comment lines).
_surfaces() {
    local d f
    for f in .claude-plugin/marketplace.json mmry/.claude-plugin/plugin.json mmry/.codex-plugin/plugin.json \
             mmry/codex-mcp.json README.md mmry/README.md; do
        [ -f "$ROOT/$f" ] && printf 'whole %s\n' "$ROOT/$f"
    done
    [ -d "$ROOT/mmry/hooks" ] && find "$ROOT/mmry/hooks" -type f -name '*.json' -print | sed 's/^/whole /'
    for d in mmry/skills mmry/skills-codex mmry/commands mmry/commands-codex; do
        [ -d "$ROOT/$d" ] && find "$ROOT/$d" -type f -name '*.md' -print | sed 's/^/whole /'
    done
    [ -d "$ROOT/docs" ] && find "$ROOT/docs" -maxdepth 1 -type f -name '*.md' -print | sed 's/^/whole /'
    for d in mmry/hooks-handlers mmry/setup; do
        [ -d "$ROOT/$d" ] && find "$ROOT/$d" -type f ! -name '*.awk' -print | sed 's/^/code /'
    done
    [ -d "$ROOT/mmry/mcp" ] && find "$ROOT/mmry/mcp" -type f -print | sed 's/^/code /'
}

files=0; findings=0; report=""
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    kind="${entry%% *}"; path="${entry#* }"
    rel="${path#$ROOT/}"
    out="$(awk -v rel="$rel" -v kind="$kind" '
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
            for (i = 1; i <= n; i++) if (low ~ re[i]) {
                text = raw; gsub(/^[ \t]+/, "", text)
                if (length(text) > 140) text = substr(text, 1, 137) "..."
                printf "%s:%d: %s: %s\n", rel, NR, lab[i], text
            }
        }' "$path")"
    files=$((files + 1))
    if [ -n "$out" ]; then
        c="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
        findings=$((findings + c)); report="${report}${out}
"
    fi
done <<EOF
$(_surfaces)
EOF

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
