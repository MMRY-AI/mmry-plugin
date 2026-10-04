#!/usr/bin/env bats
# =============================================================================================
# #31245 QA #1 delta, items 2 to 4 (formation 33, 2026-10-04): what an install leaves in the Codex
# home, how a copy of the handlers knows it is on Codex, and the order the Foundation hook asks.
#
#   2. The .mmry-host marker is written into the plugin root too. lib-host.sh finds the marker
#      beside the running copy, and took the home to be two levels up, which is right for the state
#      directory and wrong for Codex's plugin cache. So the plugin-root marker names the home on a
#      second line, believed only when the running script is inside it.
#   3. The Foundation hook asks its off switch AFTER lib-host.sh has settled the host.
#   4. The Claude Code installers are not copied into the Codex home.
#
# The relocated home here has no ".codex" in its path on purpose: that would let lib-host.sh's
# path guess answer for the marker, and these tests would prove nothing about the marker.
# =============================================================================================

load '../helpers/test-helper'

CX=""

setup() {
    setup_mock_curl 2>/dev/null || true
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE || true
    CX="$TEST_TMPDIR/cxhome"
    mkdir -p "$CX"
}

load '../helpers/mock-config'

# A plugin root, at $1, that is a faithful copy except that session-init's delegate is a probe.
_plugin_at() {
    local root="$1"
    mkdir -p "$root/hooks-handlers" "$root/setup"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/hooks-handlers/"
    cp "$PLUGIN_ROOT"/setup/*.sh "$PLUGIN_ROOT"/setup/*.bat "$PLUGIN_ROOT"/setup/*.ps1 "$root/setup/" 2>/dev/null || true
    printf '#!/usr/bin/env bash\necho "DELEGATE RAN"\n' > "$root/hooks-handlers/session-start.sh"
    printf '%s' "$root"
}

_host_of() {
    # Source the copy at $1 with nothing exported that could answer for it; print host and home.
    env -u MMRY_HOST -u CODEX_HOME -u _MMRY_HOST_DIR_FROM_MARKER HOME="$HOME" bash -c '
        source "$1/hooks-handlers/lib-host.sh" >/dev/null 2>&1 || { echo REFUSED; exit 0; }
        printf "%s|%s\n" "$(mmry_host)" "$(mmry_host_config_dir)"' _ "$1"
}

# --- 4. the Claude Code installers ------------------------------------------------------------

@test "qa4: session-init on Codex puts no Claude Code installer in the Codex home, and removes old ones" {
    local root; root="$(_plugin_at "$TEST_TMPDIR/plugin")"
    [ -f "$root/setup/install.sh" ] || { echo "the fixture has no install.sh, so this checks nothing"; return 1; }
    mkdir -p "$CX/mmry/setup"
    : > "$CX/mmry/setup/install.sh"     # left by an earlier version
    run env MMRY_HOST=codex CODEX_HOME="$CX" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$CX/mmry/setup/mmry-setup.sh" ] || { echo "setup itself was not installed"; return 1; }
    [ -f "$CX/mmry/setup/uninstall.sh" ] || { echo "the uninstaller (which refuses on Codex) was dropped"; return 1; }
    local f
    for f in install.sh install.ps1 install.bat; do
        [ ! -e "$CX/mmry/setup/$f" ] || { echo "$f is in the Codex home"; return 1; }
    done
}

@test "qa4: req4 - Claude Code still gets its installers" {
    local root; root="$(_plugin_at "$TEST_TMPDIR/plugin")"
    run env -u MMRY_HOST -u CODEX_HOME HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$HOME/.claude/mmry/setup/install.sh" ]
}

# --- 2. the marker in the plugin root -----------------------------------------------------------

@test "qa2: session-init marks a plugin root inside the Codex home, naming the home" {
    local root; root="$(_plugin_at "$CX/plugins/cache/mmry-plugin/mmry")"
    run env MMRY_HOST=codex CODEX_HOME="$CX" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$root/.mmry-host" ] || { echo "no marker in the plugin root"; return 1; }
    local host home
    { read -r host; read -r home; } < "$root/.mmry-host"
    [ "$host" = "codex" ] || { echo "marker reads [$host]"; return 1; }
    [ "$home" = "$CX" ] || { echo "marker names [$home], expected [$CX]"; return 1; }
}

@test "qa2: a plugin root outside the Codex home is never marked" {
    local root; root="$(_plugin_at "$TEST_TMPDIR/elsewhere/plugin")"
    run env MMRY_HOST=codex CODEX_HOME="$CX" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$root/.mmry-host" ]
}

@test "qa2: a plugin-cache copy with CODEX_HOME unset now knows it is Codex, and where its home is" {
    local root; root="$(_plugin_at "$CX/plugins/cache/mmry-plugin/mmry")"
    env MMRY_HOST=codex CODEX_HOME="$CX" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$root" \
        bash "$root/hooks-handlers/session-init.sh" >/dev/null 2>&1
    run _host_of "$root"
    [ "$output" = "codex|$CX" ] || { echo "resolved [$output], expected [codex|$CX]"; return 1; }

    # CONTROL: the marker is what did it. Without it the same copy resolves as Claude.
    rm -f "$root/.mmry-host"
    run _host_of "$root"
    [[ "$output" == claude\|* ]] || { echo "without the marker it still resolved [$output], so the test above proves nothing"; return 1; }
}

@test "qa2: a marker naming a home the script is not inside is not believed" {
    local root; root="$(_plugin_at "$CX/plugins/cache/mmry-plugin/mmry")"
    mkdir -p "$TEST_TMPDIR/not-the-home"
    printf 'codex\n%s\n' "$TEST_TMPDIR/not-the-home" > "$root/.mmry-host"
    run _host_of "$root"
    [[ "$output" == codex\|* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"not-the-home"* ]] || { echo "believed a home the script is not in: $output"; return 1; }
}

@test "qa2: req4 - a one-line state-directory marker resolves exactly as before" {
    local state="$CX/mmry"
    mkdir -p "$state/hooks-handlers"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$state/hooks-handlers/"
    printf 'codex\n' > "$state/.mmry-host"
    run env -u MMRY_HOST -u CODEX_HOME -u _MMRY_HOST_DIR_FROM_MARKER HOME="$HOME" bash -c '
        source "$1/hooks-handlers/lib-host.sh" >/dev/null 2>&1
        printf "%s|%s\n" "$(mmry_host)" "$(mmry_host_config_dir)"' _ "$state"
    [ "$output" = "codex|$CX" ] || { echo "$output"; return 1; }
}

# --- 3. the off switch, after the host is known -------------------------------------------------

@test "qa3: the Foundation hook loads lib-host.sh before it asks the off switch, and both before the worker" {
    local f="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" host off worker
    host="$(grep -n 'source "${PLUGIN_ROOT}/hooks-handlers/lib-host.sh"' "$f" | head -1 | cut -d: -f1)"
    off="$(grep -n '^    if _mmry_reinject_is_off_here; then' "$f" | head -1 | cut -d: -f1)"
    worker="$(grep -n '^ *MMRY_FOUNDATION_WORKER=1 ' "$f" | head -1 | cut -d: -f1)"
    [[ "$host" =~ ^[0-9]+$ && "$off" =~ ^[0-9]+$ && "$worker" =~ ^[0-9]+$ ]] || { echo "host=$host off=$off worker=$worker"; return 1; }
    (( host < off )) || { echo "the off switch (line $off) is asked before lib-host.sh (line $host)"; return 1; }
    (( off < worker ))
}

@test "qa3: a copy run without MMRY_HOST keeps Codex's Foundation even when Claude's config turns it off" {
    # The latent case QA named: safe on every shipped path because codex-hook.sh exports MMRY_HOST,
    # unsafe by order when it is not. Claude Code's file says foundationReinject false; the Codex
    # credential says nothing, so re-injection is on. Asked before the host was known, the off
    # switch read Claude's file and silenced the Codex customer's directives.
    local state="$CX/mmry"
    mkdir -p "$state/hooks-handlers" "$HOME/.claude"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$state/hooks-handlers/"
    printf 'codex\n' > "$state/.mmry-host"
    printf '%s' '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"k","foundationRefreshSeconds":0}' > "$CX/mmry-config.json"
    printf '%s' '{"apiKey":"claude-k","foundationReinject":"false"}' > "$HOME/.claude/mmry-config.json"
    local cache="$TEST_TMPDIR/mmry-foundation.md" s b n
    printf -- '- Identity: Eric builds MMRY.\n' > "$cache"
    read -r s b < <(cksum < "$cache")
    printf 'mmry-foundation v1 entries=1 bytes=%s cksum=%s\n' "$b" "$s" > "${cache}.manifest"
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"

    run env -u MMRY_HOST -u CODEX_HOME -u MMRY_CONFIG_FILE -u CLAUDE_PLUGIN_ROOT HOME="$HOME" \
        bash "$state/hooks-handlers/userpromptsubmit-foundation.sh" < /dev/null
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Eric builds MMRY"* ]] || { echo "the Foundation was silenced: [$output]"; return 1; }
}
