#!/usr/bin/env bats
# #34089 (DD-203 in MMRY-AI/mmry): the progress-limit command, formation-progress-limit.sh.
#
# How long a member with an assignment can go without progress before the lead is told: 5 to 1440
# minutes, 5 by default. Any member can read it; only the lead, the person who created the Formation or
# an account administrator can set it, and the server decides that. The words are cmo-mmry's
# (wording-34088-34089-cmo.md, C2, C4, C5 and C6 as revised to 5 to 1440). The service is a fake
# transport: no network, every call answered with FAKE_BODY, each request logged with its body.
#
# B16 (the script half). The connector tool in mcp-server.sh and the /mmry:formation progress-limit
# route in commands/formation.md wait for Seat A's merge (both files are fenced in this round).

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    SID="bats-progress-limit-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
    LOG="${BATS_TEST_TMPDIR}/limit.log"
    : > "$LOG"
    HELP="progress-limit <minutes> sets how long a member with an assignment can go without progress before the lead is told, from 5 to 1440 minutes (5 by default). Use progress-limit default to go back to 5, or progress-limit alone to see the current limit."
    RANGE="The progress limit is between 5 and 1440 minutes. Leave it unset to use the default of 5 minutes."
    STANDING="Only the lead of this Formation, the person who created it, or an account administrator can set its progress limit. Nothing was changed."
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/limit-bin"
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
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# _limit HOST CODE BODY [ARGS...]: run the script on HOST ("claude" or "codex") against the fake service.
_limit() {
    local host="$1" code="$2" body="$3"; shift 3
    local bin; bin="$(_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
    local hostenv=(env -u MMRY_HOST)
    [[ "$host" == "codex" ]] && hostenv=(env MMRY_HOST=codex CODEX_SESSION_ID="$SID")
    PATH="${bin}:${PATH}" FAKE_CODE="$code" FAKE_BODY="$body" FAKE_URL_LOG="$LOG" \
        CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run "${hostenv[@]}" bash "${HANDLERS}/formation-progress-limit.sh" "$@"
}

@test "B16: progress-limit 20 asks the server to set 20 minutes and prints its sentence" {
    _limit claude 200 '{"formationId":4242,"stallAfterMinutes":20,"stallNoticeAfterSeconds":1200,"message":"This Formation'"'"'s progress limit is now 20 minutes."}' 20
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "This Formation's progress limit is now 20 minutes." ] || { echo "$output"; return 1; }
    grep -q '^PUT http://fake.invalid/api/formations/4242/progress-limit {"minutes":20}$' "$LOG" || { cat "$LOG"; return 1; }
}

@test "B16: 5 and 1440 are sent; default sends null and prints the server's sentence" {
    _limit claude 200 '{"message":"This Formation'"'"'s progress limit is now 5 minutes."}' 5
    _limit claude 200 '{"message":"This Formation'"'"'s progress limit is now 1440 minutes."}' 1440
    _limit claude 200 '{"formationId":4242,"stallAfterMinutes":null,"stallNoticeAfterSeconds":300,"message":"This Formation'"'"'s progress limit is now 5 minutes."}' default
    [ "$output" = "This Formation's progress limit is now 5 minutes." ] || { echo "$output"; return 1; }
    grep -q '{"minutes":5}$' "$LOG" && grep -q '{"minutes":1440}$' "$LOG" && grep -q '{"minutes":null}$' "$LOG" || { cat "$LOG"; return 1; }
}

@test "B16: 4, 0 and 1441 are refused with the approved range sentence before the server is asked, on Claude Code and on Codex" {
    for host in claude codex; do
        for m in 4 0 1441; do
            _limit "$host" 200 '{}' "$m"
            [ "$status" -ne 0 ] || { echo "$host $m accepted: $output"; return 1; }
            [ "$output" = "$RANGE" ] || { echo "$host $m: $output"; return 1; }
        done
    done
    [ ! -s "$LOG" ] || { cat "$LOG"; return 1; }
}

@test "B16: abc is refused with the command's help line (C2), and the server is not asked" {
    for host in claude codex; do
        _limit "$host" 200 '{}' abc
        [ "$status" -ne 0 ] && [ "$output" = "$HELP" ] || { echo "$host: $output"; return 1; }
    done
    [ ! -s "$LOG" ] || { cat "$LOG"; return 1; }
}

@test "B16: help prints the approved help line and exits 0" {
    _limit claude 200 '{}' help
    [ "$status" -eq 0 ] && [ "$output" = "$HELP" ] || { echo "$output"; return 1; }
}

@test "B16: a member is refused with the server's approved sentence (C5)" {
    _limit claude 403 "{\"error\":\"${STANDING}\"}" 20
    [ "$status" -ne 0 ] && [ "$output" = "$STANDING" ] || { echo "$output"; return 1; }
}

@test "B16: a read says 'is', from the Formation's stallNoticeAfterSeconds, and a server without it reads the default of 5" {
    _limit claude 200 '{"formation":{"id":4242},"members":[],"stallNoticeAfterSeconds":1200}'
    [ "$status" -eq 0 ] && [ "$output" = "This Formation's progress limit is 20 minutes." ] || { echo "$output"; return 1; }
    grep -q '^GET http://fake.invalid/api/formations/4242?sessionId=' "$LOG" || { cat "$LOG"; return 1; }
    _limit claude 200 '{"formation":{"id":4242},"members":[]}'
    [ "$status" -eq 0 ] && [ "$output" = "This Formation's progress limit is 5 minutes." ] || { echo "$output"; return 1; }
}

@test "B16: a session not in a Formation is told so, and asks nothing" {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
    CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" run env -u MMRY_HOST bash "${HANDLERS}/formation-progress-limit.sh"
    [ "$status" -ne 0 ] && [ "$output" = "This session is not in a Formation, so it has no progress limit. Run /mmry:formation list to see what is active." ] || { echo "$output"; return 1; }
}

@test "B16: no answer names MMRY AI, and says how to check the limit" {
    _limit claude 503 '' 20
    [ "$status" -ne 0 ] && [ "$output" = "MMRY AI did not answer (HTTP 503), so nothing is confirmed. Run /mmry:formation progress-limit to check the limit before trying again." ] || { echo "$output"; return 1; }
}

@test "B16: the script is in the release file list" {
    grep -qx 'hooks-handlers/formation-progress-limit.sh' "${HANDLERS}/../release-files.txt"
}
