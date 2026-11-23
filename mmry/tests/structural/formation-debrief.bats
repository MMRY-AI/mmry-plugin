#!/usr/bin/env bats
# The close-out record shows how long each member was idle in the Formation, in total, and the debrief
# and the report print it (#34521, DD-202 in MMRY-AI/mmry; #33205 is built with it).
#
# WHY THIS FILE EXISTS. Idle time is counted so it is visible in retrospectives, and the retrospective
# reads the close-out record. The service writes one line per member that is not the lead, cmo-mmry's
# approved item 5 (wording-33205-34521-cmo-approved.md):
#   Member {id} >>> {name} <<<: idle for {duration} in total
# with "0 minutes" for a member never idle, so every member has a line.
#
# WHAT IS PINNED (34521 T10, the plugin's half). The record is assembled by the service in one place,
# and the plugin prints it rather than rebuilding it (formation-debrief.sh and formation-report.sh say
# why), so the idle lines reach the lead only if that printing keeps them:
#   D1  the debrief prints every idle line of the close-out record as the service sent it, the 0-minute
#       line included, on Claude Code and on Codex
#   D2  the report prints the same lines from the record it reads
#   D3  a carriage return or control character inside a member's name cannot hide or rewrite an idle
#       line in the debrief, which cleans the record (#31738). The report prints the record as it
#       comes, which predates this task and is left to its own ticket.
#
# These scripts already print the record whole. This file pins that they go on doing so for the idle
# lines; each case is seen red against a build that drops them (the mutants are recorded in the
# 33205-34521 plugin handback).

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    SID="bats-debrief-idle-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

_fake_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/fake-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# Run handler $2 on host $1 ("claude" or "codex") in formation 4242, every call answered with $3.
_run_on() {
    local host="$1" script="$2" body="$3"; shift 3
    local bin; bin="$(_fake_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
    if [[ "$host" == "codex" ]]; then
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" MMRY_HOST=codex CODEX_HOME="${BATS_TEST_TMPDIR}/codexhome" \
            CODEX_SESSION_ID="$SID" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/${script}" "$@"
    else
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" \
            CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "${HANDLERS}/${script}" "$@"
    fi
}

SUMMARY="Ported the validator and closed the billing gaps; nothing left open."

# The idle part of a close-out record as the service writes it (CRLF, as the server's AppendLine),
# with the record's other lines around it. $1 replaces Seat B's name when given.
_closeout_text() {
    local b="${1:-Seat B}"
    printf '%s' "CLOSE-OUT RECORD: formation 4242\r\n\r\nMember 12 (Wingman): Seat A\r\n    assigned: >>> port the validator <<<\r\n    outcome:  Done, reported 2026-11-23 10:00 UTC.\r\n\r\nMember 12 >>> Seat A <<<: idle for 40 minutes in total\r\nMember 13 >>> ${b} <<<: idle for 1 hour 5 minutes in total\r\nMember 14 >>> Seat C <<<: idle for 0 minutes in total\r\n\r\nThis record is assembled from the roster."
}
_debrief_body() { printf '{"formationId":4242,"status":"ClosedOut","closeOut":{"record":"%s"}}' "${1:-$(_closeout_text)}"; }
_report_body() { printf '{"formationId":4242,"record":"%s"}' "${1:-$(_closeout_text)}"; }

IDLE_A="Member 12 >>> Seat A <<<: idle for 40 minutes in total"
IDLE_B="Member 13 >>> Seat B <<<: idle for 1 hour 5 minutes in total"
IDLE_C="Member 14 >>> Seat C <<<: idle for 0 minutes in total"

# Every one of the three idle lines is a whole line of the output.
_has_idle_lines() {
    local flat; flat="$(printf '%s\n' "$output" | tr -d '\r')"
    local want
    for want in "$IDLE_A" "$IDLE_B" "$IDLE_C"; do
        [ "$(printf '%s\n' "$flat" | grep -c -x -F -- "$want")" -eq 1 ] || { echo "missing the line: $want"; echo "$output"; return 1; }
    done
}

@test "D1: the debrief prints every idle line of the close-out record, the 0-minute line included, on Claude Code" {
    _run_on claude formation-debrief.sh "$(_debrief_body)" "$SUMMARY"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _has_idle_lines
    [[ "$output" == *"Formation 4242 closed out."* ]] || { echo "$output"; return 1; }
}

@test "D1: and on Codex" {
    _run_on codex formation-debrief.sh "$(_debrief_body)" "$SUMMARY"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _has_idle_lines
}

@test "D2: the report prints the same idle lines from the record it reads, on Claude Code and on Codex" {
    _run_on claude formation-report.sh "$(_report_body)"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _has_idle_lines
    _run_on codex formation-report.sh "$(_report_body)"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _has_idle_lines
}

@test "D3: a carriage return, C0 or C1 control character in a member's name cannot hide or rewrite an idle line, in the debrief" {
    _run_on claude formation-debrief.sh "$(_debrief_body "$(_closeout_text 'Seat\r\u001b[2K\u0085B')")" "$SUMMARY"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *$'\r'* && "$output" != *$'\e'* && "$output" != *$'\xc2\x85'* ]] || { printf '%s' "$output" | od -c | tail -20; return 1; }
    printf '%s\n' "$output" | grep -q -x -F -- "Member 13 >>> Seat[2KB <<<: idle for 1 hour 5 minutes in total" || { echo "$output"; return 1; }
    printf '%s\n' "$output" | grep -q -x -F -- "$IDLE_C" || { echo "$output"; return 1; }
}
