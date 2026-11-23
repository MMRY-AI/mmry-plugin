#!/usr/bin/env bats
# The roster shows how long each member has been idle in the Formation, in total (#34521, DD-202 in
# MMRY-AI/mmry; #33205 is built with it).
#
# WHY THIS FILE EXISTS. In formation 115 a member reported Done and the lead answered "stand by" while
# work was waiting, and nothing afterwards showed how long members had sat idle, so the retrospective
# could not see it. The service now counts each member's idle time (a member waiting on a permission
# prompt never counts) and sends it on every roster entry: idleMinutesTotal, whole minutes, and
# idleTotal, cmo-mmry's approved line "idle for {duration} in total" (item 5,
# wording-33205-34521-cmo-approved.md), null for a lead and for a member never idle.
#
# WHAT IS PINNED (34521 T10, the plugin's half):
#   R1  a member with idleTotal shows it on its own roster line, as the service wrote it, in brackets
#       beside the existing marks, on Claude Code and on Codex
#   R2  null or absent prints nothing, and the line is byte for byte the line without the field
#   R3  the lead, whose idleTotal is null, shows none
#   R4  the text is the service's, so carriage returns and control characters in it are removed, and
#       a value that is not text is not shown
#   R5  it sits before the availability mark, so a member's line still ends with its availability
#
# The words are the service's (FormationIdleMinutes.RosterLine); this file proves the plugin prints
# them where the lead reads the roster. The counting itself is proven by the service's tests.

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    SID="bats-roster-idle-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

# The fake transport: no network; every call answered with FAKE_BODY.
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

# The roster of formation 4242 on host $1 ("claude" or "codex"), answered with $2.
_roster_on() {
    local host="$1" body="$2" bin; bin="$(_fake_curl_dir)"
    if [[ "$host" == "codex" ]]; then
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" MMRY_HOST=codex CODEX_HOME="${BATS_TEST_TMPDIR}/codexhome" \
            CODEX_SESSION_ID="$SID" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run bash "${HANDLERS}/formation-roster.sh" 4242
    else
        PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY="$body" \
            CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
            MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
            run env -u MMRY_HOST bash "${HANDLERS}/formation-roster.sh" 4242
    fi
}
_roster() { _roster_on claude "$1"; }

HEAD='{"formation":{"id":4242,"objective":"o"},"members":['
# The lead as the service sends it: never idle by 34432's rule, so both fields null.
LEAD='{"id":3,"role":"Lead","email":"lead@x.y","idleMinutesTotal":null,"idleTotal":null,"leftDate":null}'
# A member row: id $1, then any extra JSON fields in $2.
_member() { printf '{"id":%s,"role":"Wingman","email":"m%s@x.y","assignment":"port the validator","progress":"Accepted","leftDate":null%s}' "$1" "$1" "${2:-}"; }
_line_for() { printf '%s\n' "$output" | tr -d '\r' | grep -F "$1"; }

@test "R1: a member with idle time shows the service's line on its own roster line, on Claude Code" {
    _roster "${HEAD}${LEAD},$(_member 12 ',"idleMinutesTotal":40,"idleTotal":"idle for 40 minutes in total"'),$(_member 13 ',"idleMinutesTotal":65,"idleTotal":"idle for 1 hour 5 minutes in total"')]}"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_line_for m12@x.y)" == *"  [Accepted]  (idle for 40 minutes in total)" ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m13@x.y)" == *"  [Accepted]  (idle for 1 hour 5 minutes in total)" ]] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | grep -c 'in total')" -eq 2 ] || { echo "$output"; return 1; }
}

@test "R1: and on Codex, the same line" {
    local body="${HEAD}${LEAD},$(_member 12 ',"idleMinutesTotal":40,"idleTotal":"idle for 40 minutes in total"')]}"
    _roster_on claude "$body"
    local cc; cc="$(_line_for m12@x.y)"
    _roster_on codex "$body"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local cx; cx="$(_line_for m12@x.y)"
    [[ "$cx" == *"  (idle for 40 minutes in total)" ]] || { echo "$output"; return 1; }
    [ "$cc" = "$cx" ] || { echo "claude: $cc"; echo "codex:  $cx"; return 1; }
}

@test "R2: a null or absent idle line prints nothing, and the line is byte for byte the line without it" {
    _roster "${HEAD}${LEAD},$(_member 12)]}"
    local without="$output"
    [[ "$without" == *"m12@x.y"* ]] || { echo "control: $without"; return 1; }
    _roster "${HEAD}${LEAD},$(_member 12 ',"idleMinutesTotal":null,"idleTotal":null')]}"
    [ "$output" = "$without" ] || { echo "--- without"; echo "$without"; echo "--- null"; echo "$output"; return 1; }
    [[ "$output" != *"in total"* ]] || { echo "$output"; return 1; }
}

@test "R3: the lead shows no idle line" {
    _roster "${HEAD}${LEAD},$(_member 12 ',"idleMinutesTotal":40,"idleTotal":"idle for 40 minutes in total"')]}"
    [[ "$(_line_for lead@x.y)" != *"in total"* ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m12@x.y)" == *"in total)"* ]] || { echo "control: $output"; return 1; }
}

@test "R4: carriage returns and control characters in the line are removed, and a value that is not text is not shown" {
    _roster "${HEAD}${LEAD},$(_member 12 ',"idleTotal":"idle for 40\r minutes\u001b[2K in\u0085 total\u0007"'),$(_member 13 ',"idleTotal":40'),$(_member 14 ',"idleTotal":{"a":1}')]}"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *$'\e'* && "$output" != *$'\a'* && "$output" != *$'\xc2\x85'* ]] || { printf '%s' "$output" | od -c | tail -20; return 1; }
    [[ "$(_line_for m12@x.y)" == *"  (idle for 40 minutes[2K in total)" ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m13@x.y)" != *"in total"* && "$(_line_for m13@x.y)" != *"(40)"* ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m14@x.y)" != *"in total"* && "$(_line_for m14@x.y)" != *'"a"'* ]] || { echo "$output"; return 1; }
}

@test "R5: the idle line sits before the availability mark, so the line still ends with its availability" {
    _roster "${HEAD}${LEAD},$(_member 12 ',"idleTotal":"idle for 40 minutes in total","availability":"working","availabilitySince":null')]}"
    [[ "$(_line_for m12@x.y)" == *"  (idle for 40 minutes in total)  Availability: working." ]] || { echo "$output"; return 1; }
}
