#!/usr/bin/env bats
# The message check before each prompt starts fewer processes, and still delivers exactly as before
# (#31976).
#
# Measured on a loaded Windows machine, the check's time went on starting processes, 0.35 to 1.6 s
# each, not on any work inside them. #31976 removed the ones that need not be processes. The timing
# itself is a Windows measurement recorded on the task (docs/evidence/31976), because a wall-clock bar
# in a suite cannot tell healthy from broken on a loaded runner. What is held here is what the time
# was spent on:
#   - hook-guard.sh runs formation-check.sh in its own shell, and every other handler as before;
#   - a delivering check proves its jq by using it, not by asking `jq --version` first, with a jq on
#     PATH and with only the bundle;
#   - a jq that does not answer still falls back to the old resolution, and the check still delivers;
#   - the bundled jq is named without a process, and the name is the one `uname` gives.
# Delivery itself (printed once, marked after printing, never twice) is held by
# formation-check-timeout.bats and formation-delivery.bats, which run against the same handler.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export CLAUDE_SESSION_ID="bats-31976-$$"
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID MMRY_HOST MMRY_JQ MMRY_FORMATION_MODE CLAUDE_PLUGIN_ROOT
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
    rm -rf "${TMPDIR}/.mmry-formation-cs-${CLAUDE_SESSION_ID}"
    BODY='[{"senderRole":"lead","senderSessionID":"lead-1","senderUserID":1,"content":"PB-MSG review the claim","sentDate":"2026-10-10T01:00:00"}]'
    W="${BATS_TEST_TMPDIR}/pb"
    rm -rf "$W"; mkdir -p "$W/bin"
    REAL_JQ="$(bash -c "source '${HANDLERS}/lib-jq.sh' >/dev/null 2>&1; mmry_resolve_jq >/dev/null 2>&1; printf '%s' \"\$MMRY_JQ\"")"
    [[ "$REAL_JQ" == "jq" ]] && REAL_JQ="$(command -v jq)"
    # A curl that answers with BODY through -o, as the real one does, and logs the URL.
    cat > "$W/bin/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) printf '%s\n' "$arg" >> "${PB_DIR}/curl.log" ;; esac
    prev="$arg"
done
[[ -n "$out" ]] && printf '%s' "$PB_BODY" > "$out"
printf '200'
FAKECURL
    # A jq that logs its arguments' first word and runs the real one.
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${1:-}" >> "%s/jq.log"\nexec "%s" "$@"\n' "$W" "$REAL_JQ" > "$W/logjq"
    chmod +x "$W/bin/curl" "$W/logjq"
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$CLAUDE_SESSION_ID" || true
}

# Run the check as the UserPromptSubmit hook does: payload on stdin, no test mode.
_fire() {
    local payload
    payload="{\"session_id\":\"${CLAUDE_SESSION_ID}\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$CLAUDE_SESSION_ID"
    printf '%s' "$payload" | env PB_DIR="$W" PB_BODY="$BODY" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        "$@" bash "${HANDLERS}/formation-check.sh" 2>"$W/err"
}

@test "hook-guard: formation-check runs in the guard's own shell, with no arguments, and keeps its exit code" {
    local hd="${BATS_TEST_TMPDIR}/home/.claude/mmry/hooks-handlers"
    mkdir -p "$hd"
    cp "${HANDLERS}/hook-guard.sh" "${HANDLERS}/lib-host.sh" "$hd/"
    printf 'echo "guard=${SCRIPT_NAME:-none} args=$#"\nexit 2\n' > "$hd/formation-check.sh"
    printf 'echo "guard=${SCRIPT_NAME:-none} args=$#"\nexit 0\n' > "$hd/stop-check.sh"

    run env HOME="${BATS_TEST_TMPDIR}/home" bash "$hd/hook-guard.sh" formation-check
    [ "$status" -eq 2 ] || { echo "exit code not kept: $status"; return 1; }
    [[ "$output" == "guard=formation-check args=0" ]] || { echo "not run in the guard's shell: $output"; return 1; }

    # Every other handler is still a new bash, which cannot see the guard's variables.
    run env HOME="${BATS_TEST_TMPDIR}/home" bash "$hd/hook-guard.sh" stop-check
    [ "$status" -eq 0 ]
    [[ "$output" == "guard=none args=0" ]] || { echo "stop-check was not run as before: $output"; return 1; }
}

@test "hook-guard: a formation-check that is not beside the guard is run as a new bash, as before" {
    local hd="${BATS_TEST_TMPDIR}/home/.claude/mmry/hooks-handlers" other="${BATS_TEST_TMPDIR}/elsewhere"
    mkdir -p "$hd" "$other"
    cp "${HANDLERS}/hook-guard.sh" "${HANDLERS}/lib-host.sh" "$other/"
    printf 'echo "guard=${SCRIPT_NAME:-none}"\n' > "$hd/formation-check.sh"
    run env HOME="${BATS_TEST_TMPDIR}/home" bash "$other/hook-guard.sh" formation-check
    [[ "$output" == "guard=none" ]] || { echo "ran another copy's handler in this shell: $output"; return 1; }
}

@test "jq: a delivering prompt check with a jq on PATH never asks jq --version" {
    ln -s "$W/logjq" "$W/bin/jq" 2>/dev/null || cp "$W/logjq" "$W/bin/jq"
    run _fire PATH="$W/bin:$PATH"
    [[ "$output" == *PB-MSG* ]] || { echo "did not deliver: $output $(cat "$W/err")"; return 1; }
    [ -s "$W/jq.log" ] || { echo "the logging jq on PATH was not the one used"; return 1; }
    run grep -c -- '--version' "$W/jq.log"
    [ "$output" = "0" ] || { echo "asked jq --version:"; cat "$W/jq.log"; return 1; }
}

@test "jq: a delivering prompt check with only the bundled jq never asks jq --version" {
    # No jq on PATH, through lib-jq.sh's own seam (removing jq's directory from PATH would remove
    # bash with it on a Linux runner). The bundle as the handler looks for it, vendor/jq/<name>, the
    # name forced to one that needs no .exe so the logging wrapper can stand in for it on every host.
    mkdir -p "$W/vendor"
    cp "$W/logjq" "$W/vendor/jq-linux-amd64"; chmod +x "$W/vendor/jq-linux-amd64"
    run _fire PATH="$W/bin:$PATH" MMRY_JQ_SKIP_SYSTEM=1 MMRY_JQ_VENDOR_DIR="$W/vendor" MMRY_UNAME_S=Linux MMRY_UNAME_M=x86_64
    [[ "$output" == *PB-MSG* ]] || { echo "did not deliver: $output $(cat "$W/err")"; return 1; }
    [ -s "$W/jq.log" ] || { echo "the bundle was not the jq used"; return 1; }
    run grep -c -- '--version' "$W/jq.log"
    [ "$output" = "0" ] || { echo "asked jq --version:"; cat "$W/jq.log"; return 1; }
}

@test "jq: a jq that does not run falls back to the old resolution, and the check still delivers" {
    printf '#!/usr/bin/env bash\nexit 127\n' > "$W/broken-jq"; chmod +x "$W/broken-jq"
    ln -s "$W/logjq" "$W/bin/jq" 2>/dev/null || cp "$W/logjq" "$W/bin/jq"
    run _fire PATH="$W/bin:$PATH" MMRY_JQ="$W/broken-jq"
    [[ "$output" == *PB-MSG* ]] || { echo "a broken jq silenced delivery: $output $(cat "$W/err")"; return 1; }
    # The fallback is mmry_resolve_jq, which proves the jq it settles on by asking its version.
    grep -q -- '--version' "$W/jq.log" || { echo "the fallback did not run"; cat "$W/jq.log"; return 1; }
}

@test "jq: the bundle is named without a process, and the name is the one uname gives" {
    local out
    out="$(bash -c '
        source "$1/lib-jq.sh" >/dev/null 2>&1
        unset MMRY_JQ MMRY_UNAME_S MMRY_UNAME_M CLAUDE_PLUGIN_ROOT
        want="$(_mmry_jq_bundle_name)"
        [ -n "$want" ] || { echo "unsupported-host"; exit 0; }
        mkdir -p "$2/v"; : > "$2/v/$want"; chmod +x "$2/v/$want"
        MMRY_JQ_VENDOR_DIR="$2/v"; MMRY_JQ_SKIP_SYSTEM=1
        saved="$PATH"; PATH=""
        mmry_jq_candidate
        PATH="$saved"
        [ "$_MMRY_JQ_CANDIDATE" = "$2/v/$want" ] && echo "same:$want" || echo "differs: uname=$want candidate=$_MMRY_JQ_CANDIDATE"
    ' _ "$HANDLERS" "$W")"
    [[ "$out" == unsupported-host ]] && skip "no bundled jq for this host"
    [[ "$out" == same:* ]] || { echo "$out"; return 1; }
}
