#!/usr/bin/env bash
# build-release-files.sh - write (or check) mmry/release-files.txt, the list of every file a
# plugin release ships (#32957 fix round 4).
#
# WHY THIS EXISTS. self-update.sh used to copy a new release over the install folder and delete
# nothing, so a file a release dropped stayed on every customer machine for good. After the AI
# database rename that meant nine old database scripts (save-record.sh, query-records.sh and the
# rest) sat beside their replacements. self-update.sh now removes, from the plugin's own folders,
# whatever the release being installed does not list. It decides that from THIS file and from
# nothing else: never from a name pattern, never from a guess.
#
# WHAT IS IN IT. The first line is "# mmry release files <version>", the version in
# mmry/.claude-plugin/plugin.json, so self-update can tell a list from a different release apart
# from the one it belongs with. Every other line is one path, relative to mmry/, of a file git
# tracks under mmry/. That is exactly what a release archive contains: GitHub builds the archive
# from the same tree, and this repository has no export-ignore rules.
#
# A git submodule (the BATS libraries under tests/libs) is written as its directory with a
# trailing slash. A GitHub archive leaves submodules out but a marketplace install clones them in,
# and their contents are not listed file by file here, so the slash means "this whole directory
# belongs to the release; keep what is in it".
#
# USAGE
#   bash scripts/build-release-files.sh           rewrite mmry/release-files.txt
#   bash scripts/build-release-files.sh --check   exit 1, naming the difference, if the committed
#                                                 file does not match the tree (CI and
#                                                 structural/release-files.bats run this)
#
# Run it after adding, removing or renaming any file under mmry/ (git add first: it reads the
# index, which is what the next commit will ship), and after a version bump.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="${REPO_ROOT}/mmry/release-files.txt"
PLUGIN_JSON="${REPO_ROOT}/mmry/.claude-plugin/plugin.json"

mode="write"
case "${1:-}" in
    "") ;;
    --check) mode="check" ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

# The version, read without jq so this runs on a bare CI image. plugin.json has exactly one
# "version" key (structural/marketplace-sync.bats checks the file).
version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)"
if [[ -z "$version" ]]; then
    echo "build-release-files: could not read the version from $PLUGIN_JSON" >&2
    exit 1
fi

generate() {
    printf '# mmry release files %s\n' "$version"
    {
        # Mode 160000 is a submodule (gitlink): list the directory, not its contents.
        git -C "$REPO_ROOT" ls-files -s -z -- mmry | while IFS= read -r -d "" line; do
            meta="${line%%$'\t'*}"
            path="${line#*$'\t'}"
            path="${path#mmry/}"
            if [[ "${meta%% *}" == "160000" ]]; then
                printf '%s/\n' "$path"
            else
                printf '%s\n' "$path"
            fi
        done
        # The list ships in the release too, including the first time it is generated.
        printf '%s\n' "release-files.txt"
    } | LC_ALL=C sort -u
}

if [[ "$mode" == "write" ]]; then
    generate > "$LIST"
    echo "build-release-files: wrote $(($(wc -l < "$LIST") - 1)) paths for ${version} to mmry/release-files.txt"
    exit 0
fi

if [[ ! -f "$LIST" ]]; then
    echo "build-release-files: mmry/release-files.txt is missing; run: bash scripts/build-release-files.sh" >&2
    exit 1
fi
expected="$(generate)"
actual="$(cat "$LIST")"
if [[ "$expected" != "$actual" ]]; then
    echo "build-release-files: mmry/release-files.txt does not match the tree. Differences (< expected, > committed):" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    echo "Run: bash scripts/build-release-files.sh" >&2
    exit 1
fi
echo "build-release-files: mmry/release-files.txt matches the tree (${version})"
