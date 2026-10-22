#!/usr/bin/env bash
# check-database-names.sh - refuse customer- or assistant-readable plugin text that calls the AI
# database by its internal names (#32457, DD-150 in the mmry repository).
#
# Usage: bash scripts/check-database-names.sh [REPO_ROOT]
#   REPO_ROOT defaults to the repository this script lives in. The BATS test passes a copy.
#
# Exit 0 and a one-line summary when the text is clean. Exit 1 and one line per finding,
# "path:line: rule: text", when it is not. Exit 2 when the root holds none of the surfaces,
# because a check that read nothing must not report a pass.
#
# THE NAMES (DD-150). The feature is marketed as the AI database. One tracked thing is a
# database, each saved item in it is an entry, and its named values are fields. The code still
# says format and record (create-format.sh, --record-id, mmry_record), and those names stay,
# because installed scripts and connected assistants call them. Only the words around them change.
#
# WHAT IS READ. The same customer-readable surfaces as check-public-text.sh (the Claude Code and
# Codex skills, the commands, the READMEs, the top-level docs pages, the Codex MCP server's tool
# titles, descriptions and instructions), plus every non-comment line of the seven scripts that
# serve the database, because what they print is what the assistant reads and repeats.
#
# TWO RULES.
#   A, everywhere read: no "record type", "structured record" or "data format".
#   B, wherever the text is about the database: no "format", "formats", "record", "records",
#      "recorded" or "recording" as a word. The text is about the database in the seven scripts, in the
#      database section of a skill (a "## " heading that names records, formats or the
#      database, down to the next "## " heading), and on any line that names one of the
#      database's scripts, flags or tools or says "database". Elsewhere these are ordinary
#      English (a Formation's close-out record, a date format) and are not this feature.
#
# CODE IS NOT PROSE. A token joined by - _ . / or led by $ ${ -- (save-record.sh, --record-id,
# mmry_record, .format.name, $recorded, /records), a token written in camelCase or PascalCase
# (RecordedAs, formatId) and a shell assignment (recorded=) are identifiers and are removed from
# the line before it is checked. Nothing else is allow-listed.
#
# Portable to the bash 3.2 and BSD awk macOS ships: no mapfile, no GNU-only flags.

set -u

if [ "$#" -ge 1 ]; then
    ROOT="$1"
else
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
ROOT="${ROOT%/}"

if [ ! -d "$ROOT" ]; then
    echo "check-database-names: no such directory: $ROOT" >&2
    exit 2
fi

# The seven scripts that serve the database. Every non-comment line is read under both rules.
FEATURE_SCRIPTS="create-format.sh list-formats.sh revise-format.sh save-record.sh query-records.sh record-history.sh save-memory.sh"

# One path and its kind per line: "md", "mcp" or "script".
_surfaces() {
    local d f
    for d in mmry/skills mmry/skills-codex mmry/commands mmry/commands-codex; do
        [ -d "$ROOT/$d" ] && find "$ROOT/$d" -type f -name '*.md' -print | sed 's/^/md /'
    done
    [ -d "$ROOT/docs" ] && find "$ROOT/docs" -maxdepth 1 -type f -name '*.md' -print | sed 's/^/md /'
    for f in README.md mmry/README.md; do
        [ -f "$ROOT/$f" ] && printf 'md %s\n' "$ROOT/$f"
    done
    [ -f "$ROOT/mmry/hooks-handlers/mcp-server.sh" ] && printf 'mcp %s\n' "$ROOT/mmry/hooks-handlers/mcp-server.sh"
    for f in $FEATURE_SCRIPTS; do
        [ -f "$ROOT/mmry/hooks-handlers/$f" ] && printf 'script %s\n' "$ROOT/mmry/hooks-handlers/$f"
    done
}

files=0
findings=0
report=""

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    kind="${entry%% *}"
    path="${entry#* }"
    files=$((files + 1))
    rel="${path#$ROOT/}"
    out="$(awk -v rel="$rel" -v kind="$kind" '
        function strip_identifiers(s) {
            # camelCase and PascalCase: a lower-case letter followed by a capital.
            gsub(/[A-Za-z0-9_]*[a-z][A-Z][A-Za-z0-9_]*/, " ", s)
            # Led by $ ${ -- or a dot: a variable, a flag, a jq path.
            gsub(/([$][{]?|--|[.])[A-Za-z0-9_]+/, " ", s)
            # Joined by - _ . or /: a file, a function, a route, a key.
            gsub(/[A-Za-z0-9]*([-_.\/][A-Za-z0-9]+)+/, " ", s)
            # A shell assignment.
            gsub(/[A-Za-z0-9_]+=/, " ", s)
            return s
        }
        function word(s, w) {
            return s ~ ("(^|[^a-z0-9])" w "([^a-z0-9]|$)")
        }
        {
            raw = $0
            sub(/\r$/, "", raw)

            if (kind == "mcp") {
                if (raw ~ /^MMRY_MCP_TOOLS=/) intools = 1
                keep = 0
                if (intools && raw ~ /"(title|description)"[ \t]*:/) keep = 1
                if (raw ~ /^MMRY_MCP_INSTRUCTIONS=/) keep = 1
                if (intools && raw ~ /^\]/) intools = 0
                if (!keep) next
            }
            if (kind == "script") {
                if (raw ~ /^[ \t]*#/) next
            }
            if (kind == "md" && raw ~ /^## /) {
                feat = (tolower(raw) ~ /record|(^|[^a-z])formats?([^a-z]|$)|database/) ? 1 : 0
            }

            lraw = tolower(raw)
            about = (kind == "script") || feat
            if (lraw ~ /create-format|list-formats|revise-format|save-record|query-records|record-history|mmry_format_|mmry_record|mmry_list_formats|mmry_get_format|mmry_create_format|mmry_revise_format|mmry_rename_format|mmry_retire_format|mmry_reinstate_format|mmry_create_record|mmry_get_records|mmry_get_record_history|--record-type|--record-fields|--record-name|--record-id|--format-id|data-formats/) about = 1
            if (word(lraw, "databases?")) about = 1

            line = tolower(strip_identifiers(raw))

            what = ""
            if (line ~ /record[ \t]+types?/)                       what = "record type"
            else if (line ~ /structured[ \t]+records?/)            what = "structured record"
            else if (line ~ /data[ \t]+formats?/)                  what = "data format"
            else if (about && word(line, "formats?"))              what = "format"
            else if (about && word(line, "record(s|ed|ing)?"))     what = "record"

            if (what != "") {
                text = raw
                gsub(/^[ \t]+/, "", text)
                if (length(text) > 140) text = substr(text, 1, 137) "..."
                printf "%s:%d: %s: %s\n", rel, NR, what, text
            }
        }' "$path")"
    if [ -n "$out" ]; then
        n="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
        findings=$((findings + n))
        report="${report}${out}
"
    fi
done <<EOF
$(_surfaces)
EOF

if [ "$files" -eq 0 ]; then
    echo "check-database-names: none of the customer-readable surfaces exist under $ROOT" >&2
    exit 2
fi

if [ "$findings" -gt 0 ]; then
    printf '%s' "$report"
    echo "check-database-names: ${findings} line(s) call the AI database by an internal name (#32457, DD-150)." >&2
    echo "Say database for one tracked thing and entry for each item in it; keep identifiers as they are." >&2
    exit 1
fi

echo "check-database-names: clean (${files} files read)"
exit 0
