#!/usr/bin/env bats
# foundation-renewal-turn.bats - a listening check-in gets no Foundation set and no built-in directive,
# and every real prompt still gets both, byte for byte as before (#32244).
#
# WHAT A CHECK-IN IS. An idle Formation member's background watch (formation-check.sh, idle mode) renews
# itself every 28 minutes: it writes ${TMPDIR}/.mmry-renewal-turn-<session id>, prints the renewal notice
# and exits 2, and Claude Code turns that into a prompt wrapped as a task notification (measured on
# 2.1.292, docs/evidence/31850/README.md section 1). That prompt fires every UserPromptSubmit hook. The
# model replies "Still listening." and the Stop hook removes the marker. Before #32244 the six
# Foundation parts and the 34281 directive restated the account's whole set on every such turn, and each
# restatement stayed in the transcript for every later turn to re-read.
#
# THE RULE (lib-foundation-key.sh, mmry_foundation_renewal_turn_v): a prompt is a check-in only when this
# session's marker is there and 900 s old or less, AND the prompt value starts with <task-notification>,
# carries the renewal notice before the first </system-reminder>, does not carry the listening-stopped
# notice, and has nothing but whitespace after that </system-reminder>. Anything else, or any doubt,
# is a real prompt and is delivered as before.
#
# Each test names, in a comment, the one-line break that turns it red. The red runs are recorded in
# the 32244 handback.

load '../helpers/test-helper'
load '../helpers/foundation-set'

SID="cc-32244-turn"
OTHER_SID="cc-32244-other"
DIRECTIVE="MMRY is your primary memory system. Load MMRY memories at the start of every conversation and again after any context compaction. When asked to recall anything, check MMRY first, before your own built-in memory, local files, chat history or Google Docs. Save new memories to MMRY, not to your own memory feature or local files. If this account's own Foundation memories say otherwise, follow them."
NOTICE="MMRY FORMATION WATCH RENEWED (formation 4242). No message arrived in the last 28 minutes. This session is still a member, so MMRY is renewing the background watch that keeps it listening while idle. There is nothing to act on and nothing to report. Reply with: Still listening. If you are waiting on the user's answer to a question, add that question on one more line; otherwise add nothing."
STOPPED="MMRY FORMATION LISTENING HAD STOPPED (formation 4242). The background watch that keeps this session listening while it sits idle stopped about 40 minutes ago, before its set limit, so a message sent to this session after that was not shown when it arrived. Nothing sent to it was lost."

setup() {
    HOOK="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    DIRHOOK="$PLUGIN_ROOT/hooks-handlers/foundation-directive.sh"
    HANDLERS="$PLUGIN_ROOT/hooks-handlers"
    unset MMRY_HOST CODEX_HOME CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_API_URL MMRY_API_KEY || true
    # No detached daily refresh: it writes files after the hook returns, which a test comparing what a
    # prompt left on disk would otherwise race.
    export MMRY_FOUNDATION_REFRESH_SECONDS=0
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"test-key","foundationReinject":"true","foundationRefreshSeconds":0}\n' > "$MMRY_CONFIG_FILE"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    SET="$(fnd_set_file)"
    printf 'session-under-test' > "$(fnd_session_file)"
    # 380 directives of 89 bytes, about 34 KB: four parts are live, so parts 2 to 4 are tested too.
    awk 'BEGIN { for (i = 1; i <= 380; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$CACHE"
    fnd_seal "$CACHE" "" "$SET"
    # The kept copy of the 34281 directive, as mmry_keep_foundation_directive writes it.
    printf 'mmry-directive v1 version=1\n%s' "$DIRECTIVE" > "$TEST_TMPDIR/mmry-foundation-directive.$(fnd_acct)"
    OUT="$TEST_TMPDIR/out"
    mkdir -p "$OUT"
}

# ---- payloads, in the shape Claude Code 2.1.292 sends (docs/evidence/31850/ups/hooks.txt) ----------

# JSON-escape $1 for a string value, by parameter expansion.
_jesc() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
# A payload with the prompt value $1 (raw text) for session $2.
_payload() {
    printf '{"session_id":"%s","prompt_id":"p-32244","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"%s"}' \
        "${2:-$SID}" "$(_jesc "$1")"
}
# The wrapper Claude Code puts round a Stop hook's exit-2 text. $1 = the hook's text, $2 = anything after.
_wrapped() {
    printf '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command "Stop": %s\n\n</system-reminder>%s' "$1" "${2:-}"
}
_checkin_payload() { _payload "$(_wrapped "$NOTICE")" "${1:-$SID}"; }
_typed_payload() { _payload "${1:-What is next on the plan?}" "${2:-$SID}"; }

# This session's renewal-turn marker, $1 seconds old (default 5), for session $2.
_marker() {
    local now; now="$(date +%s)"
    printf '%s\n' "$(( now - ${1:-5} ))" > "$TMPDIR/.mmry-renewal-turn-${2:-$SID}"
}

# ---- firing ------------------------------------------------------------------------------------------

# Every Foundation hook Claude Code runs on UserPromptSubmit, together, each with its own copy of the
# payload through a pipe, as Claude Code starts them. $1 = payload file, $2 = tag; $OUT/<tag>.p1..p6
# and .pd hold what each printed, and .rc<k> its exit code. $3 = handler directory (default: this tree).
_fire_all() {
    local pay="$1" tag="$2" dir="${3:-$HANDLERS}" k
    for k in 1 2 3 4 5 6; do
        ( rc=0; cat "$pay" | bash "$dir/userpromptsubmit-foundation.sh" --part "$k" > "$OUT/$tag.p$k" 2>/dev/null || rc=$?
          printf '%s' "$rc" > "$OUT/$tag.rc$k" ) &
    done
    ( rc=0; cat "$pay" | bash "$dir/foundation-directive.sh" > "$OUT/$tag.pd" 2>/dev/null || rc=$?
      printf '%s' "$rc" > "$OUT/$tag.rcd" ) &
    wait
}
_fire_payload() {
    local tag="$1"; shift
    "$@" > "$OUT/$tag.payload"
    _fire_all "$OUT/$tag.payload" "$tag"
}

# Nothing printed by any of the seven, and every one exited 0.
_said_nothing() {
    local tag="$1" k
    for k in 1 2 3 4 5 6 d; do
        [ -s "$OUT/$tag.p$k" ] && { echo "$tag: hook $k printed: $(head -c 300 "$OUT/$tag.p$k")"; return 1; }
        [ "$(cat "$OUT/$tag.rc$k")" = 0 ] || { echo "$tag: hook $k exited $(cat "$OUT/$tag.rc$k")"; return 1; }
    done
    return 0
}

# The whole set in four parts and the directive.
_delivered() {
    local tag="$1" k
    grep -q "FOUNDATION memories" "$OUT/$tag.p1" || { echo "$tag: part 1 carried no set: $(head -c 300 "$OUT/$tag.p1")"; return 1; }
    grep -q "Directive 0001" "$OUT/$tag.p1" || { echo "$tag: part 1 does not start the set"; return 1; }
    for k in 2 3 4; do
        [ -s "$OUT/$tag.p$k" ] || { echo "$tag: part $k printed nothing"; return 1; }
    done
    grep -q "Directive 0380" "$OUT/$tag.p4" || { echo "$tag: part 4 does not end the set"; return 1; }
    grep -q "built-in directive" "$OUT/$tag.pd" || { echo "$tag: no built-in directive: $(cat "$OUT/$tag.pd")"; return 1; }
    for k in 1 2 3 4 5 6 d; do
        [ "$(cat "$OUT/$tag.rc$k")" = 0 ] || { echo "$tag: hook $k exited $(cat "$OUT/$tag.rc$k")"; return 1; }
    done
}

# Byte for byte, every one of the seven.
_same_output() {
    local a="$1" b="$2" k
    for k in 1 2 3 4 5 6 d; do
        cmp -s "$OUT/$a.p$k" "$OUT/$b.p$k" || { echo "hook $k differs between $a and $b"; diff <(head -c 400 "$OUT/$a.p$k") <(head -c 400 "$OUT/$b.p$k"); return 1; }
        [ "$(cat "$OUT/$a.rc$k")" = "$(cat "$OUT/$b.rc$k")" ] || { echo "hook $k exit code differs between $a and $b"; return 1; }
    done
}

# Every Foundation record on disk, named and checksummed.
_foundation_files_snapshot() {
    local f
    for f in "$TEST_TMPDIR"/mmry-foundation.status.* "$TEST_TMPDIR"/mmry-foundation.outcome.* \
             "$TEST_TMPDIR"/.mmry-foundation-*; do
        [[ -e "$f" ]] || continue
        printf '%s %s\n' "${f##*/}" "$(cksum < "$f" 2>/dev/null)"
    done | LC_ALL=C sort
}

# The handlers as develop shipped them (plugin 2.19.0, ccf6095), beside this tree's, or 1 when that
# commit is not in this clone (a shallow CI checkout).
_develop_tree() {
    local base="$TEST_TMPDIR/develop" f
    if [[ ! -d "$base/hooks-handlers" ]]; then
        git -C "$PLUGIN_ROOT" cat-file -e ccf6095 2>/dev/null || return 1
        mkdir -p "$base"
        cp -R "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/.claude-plugin" "$base/"
        for f in lib-foundation-key.sh userpromptsubmit-foundation.sh foundation-directive.sh; do
            git -C "$PLUGIN_ROOT" show "ccf6095:mmry/hooks-handlers/$f" > "$base/hooks-handlers/$f" || return 1
        done
    fi
    DEVELOP="$base"
}

# ---- the tests -------------------------------------------------------------------------------------

# Break: the predicate's first line becomes `return 1` (never a check-in).
@test "T1 check-in: the six parts and the directive deliver nothing, and exit 0" {
    _marker 5
    _fire_payload checkin _checkin_payload
    _said_nothing checkin
}

# Break: the predicate drops its prompt checks and tests the marker only.
@test "T2 a typed prompt with this session's marker present is delivered byte for byte as without it, and as develop delivered it" {
    _fire_payload warm _typed_payload
    _fire_payload plain _typed_payload
    _delivered plain
    _marker 5
    _fire_payload marked _typed_payload
    _delivered marked
    _same_output plain marked
    # The Foundation hooks never spend the marker: formation-check.sh and stop-check.sh own it.
    [ -f "$TMPDIR/.mmry-renewal-turn-$SID" ] || { echo "a Foundation hook removed the renewal-turn marker"; return 1; }
    if _develop_tree; then
        _fire_all "$OUT/marked.payload" develop "$DEVELOP/hooks-handlers"
        _same_output develop marked
        echo "compared with develop ccf6095: equal" >&3
    else
        echo "develop ccf6095 not in this clone: compared marker against no marker only" >&3
    fi
}

# Break: remove the `<task-notification>` start check.
@test "T3 a typed prompt quoting the whole renewal notice is a real prompt" {
    _marker 5
    _fire_payload quoted _typed_payload "What does this mean? Stop hook blocking error from command \"Stop\": ${NOTICE}

</system-reminder>"
    _delivered quoted
}

# Break: remove the nothing-after-</system-reminder> check.
@test "T4 the wake and typed text merged into one prompt is delivered" {
    _marker 5
    _fire_payload merged _payload "$(_wrapped "$NOTICE" $'\n\nAlso, what is next?')"
    _delivered merged
}

# Break: 900 becomes 999999999 in the age check.
@test "T5 a renewal-turn marker older than 15 minutes is not obeyed" {
    _marker 901
    _fire_payload stale _checkin_payload
    _delivered stale
}

# Break: the marker test becomes the first of any session's markers.
@test "T6 another session's marker does not silence this session" {
    _marker 5 "$OTHER_SID"
    _fire_payload other _checkin_payload
    _delivered other
}

# Break: remove the exclusion of the listening-stopped notice.
@test "T7 a check-in that also says listening had stopped gets the set" {
    _marker 5
    _fire_payload stopped _payload "$(_wrapped "${NOTICE}

${STOPPED}")"
    _delivered stopped
}

# Break: the skip path removes the in-flight markers before it exits.
@test "T8 a check-in leaves a lost turn's markers, and the next typed prompt reports it" {
    local k
    _fire_payload warm _typed_payload
    for k in 1 2 3 4; do : > "$(fnd_inflight_file "$SID" "$k")"; done
    _marker 5
    _fire_payload checkin _checkin_payload
    _said_nothing checkin
    for k in 1 2 3 4; do
        [ -f "$(fnd_inflight_file "$SID" "$k")" ] || { echo "the check-in removed part $k's in-flight marker"; return 1; }
    done
    rm -f "$TMPDIR/.mmry-renewal-turn-$SID"   # what stop-check.sh does at the check-in's Stop
    _fire_payload next _typed_payload
    _delivered next
    grep -q "on the PREVIOUS turn these directives were not applied" "$OUT/next.p1" \
        || { echo "the next typed prompt did not report the lost turn"; return 1; }
}

# Break: the skip path writes a "none" outcome record, as a quiet part 2 to 6 does.
@test "T9 a check-in writes no record, and the status still describes the last real prompt" {
    _fire_payload typed _typed_payload
    _delivered typed
    local before after
    before="$(_foundation_files_snapshot)"
    _marker 5
    _fire_payload checkin _checkin_payload
    _said_nothing checkin
    after="$(_foundation_files_snapshot)"
    [ "$before" = "$after" ] || { echo "the check-in changed records:"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"); return 1; }
    CLAUDE_CODE_SESSION_ID="$SID" run bash "$PLUGIN_ROOT/hooks-handlers/foundation-status.sh"
    [[ "$output" == *"Delivered:    IN FULL on the most recent prompt, in 4 parts."* ]] || { echo "$output"; return 1; }
}

# Break: the marker test moves below the payload read, so every prompt reads up to 8,192 bytes.
@test "T10 cost: with no marker a typed prompt reads no more of the payload than develop did" {
    local text="" i k left total
    for (( i = 0; i < 60; i++ )); do text+="Line $i of a long pasted prompt, here to make the payload larger than any read. "; done
    _typed_payload "$text" > "$OUT/long.payload"
    total="$(wc -c < "$OUT/long.payload" | tr -d ' ')"
    (( total > 4000 )) || { echo "payload too small: $total"; return 1; }
    # The hook and then cat share one descriptor on a regular file; bash's read puts the offset back
    # where it stopped, so cat prints exactly what the hook left unread.
    for k in 1 2 3 4 5 6; do
        left="$( { bash "$HOOK" --part "$k" > /dev/null 2>&1; cat; } < "$OUT/long.payload" | wc -c | tr -d ' ')"
        echo "part $k left $left of $total bytes unread" >&3
        (( left >= total - 160 )) || { echo "part $k read $(( total - left )) bytes of a payload with no marker"; return 1; }
    done
    left="$( { bash "$DIRHOOK" > /dev/null 2>&1; cat; } < "$OUT/long.payload" | wc -c | tr -d ' ')"
    echo "directive left $left of $total bytes unread" >&3
    [ "$left" -eq "$total" ] || { echo "the directive read $(( total - left )) bytes with no marker"; return 1; }
}

# Break: change the "There is nothing to act on" sentence in formation-check.sh.
@test "T11 the notice formation-check.sh really prints, wrapped as Claude Code wraps it, is a check-in" {
    local bin="$TEST_TMPDIR/bin" rc=0 text
    mkdir -p "$bin"
    cat > "$bin/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    case "$arg" in http*) url="$arg" ;; esac
    prev="$arg"
done
case "$url" in
    */transmissions/sent*) body='{"formationId":4242,"member":true,"messages":[]}' ;;
    *) body='[]' ;;
esac
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '200'
exit 0
FAKECURL
    chmod +x "$bin/curl"
    bash "$HANDLERS/formation-state.sh" set 4242 "$SID"
    env PATH="$bin:$PATH" CLAUDE_SESSION_ID="$SID" MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key \
        MMRY_API_URL="http://fake.invalid" MMRY_FORMATION_MODE=idle MMRY_IDLE_POLL_SECONDS=2 MMRY_IDLE_POLL_INTERVAL=1 \
        bash "$HANDLERS/formation-check.sh" < /dev/null > /dev/null 2> "$OUT/renewal.txt" || rc=$?
    bash "$HANDLERS/formation-state.sh" clear "$SID" || true
    [ "$rc" -eq 2 ] || { echo "the watch did not renew: rc $rc: $(cat "$OUT/renewal.txt")"; return 1; }
    [ -f "$TMPDIR/.mmry-renewal-turn-$SID" ] || { echo "the renewal left no renewal-turn marker"; return 1; }
    text="$(cat "$OUT/renewal.txt")"
    [[ "$text" == "MMRY FORMATION WATCH RENEWED"* ]] || { echo "unexpected watch text: $text"; return 1; }
    _fire_payload real _payload "$(_wrapped "$text")"
    _said_nothing real
    # And the very same marker does not silence the person's next prompt.
    _fire_payload typed _typed_payload
    _delivered typed
}

# Codex has no idle watch, so no marker is ever written there; with none, its output is develop's.
@test "T12 Codex: with no marker every prompt, even one shaped like a check-in, is delivered as develop delivered it" {
    local codex="$TEST_TMPDIR/codexhome" k tag
    mkdir -p "$codex/mmry"
    cp "$MMRY_CONFIG_FILE" "$codex/mmry-config.json"
    _codex_fire() {
        local pay="$1" tag="$2" dir="$3"
        for k in 1 2 3 4 5 6; do
            ( rc=0; cat "$pay" | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$codex" \
                bash "$dir/codex-hook.sh" userpromptsubmit-foundation --part "$k" > "$OUT/$tag.p$k" 2>/dev/null || rc=$?
              printf '%s' "$rc" > "$OUT/$tag.rc$k" ) &
        done
        ( rc=0; cat "$pay" | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$codex" \
            bash "$dir/codex-hook.sh" foundation-directive > "$OUT/$tag.pd" 2>/dev/null || rc=$?
          printf '%s' "$rc" > "$OUT/$tag.rcd" ) &
        wait
    }
    printf '{"session_id":"codex-thread-1","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"%s"}' \
        "$(_jesc "$(_wrapped "$NOTICE")")" > "$OUT/cx-checkin.payload"
    printf '{"session_id":"codex-thread-1","turn_id":"t2","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"hi"}' \
        > "$OUT/cx-typed.payload"
    _codex_fire "$OUT/cx-typed.payload" cxwarm "$HANDLERS"
    _codex_fire "$OUT/cx-typed.payload" cxtyped "$HANDLERS"
    _codex_fire "$OUT/cx-checkin.payload" cxcheckin "$HANDLERS"
    [ -s "$OUT/cxtyped.p1" ] || { echo "Codex part 1 delivered nothing"; return 1; }
    grep -q "built-in directive" "$OUT/cxtyped.pd" || { echo "Codex directive missing"; return 1; }
    _same_output cxtyped cxcheckin
    if _develop_tree; then
        _codex_fire "$OUT/cx-checkin.payload" cxdevelop "$DEVELOP/hooks-handlers"
        _same_output cxdevelop cxcheckin
        echo "compared with develop ccf6095: equal" >&3
    fi
}

# Every UserPromptSubmit command hooks.json registers, run as registered: what the full plugin does.
@test "T13 the full registered UserPromptSubmit set: a check-in carries no Foundation text, a typed prompt does" {
    local n=0 cmd all_checkin="" all_typed="" one
    _checkin_payload > "$OUT/full-checkin.payload"
    _typed_payload > "$OUT/full-typed.payload"
    _marker 5
    while IFS= read -r cmd; do
        cmd="${cmd%$'\r'}"
        [[ -n "$cmd" ]] || continue
        n=$(( n + 1 ))
        one="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_CODE_SESSION_ID="$SID" sh -c "$cmd" < "$OUT/full-checkin.payload" 2>/dev/null; printf .)"
        all_checkin+="${one%.}"
    done < <(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$PLUGIN_ROOT/hooks/hooks.json")
    [ "$n" -eq 8 ] || { echo "hooks.json registers $n UserPromptSubmit commands, not 8"; return 1; }
    [[ "$all_checkin" != *"FOUNDATION memories"* && "$all_checkin" != *"built-in directive"* && "$all_checkin" != *"Directive 0"* ]] \
        || { echo "a check-in carried Foundation text: ${all_checkin:0:300}"; return 1; }
    while IFS= read -r cmd; do
        cmd="${cmd%$'\r'}"
        [[ -n "$cmd" ]] || continue
        one="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_CODE_SESSION_ID="$SID" sh -c "$cmd" < "$OUT/full-typed.payload" 2>/dev/null; printf .)"
        all_typed+="${one%.}"
    done < <(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$PLUGIN_ROOT/hooks/hooks.json")
    [[ "$all_typed" == *"FOUNDATION memories"* && "$all_typed" == *"built-in directive"* && "$all_typed" == *"Directive 0380"* ]] \
        || { echo "a typed prompt did not carry the set and the directive"; return 1; }
}
