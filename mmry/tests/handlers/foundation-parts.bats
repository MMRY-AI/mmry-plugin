#!/usr/bin/env bats
# foundation-parts.bats - the Foundation set delivered in up to six labelled parts (#31411 QA round 2,
# #31583 QA round 6).
#
# Claude Code caps each hook's additionalContext at 10,000 characters. Over it, Claude Code saves
# the output to a file and shows the model a 2,000-character preview and the path, without asking
# the model to read it. The cap is per hook, and hooks that fire together land in completion order.
# So hooks.json registers the Foundation hook six times, --part 1 to 6, each firing sends one
# labelled part, and a set too large for six parts goes by reference.
#
# These tests fire the parts the way Claude Code does: each one as its own process, each with its
# own copy of the payload, and read what each one emitted.
#
# Every fixture here is free of carriage returns, so the tr -d below only removes what a native
# Windows jq adds when it writes text, never anything the set contained.

load '../helpers/test-helper'

setup() {
    HOOK="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    STATUSCMD="$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    # SessionStart writes this in every real session; see userpromptsubmit-foundation.bats.
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
    HEAD_ONE="The following are the account's FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive."
}

# Record the manifest for whatever is in the cache, as the writer would.
_seal() {
    local s b n
    read -r s b < <(cksum < "$CACHE")
    n="$(grep -c '^- ' "$CACHE" || true)"
    printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s\n' "${n:-0}" "$b" "$s" > "${CACHE}.manifest"
}

# A set of $1 numbered directives, 89 bytes each. awk, not yes: BSD yes prints "--".
_seed_lines() {
    awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$CACHE"
    _seal
}

# Fire part $1 as Claude Code would. $2 = the session id in the payload; empty = no payload.
_fire() {
    local k="$1" sid="${2:-}"
    if [[ -n "$sid" ]]; then
        printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' "$sid" \
            | bash "$HOOK" --part "$k" > "$TEST_TMPDIR/part$k.json" 2>/dev/null
    else
        bash "$HOOK" --part "$k" < /dev/null > "$TEST_TMPDIR/part$k.json" 2>/dev/null
    fi
}
# All six at once, as Claude Code fires them (#31583 QA round 3, R4(a)): the status counts a part only if
# it started with the other parts of the most recent prompt.
_fire_all() { local k; for k in 1 2 3 4 5 6; do _fire "$k" "${1:-}" & done; wait; }

_outcome_file() { printf '%s/mmry-foundation.outcome.%s%s' "$TEST_TMPDIR" "$1" "$( (( $2 > 1 )) && printf '.%s' "$2")"; }

# Fire part $1 with the payload $2, exactly as given.
_fire_payload() { printf '%s' "$2" | bash "$HOOK" --part "$1" > "$TEST_TMPDIR/part$1.json" 2>/dev/null; }

# The records of session $1, parts 1 to 6, whichever exist.
_records() {
    local f
    for f in "$TEST_TMPDIR/mmry-foundation.outcome.$1" "$TEST_TMPDIR"/mmry-foundation.outcome."$1".[2-6]; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}

# The latest second any record of session $1 says its part started, or nothing.
_latest_start() {
    local f l max=""
    while IFS= read -r f; do
        l="$(cat "$f")"
        [[ "$l" =~ ^[^[:space:]]+[[:space:]]([0-9]+)[[:space:]] ]] || continue
        [[ -z "$max" || "${BASH_REMATCH[1]}" -gt "$max" ]] && max="${BASH_REMATCH[1]}"
    done < <(_records "$1")
    printf '%s' "$max"
}

# Move every record of session $1 back by $2 seconds: they now belong to an earlier prompt.
_age() {
    local f l
    while IFS= read -r f; do
        l="$(cat "$f")"
        [[ "$l" =~ ^([^[:space:]]+)[[:space:]]([0-9]+)[[:space:]](.*)$ ]] || continue
        printf '%s %s %s' "${BASH_REMATCH[1]}" "$(( BASH_REMATCH[2] - $2 ))" "${BASH_REMATCH[3]}" > "$f"
    done < <(_records "$1")
}

# Stage one prompt out of firings made one at a time (#31583 QA round 3, R4(a)). Claude Code starts the
# six parts together; a test that changes the set between two of them cannot, so it fires them in turn
# and then gives every record the same start, which is what they would have had.
_one_prompt() {
    local f l t; t="$(_latest_start "$1")"
    [[ -n "$t" ]] || return 0
    while IFS= read -r f; do
        l="$(cat "$f")"
        [[ "$l" =~ ^([^[:space:]]+)[[:space:]]([0-9]+)[[:space:]](.*)$ ]] || continue
        printf '%s %s %s' "${BASH_REMATCH[1]}" "$t" "${BASH_REMATCH[3]}" > "$f"
    done < <(_records "$1")
}

# Write part $2's record for session $1 as the hook would on the most recent prompt.
_rec() {
    local t; t="$(_latest_start "$1")"; [[ -n "$t" ]] || t="$(date +%s)"
    printf '%s %s %s' "$1" "$t" "$3" > "$(_outcome_file "$1" "$2")"
}

# The decoded additionalContext of part $1 into PART_TEXT, trailing newlines kept: a part cut after
# a newline ends in one, and $( ) would drop it.
_ctx() {
    PART_TEXT="$(jq -j '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part$1.json" | tr -d '\r' && printf '.')" || return 1
    PART_TEXT="${PART_TEXT%.}"
}

# The stored set exactly as the hook reads it.
_stored() { STORED="$(<"$CACHE")"; }

@test "parts: hooks.json registers the hook six times, --part 1 to 6 once each, one shared timeout" {
    local cmds n k
    cmds="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$PLUGIN_ROOT/hooks/hooks.json" | tr -d '\r' | grep 'userpromptsubmit-foundation')"
    n="$(printf '%s\n' "$cmds" | grep -c .)"
    [ "$n" -eq 6 ] || { echo "expected 6 entries, found $n"; return 1; }
    for k in 1 2 3 4 5 6; do
        [ "$(printf '%s\n' "$cmds" | grep -c -- "--part $k\$")" -eq 1 ] || { echo "--part $k is not registered exactly once"; return 1; }
    done
    n="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | length' "$PLUGIN_ROOT/hooks/hooks.json" | tr -d '\r')"
    [ "$n" = "1" ] || { echo "the six entries do not share one timeout"; return 1; }
    # The handler's own count agrees with the registration.
    grep -q 'MMRY_FND_PARTS_MAX="${MMRY_FOUNDATION_PARTS_MAX:-6}"' "$HOOK" || { echo "the handler does not default to 6 parts"; return 1; }
}

@test "parts: a small set is sent whole by part 1, exactly as one hook sent it, and parts 2-6 say nothing" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity.\n' > "$CACHE"; _seal
    _fire_all
    _ctx 1; _stored
    [ "$PART_TEXT" = "${HEAD_ONE}"$'\n\n'"${STORED}" ] || { echo "part 1 is not the single-hook payload: ${PART_TEXT:0:300}"; return 1; }
    [[ "$PART_TEXT" != *"PART 1 OF"* ]] || { echo "a one-part set was labelled as a part"; return 1; }
    local k
    for k in 2 3 4 5 6; do
        [ ! -s "$TEST_TMPDIR/part$k.json" ] || { echo "part $k spoke on a small set: $(head -c 200 "$TEST_TMPDIR/part$k.json")"; return 1; }
    done
}

@test "parts: a 34 KB set arrives as four labelled parts, each under the cap, that rejoin byte for byte" {
    _seed_lines 380
    _fire_all
    local k joined=""
    for k in 1 2 3 4; do
        _ctx "$k"
        [ -n "$PART_TEXT" ] || { echo "part $k is empty"; return 1; }
        (( ${#PART_TEXT} < 10000 )) || { echo "part $k is ${#PART_TEXT} long, over the cap"; return 1; }
        [[ "$PART_TEXT" == *"This is PART $k OF 4 of the set, version "* ]] || { echo "part $k is not labelled $k of 4"; return 1; }
        joined="${joined}${PART_TEXT#*$'\n\n'}"
    done
    for k in 5 6; do
        [ ! -s "$TEST_TMPDIR/part$k.json" ] || { echo "part $k spoke on a four-part set"; return 1; }
    done
    _stored
    [ "${#joined}" -eq "${#STORED}" ] || { echo "rejoined ${#joined}, stored ${#STORED}"; return 1; }
    [ "$joined" = "$STORED" ] || { echo "the four parts do not rejoin to the stored set"; return 1; }
}

@test "parts: a set with no newline to cut at is cut hard, never inside a multibyte character" {
    {
        printf -- '- Pasted: '
        awk 'BEGIN { for (i = 0; i < 4000; i++) printf "\303\251\342\202\254\346\227\245 " }'
        printf '\n'
    } > "$CACHE"
    _seal
    _fire_all
    local k joined="" n=0 body
    local cont=$'^[\x80-\xbf]'
    for k in 1 2 3 4 5 6; do
        [ -s "$TEST_TMPDIR/part$k.json" ] || continue
        _ctx "$k" || { echo "part $k is not valid JSON"; return 1; }
        n=$(( n + 1 ))
        body="${PART_TEXT#*$'\n\n'}"
        joined="${joined}${body}"
        # Every part after the first must begin on the first byte of a character.
        if (( k > 1 )); then
            ( LC_ALL=C; [[ ! "$body" =~ $cont ]] ) || { echo "part $k starts inside a character"; return 1; }
        fi
    done
    (( n == 4 )) || { echo "expected 4 parts, got $n"; return 1; }
    _stored
    [ "$joined" = "$STORED" ] || { echo "the parts do not rejoin; a character was split or lost"; return 1; }
}

@test "parts: a set too large for six parts goes by reference, and the customer is told once per session" {
    _seed_lines 800
    _fire_all S1
    _ctx 1
    [[ "$PART_TEXT" == *"BEFORE YOU ANSWER, read this file in full"* ]] || { echo "part 1 does not tell the assistant to read the file"; return 1; }
    [[ "$PART_TEXT" == *"mmry-foundation.byref.S1.md"* ]] || { echo "part 1 does not name this session's copy: ${PART_TEXT:0:600}"; return 1; }
    [[ "$PART_TEXT" == *"permission"* ]] || { echo "part 1 does not say it may need permission"; return 1; }
    [[ "$PART_TEXT" != *"Directive 0001"* ]] || { echo "part 1 sent some of the set as well as the reference"; return 1; }
    (( ${#PART_TEXT} < 2000 )) || { echo "the reference is ${#PART_TEXT} long; it must fit a preview"; return 1; }
    jq -e '.systemMessage | test("larger than Claude Code lets a plugin show")' "$TEST_TMPDIR/part1.json" >/dev/null || { echo "the customer was not told"; return 1; }
    jq -e '.systemMessage | test("57,000") and test("permission")' "$TEST_TMPDIR/part1.json" >/dev/null || { echo "the notice lacks 57,000 or the permission warning: $(jq -r .systemMessage "$TEST_TMPDIR/part1.json")"; return 1; }
    local k
    for k in 2 3 4 5 6; do
        [ ! -s "$TEST_TMPDIR/part$k.json" ] || { echo "part $k spoke on a by-reference set"; return 1; }
    done
    # The next prompt points the assistant at the file again, but does not tell the customer again.
    _fire 1 S1
    _ctx 1
    [[ "$PART_TEXT" == *"BEFORE YOU ANSWER"* ]] || { echo "the second prompt lost the reference"; return 1; }
    if jq -e 'has("systemMessage")' "$TEST_TMPDIR/part1.json" >/dev/null; then echo "the customer was told twice"; return 1; fi
    CLAUDE_CODE_SESSION_ID=S1 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    BY REFERENCE on the most recent prompt"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

# #31411 QA round 2 R1, #31583 QA round 2 R3: the assistant was pointed at the live shared cache and
# told it was the complete, verified set, and a later write could replace it before it was opened.
# The file the assistant was told to read, from the text it was given, as a path this shell can open.
# Read from the payload, not by the name the copy is expected to have: a test that opens the copy by
# its own name cannot see the assistant being pointed somewhere else (mutation m27).
_pointed() {
    local p="${PART_TEXT#*made for this turn: }"
    p="${p%%$'\n'*}"
    command -v cygpath >/dev/null 2>&1 && p="$(cygpath -u "$p")"
    printf '%s' "$p"
}

@test "parts: by reference points at a copy of exactly the verified set, ending in the line the assistant must reach" {
    _seed_lines 800
    _fire_all S1
    _ctx 1
    local snap v
    snap="$(_pointed)"
    [ "$snap" -ef "$TEST_TMPDIR/mmry-foundation.byref.S1.md" ] || { echo "the assistant was pointed at [$snap], not this session's copy"; return 1; }
    [ -f "$snap" ] || { echo "no copy was made for this turn"; return 1; }
    v="$(cat "${CACHE}.manifest")"; v="${v##*cksum=}"; v="${v%%[!0-9]*}"
    # The closing line names this version of the set, and the assistant is told to reach it.
    [ "$(tail -n 1 "$snap")" = "END OF FOUNDATION SET $v" ] || { echo "last line: [$(tail -n 1 "$snap")]"; return 1; }
    [[ "$PART_TEXT" == *"Its last line is \"END OF FOUNDATION SET $v\""* ]] || { echo "the assistant is not told the closing line"; return 1; }
    # Everything before the closing line is the stored set, byte for byte.
    cmp -s <(head -c "$(wc -c < "$CACHE" | tr -d ' ')" "$snap") "$CACHE" || { echo "the copy differs from the stored set"; return 1; }
}

@test "parts: the copy the assistant was pointed at survives the cache being replaced after the turn" {
    _seed_lines 800
    _fire 1 S1
    _ctx 1
    local snap
    snap="$(_pointed)"
    [ -f "$snap" ] || { echo "the assistant was pointed at [$snap], which is not a file"; return 1; }
    cp "$snap" "$TEST_TMPDIR/snap-before"
    # Another session starts, or the daily refresh runs: the shared cache becomes a different set.
    awk 'BEGIN { for (i = 1; i <= 800; i++) printf "- Directive %04d: a DIFFERENT set written after the turn began.\n", i }' > "$CACHE"
    _seal
    cmp -s "$snap" "$TEST_TMPDIR/snap-before" || { echo "the copy for this turn changed under the assistant"; return 1; }
    run grep -c 'DIFFERENT' "$snap"
    [ "$output" = "0" ]
}

@test "parts: each session has its own copy, so one session's turn never rewrites another's" {
    _seed_lines 800
    _fire 1 SA
    cp "$TEST_TMPDIR/mmry-foundation.byref.SA.md" "$TEST_TMPDIR/sa-before"
    awk 'BEGIN { for (i = 1; i <= 800; i++) printf "- Directive %04d: the set session B sees, long enough to need more than six parts.\n", i }' > "$CACHE"
    _seal
    _fire 1 SB
    [ -f "$TEST_TMPDIR/mmry-foundation.byref.SB.md" ] || { echo "session B has no copy"; return 1; }
    cmp -s "$TEST_TMPDIR/mmry-foundation.byref.SA.md" "$TEST_TMPDIR/sa-before" || { echo "session B rewrote session A's copy"; return 1; }
}

@test "parts: a set replaced while its copy is being made sends nothing, and says to re-send" {
    _seed_lines 800
    # A cp that copies something other than what was verified: the case of a new set landing between
    # the check and the copy, made deterministic.
    mkdir -p "$TEST_TMPDIR/shim"
    # The shim takes its own directory off PATH first, or its cp would find itself and never return.
    printf '%s\n' '#!/usr/bin/env bash' 'PATH="${PATH#*:}"' 'src="${@: -2:1}"; dst="${@: -1}"' 'cp "$src" "$dst" && printf "%s\n" "- Directive 9999: appended by the shim." >> "$dst"' > "$TEST_TMPDIR/shim/cp"
    chmod +x "$TEST_TMPDIR/shim/cp"
    PATH="$TEST_TMPDIR/shim:$PATH" _fire 1 S9
    _ctx 1
    [[ "$PART_TEXT" != *"BEFORE YOU ANSWER"* ]] || { echo "it pointed the assistant at a copy that did not match"; return 1; }
    jq -e '.systemMessage | test("NOT applied") and test("Re-send the prompt")' "$TEST_TMPDIR/part1.json" >/dev/null || { echo "$(jq -r .systemMessage "$TEST_TMPDIR/part1.json")"; return 1; }
    if jq -e '.systemMessage | test("load-memories")' "$TEST_TMPDIR/part1.json" >/dev/null; then echo "it prescribed a rebuild for a set that was only being replaced"; return 1; fi
    [ ! -e "$TEST_TMPDIR/mmry-foundation.byref.S9.md" ] || { echo "a mismatched copy was left in place"; return 1; }
}

@test "parts: the status says IN FULL in four parts only while all four arrived, and PARTLY when one did not" {
    _seed_lines 380
    _fire_all S2
    CLAUDE_CODE_SESSION_ID=S2 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt, in 4 parts."* ]] || { echo "$output"; return 1; }
    # Part 3 of the next prompt runs out of time.
    _rec S2 3 'failed deadline 10'
    CLAUDE_CODE_SESSION_ID=S2 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3: loading them took longer than the 10s limit and was stopped."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: a part killed before it finished is reported, never counted as arrived" {
    _seed_lines 380
    _fire_all S3
    # What a killed firing leaves behind: its in-flight marker.
    : > "$TEST_TMPDIR/.mmry-foundation-inflight.S3.4"
    CLAUDE_CODE_SESSION_ID=S3 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    PARTLY on the most recent prompt - 3 of 4 parts arrived; part 4 was stopped before it finished."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

# 31583 R4(b), QA's paired control on a real Mac: a failure and a delivery a moment apart. The
# status used to order them by file time, in whole seconds, so a failure in the same second as a
# delivery read as IN FULL. Here the file times are made to lie both ways, and the answer must
# follow what happened last, not what the clock says.
@test "parts: a failure straight after a delivery reads NOT, and a delivery straight after a failure reads IN FULL" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"; _seal
    # With no config the client never runs jq, and a slow jq would delay nothing.
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"test-key","foundationReinject":"true","foundationRefreshSeconds":0}\n' > "$MMRY_CONFIG_FILE"
    local slow="$TEST_TMPDIR/slow-jq.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done' 'sleep 20' 'exec jq "$@"' > "$slow"
    chmod +x "$slow"

    _fire 1 S4
    MMRY_JQ="$slow" MMRY_FOUNDATION_DEADLINE_SECS=1 _fire 1 S4
    grep -q 'NOT applied' "$TEST_TMPDIR/part1.json" || { echo "control: the slow firing did not fail: $(head -c 300 "$TEST_TMPDIR/part1.json")"; return 1; }
    # The delivery record made to look newer than the failure.
    touch "$TEST_TMPDIR/mmry-foundation.status.S4"
    CLAUDE_CODE_SESSION_ID=S4 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    NOT on the most recent prompt - loading them took longer than the 1s limit and was stopped."* ]] || { echo "after the failure: $output"; return 1; }

    _fire 1 S4
    # The failure log made to look newer than the delivery.
    touch "$TEST_TMPDIR/mmry-foundation.log"
    CLAUDE_CODE_SESSION_ID=S4 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt."* ]] || { echo "after the recovery: $output"; return 1; }
    [[ "$output" != *"NOT on the most recent prompt"* ]]
}

# 31583 R4(c): two sessions sharing one temp directory never see each other's delivery.
@test "parts: another session's delivery is never reported as this session's" {
    printf -- '- Identity: Eric builds MMRY.\n' > "$CACHE"; _seal
    _fire_all SA
    CLAUDE_CODE_SESSION_ID=SA run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL"* ]] || { echo "control: SA should see its own delivery: $output"; return 1; }
    CLAUDE_CODE_SESSION_ID=SB run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    nothing yet in this session."* ]] || { echo "SB was shown SA's delivery: $output"; return 1; }
    [[ "$output" == *"Last sent:    nothing yet in this session."* ]] || { echo "SB was shown SA's last send: $output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

# ============================================================================
# #31411 QA round 2: R1 (sets that fit in six parts went by reference) and TC3 (a memory longer
# than a part was cut mid-sentence).
# ============================================================================

# Characters as Claude Code counts them, UTF-16 units, from the bytes, with tr and wc so it runs on
# macOS as well: bytes, less continuation bytes, plus one for each four-byte character.
_units() {
    local b c a
    b="$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')"
    c="$(printf '%s' "$1" | LC_ALL=C tr -cd '\200-\277' | wc -c | tr -d ' ')"
    a="$(printf '%s' "$1" | LC_ALL=C tr -cd '\360-\367' | wc -c | tr -d ' ')"
    printf '%s' "$(( b - c + a ))"
}

# Fire every part for the staged set and check: n parts inline, labelled, each under the cap in
# characters, rejoining to exactly the set. Sets PART_COUNT.
_assert_inline_whole() {
    local want_n="$1" k joined="" u
    _fire_all "${2:-}"
    PART_COUNT=0
    for k in 1 2 3 4 5 6; do
        [ -s "$TEST_TMPDIR/part$k.json" ] || continue
        _ctx "$k"
        [[ "$PART_TEXT" != *"BEFORE YOU ANSWER"* ]] || { echo "went by reference"; return 1; }
        u="$(_units "${PART_TEXT#*$'\n\n'}")"
        (( u <= 9500 )) || { echo "part $k holds $u characters of the set, over 9,500"; return 1; }
        (( $(_units "$PART_TEXT") < 10000 )) || { echo "part $k is over 10,000 characters"; return 1; }
        joined="${joined}${PART_TEXT#*$'\n\n'}"
        PART_COUNT=$(( PART_COUNT + 1 ))
    done
    [ "$PART_COUNT" -eq "$want_n" ] || { echo "expected $want_n parts, got $PART_COUNT"; return 1; }
    _stored
    [ "$joined" = "$STORED" ] || { echo "the parts do not rejoin to the stored set"; return 1; }
}

@test "parts: #31411 R1 seven long memories that fit in four parts are not sent by reference" {
    # QA's case: seven memories of about 5,000 characters, one line each, 35,147 bytes. Pulling
    # every part back to a line end made each one memory long, so it needed seven parts.
    awk 'BEGIN { for (m = 1; m <= 7; m++) { printf "- Memory %d: ", m; for (j = 0; j < 95; j++) printf "This is sentence %d of memory %d and it has words. ", j, m; printf "\n" } }' > "$CACHE"
    _seal
    _assert_inline_whole 4
}

@test "parts: #31411 R1 a 24,700-character Japanese set is sent inline, counted in characters, not bytes" {
    # Three bytes a character: about 74,000 bytes, which counted in bytes needs eight parts and went
    # by reference. Claude Code counts characters (measured 2026-10-04), and it fits in three.
    awk 'BEGIN { printf "- "; for (i = 0; i < 24698; i++) { if (i % 31 == 30) printf "\343\200\202"; else printf "\346\227\245" } printf "\n" }' > "$CACHE"
    _seal
    _assert_inline_whole 3
}

# The decoded additionalContext of part $1, carriage returns KEPT. For a fixture that holds them on
# purpose: _ctx strips them, because a native Windows jq adds one to every newline it prints, so
# here jq is asked not to (-b, binary output; jq builds on other platforms accept it and print the
# same bytes either way).
_ctx_raw() {
    PART_TEXT="$( { jq -b -j '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part$1.json" 2>/dev/null \
        || jq -j '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part$1.json"; } && printf '.')" || return 1
    PART_TEXT="${PART_TEXT%.}"
}

@test "parts: #31411 R1 a non-ASCII set written with CRLF, as Windows jq writes it, goes inline and loses no byte" {
    # QA round 3 (2026-10-05): on Windows both the bundled jq 1.7.1 and the system jq 1.8.2 write the
    # cache with CRLF. gawk, reading foundation-cut.awk's input in text mode, dropped every CR, so
    # the cut lengths summed short of the set, the whole-set check failed, and the hook fell back to
    # the byte cut, which needs more than six parts for non-ASCII text: every non-ASCII set of two or
    # more memories went BY REFERENCE on every Windows install. Five memories of Japanese, about
    # 24,500 characters and 73,500 bytes, each line ending CRLF.
    awk 'BEGIN { for (m = 1; m <= 5; m++) { printf "- M%d: ", m; for (i = 0; i < 4900; i++) { if (i % 31 == 30) printf "\343\200\202"; else printf "\346\227\245" } printf "\r\n" } }' > "$CACHE"
    _seal
    _stored
    [[ "$STORED" == *$'\r\n- M2'* ]] || { echo "control: the fixture does not hold CRLF line ends"; return 1; }

    _fire_all
    local k joined="" n=0
    for k in 1 2 3 4 5 6; do
        [ -s "$TEST_TMPDIR/part$k.json" ] || continue
        _ctx_raw "$k"
        [[ "$PART_TEXT" != *"BEFORE YOU ANSWER"* ]] || { echo "went by reference"; return 1; }
        (( $(_units "$PART_TEXT") < 10000 )) || { echo "part $k is over 10,000 characters"; return 1; }
        joined="${joined}${PART_TEXT#*$'\n\n'}"
        n=$(( n + 1 ))
    done
    (( n >= 2 && n <= 6 )) || { echo "expected 2 to 6 parts inline, got $n"; return 1; }
    [ "$joined" = "$STORED" ] || {
        echo "the parts do not rejoin to the stored set: $(printf '%s' "$joined" | LC_ALL=C wc -c) of $(printf '%s' "$STORED" | LC_ALL=C wc -c) bytes"
        return 1
    }
}

@test "parts: #31411 R1 a character outside the Basic Multilingual Plane counts as two" {
    # 15,000 emoji: 60,000 bytes, too many for six parts counted in bytes, so they are counted in
    # characters - and an emoji is two characters to Claude Code, as to JavaScript. Counted as one,
    # a part would hold 19,000 and be cut to a preview.
    awk 'BEGIN { printf "- "; for (i = 0; i < 15000; i++) printf "\360\237\230\200"; printf "\n" }' > "$CACHE"
    _seal
    _assert_inline_whole 4
}

@test "parts: #31411 TC3 a memory longer than a part is cut at a sentence end, never mid-word" {
    printf -- '- Long: %s\n' "$(awk 'BEGIN { for (j = 0; j < 400; j++) printf "Sentence number %d is here to make the memory long enough. ", j }')" > "$CACHE"
    _seal
    _fire_all
    local k n=0 last=""
    for k in 1 2 3 4 5 6; do
        [ -s "$TEST_TMPDIR/part$k.json" ] || continue
        n=$(( n + 1 ))
        _ctx "$k"; last="$PART_TEXT"
        # Every part but the last must end exactly at a sentence end, with its space.
        [ -s "$TEST_TMPDIR/part$(( k + 1 )).json" ] || continue
        [[ "$PART_TEXT" == *'long enough. ' ]] || { echo "part $k ends mid-sentence: [${PART_TEXT: -40}]"; return 1; }
    done
    (( n >= 2 )) || { echo "control: the memory was not long enough to need two parts"; return 1; }
}

@test "parts: #31411 TC3 when parts are filled to fit, each is still cut at a sentence end" {
    # QA round 3 (2026-10-05): QA's seven memories of about 5,000 characters need the fill cut to fit
    # in four parts, and the fill cut pulled back only to a space, so every boundary fell
    # mid-sentence, including inside a memory, with a sentence end 70 characters back. It now takes
    # the last line end or sentence end in a part's last 400 bytes before falling back to a space.
    awk 'BEGIN { for (m = 1; m <= 7; m++) { printf "- Memory %d: ", m; for (j = 0; j < 95; j++) printf "This is sentence %d of memory %d and it has words. ", j, m; printf "\n" } }' > "$CACHE"
    _seal
    _assert_inline_whole 4
    local k
    for k in 1 2 3; do
        _ctx "$k"
        [[ "$PART_TEXT" == *'has words. ' || "$PART_TEXT" == *$'\n' ]] \
            || { echo "part $k ends mid-sentence: [${PART_TEXT: -60}]"; return 1; }
    done
}

@test "parts: #31411 TC3 the same holds for a non-ASCII set, cut by foundation-cut.awk" {
    # The same seven memories with one accented word each, so the hook hands them to the awk cut.
    awk 'BEGIN { for (m = 1; m <= 7; m++) { printf "- Memory %d caf\303\251: ", m; for (j = 0; j < 95; j++) printf "This is sentence %d of memory %d and it has words. ", j, m; printf "\n" } }' > "$CACHE"
    _seal
    _assert_inline_whole 4
    local k
    for k in 1 2 3; do
        _ctx "$k"
        [[ "$PART_TEXT" == *'has words. ' || "$PART_TEXT" == *$'\n' ]] \
            || { echo "part $k ends mid-sentence: [${PART_TEXT: -60}]"; return 1; }
    done
}

@test "parts: #31411 the cut in bash and the cut in foundation-cut.awk agree, part for part" {
    # The hook cuts a plain ASCII set itself and hands anything else to foundation-cut.awk. The two
    # must make the same cuts, or what a set receives would depend on one accented letter. Checked on
    # a set the tidy cut handles and one that needs the fuller cut.
    local which lens k want
    for which in lines long; do
        if [[ "$which" == lines ]]; then
            _seed_lines 380
        else
            awk 'BEGIN { for (m = 1; m <= 7; m++) { printf "- Memory %d: ", m; for (j = 0; j < 95; j++) printf "This is sentence %d of memory %d and it has words. ", j, m; printf "\n" } }' > "$CACHE"; _seal
        fi
        _stored
        lens="$(LC_ALL=C awk -v cap=9500 -v max=6 -f "$PLUGIN_ROOT/hooks-handlers/foundation-cut.awk" <<<"$STORED" | tr '\n' ' ')"
        _fire_all
        want=""
        for k in 1 2 3 4 5 6; do
            [ -s "$TEST_TMPDIR/part$k.json" ] || continue
            _ctx "$k"
            want="${want}$(printf '%s' "${PART_TEXT#*$'\n\n'}" | LC_ALL=C wc -c | tr -d ' ') "
        done
        [ "$lens" = "$want" ] || { echo "$which: awk cut [$lens], hook cut [$want]"; return 1; }
    done
}

@test "parts: #31411 the largest part there can be, with the cut-short note, is still under 10,000 characters" {
    # The worst case, measured rather than reasoned about: the largest part the cut can make (a set
    # with no blank, cut hard at 9,500 characters) and the note added when the previous firing of
    # that part was cut short. Claude Code swaps anything over 10,000 for a 2,000-character preview.
    { printf -- '- Pasted: '; awk 'BEGIN { for (i = 0; i < 30000; i++) printf "x" }'; printf '\n'; } > "$CACHE"
    _seal
    _fire 2 S8
    _ctx 2
    local plain; plain="$(_units "$PART_TEXT")"
    : > "$TEST_TMPDIR/.mmry-foundation-inflight.S8.2"
    _fire 2 S8
    _ctx 2
    [[ "$PART_TEXT" == *'PREVIOUS turn'* ]] || { echo "control: the cut-short note was not added"; return 1; }
    local worst; worst="$(_units "$PART_TEXT")"
    echo "part 2: ${plain} characters plain, ${worst} with the note" >&3
    (( plain >= 9500 )) || { echo "control: part 2 was not a full-size part ($plain)"; return 1; }
    (( worst < 10000 ))
}

# ============================================================================
# #31583 QA round 2, R4: tie every part's record to the set and to the prompt. If the set changes
# while a prompt's parts are firing - the daily refresh, another session starting - the status could
# say IN FULL when a part did not arrive, or when the parts came from two versions.
# ============================================================================

_version() { local v; v="$(cat "${CACHE}.manifest")"; v="${v##*cksum=}"; printf '%s' "${v%%[!0-9]*}"; }

@test "parts: #31583 R4 every part names the version of the set it was cut from, and so does its record" {
    _seed_lines 380
    local v; v="$(_version)"
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "no checksum in the manifest"; return 1; }
    _fire_all S6
    local k
    for k in 1 2 3 4; do
        _ctx "$k"
        [[ "$PART_TEXT" == *"This is PART $k OF 4 of the set, version $v."* ]] || { echo "part $k does not name version $v: ${PART_TEXT:0:420}"; return 1; }
        [[ "$(cat "$(_outcome_file S6 "$k")")" =~ ^S6\ [0-9]+\ ok\ part\ $k\ of\ 4\ set\ $v$ ]] || { echo "part $k record: $(cat "$(_outcome_file S6 "$k")")"; return 1; }
    done
}

@test "parts: #31583 R4 a prompt whose parts came from two versions of the set is PARTLY, never IN FULL" {
    _seed_lines 380
    _fire 1 S7; _fire 2 S7
    # Replaced between the firings of one prompt: a different set of the same shape.
    awk 'BEGIN { for (i = 1; i <= 380; i++) printf "- Directive %04d: a REPLACED set, every line of it different from the first one.\n", i }' > "$CACHE"
    _seal
    _fire 3 S7; _fire 4 S7
    _one_prompt S7
    _ctx 3
    [[ "$PART_TEXT" == *'REPLACED'* ]] || { echo "control: part 3 did not come from the new set"; return 1; }
    CLAUDE_CODE_SESSION_ID=S7 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    PARTLY on the most recent prompt - 2 of 4 parts arrived; part 3 came from a different version of the set"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 R4 a part with nothing to send records none, so an earlier prompt's record never counts" {
    # Prompt 1 delivers a four-part set in full, leaving a record for every part.
    _seed_lines 380
    _fire_all S10
    CLAUDE_CODE_SESSION_ID=S10 run bash "$STATUSCMD"
    [[ "$output" == *"IN FULL on the most recent prompt, in 4 parts"* ]] || { echo "control: $output"; return 1; }
    # Prompt 2: parts 1 and 2 see the same set, then it is replaced by a one-part set before parts 3
    # and 4 fire, so they leave at once with nothing to send. Their prompt-1 records name the same
    # version as part 1's, so only the "none" they now write keeps them from counting.
    _fire 1 S10; _fire 2 S10
    printf -- '- Identity: a small set now.\n' > "$CACHE"; _seal
    _fire 3 S10; _fire 4 S10
    _one_prompt S10
    [[ "$(cat "$(_outcome_file S10 3)")" =~ ^S10\ [0-9]+\ none$ ]] || { echo "part 3 record: $(cat "$(_outcome_file S10 3)")"; return 1; }
    CLAUDE_CODE_SESSION_ID=S10 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    PARTLY on the most recent prompt - 2 of 4 parts arrived; part 3 has no record of arriving; part 4 has no record of arriving."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 the status fails closed on a record it does not recognise" {
    _seed_lines 380
    _fire_all S11
    printf 'S11 ok, trust me' > "$(_outcome_file S11 1)"
    CLAUDE_CODE_SESSION_ID=S11 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    UNKNOWN for the most recent prompt"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 the status refuses a part count above six" {
    _seed_lines 380
    _fire_all S12
    local v; v="$(_version)"
    _rec S12 1 "ok part 1 of 7 set $v"
    CLAUDE_CODE_SESSION_ID=S12 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    UNKNOWN for the most recent prompt"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 the PARTLY advice follows the cause of the part that did not arrive" {
    _seed_lines 380
    _fire_all S13
    # Part 3's loader crashed: the hook tells the customer re-sending will not help, and so must this.
    _rec S13 3 'failed crash'
    CLAUDE_CODE_SESSION_ID=S13 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3: the loader failed before it finished"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Action:       re-sending will not help."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 a marker that is not a regular file is still a marker: the part was cut short" {
    _seed_lines 380
    _fire_all S14
    mkdir -p "$TEST_TMPDIR/.mmry-foundation-inflight.S14.3"
    CLAUDE_CODE_SESSION_ID=S14 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3 was stopped before it finished"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 a record that is not a regular file is not read, and the answer is UNKNOWN" {
    _seed_lines 380
    _fire_all S15
    rm -f "$(_outcome_file S15 1)"; mkdir -p "$(_outcome_file S15 1)"
    CLAUDE_CODE_SESSION_ID=S15 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    UNKNOWN for the most recent prompt"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31411 a part that fails names itself and does not say the whole turn went without" {
    _seed_lines 380
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"test-key","foundationReinject":"true","foundationRefreshSeconds":0}\n' > "$MMRY_CONFIG_FILE"
    local slow="$TEST_TMPDIR/slow-jq.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done' 'sleep 20' 'exec jq "$@"' > "$slow"
    chmod +x "$slow"
    MMRY_JQ="$slow" MMRY_FOUNDATION_DEADLINE_SECS=1 _fire 3 S16
    local ctx msg
    ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part3.json")"
    msg="$(jq -r '.systemMessage // ""' "$TEST_TMPDIR/part3.json")"
    [[ "$ctx" == *"could not load PART 3 of this account"* ]] || { echo "assistant: $ctx"; return 1; }
    [[ "$ctx" != *"running WITHOUT the account's standing directives"* ]] || { echo "part 3 told the assistant the whole turn went without"; return 1; }
    [[ "$msg" == *"part 3 of your Foundation directives was NOT applied"* ]] || { echo "customer: $msg"; return 1; }
}

# #31411 QA round 2: the "customer was told" marker is named by the session. With one shared marker
# holding the last session told, two sessions taking turns each overwrote it, and a session was told
# again on every prompt that followed one from the other.
@test "parts: #31411 a by-reference set is announced once per session even while another session takes turns" {
    _seed_lines 800
    _fire 1 SA
    jq -e 'has("systemMessage")' "$TEST_TMPDIR/part1.json" >/dev/null || { echo "control: session A was not told"; return 1; }
    _fire 1 SB
    jq -e 'has("systemMessage")' "$TEST_TMPDIR/part1.json" >/dev/null || { echo "session B was never told"; return 1; }
    _fire 1 SA
    if jq -e 'has("systemMessage")' "$TEST_TMPDIR/part1.json" >/dev/null; then echo "session A was told a second time"; return 1; fi
    _ctx 1
    [[ "$PART_TEXT" == *"BEFORE YOU ANSWER"* ]] || { echo "session A's assistant lost the reference"; return 1; }
}

# QA #2's H7 (#31411 QA round 2, handback 3 of 4). A part k > 1 leaves without reading the set when
# the set is too small to have a part k. A part cut at a line end can be little over half the cap, so
# the bound is half a part per part; assuming full parts drops the last parts of such a set silently.
@test "parts: #31411 a set cut into parts just over half the cap still sends every part" {
    # Five lines of 4,800 bytes. Each newline is in the second half of its window, so each part is
    # one line: five parts for 24,000 bytes, where full parts would need three.
    awk 'BEGIN { for (m = 1; m <= 5; m++) { s = sprintf("- Memory %d:", m); while (length(s) < 4799) s = s " word"; printf "%s\n", substr(s, 1, 4799) } }' > "$CACHE"
    _seal
    _assert_inline_whole 5 S18
    CLAUDE_CODE_SESSION_ID=S18 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt, in 5 parts."* ]] || { echo "$output"; return 1; }
}

# QA #2's H9 (#31583 QA round 2, handback 3 of 4). A part 2 to 6 that fails records why, so the status
# names the part and the cause instead of a part with no record.
@test "parts: #31583 a part 2-6 that runs out of time records it, and the status names the part and the cause" {
    _seed_lines 380
    _fire 1 S17; _fire 2 S17; _fire 4 S17
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"test-key","foundationReinject":"true","foundationRefreshSeconds":0}\n' > "$MMRY_CONFIG_FILE"
    local slow="$TEST_TMPDIR/slow-jq.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [[ "$a" == "--version" ]] && exec jq "$@"; done' 'sleep 20' 'exec jq "$@"' > "$slow"
    chmod +x "$slow"
    MMRY_JQ="$slow" MMRY_FOUNDATION_DEADLINE_SECS=1 _fire 3 S17
    _one_prompt S17
    CLAUDE_CODE_SESSION_ID=S17 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3: loading them took longer than the 1s limit and was stopped."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"has no record"* ]] || { echo "$output"; return 1; }
}

# ---- #31411 QA round 3: N2 (a FIFO where the hook writes) and F7 (a dot in a session id) -------

# Runs "$@" in the background and waits up to $1 seconds. 0 if it finished, 1 if it was still running,
# in which case it is killed. Portable: no timeout(1), which a stock Mac does not have.
_finishes_within() {
    local secs="$1" pid i; shift
    "$@" & pid=$!
    for (( i = 0; i < secs * 10; i++ )); do
        if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null; return 0; fi
        sleep 0.1
    done
    kill "$pid" 2>/dev/null
    return 1
}

# Opens a FIFO for reading and writing at once, which never blocks, so a hook stuck on it is released.
_release_fifo() { [[ -p "$1" ]] && { exec 9<>"$1"; exec 9>&-; } ; rm -f "$1"; }

@test "parts: #31411 N2 a FIFO at the by-reference marker does not hang the hook, and the customer is still told" {
    # QA round 3: by reference records that the customer has been told this session. A FIFO planted
    # at that marker blocked the write, and with it the whole hook, outside any deadline.
    _seed_lines 800
    local fifo="$TEST_TMPDIR/.mmry-foundation-byref-told.N2S"
    mkfifo "$fifo"
    _finishes_within 25 _fire 1 N2S || { _release_fifo "$fifo"; echo "the hook hung on the FIFO"; return 1; }
    _ctx 1
    [[ "$PART_TEXT" == *"BEFORE YOU ANSWER"* ]] || { echo "part 1 lost the reference: ${PART_TEXT:0:200}"; return 1; }
    jq -e '.systemMessage | test("larger than Claude Code lets a plugin show")' "$TEST_TMPDIR/part1.json" >/dev/null \
        || { echo "the customer was not told"; return 1; }
    [[ -f "$fifo" && ! -p "$fifo" ]] || { echo "the marker is still not a regular file"; _release_fifo "$fifo"; return 1; }
}

@test "parts: #31411 N2 a FIFO at the log does not hang a refusal, and the refusal still reaches the customer" {
    # The log is written when the cache is refused or the loader fails. A FIFO there blocked that
    # write, so a damaged set hung the hook instead of being reported.
    _seed_lines 3
    printf -- '- x\n' > "$CACHE"      # the stub #31583 is about, against the manifest of the real set
    local fifo="$TEST_TMPDIR/mmry-foundation.log"
    mkfifo "$fifo"
    _finishes_within 25 _fire 1 N2L || { _release_fifo "$fifo"; echo "the hook hung on the FIFO"; return 1; }
    jq -e '.systemMessage | test("NOT applied")' "$TEST_TMPDIR/part1.json" >/dev/null \
        || { echo "the refusal did not reach the customer: $(cat "$TEST_TMPDIR/part1.json")"; _release_fifo "$fifo"; return 1; }
    [[ -p "$fifo" ]] || { echo "control: the FIFO was replaced, so this proves nothing about writing past it"; return 1; }
    _release_fifo "$fifo"
}

@test "parts: #31411 F7 a session id with a dot is no session id, so it cannot name another session's part" {
    # QA round 3: records are named <name>.<session id>.<part>, so the session "S7.2" wrote its part 1
    # record to exactly the file session "S7" uses for part 2. A dot is not accepted in a session id;
    # Claude Code and Codex send ids without one.
    _seed_lines 3
    _fire 1 S7.2
    [ ! -e "$TEST_TMPDIR/mmry-foundation.outcome.S7.2" ] || { echo "S7.2 wrote S7's part-2 record"; return 1; }
    # CONTROL: an ordinary id names its own record.
    _fire 1 S7
    [ -f "$TEST_TMPDIR/mmry-foundation.outcome.S7" ] || { echo "control: S7 did not write its own record"; return 1; }
    # And the shared helper agrees.
    run bash -c 'source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1; printf "[%s][%s]" "$(mmry_foundation_sid S7.2)" "$(mmry_foundation_sid S7)"' _ "$PLUGIN_ROOT"
    [ "$output" = "[][S7]" ] || { echo "mmry_foundation_sid gave $output"; return 1; }
}

# ============================================================================
# #31583 QA round 3: every record tied to its prompt (R4(a)), every exit recorded (R4(b)), a part 2-6
# refusal told on the turn (R3, architecture P4), the by-reference copy (a directory at its path, a copy
# that cannot be written), and a session id the hook finds late in the payload (P8).
# ============================================================================

@test "parts: #31583 R4(a) a part that never runs on the most recent prompt is not counted from an earlier one" {
    _seed_lines 380
    _fire_all S40
    _age S40 60
    # The next prompt: part 3 never runs. Its record still says "ok part 3 of 4" for the same set.
    _fire 1 S40 & _fire 2 S40 & _fire 4 S40 & _fire 5 S40 & _fire 6 S40 & wait
    CLAUDE_CODE_SESSION_ID=S40 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3 has no record of arriving."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 R4(a) a prompt on which part 1 never runs is not delivered, whatever part 1 recorded before" {
    _seed_lines 380
    _fire_all S41
    _age S41 60
    _fire 2 S41 & _fire 3 S41 & _fire 4 S41 & _fire 5 S41 & _fire 6 S41 & wait
    CLAUDE_CODE_SESSION_ID=S41 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    NOT on the most recent prompt - part 1 of your directives has no record of arriving on it."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 R4(a) the hook's own start times tell two prompts apart" {
    # No record is edited here: the second prompt starts more than the status's 3 s apart from the first.
    _seed_lines 380
    _fire_all S42
    CLAUDE_CODE_SESSION_ID=S42 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt, in 4 parts."* ]] || { echo "control: $output"; return 1; }
    sleep 5
    _fire 1 S42 & _fire 2 S42 & _fire 4 S42 & wait
    CLAUDE_CODE_SESSION_ID=S42 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3 has no record of arriving."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 R4(b) a part whose loader cannot even start records a failure, and the customer is told" {
    _seed_lines 380
    _fire_all S43
    # A plugin install missing its client: the worker could not load it and used to leave in silence.
    local broken="$TEST_TMPDIR/broken-plugin"
    mkdir -p "$broken"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$broken/"
    rm -f "$broken/hooks-handlers/mmry-client.sh"
    printf '{"session_id":"S43","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' \
        | bash "$broken/hooks-handlers/userpromptsubmit-foundation.sh" --part 3 > "$TEST_TMPDIR/part3.json" 2>/dev/null
    jq -e '.systemMessage | test("part 3 of your Foundation directives was NOT applied")' "$TEST_TMPDIR/part3.json" >/dev/null \
        || { echo "the customer was not told: $(cat "$TEST_TMPDIR/part3.json")"; return 1; }
    # Part 3 was fired after the other five to stage this prompt; on a busy machine that can be more
    # than the status's 3 s apart, so the firings are stood in for one prompt (#31411 QA round 4).
    _one_prompt S43
    CLAUDE_CODE_SESSION_ID=S43 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3: the loader failed before it finished."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 R4(b) a part whose loader finds an empty set replaces its record, so the previous prompt's never stands" {
    _seed_lines 380
    _fire_all S44
    # Architecture's 2b: the set is now verified empty, under a record whose byte count still reaches
    # part 3, so part 3 runs its loader, which finds nothing to send. That exit used to write nothing.
    : > "$CACHE"
    printf 'mmry-foundation v1 entries=0 bytes=40000 cksum=0
' > "${CACHE}.manifest"
    _fire 3 S44
    [[ "$(cat "$(_outcome_file S44 3)")" =~ ^S44\ [0-9]+\ none$ ]] || { echo "part 3 record: $(cat "$(_outcome_file S44 3)")"; return 1; }
}

@test "parts: #31583 R4(b) a loader that leaves in silence leaves a failure on the record, not the previous prompt's delivery" {
    _seed_lines 380
    _fire_all S52
    # Any loader that exits cleanly having said nothing: here the bash it is started with does exactly
    # that. The record written when the part started has to stand.
    local real_bash shim
    real_bash="$(command -v bash)"
    shim="$TEST_TMPDIR/silent-bash"
    mkdir -p "$shim"
    printf '#!/bin/sh\nexit 0\n' > "$shim/bash"
    chmod +x "$shim/bash"
    printf '{"session_id":"S52","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' \
        | PATH="$shim:$PATH" "$real_bash" "$HOOK" --part 3 > "$TEST_TMPDIR/part3.json" 2>/dev/null
    [[ "$(cat "$(_outcome_file S52 3)")" =~ ^S52\ [0-9]+\ failed\ unfinished$ ]] || { echo "part 3 record: $(cat "$(_outcome_file S52 3)")"; return 1; }
    # Part 3 was fired after the other five to stage this prompt; on a busy machine that can be more
    # than the status's 3 s apart, so the firings are stood in for one prompt (#31411 QA round 4).
    _one_prompt S52
    CLAUDE_CODE_SESSION_ID=S52 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3: the loader ended without recording what it sent."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 R4(b) a part whose output cannot be handed over records that, never the previous delivery" {
    _seed_lines 380
    _fire_all S45
    # Standard output closed: the part prepares its text and the hand-over to Claude Code fails.
    printf '{"session_id":"S45","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' \
        | bash "$HOOK" --part 3 >&- 2>/dev/null
    [[ "$(cat "$(_outcome_file S45 3)")" =~ ^S45\ [0-9]+\ failed\ emit$ ]] || { echo "part 3 record: $(cat "$(_outcome_file S45 3)")"; return 1; }
    # Part 3 was fired after the other five to stage this prompt; on a busy machine that can be more
    # than the status's 3 s apart, so the firings are stood in for one prompt (#31411 QA round 4).
    _one_prompt S45
    CLAUDE_CODE_SESSION_ID=S45 run bash "$STATUSCMD"
    [[ "$output" == *"PARTLY on the most recent prompt - 3 of 4 parts arrived; part 3: they were prepared but could not be handed to Claude Code."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 R3 a part 2-6 that refuses tells the assistant and the customer on that turn, naming the part" {
    # Part 3 finds a stub where the set was, against the record of the real set.
    _seed_lines 380
    printf -- '- x\n' > "$CACHE"
    _fire 3 S46
    local ctx msg
    ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part3.json")"
    msg="$(jq -r '.systemMessage // ""' "$TEST_TMPDIR/part3.json")"
    [[ "$ctx" == *"could not verify PART 3 of this account's FOUNDATION directives"* ]] || { echo "assistant: $ctx"; return 1; }
    [[ "$ctx" != *"running WITHOUT the account's standing directives"* ]] || { echo "part 3 told the assistant the whole turn went without"; return 1; }
    [[ "$msg" == *"part 3 of your Foundation directives was NOT applied"* ]] || { echo "customer: $msg"; return 1; }
    [[ "$(cat "$(_outcome_file S46 3)")" =~ ^S46\ [0-9]+\ failed\ refused\ [a-z-]+$ ]] || { echo "part 3 record: $(cat "$(_outcome_file S46 3)")"; return 1; }
}

@test "parts: #31411 a directory at the by-reference copy path is reported, and the assistant is not pointed at it" {
    _seed_lines 800
    local snap="$TEST_TMPDIR/mmry-foundation.byref.S47.md"
    mkdir -p "$snap"
    _fire 1 S47
    _ctx 1
    [[ "$PART_TEXT" != *"BEFORE YOU ANSWER"* ]] || { echo "the assistant was pointed at a directory: ${PART_TEXT:0:300}"; return 1; }
    jq -e '.systemMessage | test("NOT applied") and test("could not be written")' "$TEST_TMPDIR/part1.json" >/dev/null \
        || { echo "customer: $(jq -r '.systemMessage // ""' "$TEST_TMPDIR/part1.json")"; return 1; }
    if jq -e '.systemMessage | test("being replaced")' "$TEST_TMPDIR/part1.json" >/dev/null; then echo "it blamed a replacement"; return 1; fi
    [ -d "$snap" ] && [ -z "$(ls -A "$snap")" ] || { echo "the directory was changed: $(ls -A "$snap")"; return 1; }
    CLAUDE_CODE_SESSION_ID=S47 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    NOT on the most recent prompt - the copy your assistant reads them from could not be written"* ]] || { echo "$output"; return 1; }
}

@test "parts: #31411 a by-reference copy that cannot be written has its own state, not 'being replaced'" {
    _seed_lines 800
    local shim="$TEST_TMPDIR/shim"
    mkdir -p "$shim"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$shim/cp"
    chmod +x "$shim/cp"
    PATH="$shim:$PATH" _fire 1 S48
    local msg; msg="$(jq -r '.systemMessage // ""' "$TEST_TMPDIR/part1.json")"
    [[ "$msg" == *"NOT applied"* && "$msg" == *"could not be written"* ]] || { echo "customer: $msg"; return 1; }
    [[ "$msg" != *"being replaced"* ]] || { echo "it blamed a replacement: $msg"; return 1; }
    [[ "$(cat "$(_outcome_file S48 1)")" =~ ^S48\ [0-9]+\ failed\ refused\ copy$ ]] || { echo "record: $(cat "$(_outcome_file S48 1)")"; return 1; }
}

@test "parts: #31583 P8 a session id past byte 160 still names this session's records" {
    _seed_lines 380
    local pad payload k
    pad="$(printf '%0300d' 0)"
    payload='{"hook_event_name":"UserPromptSubmit","transcript_path":"/tmp/'"$pad"'.jsonl","session_id":"S49","prompt":"MMRY TEST DATA"}'
    for k in 1 2 3 4 5 6; do _fire_payload "$k" "$payload" & done; wait
    [ -f "$(_outcome_file S49 1)" ] || { echo "part 1 did not file its record under the session"; ls -a "$TEST_TMPDIR"; return 1; }
    CLAUDE_CODE_SESSION_ID=S49 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt, in 4 parts."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 P8 a payload spread over lines still names this session's records" {
    _seed_lines 3
    _fire_payload 1 $'{\n  "hook_event_name": "UserPromptSubmit",\n  "session_id": "S50",\n  "prompt": "MMRY TEST DATA"\n}\n'
    [ -f "$(_outcome_file S50 1)" ] || { echo "part 1 did not file its record under the session"; return 1; }
}

@test "parts: #31583 P8 a session id the hook cannot reach still gets its delivery reported" {
    # After a 5,000-character prompt: beyond what the hook reads. It files under the session token, and
    # the status, finding nothing under this session's id, reads those.
    _seed_lines 3
    local long payload k
    long="$(printf '%05000d' 0)"
    payload='{"hook_event_name":"UserPromptSubmit","prompt":"'"$long"'","session_id":"S51"}'
    for k in 1 2 3 4 5 6; do _fire_payload "$k" "$payload" & done; wait
    [ ! -e "$(_outcome_file S51 1)" ] || { echo "control: the hook did find the id, so this proves nothing about the fallback"; return 1; }
    CLAUDE_CODE_SESSION_ID=S51 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Last sent:    nothing yet"* ]] || { echo "$output"; return 1; }
}

# ---- #31411 QA round 3: the status's own wording (compliance) ------------------------------------

@test "parts: #31411 the status does not say 'nothing is trimmed or cut' of a set it sent in parts" {
    _seed_lines 380
    _fire_all S60
    CLAUDE_CODE_SESSION_ID=S60 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt, in 4 parts. Every part arrived; together they are the whole set."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"trimmed or cut"* ]] || { echo "$output"; return 1; }
    # In full, the size is the size of what arrived.
    [[ "$output" == *"Last sent:    "*" (380 directives, 33820 bytes)."* ]] || { echo "$output"; return 1; }
}

@test "parts: #31411 under PARTLY the last-sent line does not give the full set's size" {
    _seed_lines 380
    _fire_all S61
    _rec S61 3 'failed deadline 10'
    CLAUDE_CODE_SESSION_ID=S61 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    PARTLY"* ]] || { echo "control: $output"; return 1; }
    [[ "$output" == *"Last sent:    "*", in part (see above)."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"(380 directives, 33820 bytes)"* ]] || { echo "$output"; return 1; }
}

@test "parts: #31411 under BY REFERENCE nothing says the set was re-sent, or gives the size of what was only pointed to" {
    _seed_lines 800
    _fire_all S62
    CLAUDE_CODE_SESSION_ID=S62 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    BY REFERENCE on the most recent prompt"* ]] || { echo "control: $output"; return 1; }
    [[ "$output" != *"re-sent on every prompt"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Last sent:    "*", by reference to a copy (see above)."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"(800 directives"* ]] || { echo "$output"; return 1; }
}

# ---- P4: ONE notice when the whole set is damaged (Lead/PM decision, 2026-10-05) --------------------

# The set damaged under its own record, the stub #31583 is about, in whichever layout this branch keeps
# it: a cache beside its manifest, or (#31597) one file holding both.
_damage_set() {
    if [[ -n "${SET:-}" ]]; then fnd_set_with "$(fnd_set_record)" $'- x\n'; else printf -- '- x\n' > "$CACHE"; fi
}

@test "parts: #31583 P4 whole-set damage gives the turn ONE notice, part 1's, not one per part" {
    # 380 directives: every one of the six parts reaches its loader, and every one refuses the stub.
    _seed_lines 380
    _damage_set
    _fire_all S70
    local k shown=0
    for k in 1 2 3 4 5 6; do
        [ -s "$TEST_TMPDIR/part$k.json" ] && shown=$(( shown + 1 ))
    done
    [ "$shown" -eq 1 ] || { echo "$shown parts spoke; expected part 1 alone"; for k in 2 3 4 5 6; do [ -s "$TEST_TMPDIR/part$k.json" ] && echo "part $k: $(jq -r '.systemMessage // ""' "$TEST_TMPDIR/part$k.json")"; done; return 1; }
    jq -e '.systemMessage | test("your Foundation directives were NOT applied")' "$TEST_TMPDIR/part1.json" >/dev/null \
        || { echo "part 1 did not give the whole-set notice: $(cat "$TEST_TMPDIR/part1.json")"; return 1; }
    jq -e '.hookSpecificOutput.additionalContext | test("running WITHOUT the account")' "$TEST_TMPDIR/part1.json" >/dev/null \
        || { echo "the assistant was not told: $(cat "$TEST_TMPDIR/part1.json")"; return 1; }
    # The silent parts still record their refusal, so the status names them.
    for k in 2 3 4 5 6; do
        [[ "$(cat "$(_outcome_file S70 "$k")")" =~ ^S70\ [0-9]+\ failed\ refused\ [a-z-]+$ ]] || { echo "part $k record: $(cat "$(_outcome_file S70 "$k")")"; return 1; }
    done
    # And the status says the copy is refused, not that anything arrived.
    CLAUDE_CODE_SESSION_ID=S70 run bash "$STATUSCMD"
    [[ "$output" == *"It is being REFUSED, not used."* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]] || { echo "$output"; return 1; }
}

@test "parts: #31583 P4 a part 2-6 refused on a prompt whose part 1 delivered still names itself" {
    _seed_lines 380
    # Part 1 delivers; the set is then damaged before part 3 reads it.
    _fire 1 S71
    _damage_set
    _fire 3 S71
    local ctx msg
    ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part3.json")"
    msg="$(jq -r '.systemMessage // ""' "$TEST_TMPDIR/part3.json")"
    [[ "$ctx" == *"could not verify PART 3 of this account's FOUNDATION directives"* ]] || { echo "assistant: $ctx"; return 1; }
    [[ "$msg" == *"part 3 of your Foundation directives was NOT applied"* ]] || { echo "customer: $msg"; return 1; }
}

@test "parts: #31411 after a by-reference prompt and then a failed one, the last-sent line gives no size" {
    # QA #2, round 4: "Last sent: ... (8 directives, 70009 bytes)" after the set went by reference and
    # the next prompt failed, the full size of something that was never sent in full.
    _seed_lines 800
    _fire_all S80
    CLAUDE_CODE_SESSION_ID=S80 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    BY REFERENCE"* ]] || { echo "control: $output"; return 1; }
    # The next prompt: part 1's loader fails.
    _rec S80 1 'failed crash'
    CLAUDE_CODE_SESSION_ID=S80 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    NOT on the most recent prompt"* ]] || { echo "control: $output"; return 1; }
    [[ "$output" == *"Last sent:    "* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"(800 directives"* ]] || { echo "the size of a set never sent in full: $output"; return 1; }
}

@test "parts: #31411 the shipped hook keeps to bash 3.2: no bash 5 clock variable" {
    # #31245's portability guard refuses bash 5's clock variables in shipped code; this branch had one
    # in the hook and two in hook-budgets.bats. Checked here on the files this ticket changed, with the
    # guard's own pattern, comment lines skipped as the guard skips them.
    local f hits=""
    for f in "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh" "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh" \
             "$PLUGIN_ROOT/tests/structural/hook-budgets.bats"; do
        hits="${hits}$(grep -n -E 'EPOCH(SECONDS|REALTIME)' "$f" | grep -v -E '^[0-9]+:[[:space:]]*#' | sed "s|^|${f##*/}:|")"
    done
    [ -z "$hits" ] || { echo "$hits"; return 1; }
}

# Test 506 on macOS (#31583): after a failed emit the shell's printf there carried 1,024 bytes of the
# payload into the next record it wrote. Only the Mac shows the bytes; this checks, on any platform, the
# thing that prevents them: once an emit has failed, records are written by an external printf, and on a
# prompt whose emit worked they are not (no process on the path every prompt takes).
@test "parts: #31583 506 after a failed emit the record is written by an external printf, and only then" {
    _seed_lines 380
    _fire_all S90
    local shim="$TEST_TMPDIR/printf-shim" calls="$TEST_TMPDIR/printf-calls" real
    real="$(type -P printf)"
    mkdir -p "$shim"
    printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$calls" "$real" > "$shim/printf"
    chmod +x "$shim/printf"
    # CONTROL: an emit that works writes its records with the builtin.
    printf '{"session_id":"S90","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' \
        | PATH="$shim:$PATH" bash "$HOOK" --part 3 > "$TEST_TMPDIR/part3.json" 2>/dev/null
    [ ! -s "$calls" ] || { echo "a working emit used an external printf $(wc -l < "$calls") time(s)"; return 1; }
    # Standard output closed: the emit fails, and what follows must not go through the builtin.
    printf '{"session_id":"S90","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' \
        | PATH="$shim:$PATH" bash "$HOOK" --part 3 >&- 2>/dev/null
    [ -s "$calls" ] || { echo "after a failed emit the record was still written with the builtin"; return 1; }
    [[ "$(cat "$(_outcome_file S90 3)")" =~ ^S90\ [0-9]+\ failed\ emit$ ]] || { echo "part 3 record: $(cat "$(_outcome_file S90 3)")"; return 1; }
}
