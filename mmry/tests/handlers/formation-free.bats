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
# The route's validator: a note longer than 500 characters (counted as characters, not bytes) is
# refused 400 with its own sentence in a validation problem, and nothing is recorded.
if [[ "$url" == *"/progress"* ]]; then
    n="$(printf '%s' "$data" | "${MMRY_JQ:-jq}" -r '(.note // "") | length' 2>/dev/null | tr -d '\r')"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 500 )); then
        body='{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.1","title":"One or more validation errors occurred.","status":400,"errors":{"Note":["The length of '"'"'Note'"'"' must be 500 characters or fewer. You entered '"$n"' characters."]}}'
        code=400
    fi
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
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="${BODY_OVERRIDE:-$(_done_body)}" FAKE_BODY_GET="$roster" FAKE_URL_LOG="$LOG" \
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

# ---- fix round 1 ------------------------------------------------------------------------------------

# cmo-mmry item 7 (lead ruling 2026-11-24), byte for byte, NO APOSTROPHES.
FREE_BLOCKED="Your work is reported as Blocked, so you cannot report that you are free. Nothing was changed. Keep the block reported so the lead can help you clear it or release you from the work."

# The roster with THIS session as the lead (3) and somebody else as member 7, holding work.
_lead_roster() {
    printf '{"formation":{"id":4242,"objective":"o"},"members":[{"id":3,"sessionId":"%s","role":"Lead","assignment":null,"progress":null,"leftDate":null},{"id":7,"sessionId":null,"role":"Wingman","assignment":"the validator","progress":"%s","leftDate":null}]}' \
        "$SID" "${1:-Accepted}"
}
# The service's answer to a lead reporting for member 7: that member's entry, no session, no free field.
_lead_done_body() {
    printf '%s' '{"id":7,"sessionId":null,"role":"Wingman","assignment":"the validator","progress":"Done","progressUpdatedDate":"2026-11-24T09:00:00","leftDate":null}'
}

@test "34650 fix 1: a lead's free for member 7 prints exactly what a lead's Done for member 7 prints, not the member's confirmation" {
    BODY_OVERRIDE="$(_lead_done_body)" _free claude "$(_lead_roster)" 7 free
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    local free_out="$output"
    grep -q '^PUT http://fake.invalid/api/formations/4242/members/7/progress .*"progress":"Done".*"note":"free"' "$LOG" || { cat "$LOG"; return 1; }
    BODY_OVERRIDE="$(_lead_done_body)" _free claude "$(_lead_roster)" 7 Done
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$free_out" = "$output" ] || { printf 'free:\n%s\ndone:\n%s\n' "$free_out" "$output"; return 1; }
    [[ "$free_out" != *"$FREE_DONE"* ]] || { echo "$free_out"; return 1; }
    [[ "$free_out" != *"Is there anything else I can do?"* ]] || { echo "$free_out"; return 1; }
}

@test "34650 fix 1: the member's own free still gets the approved confirmation" {
    _free claude "$(_roster '"the validator"' '"Accepted"')" free
    [ "$(_line "$FREE_DONE")" -eq 1 ] || { echo "$output"; return 1; }
}

@test "34650 fix 2: free on Blocked work is refused with cmo-mmry's sentence, nothing is sent, on Claude Code" {
    _free claude "$(_roster '"the validator"' '"Blocked"')" free "it is finished really"
    [ "$status" -eq 1 ] || { echo "status $status"; echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | tr -d '\r')" = "$FREE_BLOCKED" ] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650 fix 2: on Codex, the state Free on Blocked work is refused with the same sentence (an error result)" {
    _free codex "$(_roster '"the validator"' '"blocked"')" Free
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | tr -d '\r')" = "$FREE_BLOCKED" ] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650 fix 2: a member naming its own member id with free on Blocked work is refused too" {
    _free claude "$(_roster '"the validator"' '"Blocked"')" 7 free
    [ "$status" -eq 1 ] || { echo "status $status"; echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | tr -d '\r')" = "$FREE_BLOCKED" ] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650 fix 2: free on Assigned and on Accepted is still recorded as Done" {
    _free claude "$(_roster '"the validator"' '"Assigned"')" free
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _free codex "$(_roster '"the validator"' '"Accepted"')" Free
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -c '^PUT .*"progress":"Done".*"note":"free"' "$LOG")" -eq 2 ] || { cat "$LOG"; return 1; }
}

# ---- fix round 2 ------------------------------------------------------------------------------------

@test "34650 fix round 2, fix 3: free on Blocked with no assignment gets item 7, not the already-free line (Claude Code)" {
    _free claude "$(_roster 'null' '"Blocked"')" free
    [ "$status" -eq 1 ] || { echo "status $status"; echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | tr -d '\r')" = "$FREE_BLOCKED" ] || { echo "$output"; return 1; }
    [[ "$output" != *"$FREE_NONE"* ]] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650 fix round 2, fix 3: on Codex, Free on Blocked with an empty assignment gets item 7 as an error result" {
    _free codex "$(_roster '""' '"Blocked"')" Free
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | tr -d '\r')" = "$FREE_BLOCKED" ] || { echo "$output"; return 1; }
    ! grep -q '^PUT ' "$LOG" || { cat "$LOG"; return 1; }
}

@test "34650 fix round 2, fix 6a: a lead's free for member 7 whose work is Blocked is sent as Done with the note free, and prints what a lead's Done prints" {
    BODY_OVERRIDE="$(_lead_done_body)" _free claude "$(_lead_roster Blocked)" 7 free
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    local free_out="$output"
    grep -q '^PUT http://fake.invalid/api/formations/4242/members/7/progress .*"progress":"Done".*"note":"free"' "$LOG" || { cat "$LOG"; return 1; }
    BODY_OVERRIDE="$(_lead_done_body)" _free claude "$(_lead_roster Blocked)" 7 Done
    [ "$free_out" = "$output" ] || { printf 'free:\n%s\ndone:\n%s\n' "$free_out" "$output"; return 1; }
    [[ "$free_out" != *"$FREE_BLOCKED"* ]] || { echo "$free_out"; return 1; }
}

# Fix 5 (R4 variants): the send path. formation-say.sh posts a message and nothing else; a message saying
# free in any words, directed or to everyone, never reaches the progress route.
_say() {
    local bin; bin="$(_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
    PATH="${bin}:${PATH}" FAKE_CODE=201 FAKE_BODY='{"id":501}' FAKE_BODY_GET='{"id":501,"stored":1}' FAKE_URL_LOG="$LOG" \
        CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run env -u MMRY_HOST bash "${HANDLERS}/formation-say.sh" "$@"
}

@test "34650 fix round 2, fix 5: 'I am free' and 'free?' to the lead and 'free' to everyone are sent as messages and never as progress" {
    _say "I am free" 3 --confirm
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    _say "free?" 3 --confirm
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    _say "free"
    [ "$status" -eq 0 ] || { echo "$output"; cat "$LOG"; return 1; }
    [ "$(grep -c '^POST .*/transmissions' "$LOG")" -eq 3 ] || { cat "$LOG"; return 1; }
    ! grep -q '/progress' "$LOG" || { cat "$LOG"; return 1; }
}

# The note as the fake logged it on the PUT.
_sent_note() { grep '^PUT ' "$LOG" | tail -n 1 | sed 's/^PUT [^ ]* //' | "${MMRY_JQ:-jq}" -r '.note' | tr -d '\r'; }
_rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }
TOO_LONG_501="The length of 'Note' must be 500 characters or fewer. You entered 501 characters."

@test "34650 fix 3: free with a note one over the limit is sent whole and refused with the route's too-long sentence" {
    local note; note="$(_rep a 496)"
    _free claude "$(_roster '"the validator"' '"Accepted"')" free "$note"
    [ "$status" -eq 1 ] || { echo "status $status"; echo "$output"; return 1; }
    [ "$(_sent_note)" = "free ${note}" ] || { echo "the note was cut"; _sent_note | wc -c; return 1; }
    [ "$(_line "The server refused it, and nothing was recorded. ${TOO_LONG_501}")" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" != *"$FREE_DONE"* ]] || { echo "$output"; return 1; }
}

@test "34650 fix 3: a multibyte note one over the limit is refused, not cut, under the C locale too" {
    local note; note="$(_rep '€' 496)"
    LC_ALL=C _free claude "$(_roster '"the validator"' '"Accepted"')" free "$note"
    [ "$status" -eq 1 ] || { echo "status $status"; echo "$output"; return 1; }
    [ "$(_sent_note)" = "free ${note}" ] || { echo "the note was cut"; return 1; }
    [ "$(_line "The server refused it, and nothing was recorded. ${TOO_LONG_501}")" -eq 1 ] || { echo "$output"; return 1; }
}

@test "34650 fix 3: a note at the limit is accepted whole, ASCII and multibyte, under the C locale too" {
    local note
    note="$(_rep a 495)"
    _free claude "$(_roster '"the validator"' '"Accepted"')" free "$note"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_sent_note)" = "free ${note}" ] || { echo "ascii note cut"; return 1; }
    [ "$(_line "$FREE_DONE")" -eq 1 ] || { echo "$output"; return 1; }
    note="$(_rep '€' 495)"
    LC_ALL=C _free claude "$(_roster '"the validator"' '"Accepted"')" free "$note"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_sent_note)" = "free ${note}" ] || { echo "multibyte note cut"; return 1; }
    [ "$(_line "$FREE_DONE")" -eq 1 ] || { echo "$output"; return 1; }
}

@test "34650 fix 3: the script does not cut the note itself" {
    ! grep -q -F -- 'note="${note:0:' "${HANDLERS}/formation-progress.sh" || return 1
}

@test "34650 fix 4: the usage lines and the Codex reference list Free last, as cmo-mmry's item 6 says" {
    _free claude "$(_roster '"the validator"' '"Accepted"')"
    [[ "$output" == *'<Accepted|Done|Blocked|Abandoned|Free>'* ]] || { echo "$output"; return 1; }
    _free claude "$(_roster '"the validator"' '"Accepted"')" 7
    [[ "$output" == *'<Accepted|Done|Blocked|Abandoned|Free>'* ]] || { echo "$output"; return 1; }
    _free codex "$(_roster '"the validator"' '"Accepted"')"
    [[ "$output" == *"with state Accepted, Done, Blocked, Abandoned or Free, and an optional note"* ]] || { echo "$output"; return 1; }
    ! grep -q -F -- '<Accepted|Done|Blocked|Abandoned>' "${HANDLERS}/formation-progress.sh" || return 1
    ! grep -q -F -- 'with state Accepted, Done, Blocked or Abandoned, and' "${HANDLERS}/lib-host.sh" || return 1
}
