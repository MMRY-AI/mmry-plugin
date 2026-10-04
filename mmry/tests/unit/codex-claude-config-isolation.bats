#!/usr/bin/env bats
# =============================================================================================
# TC6 (#31245): A CODEX INSTALL NEVER READS ~/.claude/mmry-config.json.
#
# That file is the OTHER product's credential. Two discovery chains used to end in it, with no
# regard for which host was asking:
#
#   mmry-client.sh         mmry_load_config: MMRY_CONFIG_FILE, then the plugin root, then ~/.claude
#   lib-foundation-switch  _mmry_reinject_is_off_here: the same three, for the Foundation off switch
#
# On Codex, lib-host.sh points MMRY_CONFIG_FILE at the Codex home and refuses outright when that
# file is missing. But two doors stay open past that refusal, by design: MMRY_ALLOW_NO_CREDENTIAL=1
# (mmry-setup.sh, which runs BEFORE a Codex credential exists) and a key supplied in the
# environment. Through either, the missing Codex file fell through to the Claude one, and Codex
# setup on a machine that also runs Claude Code could pick up the Claude account's key.
#
# THE ORACLE. The Claude file planted here carries values that cannot come from anywhere else: a
# sentinel key, an .invalid URL, foundationReinject "false" against a default of "true", and a
# refresh interval of 4242. If any of them appears, the file was read. Every refusal below has a
# CONTROL beside it, run on Claude Code with the same file, that proves the oracle does see a read
# when one happens; a refusal with no control could be passing because nothing looks.
# =============================================================================================

load '../helpers/test-helper'

CODEX_DIR=""

setup() {
    unset MMRY_HOST MMRY_CONFIG_FILE MMRY_API_KEY MMRY_API_URL MMRY_AUTH_METHOD \
          MMRY_FOUNDATION_REINJECT MMRY_FOUNDATION_REFRESH_SECONDS MMRY_ALLOW_NO_CREDENTIAL \
          CODEX_HOME _MMRY_HOST_DIR_FROM_MARKER || true
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude"
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$CODEX_DIR"
    # Not a real credential: a fake key that exists only so its presence can be detected.
    printf '%s' '{"apiUrl":"https://claude-file.invalid","apiKey":"CLAUDE-FILE-SENTINEL","authMethod":"apikey","foundationReinject":"false","foundationRefreshSeconds":4242}' \
        > "$HOME/.claude/mmry-config.json"
    rm -f "$PLUGIN_ROOT/mmry-config.json"
}

teardown() {
    rm -f "$PLUGIN_ROOT/mmry-config.json"
}

# Source the client in a child shell under the given environment and print what it loaded,
# as KEY=<sentinel or not> rather than the key itself.
_client_loaded() {
    env "$@" bash -c '
        source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1 || { echo "SOURCE-REFUSED"; exit 0; }
        k=other; [[ "${MMRY_API_KEY:-}" == "CLAUDE-FILE-SENTINEL" ]] && k=SENTINEL
        [[ -z "${MMRY_API_KEY:-}" ]] && k=empty
        printf "key=%s url=%s reinject=%s refresh=%s\n" "$k" "${MMRY_API_URL:-}" \
            "${MMRY_FOUNDATION_REINJECT:-}" "${MMRY_FOUNDATION_REFRESH_SECONDS:-}"
    ' _ "$PLUGIN_ROOT"
}

# Ask the Foundation off switch, in a child shell, whether re-injection is off and what it read.
_switch_says() {
    env "$@" bash -c '
        source "$1/hooks-handlers/lib-foundation-switch.sh" >/dev/null 2>&1 || { echo "SOURCE-FAILED"; exit 0; }
        if _mmry_reinject_is_off_here; then r=off; else r=not-off; fi
        printf "%s matched=%s\n" "$r" "${MMRY_REINJECT_MATCHED_VALUE:-}"
    ' _ "$PLUGIN_ROOT"
}

_no_claude_value() {
    [[ "$output" != *SENTINEL* ]] || { echo "the Claude key was loaded: $output"; return 1; }
    [[ "$output" != *claude-file.invalid* ]] || { echo "the Claude URL was loaded: $output"; return 1; }
    [[ "$output" != *"reinject=false"* ]] || { echo "the Claude off switch was read: $output"; return 1; }
    [[ "$output" != *"refresh=4242"* ]] || { echo "the Claude refresh interval was read: $output"; return 1; }
}

# --- the config loader -----------------------------------------------------------------------

@test "TC6 control: on Claude Code the fallback file IS read, so the oracle can see a read" {
    run _client_loaded HOME="$HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"key=SENTINEL"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"refresh=4242"* ]] || { echo "$output"; return 1; }
}

@test "TC6: Codex setup, before a Codex credential exists, does not load the Claude account" {
    # MMRY_ALLOW_NO_CREDENTIAL=1 is how mmry-setup.sh gets past the refusal. This is the leak that
    # mattered: setup is the first thing a new Codex customer runs.
    run _client_loaded HOME="$HOME" MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_ALLOW_NO_CREDENTIAL=1
    [ "$status" -eq 0 ]
    [[ "$output" != SOURCE-REFUSED ]] || { echo "the opt-out stopped working, so this checked nothing"; return 1; }
    [[ "$output" == *"key=empty"* ]] || { echo "$output"; return 1; }
    _no_claude_value
}

@test "TC6: a Codex credential given in the ENVIRONMENT takes nothing else from the Claude file" {
    run _client_loaded HOME="$HOME" MMRY_HOST=codex CODEX_HOME="$CODEX_DIR" MMRY_API_KEY=env-key
    [ "$status" -eq 0 ]
    [[ "$output" == *"key=other"* ]] || { echo "$output"; return 1; }
    _no_claude_value
}

@test "TC6: a command the model runs, with no MMRY_HOST in its environment, is guarded too" {
    # A command the model runs from the skill carries no MMRY_HOST; lib-host.sh resolves Codex
    # from the .mmry-host marker session-init writes, and sets MMRY_HOST in the shell as it does.
    # This is the route a guard on the inherited environment alone would have missed.
    local root="$TEST_TMPDIR/staged"
    mkdir -p "$root/mmry/hooks-handlers"
    cp "$PLUGIN_ROOT"/hooks-handlers/*.sh "$root/mmry/hooks-handlers/"
    printf 'codex\n' > "$root/mmry/.mmry-host"
    run env -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT HOME="$HOME" CODEX_HOME="$root" MMRY_ALLOW_NO_CREDENTIAL=1 bash -c '
        source "$1/mmry/hooks-handlers/mmry-client.sh" >/dev/null 2>&1 || { echo SOURCE-REFUSED; exit 0; }
        printf "host=%s " "$(mmry_host)"
        k=other; [[ "${MMRY_API_KEY:-}" == "CLAUDE-FILE-SENTINEL" ]] && k=SENTINEL
        [[ -z "${MMRY_API_KEY:-}" ]] && k=empty
        printf "key=%s url=%s reinject=%s refresh=%s\n" "$k" "${MMRY_API_URL:-}" \
            "${MMRY_FOUNDATION_REINJECT:-}" "${MMRY_FOUNDATION_REFRESH_SECONDS:-}"
    ' _ "$root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"host=codex"* ]] || { echo "the staged copy did not resolve as Codex, so this checked nothing: $output"; return 1; }
    _no_claude_value
}

# --- the Foundation off switch ---------------------------------------------------------------

@test "TC6 control: on Claude Code the off switch reads the fallback file" {
    run _switch_says HOME="$HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == "off matched=false" ]] || { echo "$output"; return 1; }
}

@test "TC6: on Codex the off switch does not read the Claude file" {
    run _switch_says HOME="$HOME" MMRY_HOST=codex MMRY_CONFIG_FILE="$CODEX_DIR/mmry-config.json"
    [ "$status" -eq 0 ]
    [[ "$output" == "not-off matched=" ]] || { echo "$output"; return 1; }
}

@test "TC6: and the Codex install's OWN off switch is still honoured" {
    # The guard closes one door, not the switch.
    printf '%s' '{"apiKey":"k","foundationReinject":"off"}' > "$CODEX_DIR/mmry-config.json"
    run _switch_says HOME="$HOME" MMRY_HOST=codex MMRY_CONFIG_FILE="$CODEX_DIR/mmry-config.json"
    [ "$status" -eq 0 ]
    [[ "$output" == "off matched=off" ]] || { echo "$output"; return 1; }
}

# --- every mention of the Claude credential, in every shipped file (#31245 QA #1 delta) ----------
#
# The first version of this check scanned hooks-handlers/*.sh for one spelling of a file test and
# caught 3 of the 11 spellings QA's Security reviewer tried. It now reads every file an install
# ships (hooks-handlers and setup; .sh .cmd .bat .ps1), finds every line that names the Claude
# credential file in any spelling (either slash, through CLAUDE_DIR, any HOME form), and requires
# each to be one of three things:
#   GUARDED  a read in a branch that has asked _mmry_claude_config_fallback_ok, which is false on
#            Codex (the guarding line itself, or the assignment directly under it);
#   DISPLAY  a fallback display string, a single-quoted literal assigned to a name, which is text
#            for Claude Code's customer and never opened;
#   CLAUDE   a Claude Code installer or uninstaller. The uninstallers refuse on Codex (their own
#            tests), and since QA item 4 the installers are not put in a Codex home at all.
# Anything else fails, which is how a new reading of the other product's file gets caught.

_CLAUDE_CRED='\.claude[/\\]+mmry-config\.json|CLAUDE_DIR\}?/mmry-config\.json'

# Prints "<lineno>\t<code line>\t<previous code line>" for each mention in a file.
_claude_cred_mentions() {
    RE="$_CLAUDE_CRED" awk '
        { sub(/\r$/, ""); t = $0; sub(/^[ \t]+/, "", t) }
        t == "" || t ~ /^#/ || t ~ /^(rem|REM|::)/ { next }
        $0 ~ ENVIRON["RE"] { printf "%d\t%s\t%s\n", NR, t, prev }
        { prev = t }
    ' "$1"
}

_classify() {
    local base="$1" code="$2" prev="$3"
    [[ "$code" == *_mmry_claude_config_fallback_ok* ]] && { printf GUARDED; return 0; }
    if [[ "$prev" == *_mmry_claude_config_fallback_ok* && "$code" =~ ^[A-Za-z_]+= ]]; then printf GUARDED; return 0; fi
    if [[ "$code" =~ ^_?[A-Za-z_]+=\'~/\.claude/mmry-config\.json\'$ ]]; then printf DISPLAY; return 0; fi
    case "$base" in
        install.sh|install.ps1|install.bat|uninstall.sh|uninstall.bat) printf CLAUDE; return 0 ;;
    esac
    return 1
}

@test "TC6: every shipped mention of the Claude credential is a guarded read, a display string, or Claude Code's own" {
    local f base n=0 bad="" lineno code prev kind
    for f in "$PLUGIN_ROOT"/hooks-handlers/*.sh "$PLUGIN_ROOT"/hooks-handlers/*.cmd \
             "$PLUGIN_ROOT"/setup/*.sh "$PLUGIN_ROOT"/setup/*.bat "$PLUGIN_ROOT"/setup/*.ps1; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        while IFS=$'\t' read -r lineno code prev; do
            [[ -n "$lineno" ]] || continue
            n=$((n + 1))
            if kind="$(_classify "$base" "$code" "$prev")"; then
                echo "  $kind  $base:$lineno" >&3
            else
                bad="${bad}${base}:${lineno}: ${code}"$'\n'
            fi
        done < <(_claude_cred_mentions "$f")
    done
    echo "mentions found: $n" >&3
    # SAMPLE SIZE: the two guarded chains alone are four lines. Fewer means the scan stopped seeing.
    (( n >= 5 )) || { echo "only $n mentions found; the scan is not seeing the files"; return 1; }
    [[ -z "$bad" ]] || { echo "mentions of the Claude credential that are none of the three:"; printf '%s' "$bad"; return 1; }
}

@test "control: the scan finds every spelling QA tried, and refuses an unguarded one" {
    local probe="$BATS_TEST_TMPDIR/probe.sh"
    cat > "$probe" <<'EOF'
a="${HOME}/.claude/mmry-config.json"
b="$HOME/.claude/mmry-config.json"
c=~/.claude/mmry-config.json
d="${HOME:-}/.claude/mmry-config.json"
e='.claude\mmry-config.json'
f="$CLAUDE_DIR/mmry-config.json"
g="${CLAUDE_DIR}/mmry-config.json"
cat ~/.claude//mmry-config.json
h="$(mmry_home)/.claude/mmry-config.json"
$p = Join-Path $env:USERPROFILE '.claude\mmry-config.json'
set "P=%USERPROFILE%\.claude\mmry-config.json"
# a comment naming ~/.claude/mmry-config.json is not a use
EOF
    local found; found="$(_claude_cred_mentions "$probe" | wc -l | tr -d ' ')"
    [ "$found" -eq 11 ] || { echo "found $found of 11"; _claude_cred_mentions "$probe"; return 1; }
    # And an unguarded read in an ordinary handler is refused.
    run _classify "save-memory.sh" 'if [[ -f "$HOME/.claude/mmry-config.json" ]]; then' 'x=1'
    [ "$status" -ne 0 ]
}
