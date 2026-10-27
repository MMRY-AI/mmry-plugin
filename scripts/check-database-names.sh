#!/usr/bin/env bash
# check-database-names.sh - refuse customer- or assistant-readable plugin text, and any name an
# assistant runs, that calls the AI database by its old names (#32457 DD-150, #32957 DD-164 in the
# mmry repository).
#
# Usage: bash scripts/check-database-names.sh [REPO_ROOT]
#   REPO_ROOT defaults to the repository this script lives in. The BATS test passes a copy.
#
# Exit 0 and a one-line summary when the text is clean. Exit 1 and one line per finding,
# "path:line: rule: text", when it is not. Exit 2 when the root holds none of the surfaces,
# because a check that read nothing must not report a pass.
#
# THE NAMES (DD-150, DD-164). The feature is marketed as the AI database. One tracked thing is a
# database, each saved item in it is an entry, and its named values are fields. Since #32957 the
# names an assistant runs say so too: "The old names don't need to work. Get rid of them." (Eric,
# 2026-10-27). So a third rule, N, below.
#
# WHAT IS READ. The same customer-readable surfaces as check-public-text.sh (the Claude Code and
# Codex skills, the commands, the READMEs, the top-level docs pages, the Codex MCP server's tool
# titles, descriptions and instructions), plus every non-comment line of the eight scripts that
# serve the database, because what they print is what the assistant reads and repeats.
#
# RULE N, THE NAMES (#32957). Formation is a different feature: "formation" is not the old word.
#   - no script in mmry/hooks-handlers is named with format or record;
#   - no option a database script or save-memory.sh accepts (its case labels) carries format or record;
#   - no client function in mmry-client.sh that calls /api/databases carries format or record;
#   - no tool the Codex local MCP server lists (mcp-server.sh) is named with format or record;
#   - no surface above, comments included, names a retired script, option, tool or route
#     (create-format.sh, --record-id, mmry_record, /api/data-formats and the rest), or the account
#     database page's retired address mmryai.com/records (it is mmryai.com/databases).
#
# TWO RULES.
#   A, everywhere read: no "record type", "structured record" or "data format".
#   B, wherever the text is about the database: no "format", "formats", "record", "records",
#      "recorded" or "recording" as a word. The text is about the database in the eight scripts, in the
#      database section of a skill (a "## " or "### " heading that names records, formats
#      or the database, down to the next heading of its level), and on any line that names one of the
#      database's scripts, flags or tools or says "database". Elsewhere these are ordinary
#      English (a Formation's close-out record, a date format) and are not this feature.
#
# CODE IS NOT PROSE. A token joined by - _ . / or led by $ ${ -- (save-record.sh, --record-id,
# mmry_record, .format.name, $recorded, /records), a token written in camelCase or PascalCase
# (SavedInDatabase, databaseId) and a shell assignment (saved_in=) are identifiers and are removed from
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

# The eight scripts that serve the database. Every non-comment line is read under both rules.
# database.sh joined in #32957 fix round 1: it prints the account page's address, which rule N reads.
FEATURE_SCRIPTS="create-database.sh list-databases.sh revise-database.sh save-entry.sh query-entries.sh entry-history.sh save-memory.sh database.sh"
# The scripts whose options rule N reads: every database script, the dispatcher and save-memory.sh.
OPTION_SCRIPTS="create-database.sh list-databases.sh revise-database.sh rename-database.sh retire-database.sh reinstate-database.sh save-entry.sh query-entries.sh entry-history.sh database.sh save-memory.sh"
# A retired script, option, tool, client function or route, named anywhere (#32957), and the account
# database page's retired address mmryai.com/records (now mmryai.com/databases, DD-164 decision 6).
OLD_NAMES='create-format|list-formats|revise-format|rename-format|retire-format|reinstate-format|save-record|query-records|record-history|--format-id|--record-id|--record-type|--record-fields|--record-name|mmry_format_|mmry_records?([^a-z_]|$)|mmry_record_history|mmry_list_formats|mmry_get_format([^a-z_]|$)|mmry_create_format|mmry_revise_format|mmry_rename_format|mmry_retire_format|mmry_reinstate_format|mmry_create_record|mmry_get_records|mmry_get_record_history|_mmry_format_|data-formats|formatId|recordId|recordName|recordType|recordFields|mmryai[.]com/records([^a-z_-]|$)'

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
    out="$(awk -v rel="$rel" -v kind="$kind" -v old="$OLD_NAMES" '
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
            if (kind == "md" && raw ~ /^###? /) {
                hit = (tolower(raw) ~ /record|(^|[^a-z])formats?([^a-z]|$)|database/) ? 1 : 0
                if (raw ~ /^## /) { feat2 = hit; feat3 = 0 } else { feat3 = hit }
                feat = feat2 || feat3
            }

            # Rule N, before comments are dropped: a retired name anywhere, a comment included.
            if (raw ~ old) {
                text = raw
                gsub(/^[ \t]+/, "", text)
                if (length(text) > 140) text = substr(text, 1, 137) "..."
                printf "%s:%d: old name: %s\n", rel, NR, text
                next
            }

            if (kind == "script" && raw ~ /^[ \t]*#/) next

            lraw = tolower(raw)
            about = (kind == "script") || feat
            if (lraw ~ /create-database|list-databases|revise-database|save-entry|query-entries|entry-history|mmry_database_|mmry_entry_|mmry_list_databases|mmry_get_database|mmry_create_database|mmry_revise_database|mmry_rename_database|mmry_retire_database|mmry_reinstate_database|mmry_save_entry|mmry_get_entries|mmry_get_entry_history|--database-name|--entry-fields|--entry-name|--entry-id|--database-id|\/api\/databases/) about = 1
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


# ---- Rule N: the names themselves (#32957) ---------------------------------------------------
_name_finding() { # where, name
    findings=$((findings + 1))
    report="${report}$1: name: $2
"
}
HH="$ROOT/mmry/hooks-handlers"
if [ -d "$HH" ]; then
    for f in "$HH"/*; do
        b="$(basename "$f")"
        lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]' | sed 's/formation//g')"
        case "$lb" in *format*|*record*) _name_finding "mmry/hooks-handlers" "$b" ;; esac
    done
    for s in $OPTION_SCRIPTS; do
        [ -f "$HH/$s" ] || continue
        files=$((files + 1))
        # Each case label that is an option: "--name)" or "--a|--b)".
        opts="$(grep -oE '^[[:space:]]*--[a-z0-9-]+(\|--[a-z0-9-]+)*\)' "$HH/$s" | tr -d ' )' | tr '|' '\n')"
        for o in $opts; do
            case "$(printf '%s' "$o" | tr '[:upper:]' '[:lower:]')" in
                *format*|*record*) _name_finding "mmry/hooks-handlers/$s option" "$o" ;;
            esac
        done
    done
    if [ -f "$HH/mmry-client.sh" ]; then
        files=$((files + 1))
        # A client function is a database function when its body calls /api/databases (or did).
        fns="$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { name = $1; sub(/\(\).*/, "", name) }
                    /\/api\/(databases|data-formats)/ && name != "" { print name }' "$HH/mmry-client.sh" | sort -u)"
        for fn in $fns; do
            case "$(printf '%s' "$fn" | tr '[:upper:]' '[:lower:]')" in
                *format*|*record*) _name_finding "mmry/hooks-handlers/mmry-client.sh function" "$fn" ;;
            esac
        done
    fi
    if [ -f "$HH/mcp-server.sh" ]; then
        tools="$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[a-z_]+"' "$HH/mcp-server.sh" | sed -E 's/.*"([a-z_]+)"$/\1/' | sort -u)"
        for t in $tools; do
            case "$(printf '%s' "$t" | sed 's/formation//g')" in
                *format*|*record*) _name_finding "mmry/hooks-handlers/mcp-server.sh tool" "$t" ;;
            esac
        done
    fi
fi

# ---- Rule N in the code: every shell name and every database test name (#32957 fix round 3) ----
# Fix round 2 read the script names, the options, the client functions that call /api/databases and
# the Codex tools, so a usage comment's RECORD_FIELDS_JSON, a test array RECORD_HANDLERS and the
# feature's own test names kept the old words and the check passed. This reads every shell file in
# mmry/ and scripts/ (.sh, .bash, .bats): each function it defines, each variable it sets, declares
# or expands, and each upper-case placeholder in a "Usage:" comment. A name carrying format (not
# formation) or record is refused unless SHELL_ALLOWED lists it, with why it is another feature's.
# The generic words alone (record, records, recorded, format, formats) are allowed only in a file
# about another feature (a Formation, the Foundation check, the tool server's own bookkeeping).
# In the database's own test files, a test's name (@test "...") is read under rules A and B as well.
SHELL_ALLOWED=" _MMRY_FS_RECORD_RE _fnd_any_record fnd_set_record mmry_foundation_record_path _records _recorded _recorded_bytes \
mmry_ts_record_exit mmry_ts_record_failure mmry_ts_record_launch mmry_ts_record_running mmry_ts_record_session _record_running_server \
mmry_record_session_agent _recording_curl_dir _record_body _format_error "
# Why: _MMRY_FS_RECORD_RE, _record_body, _recording_curl_dir: a Formation's local membership record
# and close-out record. _fnd_*, fnd_set_record, mmry_foundation_record_path, _records, _recorded*:
# the Foundation delivery record. mmry_ts_record_*, _record_running_server: the Codex tool server
# records its own start. mmry_record_session_agent: the verb. _format_error: an error message's format.
GENERIC_ELSEWHERE='formation|foundation|tool-server|mcp-server|codex-missing-tools'
DATABASE_TESTS='entry-handlers[.]bats|entries[.]bats|entry-surface[.]bats|database-command[.]bats'
code_files="$( { [ -d "$ROOT/mmry" ] && find "$ROOT/mmry" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' \) -print
                 [ -d "$ROOT/scripts" ] && find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' \) -print; } \
               | grep -v '/[.]git/' | grep -v '/tests/libs/' | grep -v '/tests/test_helper/' | sort)"
code_list=()
while IFS= read -r path; do [ -n "$path" ] && code_list+=("$path"); done <<CODEFILES
$code_files
CODEFILES
code_count=${#code_list[@]}
if [ "$code_count" -gt 0 ]; then
    out="$(awk -v root="$ROOT/" -v allowed="$SHELL_ALLOWED" -v elsewhere="$GENERIC_ELSEWHERE" -v dbtests="$DATABASE_TESTS" '
        function old(id,   l) { l = tolower(id); gsub(/formation/, "", l); return l ~ /format|record/ }
        function judge(id) {
            if (!old(id)) return
            if (index(allowed, " " id " ")) return
            if ((id == "record" || id == "records" || id == "recorded" || id == "format" || id == "formats") && rel ~ elsewhere) return
            printf "%s:%d: identifier: %s\n", rel, FNR, id
        }
        FNR == 1 { rel = FILENAME; if (index(rel, root) == 1) rel = substr(rel, length(root) + 1) }
        {
            line = $0; sub(/\r$/, "", line)
            if (line ~ /^[ \t]*#/) {
                if (line ~ /Usage:/) { s = line; while (match(s, /[A-Z][A-Z0-9_]*[A-Z0-9]/)) { judge(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH) } }
                next
            }
            if (line ~ /^[ \t]*@test /) {
                if (rel ~ dbtests) {
                    t = tolower(line)
                    if (t ~ /record[- \t]+types?|structured[- \t]+records?|data[- \t]+formats?|(^|[^a-z0-9_.-])(records?|recorded|recording|formats?)([^a-z0-9_.-]|$)/)
                        printf "%s:%d: test name: %s\n", rel, FNR, line
                }
                next
            }
            # A single-quoted string is literal text (a sed expression, a planted line in a test),
            # never a name the shell defines or expands, so it is not read.
            gsub(/\047[^\047]*\047/, "\047\047", line)
            if (match(line, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*[(][)]/)) {
                t = substr(line, RSTART, RLENGTH); sub(/^[ \t]*(function[ \t]+)?/, "", t); sub(/[ \t]*[(][)]$/, "", t); judge(t)
            }
            s = line; while (match(s, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) { t = substr(s, RSTART, RLENGTH); sub(/^[$][{]?/, "", t); judge(t); s = substr(s, RSTART + RLENGTH) }
            s = line; while (match(s, /(^|[ \t;(])[A-Za-z_][A-Za-z0-9_]*[+]?=/)) { t = substr(s, RSTART, RLENGTH); sub(/^[ \t;(]/, "", t); sub(/[+]?=$/, "", t); judge(t); s = substr(s, RSTART + RLENGTH) }
            s = line; while (match(s, /(local|declare|readonly|export|unset)([ \t]+-[a-zA-Z]+)*[ \t]+[A-Za-z_][A-Za-z0-9_ \t]*/)) {
                t = substr(s, RSTART, RLENGTH); sub(/^(local|declare|readonly|export|unset)([ \t]+-[a-zA-Z]+)*[ \t]+/, "", t)
                n = split(t, a, /[ \t]+/); for (i = 1; i <= n; i++) if (a[i] != "") judge(a[i])
                s = substr(s, RSTART + RLENGTH)
            }
        }' "${code_list[@]}")"
    if [ -n "$out" ]; then
        n="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
        findings=$((findings + n))
        report="${report}${out}
"
    fi
fi
files=$((files + code_count))
if [ -d "$ROOT/mmry/hooks-handlers" ] && [ "$code_count" -lt 50 ]; then
    echo "check-database-names: read only ${code_count} shell files for names under $ROOT" >&2
    exit 2
fi

if [ "$files" -eq 0 ]; then
    echo "check-database-names: none of the customer-readable surfaces exist under $ROOT" >&2
    exit 2
fi

if [ "$findings" -gt 0 ]; then
    printf '%s' "$report"
    echo "check-database-names: ${findings} line(s) or name(s) call the AI database by an old name (#32457 DD-150, #32957 DD-164)." >&2
    echo "Say database for one tracked thing and entry for each item in it, in the words and in the names." >&2
    exit 1
fi

echo "check-database-names: clean (${files} files read)"
exit 0
