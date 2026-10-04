#!/usr/bin/env bats
# =============================================================================================
# SETUP THAT CANNOT REACH MMRY AI SAYS SO (#31245, Mac live run 2026-10-04).
#
# Asked to run setup inside the Codex desktop app, whose default sandbox has no network, the
# script printed "Requesting authorization..." and exited 6 with nothing else. The cause is in the
# script: it runs under set -euo pipefail, and `VAR=$(curl ...)` ends the script with curl's own
# status the moment curl cannot connect, before the HTTP checks that would have explained it.
# Reproduced on Windows against an unresolvable host, and identical on released master.
#
# Every request setup makes now names the failure, says what to do (run the same command in a
# terminal, where no assistant sandbox applies), exits 1 like every other setup error, and writes
# nothing. The stand-in curl below is what a sandbox with no network gives: http_code 000 and a
# non-zero exit status.
# =============================================================================================

load '../helpers/test-helper'

BIN=""

setup() {
    export MMRY_NO_BROWSER=1
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    export MMRY_JQ_VENDOR_DIR="$PLUGIN_ROOT/vendor/jq"
    unset MMRY_HOST CODEX_HOME MMRY_CONFIG_FILE || true
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
    chmod +x "$BIN/sleep"
}

# A curl that reaches nothing. $1 is the exit status it returns (6: could not resolve host).
_no_network() {
    printf '#!/usr/bin/env bash\nprintf 000\nexit %s\n' "${1:-6}" > "$BIN/curl"
    chmod +x "$BIN/curl"
}

_setup() { env PATH="$BIN:$PATH" bash "$PLUGIN_ROOT/setup/mmry-setup.sh" "$@"; }

@test "unreachable: Codex setup names the failure, says what to do, exits 1, and writes nothing" {
    _no_network 6
    local codex="$TEST_TMPDIR/codexhome"
    mkdir -p "$codex"
    run env CODEX_HOME="$codex" PATH="$BIN:$PATH" bash "$PLUGIN_ROOT/setup/mmry-setup.sh" --host codex
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"could not reach MMRY AI"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"could not be resolved"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"terminal"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"bash ${codex}/mmry/setup/mmry-setup.sh"* ]] || { echo "$output"; return 1; }
    [ ! -e "$codex/mmry-config.json" ]
}

@test "unreachable: and the same on Claude Code" {
    _no_network 6
    run _setup --host claude
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"could not reach MMRY AI"* ]] || { echo "$output"; return 1; }
    [ ! -e "$HOME/.claude/mmry-config.json" ]
}

@test "unreachable: the email and password sign-in says so too" {
    _no_network 6
    run _setup --host claude --email a@example.com --password 'Secret-1!'
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"could not reach MMRY AI"* ]] || { echo "$output"; return 1; }
    [ ! -e "$HOME/.claude/mmry-config.json" ]
}

@test "unreachable: a refused connection and a timeout are named for what they are" {
    _no_network 7
    run _setup --host claude
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"refused"* ]] || { echo "$output"; return 1; }
    _no_network 28
    run _setup --host claude
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"timed out"* ]] || { echo "$output"; return 1; }
}

@test "unreachable: a real unresolvable host, with the real curl" {
    command -v curl >/dev/null 2>&1 || skip "no curl"
    local codex="$TEST_TMPDIR/codexhome"
    mkdir -p "$codex"
    run env CODEX_HOME="$codex" PATH="$BIN:$PATH" bash "$PLUGIN_ROOT/setup/mmry-setup.sh" \
        --host codex --api-url https://no-such-host.invalid
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"could not reach MMRY AI at https://no-such-host.invalid"* ]] || { echo "$output"; return 1; }
    [ ! -e "$codex/mmry-config.json" ]
}

@test "unreachable: losing the network while waiting for the browser sign-in is reported, after two retries" {
    # The authorization request succeeds; every status poll after it reaches nothing.
    cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w|-X|-H|-d|--connect-timeout|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
if [[ "$url" == */status ]]; then
    echo poll >> "$(dirname "$0")/polls"
    printf 000; exit 6
fi
printf '{"deviceCode":"dc","verificationUrl":"https://example.invalid/authorize","expiresIn":600,"interval":1}' > "$out"
printf 200
EOF
    chmod +x "$BIN/curl"
    run _setup --host claude
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"while waiting for you to authorize in the browser"* ]] || { echo "$output"; return 1; }
    [ "$(wc -l < "$BIN/polls" | tr -d ' ')" -eq 3 ] || { echo "polled $(cat "$BIN/polls" | wc -l) times"; return 1; }
    [ ! -e "$HOME/.claude/mmry-config.json" ]
}
