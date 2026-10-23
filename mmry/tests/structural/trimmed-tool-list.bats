#!/usr/bin/env bats
# trimmed-tool-list.bats - two handlers, their Codex tools and their client functions were removed
# from the plugin (#32640). Nothing in the plugin tree names them any more, outside the historical
# evidence under docs/evidence, which is kept as it was.
#
# The four names are assembled from parts, so this file does not itself contain what it searches for.

load '../helpers/test-helper'

_names() {
    local r="rein""force" l="li""nk"
    printf '%s\n' "${r}-memory" "${l}-memories" "memory_${r}" "memory_${l}"
}

# Every file under ROOT, outside .git and docs/evidence, that names one of the four.
_hits() {
    local root="$1" n
    while IFS= read -r n; do
        (cd "$root" && grep -rlF --exclude-dir=.git -- "$n" . 2>/dev/null) | grep -v '^\./docs/evidence/' || true
    done < <(_names)
}

setup() {
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
}

@test "32640 req1: no file in the plugin tree outside docs/evidence names a removed handler or tool" {
    local found
    found="$(_hits "$REPO_ROOT" | sort -u)"
    [[ -z "$found" ]] || { echo "still named in:"; echo "$found"; return 1; }
}

@test "32640 req1: the scan is real: it finds each name planted in a scratch tree, and skips docs/evidence" {
    local root="$BATS_TEST_TMPDIR/scan" n i=0
    mkdir -p "$root/mmry" "$root/docs/evidence"
    while IFS= read -r n; do
        i=$((i + 1))
        printf 'see %s here\n' "$n" > "$root/mmry/planted-$i.md"
        printf 'see %s here\n' "$n" > "$root/docs/evidence/kept-$i.md"
    done < <(_names)
    [ "$(_hits "$root" | sort -u | grep -c .)" -eq 4 ]
    [[ "$(_hits "$root")" != *evidence* ]]
}

@test "32640 req1: the two handler scripts and their unit tests do not exist" {
    local n
    for n in "rein""force-memory" "li""nk-memories"; do
        [[ ! -e "$PLUGIN_ROOT/hooks-handlers/$n.sh" ]] || { echo "hooks-handlers/$n.sh exists"; return 1; }
        [[ ! -e "$PLUGIN_ROOT/tests/handlers/$n.bats" ]] || { echo "tests/handlers/$n.bats exists"; return 1; }
    done
}

@test "32640 req1: the client library no longer defines the matching functions" {
    local f="$PLUGIN_ROOT/hooks-handlers/mmry-client.sh" fn
    for fn in mmry_reinforce_memory mmry_create_link mmry_delete_link; do
        ! grep -qE "^${fn}\(\)" "$f" || { echo "$fn is still defined"; return 1; }
    done
}

@test "32640: the related-memories read function is left in the client library" {
    # The read side belongs to 32623, not to this change.
    grep -qE '^mmry_get_related\(\)' "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh"
}

@test "32640 req1: the Codex host gives no tool reference for the removed tool names" {
    local n out
    for n in "memory_rein""force" "memory_li""nk"; do
        out="$(MMRY_HOST=codex CODEX_HOME="$BATS_TEST_TMPDIR/codex" bash -c \
            'source "$1/hooks-handlers/lib-host.sh"; mmry_host_tool_ref "$2"; echo " rc=$?"' _ "$PLUGIN_ROOT" "$n")"
        [[ "$out" == " rc=1" ]] || { echo "$n: $out"; return 1; }
    done
    # Control: a tool that remains is still referenced.
    out="$(MMRY_HOST=codex CODEX_HOME="$BATS_TEST_TMPDIR/codex" bash -c \
        'source "$1/hooks-handlers/lib-host.sh"; mmry_host_tool_ref memory_save' _ "$PLUGIN_ROOT")"
    [[ "$out" == "the mmry_plugin memory_save tool" ]] || { echo "$out"; return 1; }
}
