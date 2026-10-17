#!/usr/bin/env bash
# check-public-text.sh - refuse customer-readable plugin text that names an internal memory
# mechanic (#32272, DD-140 in the mmry repository).
#
# Usage: bash scripts/check-public-text.sh [REPO_ROOT]
#   REPO_ROOT defaults to the repository this script lives in. The BATS test passes a copy.
#
# Exit 0 and a one-line summary when the text is clean. Exit 1 and one line per finding,
# "path:line: what: text", when it is not. Exit 2 when the root holds none of the surfaces,
# because a check that read nothing must not report a pass.
#
# WHAT IS CUSTOMER-READABLE. Everything a customer can read in the published plugin or in the
# documentation it links to: the Claude Code and Codex skills, the commands, the READMEs, the
# top-level docs pages and the description lines of the three manifests. Also the text the
# Codex MCP server hands the assistant in mmry/hooks-handlers/mcp-server.sh: every title and
# description line in its tool list, and its server instructions line. Only those lines of
# that file are read; the rest is code. docs/evidence/ is engineering evidence kept for QA
# (raw request logs and traces), not documentation, and is not read.
#
# WHAT IS AN INTERNAL MECHANIC. How long each kind of memory lasts, how memories are kept alive,
# and the server's route list. Connected assistants already keep these out of every tool
# description (DD-48); this holds the plugin to the same rule.
#
# CODE IS NOT PROSE. The handler file name reinforce-memory.sh, the client function
# mmry_reinforce_memory and the Codex MCP tool name memory_reinforce are code in a public
# repository and cannot be hidden (renaming the tool would change behaviour), so those three
# identifiers are removed from a line before it is checked. Nothing else is allow-listed.
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
    echo "check-public-text: no such directory: $ROOT" >&2
    exit 2
fi

# The surfaces, one path per line, relative to ROOT.
_surfaces() {
    local d
    for d in mmry/skills mmry/skills-codex mmry/commands mmry/commands-codex; do
        [ -d "$ROOT/$d" ] && find "$ROOT/$d" -type f -name '*.md' -print
    done
    [ -d "$ROOT/docs" ] && find "$ROOT/docs" -maxdepth 1 -type f -name '*.md' -print
    local f
    for f in README.md mmry/README.md .claude-plugin/marketplace.json \
             mmry/.claude-plugin/plugin.json mmry/.codex-plugin/plugin.json \
             mmry/hooks-handlers/mcp-server.sh; do
        [ -f "$ROOT/$f" ] && printf '%s\n' "$ROOT/$f"
    done
}

files=0
findings=0
report=""

while IFS= read -r path; do
    [ -n "$path" ] || continue
    files=$((files + 1))
    rel="${path#$ROOT/}"
    mcp=0
    [ "$rel" = "mmry/hooks-handlers/mcp-server.sh" ] && mcp=1
    out="$(awk -v rel="$rel" -v mcp="$mcp" '
        {
            raw = $0
            sub(/\r$/, "", raw)
            if (mcp == 1) {
                # Only the text the assistant is shown: title and description lines inside the
                # tool list, and the server instructions line. The rest of the file is code.
                if (raw ~ /^MMRY_MCP_TOOLS=/) intools = 1
                keep = 0
                if (intools && raw ~ /"(title|description)"[ \t]*:/) keep = 1
                if (raw ~ /^MMRY_MCP_INSTRUCTIONS=/) keep = 1
                if (intools && raw ~ /^\]/) intools = 0
                if (!keep) next
            }
            line = tolower(raw)
            gsub(/reinforce-memory\.sh/, "", line)
            gsub(/mmry_reinforce_memory/, "", line)
            gsub(/memory_reinforce/, "", line)

            what = ""
            if (line ~ /reinforc/)                                   what = "reinforce or reinforcement"
            else if (line ~ /expiration clock|expiry clock|tier clock/) what = "expiry clock"
            else if (line ~ /access[ _-]?count/)                     what = "access count"
            else if (line ~ /\/api\//)                               what = "server route"
            else if (line ~ /(aged?|ages) out|(stay|stays|kept|keep|keeps) alive|fades? naturally|regardless of (its |their )?age|ignores age/) what = "how memories are kept alive"
            else if (line ~ /foundation|strategic|operational|tactical|momentary/ &&
                     (line ~ /[0-9]+[ -]*(hour|day|week|month|year)s?/ ||
                      line ~ /(one|two|three|four|five|six|seven|eight|nine|ten|twelve)[ -]+(hour|day|week|month|year)s?/ ||
                      line ~ /expir|forever|last access|from creation/))
                what = "how long a kind of memory lasts"

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
    echo "check-public-text: none of the customer-readable surfaces exist under $ROOT" >&2
    exit 2
fi

if [ "$findings" -gt 0 ]; then
    printf '%s' "$report"
    echo "check-public-text: ${findings} line(s) in customer-readable text name an internal memory mechanic (#32272, DD-140)." >&2
    echo "Describe what the customer or assistant does, not how the server keeps memories." >&2
    exit 1
fi

echo "check-public-text: clean (${files} customer-readable files read)"
exit 0
