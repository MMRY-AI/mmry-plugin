#!/usr/bin/env bats
# #34650 (MMRY-AI/mmry FormationFreeReport): a member reports that it is free.
#
# On Claude Code, /mmry:formation free ["note"] runs formation-progress.sh free; on Codex, the
# formation_progress tool takes the state Free and runs the same script. Either way the script reads
# this session's own roster entry and:
#   - with work, sends the state Done with the note "free" (the member's note after it), so it works
#     against a server that has never heard of Free, and prints cmo-mmry's confirmation;
#   - with no work (no assignment, or Done or Abandoned already), sends nothing and prints the
#     approved "already free" line.
# A message saying free changes nothing; only this report does. The service is a fake transport: no
# network; the roster read and the progress write are answered separately and every request is logged
# with its body.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    SID="bats-free-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
    LOG="${BATS_TEST_TMPDIR}/free.log"
    : > "$LOG"
    # cmo-mmry, wording-free-release-cmo.md item 1, byte for byte.
    FREE_DONE="Your work is recorded as Done and you are free. The lead is told, so it can give you your next job."
    FREE_NONE="You have no work, so you are already free. Nothing was changed."
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/free-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""; method="GET"; data=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "-X" ]] && method="$arg"
    [[ "$prev" == "-d" || "$prev" == "--data" || "$prev" == "--data-binary" ]] && data="$arg"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
[[ "$data" == @* ]] && data="$(cat "${data#@}" 2>/dev/null)"
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s %s %s\n' "$method" "$url" "$data" >> "$FAKE_URL_LOG"
body="${FAKE_BODY:-}"; code="${FAKE_CODE:-200}"
if [[ "$url" != *"/progress"* ]]; then body="${FAKE_BODY_GET:-}"; code=200; fi
# A server that does not know Free refuses it as the procedure does, so a client that sent it unmapped
# would be refused here exactly as it would be on a server without #34650.
if [[ "$url" == *"/progress"* && "$data" == *'"progress":"'[Ff][Rr][Ee][Ee]'"'* ]]; then
    body='{"error":"Progress is one of Assigned, Accepted, Done, Blocked or Abandoned."}'; code=400
fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# The roster with THIS session as member 7, holding ASSIGNMENT at PROGRESS (null for none).
_roster() {
    local assignment="$1" progress="$2"
    printf '{"formation":{"id":4242,"objective":"o"},"members":[{"id":3,"sessionId":"somebody-else","role":"Lead","assignment":null,"progress":null,"leftDate":null},{"id":7,"sessionId":"%s","role":"Wingman","assignment":%s,"progress":%s,"leftDate":null}]}' \
        "$SID" "$assignment" "$progress"
}

_done_body() {
    printf '%s' '{"id":7,"sessionId":"'"$SID"'","role":"Wingman","assignment":"the validator","progress":"Done","progressUpdatedDate":"2026-11-24T09:00:00","leftDate":null,"free":"'"$FREE_DONE"'"}'
}

# _free HOST ROSTER [ARGS...]: run formation-progress.sh on HOST ("claude" or "codex") against the fake.
_free() {
    local host="$1" roster="$2"; shift 2
    local bin; bin="$(_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
    local hostenv=(env -u MMRY_HOST)
    [[ "$host" == "codex" ]] && hostenv=(env MMRY_HOST=codex CODEX_SESSION_ID="$SID")
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$(_done_body)" FAKE_BODY_GET="$roster" FAKE_URL_LOG="$LOG" \
        CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run "${hostenv[@]}" bash "${HANDLERS}/formation-progress.sh" "$@"
}

_line() { printf '%s\n' "$output" | tr -d '\r' | grep -c -x -F -- "$1"; }

# ---- with work: Done with the note free -----------------------------------------------------------

@test "34650: free on Accepted work sends state Done with the note free to this session's own entry" {
    _free claude "$(_roster '"the validator"' '"Accepted"')" free
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    grep -q '^PUT http://fake.invalid/api/formations/4242/members/7/progress .*"progress":"Done"' "$LOG" || { cat "$LOG"; return 1; }
    grep -q '^PUT .*"note":"free"' "$LOG" || { cat "$LOG"; return 1; }
    ! grep -q '"progress":"[Ff]ree"' "$LOG" || { cat "$LOG"; return 1; }
    ! grep -q '/members/3/progress' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650: free on Assigned work is recorded as Done too" {
    _free claude "$(_roster '"the validator"' '"Assigned"')" free
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '^PUT .*"progress":"Done"' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650: free \"note\" carries the note after the word free" {
    _free claude "$(_roster '"the validator"' '"Accepted"')" free "validator merged"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '^PUT .*"note":"free validator merged"' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650: free in any case: Free, FREE" {
    _free claude "$(_roster '"the validator"' '"Accepted"')" Free
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _free claude "$(_roster '"the validator"' '"Accepted"')" FREE
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -c '^PUT .*"progress":"Done"' "$LOG")" -eq 2 ] || { cat "$LOG"; return 1; }
}

@test "34650: free prints cmo-mmry's confirmation once, and the Done offer line" {
    _free claude "$(_roster '"the validator"' '"Accepted"')" free
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_line "$FREE_DONE")" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Is there anything else I can do?"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"$FREE_NONE"* ]] || { echo "$output"; return 1; }
}

@test "34650: on Codex, the state Free runs the same report and prints the same confirmation" {
    _free codex "$(_roster '"the validator"' '"Accepted"')" Free
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    grep -q '^PUT .*/members/7/progress .*"progress":"Done".*"note":"free"' "$LOG" || { cat "$LOG"; return 1; }
    [ "$(_line "$FREE_DONE")" -eq 1 ] || { echo "$output"; return 1; }
}

# ---- no work: nothing sent ------------------------------------------------------------------------

@test "34650: free with no assignment sends nothing and says you are already free" {
    _free claude "$(_roster 'null' 'null')" free
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
    [ "$(_line "$FREE_NONE")" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" != *"$FREE_DONE"* ]] || { echo "$output"; return 1; }
}

@test "34650: free after Done or Abandoned sends nothing and says you are already free" {
    _free claude "$(_roster '"the validator"' '"Done"')" free
    [ "$(_line "$FREE_NONE")" -eq 1 ] || { echo "$output"; return 1; }
    _free codex "$(_roster '"the validator"' '"Abandoned"')" Free
    [ "$(_line "$FREE_NONE")" -eq 1 ] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
}

# ---- every other state as before --------------------------------------------------------------------

@test "34650: Done is still sent as Done with no note added, and an unknown state still reaches the server's refusal" {
    _free claude "$(_roster '"the validator"' '"Accepted"')" Done
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '^PUT .*"progress":"Done"' "$LOG" || { cat "$LOG"; return 1; }
    ! grep -q '"note":"free"' "$LOG" || { cat "$LOG"; return 1; }
    [[ "$output" != *"$FREE_DONE"* ]] || { echo "$output"; return 1; }
}
