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
        [[ "$PART_TEXT" == *"This is PART $k OF 4 of the set."* ]] || { echo "part $k is not labelled $k of 4"; return 1; }
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
    [[ "$PART_TEXT" == *"mmry-foundation.md"* ]] || { echo "part 1 does not name the file"; return 1; }
    [[ "$PART_TEXT" != *"Directive 0001"* ]] || { echo "part 1 sent some of the set as well as the reference"; return 1; }
    (( ${#PART_TEXT} < 2000 )) || { echo "the reference is ${#PART_TEXT} long; it must fit a preview"; return 1; }
    jq -e '.systemMessage | test("larger than Claude Code lets a plugin show")' "$TEST_TMPDIR/part1.json" >/dev/null || { echo "the customer was not told"; return 1; }
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
