#!/usr/bin/env bats
# formation-upgrade-refusal.bats - an account without the Formation upgrade (#34285, DD-199 in the
# API repository).
#
# The service answers every /api/formations route for such an account with HTTP 403, the code
# formation_upgrade_required and one approved sentence. Every Formation command, on Claude Code and on
# Codex, must print that sentence once and nothing else about the failure, clear this session's local
# Formation membership and stop; the idle watch and every hook must stop asking: no retry, no further
# request, so nothing more is spent on Formation. Any other 403 is not the upgrade refusal and changes
# nothing locally.
#
# The network is a fake curl: every /api/formations request answers FAKE_FORM_CODE (403) with
# FAKE_FORM_BODY, /api/sessions answers 201, and every URL asked is logged.

load '../helpers/test-helper'

SENTENCE='Formation is an upgrade this account does not have yet, and an account administrator can add it on the account page at mmryai.com/account.'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    mkdir -p "$BIN"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; method="GET"; url=""; prev=""
for arg in "$@"; do
    case "$prev" in -o) out="$arg" ;; -X) method="$arg" ;; esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s %s\n' "$method" "$url" >> "$FAKE_URL_LOG"
code=200; resp='{}'
case "$url" in
    */api/sessions*) code=201; resp='' ;;
    */api/formations*) code="${FAKE_FORM_CODE:-403}"; resp="$FAKE_FORM_BODY" ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID MMRY_FORMATION_MODE
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    export TMPDIR="$TEST_TMPDIR"
    SID="aaaa4444-upgrade-$$"
    export CLAUDE_CODE_SESSION_ID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    URLS="$TEST_TMPDIR/urls.log"; : > "$URLS"
    export FAKE_URL_LOG="$URLS"
    export FAKE_FORM_CODE=403
    export FAKE_FORM_BODY='{"error":"Formation is an upgrade this account does not have yet, and an account administrator can add it on the account page at mmryai.com/account.","detail":null,"code":"formation_upgrade_required"}'
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_state() { bash "$HH/formation-state.sh" get "$SID"; }
_member() { bash "$HH/formation-state.sh" set 40 "$SID" >/dev/null; [ -n "$(_state)" ]; }
_formation_requests() { grep -c '/api/formations' "$URLS" 2>/dev/null || true; }
_count() { local hay="$1" needle="$2"; local rest="$hay" n=0; while [[ "$rest" == *"$needle"* ]]; do n=$((n+1)); rest="${rest#*"$needle"}"; done; printf '%s' "$n"; }

# The sentence once, no HTTP status, no other failure text, nothing local, one request.
_refused_once() {
    local label="$1"
    [ "$(_count "$output" "$SENTENCE")" -eq 1 ] || { echo "$label: sentence printed $(_count "$output" "$SENTENCE") times: $output"; return 1; }
    [[ "$output" != *"HTTP 403"* && "$output" != *"(HTTP"* ]] || { echo "$label: an HTTP status was printed: $output"; return 1; }
    [[ "$output" != *"formation_upgrade_required"* && "$output" != *'"error"'* ]] || { echo "$label: the raw body was printed: $output"; return 1; }
    [ -z "$(_state)" ] || { echo "$label: local membership kept: $(_state)"; return 1; }
    [ "$(_formation_requests)" -le 1 ] || { echo "$label: retried, $(_formation_requests) Formation requests: $(cat "$URLS")"; return 1; }
}

@test "U-01 start: the sentence once, nothing local, no retry" {
    run bash "$HH/formation-start.sh" "the next job for the formation"
    [ "$status" -ne 0 ]
    _refused_once start
}

@test "U-02 join: the sentence once, nothing local, no retry" {
    run bash "$HH/formation-join.sh" 40
    [ "$status" -ne 0 ]
    _refused_once join
}

@test "U-03 say from a member: the sentence once, the local membership cleared, no retry" {
    _member
    run bash "$HH/formation-say.sh" "hello team"
    [ "$status" -ne 0 ]
    _refused_once say
}

@test "U-04 every other Formation command: the sentence once, the local membership cleared" {
    local -a cmds=(
        "formation-leave.sh"
        "formation-list.sh"
        "formation-status.sh"
        "formation-roster.sh"
        "formation-report.sh"
        "formation-progress.sh Done"
        "formation-claim.sh mmry ."
        "formation-queue.sh list"
        "formation-remove.sh 5"
        "formation-assign.sh 5 do-the-tests"
        "formation-debrief.sh all-done-and-closed-out"
        "formation-idle-limit.sh"
        "formation-idle-limit.sh 30"
    )
    local c
    for c in "${cmds[@]}"; do
        _member
        : > "$URLS"
        # shellcheck disable=SC2086
        run bash "$HH"/$c
        [ "$status" -ne 0 ] || { echo "$c: exit 0 on a refusal: $output"; return 1; }
        _refused_once "$c"
    done
}

@test "U-05 the idle watch: the sentence once, the watch stops, the membership is cleared, and the next watch asks nothing" {
    _member
    run env MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=6 MMRY_IDLE_POLL_INTERVAL=1 bash "$HH/formation-check.sh" </dev/null
    [ "$(_count "$output" "$SENTENCE")" -eq 1 ] || { echo "idle: $output"; return 1; }
    [ -z "$(_state)" ] || { echo "idle: membership kept"; return 1; }
    [ "$(_formation_requests)" -eq 1 ] || { echo "idle: $(_formation_requests) requests: $(cat "$URLS")"; return 1; }

    : > "$URLS"
    run env MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=4 MMRY_IDLE_POLL_INTERVAL=1 bash "$HH/formation-check.sh" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "a second watch spoke: $output"; return 1; }
    [ "$(_formation_requests)" -eq 0 ] || { echo "a second watch asked: $(cat "$URLS")"; return 1; }
}

@test "U-06 the per-tool check: the sentence once, then silence and no request on the next tool call" {
    _member
    run env MMRY_FORMATION_MODE=tool bash "$HH/formation-check.sh" </dev/null
    [ "$(_count "$output" "$SENTENCE")" -eq 1 ] || { echo "tool: $output"; return 1; }
    [ -z "$(_state)" ]
    : > "$URLS"
    run env MMRY_FORMATION_MODE=tool bash "$HH/formation-check.sh" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(_formation_requests)" -eq 0 ]
}

@test "U-07 Codex: start, join and say print the sentence once and clear the membership" {
    local codex="$TEST_TMPDIR/codexhome"; mkdir -p "$codex"
    export MMRY_HOST=codex CODEX_HOME="$codex" CODEX_SESSION_ID="conv-upgrade-$$"
    SID="conv-upgrade-$$"
    run bash "$HH/formation-start.sh" "the next job for the formation"
    _refused_once codex-start
    : > "$URLS"
    run bash "$HH/formation-join.sh" 40
    _refused_once codex-join
    : > "$URLS"; _member
    run bash "$HH/formation-say.sh" "hello team"
    _refused_once codex-say
}

@test "U-08 another 403 is not the upgrade refusal: the membership stays" {
    _member
    export FAKE_FORM_BODY='{"error":"Only the lead can do that.","detail":null}'
    run bash "$HH/formation-say.sh" "hello team"
    [[ "$output" != *"$SENTENCE"* ]] || { echo "a 403 without the code printed the upgrade sentence: $output"; return 1; }
    [ -n "$(_state)" ] || { echo "a 403 without the code cleared the membership"; return 1; }
}

@test "U-09 the server's own sentence is printed, cleaned, and the approved one when the body names only the code" {
    export FAKE_FORM_BODY='{"error":"Formation is an upgrade\nthis account does not have yet.\u001b[31m","code":"formation_upgrade_required"}'
    run bash "$HH/formation-join.sh" 40
    [ "${#lines[@]}" -eq 1 ] || { echo "printed ${#lines[@]} lines: $output"; return 1; }
    [[ "$output" == *"Formation is an upgrade"* && "$output" != *$'\e'* ]] || { echo "$output"; return 1; }
    export FAKE_FORM_BODY='{"code":"formation_upgrade_required"}'
    : > "$URLS"
    run bash "$HH/formation-join.sh" 40
    _refused_once code-only
}

@test "U-11 idle-limit (34432's command): the approved sentence once when the body names only the code, read and set" {
    export FAKE_FORM_BODY='{"code":"formation_upgrade_required"}'
    local c
    for c in "formation-idle-limit.sh" "formation-idle-limit.sh 30" "formation-idle-limit.sh default"; do
        _member
        : > "$URLS"
        # shellcheck disable=SC2086
        run bash "$HH"/$c
        [ "$status" -ne 0 ] || { echo "$c: exit 0 on a refusal: $output"; return 1; }
        [ "${#lines[@]}" -eq 1 ] || { echo "$c: printed ${#lines[@]} lines: $output"; return 1; }
        _refused_once "$c code-only"
    done
}

@test "U-10 the help for Formation names the upgrade in the approved words, on Claude Code and Codex" {
    local help='Formation is an upgrade to your MMRY AI plan. If your account does not have it, an account administrator can add it on the account page at mmryai.com/account.'
    local f
    for f in "$PLUGIN_ROOT/commands/formation.md" "$PLUGIN_ROOT/commands/help.md" \
             "$PLUGIN_ROOT/skills-codex/help/SKILL.md" "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" \
             "$PLUGIN_ROOT/skills/memory-system/SKILL.md"; do
        grep -qF "$help" "$f" || { echo "missing in $f"; return 1; }
    done
}
