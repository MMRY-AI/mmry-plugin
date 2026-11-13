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
# and the MCP server codex-mcp.json registers, run as Codex starts it, for three sessions in a row with
# no new release, leave that folder byte-identical: no file added, removed or changed, no executable bit
# moved. Each test also checks the sessions did their work (memories delivered, the install written to
# the Codex home), so a run that did nothing cannot pass.
#
# AND WHEN THERE IS A NEW RELEASE (#33062 fix round 5, option (a)). The hooks and the MCP server run
# from that folder, so a release reaches them only by being written there, as on 2.15.5: the session
# that is offered a newer verified release writes it into the plugin folder (and the Codex home), Codex
# asks for one hook review, and the next session runs the new hooks and MCP server. MMRY's bookkeeping
# (.last-release-cleanup, .last-self-update, .mmry-host) stays in the Codex home, so the sessions after
# that, with no further release, again leave the folder byte-identical. Only the plugin folder's own
# copy of self-update.sh updates: the Codex home's copy is not part of what Codex reviewed.
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

# A newer release on offer, as GitHub would serve it to self-update.sh: the plugin as it ships, at
# version $1, with a release-files.txt for that version, and one probe line in the hook launcher
# (codex-hook.sh, which every hook and the MCP server go through) that records which release ran.
# The pristine copy of that release is left at $RELEASE for comparison.
_offer_release() {
    local ver="$1"
    RELEASE="$TEST_TMPDIR/remote/mmry-plugin-master/mmry"
    rm -rf "${TEST_TMPDIR:?}/remote" "${TEST_TMPDIR:?}/remote.tar.gz"
    mkdir -p "$TEST_TMPDIR/remote/mmry-plugin-master"
    _copy_plugin "$RELEASE"
    jq --arg v "$ver" '.version = $v' "$REF/.claude-plugin/plugin.json" > "$RELEASE/.claude-plugin/plugin.json"
    sed "1s/.*/# mmry release files $ver/" "$REF/release-files.txt" > "$RELEASE/release-files.txt"
    { head -1 "$REF/hooks-handlers/codex-hook.sh"
      printf 'printf "PROBE-%s %%s\\n" "${1:-hook}" >> "${TMPDIR:-/tmp}/mmry-release-probe.log" 2>/dev/null || :\n' "$ver"
      tail -n +2 "$REF/hooks-handlers/codex-hook.sh"; } > "$RELEASE/hooks-handlers/codex-hook.sh"
    ( cd "$TEST_TMPDIR/remote" && tar -czf "$TEST_TMPDIR/remote.tar.gz" mmry-plugin-master )
    if [[ ! -e "$TEST_TMPDIR/mock-bin/curl-service" ]]; then
        mv "$TEST_TMPDIR/mock-bin/curl" "$TEST_TMPDIR/mock-bin/curl-service"
    fi
    cat > "$TEST_TMPDIR/mock-bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *marketplace.json*) printf '%s' '{"plugins":[{"name":"mmry","version":"$ver"}]}'; exit 0 ;;
    *archive/refs/heads/master.tar.gz*)
        prev=""; for a in "\$@"; do [[ "\$prev" == "-o" ]] && cp "$TEST_TMPDIR/remote.tar.gz" "\$a"; prev="\$a"; done
        exit 0 ;;
esac
exec "$TEST_TMPDIR/mock-bin/curl-service" "\$@"
EOF
    chmod +x "$TEST_TMPDIR/mock-bin/curl"
}

# The plugin folder against the release it should now be: the same paths, the same bytes. Nothing of
# MMRY's own bookkeeping (.mmry-host, .last-release-cleanup, .last-self-update) may sit beside it.
_root_vs_release() {
    local a b
    a="$( cd "$RELEASE" && find . -print | LC_ALL=C sort )"
    b="$( cd "$ROOT" && find . -print | LC_ALL=C sort )"
    [[ "$a" == "$b" ]] || diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
    diff -r "$RELEASE" "$ROOT" >/dev/null 2>&1 || diff -rq "$RELEASE" "$ROOT"
    return 0
}

# What the MCP server in the plugin folder says its version is, as Codex starts it.
_mcp_version() {
    ( cd "$ROOT" && printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
        | env -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" sh ./mcp/mmry-mcp 2>/dev/null ) \
        | tr -d '\r' | jq -r 'select(.id==1) | .result.serverInfo.version' 2>/dev/null
}

# Waits until the plugin folder holds release $1, or 60 s, then for quiet.
_wait_for_root_version() {
    local i=0
    while ! grep -qs "\"version\": *\"$1\"" "$ROOT/.claude-plugin/plugin.json" && (( i < 120 )); do
        sleep 0.5; i=$((i + 1))
    done
    _settle 60
}

@test "update: a session offered a newer verified release writes it into the plugin folder, hooks and MCP server, with the bookkeeping in the Codex home" {
    # Option (a), #33062 fix round 5: the update goes where the hooks and the MCP server run from, the
    # plugin folder, as on 2.15.5, so Codex asks for one hook review and then runs the new release.
    _offer_release 99.0.0
    _session 1 || true      # the release session's quiet-wait; _wait_for_root_version settles below
    _wait_for_root_version 99.0.0
    local d; d="$(_root_vs_release)"
    [[ -z "$d" ]] || {
        echo "the plugin folder is not the release that was offered (it is $(jq -r .version "$ROOT/.claude-plugin/plugin.json")):"
        printf '%s\n' "$d"; return 1; }
    [ "$(_mcp_version)" = "99.0.0" ] || { echo "the MCP server in the plugin folder reports [$(_mcp_version)], expected 99.0.0"; return 1; }
    grep -q '"version": *"99.0.0"' "$CX/mmry/.claude-plugin/plugin.json" \
        || { echo "the Codex home's copy was not updated: $(jq -r .version "$CX/mmry/.claude-plugin/plugin.json" 2>/dev/null)"; return 1; }
    [ "$(tr -d '\r' < "$CX/mmry/.last-self-update")" = "99.0.0" ] || { echo "no version record in the Codex home"; return 1; }
    [ "$(tr -d '\r' < "$CX/mmry/.last-release-cleanup")" = "99.0.0" ] || { echo "no cleanup record in the Codex home"; return 1; }

    # The next session's hooks run the new release from the plugin folder.
    rm -f "$TMPDIR/mmry-release-probe.log"
    : > "$TEST_TMPDIR/hooks.out"
    _session 2
    grep -q '^PROBE-99.0.0 ' "$TMPDIR/mmry-release-probe.log" 2>/dev/null \
        || { echo "the next session's hooks did not run the new release"; return 1; }
    grep -q '^PROBE-99.0.0 mcp-server' "$TMPDIR/mmry-release-probe.log" 2>/dev/null \
        || { echo "the next session's MCP server did not run the new release"; return 1; }
    grep -q 'Test Memory' "$TEST_TMPDIR/hooks.out" || { echo "no memories were delivered on the new release"; return 1; }
}

@test "update: after the release session, sessions with no further release leave the plugin folder byte-identical" {
    _offer_release 99.0.0
    _session 1 || true      # the release session's quiet-wait; _wait_for_root_version settles below
    _wait_for_root_version 99.0.0
    local d; d="$(_root_vs_release)"
    [[ -z "$d" ]] || { echo "the release session did not install the release:"; printf '%s\n' "$d"; return 1; }
    # From here the folder Codex fingerprints, once the customer has reviewed the new hooks, is this one.
    rm -rf "${REF:?}"; mkdir -p "$REF"
    ( cd "$ROOT" && tar -cf - . ) | ( cd "$REF" && tar -xf - )
    local s
    for s in 2 3; do
        _session "$s"
        d="$(_root_differences)"
        [[ -z "$d" ]] || { echo "after session $s, with no further release, the plugin folder has changed:"; printf '%s\n' "$d"; return 1; }
    done
}

@test "update: self-update.sh run from the plugin folder on Codex with no release writes nothing there" {
    rm -f "$TMPDIR/.mmry-update-checked"
    run env -u MMRY_NO_SELF_UPDATE -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" \
        bash "$ROOT/hooks-handlers/self-update.sh"
    local d; d="$(_root_differences)"
    [[ -z "$d" ]] || { echo "self-update.sh wrote into the plugin folder Codex fingerprints:"; printf '%s\n' "$d"; echo "$output"; return 1; }
}

@test "update: on Codex the Codex home's copy of self-update.sh, which Codex does not fingerprint, updates nothing" {
    # Security, QA round 2: a trusted hook must not start code from outside the folder Codex reviewed.
    _offer_release 99.0.0
    mkdir -p "$CX/mmry"
    _copy_plugin "$CX/mmry"
    local before; before="$( cd "$CX/mmry" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3 )"
    rm -f "$TMPDIR/.mmry-update-checked"
    run env -u MMRY_NO_SELF_UPDATE -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" \
        bash "$CX/mmry/hooks-handlers/self-update.sh"
    [[ "$output" == *"only the plugin folder's own copy updates"* ]] || { echo "no refusal said: $output"; return 1; }
    [ "$before" = "$( cd "$CX/mmry" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3 )" ] \
        || { echo "the Codex home's copy changed: $output"; return 1; }
    [[ -z "$(_root_differences)" ]] || { echo "the plugin folder changed: $output"; return 1; }
}

@test "update: session-init.sh on Codex starts the plugin folder's self-update.sh, not the Codex home's" {
    # self-update.sh is replaced, in the plugin folder, by one that records where it ran from.
    # session-init.sh copies the plugin folder's handlers into the Codex home too, so the record, not
    # the mere fact that it ran, tells the two copies apart.
    rm -f "$TMPDIR/.mmry-update-checked" "$TEST_TMPDIR/which-ran"
    printf '#!/usr/bin/env bash\necho "$0" >> "%s"\n' "$TEST_TMPDIR/which-ran" > "$ROOT/hooks-handlers/self-update.sh"
    run env -u MMRY_NO_SELF_UPDATE -u MMRY_CONFIG_FILE MMRY_HOST=codex HOME="$HOME" CODEX_HOME="$CX" \
        CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks-handlers/session-init.sh" --after-delivery
    cp "$REF/hooks-handlers/self-update.sh" "$ROOT/hooks-handlers/self-update.sh"
    [ -e "$TEST_TMPDIR/which-ran" ] || { echo "no self-update.sh was started: $output"; return 1; }
    grep -q '/plugins/cache/mmry-plugin/mmry/local/hooks-handlers/self-update.sh$' "$TEST_TMPDIR/which-ran" \
        || { echo "the copy started was not the plugin folder's: $(cat "$TEST_TMPDIR/which-ran")"; return 1; }
    ! grep -q '/codexhome/mmry/hooks-handlers/' "$TEST_TMPDIR/which-ran" \
        || { echo "the Codex home's copy was started: $(cat "$TEST_TMPDIR/which-ran")"; return 1; }
}

@test "req4: on Claude Code self-update.sh still keeps its once-per-version record in its own plugin folder" {
    # The control: Claude Code does not fingerprint its plugin folder, and nothing there changes.
    local croot="$HOME/.claude/plugins/cache/mmry-plugin/mmry/test"
    _copy_plugin "$croot"
    run env -u MMRY_NO_SELF_UPDATE -u MMRY_CONFIG_FILE -u MMRY_HOST -u CODEX_HOME HOME="$HOME" \
        bash "$croot/hooks-handlers/self-update.sh"
    [ -f "$croot/.last-release-cleanup" ] || { echo "Claude Code's self-update no longer records its tidy-up: $output"; return 1; }
}
