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
_fire_all() { local k; for k in 1 2 3 4 5 6; do _fire "$k" "${1:-}"; done; }

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
@test "parts: by reference points at a copy of exactly the verified set, ending in the line the assistant must reach" {
    _seed_lines 800
    _fire_all S1
    _ctx 1
    local snap="$TEST_TMPDIR/mmry-foundation.byref.S1.md" v
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
    local snap="$TEST_TMPDIR/mmry-foundation.byref.S1.md"
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
    printf 'S2 failed deadline 10' > "$TEST_TMPDIR/mmry-foundation.outcome.S2.3"
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
_outcome_file() { printf '%s/mmry-foundation.outcome.%s%s' "$TEST_TMPDIR" "$1" "$( (( $2 > 1 )) && printf '.%s' "$2")"; }

@test "parts: #31583 R4 every part names the version of the set it was cut from, and so does its record" {
    _seed_lines 380
    local v; v="$(_version)"
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "no checksum in the manifest"; return 1; }
    _fire_all S6
    local k
    for k in 1 2 3 4; do
        _ctx "$k"
        [[ "$PART_TEXT" == *"This is PART $k OF 4 of the set, version $v."* ]] || { echo "part $k does not name version $v: ${PART_TEXT:0:420}"; return 1; }
        [ "$(cat "$(_outcome_file S6 "$k")")" = "S6 ok part $k of 4 set $v" ] || { echo "part $k record: $(cat "$(_outcome_file S6 "$k")")"; return 1; }
    done
}

@test "parts: #31583 R4 a prompt whose parts came from two versions of the set is PARTLY, never IN FULL" {
    _seed_lines 380
    _fire 1 S7; _fire 2 S7
    # Replaced between the firings of one prompt: a different set of the same shape.
    awk 'BEGIN { for (i = 1; i <= 380; i++) printf "- Directive %04d: a REPLACED set, every line of it different from the first one.\n", i }' > "$CACHE"
    _seal
    _fire 3 S7; _fire 4 S7
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
    [ "$(cat "$(_outcome_file S10 3)")" = "S10 none" ] || { echo "part 3 record: $(cat "$(_outcome_file S10 3)")"; return 1; }
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
    printf 'S12 ok part 1 of 7 set %s' "$v" > "$(_outcome_file S12 1)"
    CLAUDE_CODE_SESSION_ID=S12 run bash "$STATUSCMD"
    [[ "$output" == *"Delivered:    UNKNOWN for the most recent prompt"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"IN FULL"* ]]
}

@test "parts: #31583 the PARTLY advice follows the cause of the part that did not arrive" {
    _seed_lines 380
    _fire_all S13
    # Part 3's loader crashed: the hook tells the customer re-sending will not help, and so must this.
    printf 'S13 failed crash' > "$(_outcome_file S13 3)"
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
