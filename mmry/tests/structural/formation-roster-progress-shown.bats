#!/usr/bin/env bats
# The roster shows each member's real progress (#34466 R1 to R3, DD-205 in MMRY-AI/mmry).
#
# WHY THIS FILE EXISTS. In 1.38 every member read "not started" all day while all of them were working,
# because the bracket only changed when a member remembered to report. The service now sends, on every
# roster entry, progressShown: Blocked, Done or Abandoned as the member reported it; otherwise working once
# MMRY AI has recorded activity from the member since its work was given, or not started if it has
# recorded none; null for a lead, a member that has left and an inactive account. The stored progress is
# unchanged and still sent.
#
# WHAT IS PINNED:
#   P1  a member's bracket is the service's progressShown, on Claude Code and on Codex
#   P2  a member whose progressShown is null, on a roster that carries the field, shows no bracket
#   P3  a roster from an older service (no progressShown anywhere) reads byte for byte as today
#   P4  the new footer (cmo-mmry wording item 2) is printed only under a roster that carries the field,
#       byte for byte, on each host; an older service keeps today's footer byte for byte
#   P5  the service's word is text from the network, so control characters are removed and a value
#       that is not text is not shown

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    SID="bats-roster-shown-$$"
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
_line_for() { printf '%s\n' "$output" | tr -d '\r' | grep -F "$1"; }
_footer() { printf '%s\n' "$output" | tr -d '\r' | sed -n '/^Direct a message at one of them with/,$p'; }

HEAD='{"formation":{"id":4242,"objective":"o"},"members":['
LEAD='{"id":3,"role":"Lead","email":"lead@x.y","progress":null,"progressShown":null,"leftDate":null}'
# A member: id $1, stored progress $2, then any extra JSON fields in $3.
_member() { printf '{"id":%s,"role":"Wingman","email":"m%s@x.y","assignment":"port the validator","progress":"%s","leftDate":null%s}' "$1" "$1" "$2" "${3:-}"; }

NEW_FOOTER_CLAUDE='Direct a message at one of them with /mmry:formation say "..." --to <id>. Leave the id off
and the message goes to the whole formation.
In brackets, working means MMRY AI has recorded activity from the member since its work was given,
and not started means it has recorded none. Blocked, Done and Abandoned are what the member
reported, and they always show. Messages count as activity, not as progress. Report your own with
/mmry:formation progress <Accepted|Done|Blocked|Abandoned>, and read the whole account
with /mmry:formation report.'

OLD_FOOTER_CLAUDE='Direct a message at one of them with /mmry:formation say "..." --to <id>. Leave the id off
and the message goes to the whole formation.
The state in brackets is the last thing that member reported. Report your own with
/mmry:formation progress <Accepted|Done|Blocked|Abandoned>, and read the whole account
with /mmry:formation report.'

@test "P1: an Assigned member that has been active shows working, not not started, on Claude Code" {
    _roster "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"working"')]}"
    [ "$status" -eq 0 ]
    [[ "$(_line_for m7@x.y)" == *"  [working]"* ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m7@x.y)" != *"not started"* ]] || { echo "$output"; return 1; }
}

@test "P1: and on Codex, the same bracket" {
    _roster_on codex "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"working"')]}"
    [ "$status" -eq 0 ]
    [[ "$(_line_for m7@x.y)" == *"  [working]"* ]] || { echo "$output"; return 1; }
}

@test "P1: not started and a reported Blocked show as the service sends them" {
    _roster "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"not started"'),$(_member 8 Blocked ',"progressShown":"Blocked"')]}"
    [[ "$(_line_for m7@x.y)" == *"  [not started]"* ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m8@x.y)" == *"  [Blocked]"* ]] || { echo "$output"; return 1; }
}

@test "P1: an Accepted member shows working, as the service sends it" {
    _roster "${HEAD}${LEAD},$(_member 7 Accepted ',"progressShown":"working"')]}"
    [[ "$(_line_for m7@x.y)" == *"  [working]"* ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m7@x.y)" != *"[Accepted]"* ]] || { echo "$output"; return 1; }
}

@test "P2: a member with null progressShown on a roster that carries it shows no bracket" {
    local left='{"id":9,"role":"Wingman","email":"m9@x.y","assignment":"old work","progress":"Assigned","progressShown":null,"leftDate":"2026-11-23T08:00:00"}'
    _roster "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"working"'),${left}]}"
    [[ "$(_line_for m9@x.y)" != *"["*"]"* ]] || { echo "$output"; return 1; }
    [[ "$(_line_for m9@x.y)" != *"not started"* ]] || { echo "$output"; return 1; }
}

@test "P3: an older service with no progressShown reads byte for byte as today" {
    local body="${HEAD}${LEAD},$(_member 7 Assigned),$(_member 8 Accepted)]}"
    _roster "$body"
    [ "$status" -eq 0 ]
    [ "$(_line_for m7@x.y)" = "  7  Wingman  m7@x.y  - port the validator  [not started]" ] || { echo "$output"; return 1; }
    [ "$(_line_for m8@x.y)" = "  8  Wingman  m8@x.y  - port the validator  [Accepted]" ] || { echo "$output"; return 1; }
    [ "$(_footer)" = "$OLD_FOOTER_CLAUDE" ] || { echo "--- actual ---"; _footer; return 1; }
}

@test "P4: the new footer is printed under a roster that carries progressShown, byte for byte, on Claude Code" {
    _roster "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"working"')]}"
    [ "$(_footer)" = "$NEW_FOOTER_CLAUDE" ] || { echo "--- actual ---"; _footer; return 1; }
}

@test "P4: on Codex the new footer carries Codex's own references" {
    _roster_on codex "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"working"')]}"
    local f; f="$(_footer)"
    [[ "$f" == *"In brackets, working means MMRY AI has recorded activity from the member since its work was given,
and not started means it has recorded none. Blocked, Done and Abandoned are what the member
reported, and they always show. Messages count as activity, not as progress. Report your own with
"* ]] || { echo "$f"; return 1; }
    [[ "$f" != *"/mmry:"* ]] || { echo "a slash command on Codex: $f"; return 1; }
    [[ "$f" != *"The state in brackets is the last thing"* ]] || { echo "$f"; return 1; }
}

@test "P5: control characters in the service's word are removed, and a value that is not text is not shown" {
    _roster "${HEAD}${LEAD},$(_member 7 Assigned ',"progressShown":"work\u001b[31m\u0085ing\r"'),$(_member 8 Assigned ',"progressShown":42')]}"
    local l7 l8; l7="$(printf '%s\n' "$output" | grep -F m7@x.y)"; l8="$(_line_for m8@x.y)"
    # Raw line, so a carriage return inside the word would show as "ing\r]" (jq on Windows may end the
    # line with its own \r, which is after the bracket).
    [[ "$l7" != *$'\e'* ]] || { echo "an escape character was printed"; return 1; }
    # U+0085 (NEL, a C1 control, two bytes in UTF-8) is removed only by the C1 part of the jq clean.
    [[ "$l7" != *$'\xc2\x85'* ]] || { echo "a C1 control (U+0085) was printed"; return 1; }
    [[ "$l7" == *"  [work[31ming]"* ]] || { echo "$l7"; return 1; }
    [[ "$l8" != *"["*"]"* ]] || { echo "$l8"; return 1; }
}
