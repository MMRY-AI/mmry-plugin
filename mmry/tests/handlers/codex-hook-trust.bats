#!/usr/bin/env bats
# codex-hook-trust.bats - MMRY writes nothing into its own Codex plugin folder at session time (#33062).
#
# THE DEFECT. Codex fingerprints the plugin folder it installed (<CODEX_HOME>/plugins/cache/...) into
# each hook's trusted_content_hash when the customer trusts MMRY's hooks. On 2.15.5 and 2.15.6 the
# first session then wrote two files into that folder: session-init.sh the .mmry-host marker, and
# self-update.sh (run by session-init.sh on Codex) its .last-release-cleanup record. From the second
# session on Codex saw "plugin contents changed": the app asked "Hooks need review" again, and in
# codex exec every MMRY hook failed with "plugin contents changed; hook approval required", so the
# conversation got no memories at all.
#
# WHAT THIS FILE PROVES. Every hook hooks/codex-hooks.json registers, run by the command Codex runs,
# and the MCP server codex-mcp.json registers, run as Codex starts it, for three sessions in a row,
# leave that folder byte-identical: no file added, removed or changed, no executable bit moved. Also
# when an update is available and self-update applies it. Each test also checks the sessions did
# their work (memories delivered, the install written to the Codex home), so a run that did nothing
# cannot pass.
#
# The real Codex check, a second and third `codex exec` keeping hook trust, is
# tests/integration/codex-hook-trust-live.bats.

load '../helpers/test-helper'
load '../helpers/mock-config'

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    unset MMRY_HOST CODEX_HOME MMRY_NO_SELF_UPDATE || true
    CX="$TEST_TMPDIR/codexhome"
    mkdir -p "$CX"
    printf '{"apiUrl":"http://localhost:5291","authMethod":"apikey","apiKey":"test-api-key-12345"}' > "$CX/mmry-config.json"
    # Where `codex plugin add` puts a plugin from a local marketplace, and a pristine copy beside it.
    ROOT="$CX/plugins/cache/mmry-plugin/mmry/local"
    REF="$TEST_TMPDIR/pristine"
    _copy_plugin "$ROOT"
    _copy_plugin "$REF"
}

teardown() {
    # The housekeeping runs on after each hook returns; give it its end before the folder goes.
    _settle 30 || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

# The plugin as a release ships it: everything in mmry/ but the test suite, which is not run there.
_copy_plugin() {
    mkdir -p "$1"
    ( cd "$PLUGIN_ROOT" && tar -cf - --exclude=./tests . ) | ( cd "$1" && tar -xf - )
}

# The folder Codex fingerprints, as a listing a person can read: every path and type, which files are
# executable, and every file's bytes compared against the pristine copy.
_root_differences() {
    local a b
    a="$( cd "$REF" && find . -print | LC_ALL=C sort )"
    b="$( cd "$ROOT" && find . -print | LC_ALL=C sort )"
    [[ "$a" == "$b" ]] || diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
    a="$( cd "$REF" && find . -type f -perm -u+x -print | LC_ALL=C sort )"
    b="$( cd "$ROOT" && find . -type f -perm -u+x -print | LC_ALL=C sort )"
    [[ "$a" == "$b" ]] || { echo "executable files differ:"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"); }
    diff -r "$REF" "$ROOT" >/dev/null 2>&1 || diff -rq "$REF" "$ROOT"
    return 0
}

# True once the session's deferred work has written its last mark and nothing in the Codex home or the
# plugin folder has changed for 3 s. $1 is the most seconds to wait.
# One process per look, not one per file: on Windows a process costs tens of milliseconds.
_tree_sig() {
    ls -lRa "$ROOT" "$CX/mmry" "$TMPDIR" 2>/dev/null
}
_settle() {
    local i=0 prev="" cur="" still=0
    while (( i < $1 * 2 )); do
        cur="$(_tree_sig)"
        if [[ "$cur" == "$prev" ]]; then
            still=$((still + 1))
            (( still >= 6 )) && return 0
        else
            still=0
        fi
        prev="$cur"
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

# Every hook of $1 (a hooks/codex-hooks.json event) for session $2, by the command Codex runs, with the
# environment Codex gives a plugin hook. Output to $TEST_TMPDIR/hooks.out and hooks.err.
_run_event() {
    local ev="$1" sid="$2" cmd payload
    case "$ev" in
        SessionStart)     payload="{\"session_id\":\"$sid\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$TEST_TMPDIR\"}" ;;
        UserPromptSubmit) payload="{\"session_id\":\"$sid\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\",\"cwd\":\"$TEST_TMPDIR\"}" ;;
        *)                payload="{\"session_id\":\"$sid\",\"hook_event_name\":\"$ev\",\"tool_name\":\"shell\",\"cwd\":\"$TEST_TMPDIR\"}" ;;
    esac
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        ( cd "$TEST_TMPDIR" && printf '%s' "$payload" | env -u MMRY_HOST -u MMRY_CONFIG_FILE -u MMRY_NO_SELF_UPDATE \
            HOME="$HOME" CODEX_HOME="$CX" PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$cmd" ) \
            >> "$TEST_TMPDIR/hooks.out" 2>> "$TEST_TMPDIR/hooks.err" || true
    done < <(jq -r --arg e "$ev" '.hooks[$e][]?.hooks[]?.command' "$ROOT/hooks/codex-hooks.json" | tr -d '\r')
}

# One whole Codex session: every registered event, and the MCP server started and asked for its tools.
_session() {
    local sid="trust-$1" ev
    rm -f "$TMPDIR/.mmry-update-checked"    # so self-update runs in full every session, not once an hour
    for ev in $(jq -r '.hooks | keys[]' "$ROOT/hooks/codex-hooks.json" | tr -d '\r'); do
        [[ "$ev" == SessionStart ]] && _run_event "$ev" "$sid"
    done
    for ev in $(jq -r '.hooks | keys[]' "$ROOT/hooks/codex-hooks.json" | tr -d '\r'); do
        [[ "$ev" != SessionStart ]] && _run_event "$ev" "$sid"
    done
    ( cd "$ROOT" && printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        | env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" sh ./mcp/mmry-mcp ) \
        >> "$TEST_TMPDIR/mcp.out" 2>> "$TEST_TMPDIR/mcp.err" || true
    # The update check is the last step of the deferred work; wait for it, then for quiet.
    local i=0
    while [[ ! -e "$TMPDIR/.mmry-update-checked" ]] && (( i < 120 )); do sleep 0.5; i=$((i + 1)); done
    _settle 60
}

@test "codex: three sessions of every MMRY hook and the MCP server leave the plugin folder byte-identical" {
    [[ -z "$(_root_differences)" ]] || { echo "the copies differ before any session"; return 1; }
    local s d
    for s in 1 2 3; do
        _session "$s"
        d="$(_root_differences)"
        [[ -z "$d" ]] || {
            echo "after session $s the plugin folder Codex fingerprints has changed:"
            printf '%s\n' "$d"
            return 1
        }
    done
    # The sessions did their work: memories handed over, the install written to the Codex home.
    grep -q 'Test Memory' "$TEST_TMPDIR/hooks.out" || { echo "no memories were delivered: $(head -c 600 "$TEST_TMPDIR/hooks.out")"; return 1; }
    [ -f "$CX/mmry/hooks-handlers/save-memory.sh" ] || { echo "the handlers were not installed in the Codex home"; return 1; }
    grep -qx 'codex' "$CX/mmry/.mmry-host" || { echo "the Codex home's install has no host marker"; return 1; }
    grep -q '"tools"' "$TEST_TMPDIR/mcp.out" || { echo "the MCP server did not answer: $(head -c 400 "$TEST_TMPDIR/mcp.err")"; return 1; }
}

@test "codex: a session that self-updates to a newer release still leaves the plugin folder byte-identical" {
    # A newer release is on offer. The update goes where MMRY's own files live, the Codex home's copy;
    # the plugin folder is Codex's, and it changes when Codex installs a new version, not before.
    local ver rel="$TEST_TMPDIR/remote/mmry-plugin-master/mmry"
    ver="$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json" | tr -d '\r')"
    mkdir -p "$TEST_TMPDIR/remote/mmry-plugin-master"
    _copy_plugin "$rel"
    jq '.version = "99.0.0"' "$ROOT/.claude-plugin/plugin.json" > "$rel/.claude-plugin/plugin.json"
    sed "1s/.*/# mmry release files 99.0.0/" "$ROOT/release-files.txt" > "$rel/release-files.txt"
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
    local real_curl="$TEST_TMPDIR/mock-bin/curl"
    mv "$real_curl" "$TEST_TMPDIR/mock-bin/curl-service"
    cat > "$real_curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *marketplace.json*) printf '%s' '{"plugins":[{"name":"mmry","version":"99.0.0"}]}'; exit 0 ;;
    *archive/refs/heads/master.tar.gz*)
        prev=""; for a in "\$@"; do [[ "\$prev" == "-o" ]] && cp "$TEST_TMPDIR/remote.tar.gz" "\$a"; prev="\$a"; done
        exit 0 ;;
esac
exec "$TEST_TMPDIR/mock-bin/curl-service" "\$@"
EOF
    chmod +x "$real_curl"

    _session 1
    local i=0
    while ! grep -qs '99.0.0' "$CX/mmry/.claude-plugin/plugin.json" && [[ -z "$(_root_differences)" ]] && (( i < 120 )); do
        sleep 0.5; i=$((i + 1))
    done
    _settle 60
    local d; d="$(_root_differences)"
    [[ -z "$d" ]] || { echo "the update was written into the plugin folder Codex fingerprints:"; printf '%s\n' "$d"; return 1; }
    grep -q '"version": *"99.0.0"' "$CX/mmry/.claude-plugin/plugin.json" \
        || { echo "the update did not reach the Codex home's copy (still $(jq -r .version "$CX/mmry/.claude-plugin/plugin.json" 2>/dev/null), was $ver)"; return 1; }
    _session 2
    d="$(_root_differences)"
    [[ -z "$d" ]] || { echo "after the second session the plugin folder has changed:"; printf '%s\n' "$d"; return 1; }
}
