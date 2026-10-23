#!/usr/bin/env bats
# formation-held-refusal.bats - a start or join refused because the session already holds a seat
# shows WHICH formation holds it and how to release it (#32401 requirement 3, DD-155 in the API
# repository).
#
# The service (migration 078) no longer lets a closed-out formation hold a session, so what is
# left is a session in a formation that is still active. The service's 409 now names it:
#   "This session is still a member of formation 36 ("..."), which is still active. Leave
#    formation 36 to release the session, then start or join again."
# The handlers used to print a fixed "This session already belongs to an active formation. Run
# leave first." and threw the service's words away. Now they print the service's sentence and the
# host's own leave command after it. A service that does not name a formation (one older than
# #32401) still gets the old sentence, word for word, so nothing regresses against it.
#
# The network is a fake curl that answers 409 with whatever FAKE_409_BODY holds.

load '../helpers/test-helper'

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
code=200; resp='{}'
case "$method $url" in
    "POST "*/api/sessions) code=201; resp='' ;;
    "POST "*/api/formations/*/join) code=409; resp="$FAKE_409_BODY" ;;
    "POST "*/api/formations) code=409; resp="$FAKE_409_BODY" ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    SID="aaaa3333-held-$$"
    export CLAUDE_CODE_SESSION_ID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    NAMED='This session is still a member of formation 36 ("Migrate the billing schema"), which is still active. Leave formation 36 to release the session, then start or join again.'
    export FAKE_409_BODY='{"error":"This session is still a member of formation 36 (\"Migrate the billing schema\"), which is still active. Leave formation 36 to release the session, then start or join again.","detail":null}'
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    rm -rf "$TEST_TMPDIR"
}

_state() { bash "$HH/formation-state.sh" get "$SID"; }

@test "H-01 join: the refusal names the formation that holds the session and the leave command" {
    run bash "$HH/formation-join.sh" 40
    [ "$status" -ne 0 ]
    [[ "$output" == *"$NAMED To leave it, run /mmry:formation leave."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Run /mmry:formation leave first."* ]] || { echo "the fixed sentence is still printed: $output"; return 1; }
    [ -z "$(_state)" ] || { echo "a refused join wrote local state: $(_state)"; return 1; }
}

@test "H-02 start: the refusal names the formation that holds the session and the leave command" {
    run bash "$HH/formation-start.sh" "the next job"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$NAMED To leave it, run /mmry:formation leave."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Run /mmry:formation leave first."* ]] || { echo "the fixed sentence is still printed: $output"; return 1; }
    [ -z "$(_state)" ] || { echo "a refused start wrote local state: $(_state)"; return 1; }
}

@test "H-03 Codex: the leave step names the mmry_plugin formation_leave tool" {
    local codex="$TEST_TMPDIR/codexhome"; mkdir -p "$codex"
    local out
    out="$(env MMRY_HOST=codex CODEX_HOME="$codex" CODEX_SESSION_ID="conv-held-$$" \
        bash "$HH/formation-join.sh" 40 2>&1 || true)"
    [[ "$out" == *"$NAMED To leave it, run the mmry_plugin formation_leave tool."* ]] || { echo "$out"; return 1; }
    out="$(env MMRY_HOST=codex CODEX_HOME="$codex" CODEX_SESSION_ID="conv-held-$$" \
        bash "$HH/formation-start.sh" "the next job" 2>&1 || true)"
    [[ "$out" == *"$NAMED To leave it, run the mmry_plugin formation_leave tool."* ]] || { echo "$out"; return 1; }
}

@test "H-04 an older service that names no formation still gets the old sentence, word for word" {
    export FAKE_409_BODY='{"error":"That session already belongs to an active formation. Leave it first.","detail":null}'
    run bash "$HH/formation-join.sh" 40
    [[ "$output" == *"This session already belongs to an active formation. Run /mmry:formation leave first."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Leave it first"* ]] || { echo "the unnamed service sentence was printed: $output"; return 1; }
    run bash "$HH/formation-start.sh" "the next job"
    [[ "$output" == *"This session already belongs to an active formation. Run /mmry:formation leave first."* ]] || { echo "$output"; return 1; }
}

@test "H-05 an empty or non-JSON 409 body falls back to the old sentence" {
    export FAKE_409_BODY=''
    run bash "$HH/formation-join.sh" 40
    [[ "$output" == *"This session already belongs to an active formation. Run /mmry:formation leave first."* ]] || { echo "$output"; return 1; }
    export FAKE_409_BODY='<html>conflict</html>'
    run bash "$HH/formation-start.sh" "the next job"
    [[ "$output" == *"This session already belongs to an active formation. Run /mmry:formation leave first."* ]] || { echo "$output"; return 1; }
}

@test "H-06 the service's sentence cannot break the line or carry control characters" {
    export FAKE_409_BODY='{"error":"This session is still a member of formation 36 (\"a\nb\r\tc\u001b[31m\"), which is still active. Leave formation 36 to release the session, then start or join again."}'
    run bash "$HH/formation-join.sh" 40
    [ "${#lines[@]}" -eq 1 ] || { echo "printed ${#lines[@]} lines: $output"; return 1; }
    # Each line break or tab becomes a space (a jq on Windows writes \n as \r\n, so the count of
    # spaces differs by platform; what may not differ is that the text stays on one line).
    [[ "$output" =~ formation\ 36\ \(\"a\ +b\ +c\[31m\"\) ]] || { echo "$output"; return 1; }
    [[ "$output" != *$'\r'* && "$output" != *$'\t'* ]] || { echo "a carriage return or tab was printed"; return 1; }
    [[ "$output" != *$'\e'* ]] || { echo "an escape character was printed"; return 1; }
}
