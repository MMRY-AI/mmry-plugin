#!/usr/bin/env bats
# foundation-in-time.bats - the Foundation re-injection finishes inside its time limit on a busy
# machine (#31893).
#
# Before every prompt the six registered parts start together. Up to plugin 2.10.1 each of them read
# the set, verified it with cksum, loaded the config with jq, cut it and escaped it, in its own worker
# process: one prompt paid that six times, about 280 processes on Windows, and under load part 1 ran
# past its 10 s deadline and then past the 20 s the harness allows, which the customer saw as a hook
# timeout error, several in a row.
#
# What these tests hold the hook to:
#   R2  a prompt prepares the set once. One firing verifies, cuts and escapes it and writes each part
#       where the others can read it; while the set is unchanged, later prompts only read.
#   R4  the set still arrives whole and in order, and never from a stale or mismatched preparation:
#       a part is served from the prepared copy only while the set on disk is byte for byte the set
#       that was verified.
#   R3  a firing that cannot finish in time shows the person nothing, tells the assistant that the
#       directives were cut short, and the next turn is told too.
#
# Slowness is injected with a cksum on PATH, because verifying the set is the one external step left
# on the per-prompt path. Every shim logs each call, so "once" is counted, not inferred.

load '../helpers/test-helper'
load '../helpers/foundation-set'

setup() {
    HOOK="$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    SET="$TEST_TMPDIR/mmry-foundation-set.md"
    printf 'session-under-test' > "$TEST_TMPDIR/mmry-foundation.session"
    REAL_CKSUM="$(command -v cksum)"
    REAL_JQ="$(command -v jq)"
    SHIMS="$TEST_TMPDIR/shims"
    mkdir -p "$SHIMS"
    CALLS="$TEST_TMPDIR/calls.log"
    : > "$CALLS"
    _cksum_shim 0
    # jq is logged too: the per-prompt path has no business starting one.
    printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s"\nexec "%s" "$@"\n' "$CALLS" "$REAL_JQ" > "$SHIMS/jq"
    chmod +x "$SHIMS/jq"
    export PATH="$SHIMS:$PATH"
    unset MMRY_JQ
    HEAD_ONE="The following are the account's FOUNDATION memories - authoritative directives that take precedence over defaults. If a response would conflict with any of them, follow the directive."
}

# A cksum that logs every call and takes $1 seconds first.
_cksum_shim() {
    printf '#!/usr/bin/env bash\nprintf "cksum\\n" >> "%s"\nsleep %s\nexec "%s" "$@"\n' "$CALLS" "$1" "$REAL_CKSUM" > "$SHIMS/cksum"
    chmod +x "$SHIMS/cksum"
}
_calls() { grep -c "^$1\$" "$CALLS" 2>/dev/null || true; }

_seed_lines() {
    awk -v n="$1" -v t="${2:-keep every sentence short and every claim backed by something you ran}" \
        'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: %s.\n", i, t }' > "$CACHE"
    fnd_seal "$CACHE" "" "$SET"
    # Sealing runs cksum too; only what the hook starts is counted.
    : > "$CALLS"
}

_fire() {
    local k="$1" sid="${2:-S1}"
    printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' "$sid" \
        | bash "$HOOK" --part "$k" > "$TEST_TMPDIR/part$k.json" 2>/dev/null
}
_fire_all() {
    local k pids=()
    rm -f "$TEST_TMPDIR"/part[1-6].json
    for k in 1 2 3 4 5 6; do _fire "$k" "${1:-S1}" & pids+=("$!"); done
    wait "${pids[@]}"
}

_ctx() {
    PART_TEXT=""
    [[ -s "$TEST_TMPDIR/part$1.json" ]] || return 0
    PART_TEXT="$("$REAL_JQ" -j '.hookSpecificOutput.additionalContext // ""' "$TEST_TMPDIR/part$1.json" | tr -d '\r' && printf '.')" || return 1
    PART_TEXT="${PART_TEXT%.}"
}
_sysmsg() { [[ -s "$TEST_TMPDIR/part$1.json" ]] && "$REAL_JQ" -r '.systemMessage // ""' "$TEST_TMPDIR/part$1.json" | tr -d '\r'; }

# The parts that arrived, rejoined in label order, into JOINED; their count into NPARTS; and the
# version each named, space separated, into VERSIONS.
# Parsed with the real jq, not the logging one, so a count of jq is a count of what the hook started.
_rejoin() {
    local k
    JOINED=""; NPARTS=0; VERSIONS=""
    for k in 1 2 3 4 5 6; do
        _ctx "$k"
        [[ "$PART_TEXT" =~ This\ is\ PART\ $k\ OF\ [0-9]+\ of\ the\ set,\ version\ ([0-9]+)\. ]] || continue
        VERSIONS+=" ${BASH_REMATCH[1]}"
        # After the part's own heading: a note about a previous turn can come before it.
        JOINED+="${PART_TEXT#*if their versions differ, tell the user.$'\n\n'}"
        NPARTS=$(( NPARTS + 1 ))
    done
}
_want() { WANT="$(cat "$CACHE"; printf .)"; WANT="${WANT%.}"; WANT="${WANT%$'\n'}"; }
_setid() { fnd_set_record "$SET" | sed -n 's/.*cksum=\([0-9]*\).*/\1/p'; }

@test "in-time R2: a six-part prompt verifies the set once, not once per part, and it arrives whole and in order" {
    _seed_lines 600
    # The detached refresh decision (its own test below) starts a jq of its own off the prompt's
    # path; it is switched off here so the count is the prompt's path alone.
    MMRY_FOUNDATION_REFRESH_SECONDS=0 _fire_all
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] || { echo "expected six parts, got $NPARTS"; return 1; }
    [ "$JOINED" = "$WANT" ] || { echo "the six parts do not rejoin into the set (${#JOINED} of ${#WANT} bytes)"; return 1; }
    local n; n="$(_calls cksum)"
    [ "$n" -eq 1 ] || { echo "the set was verified $n times on one prompt"; return 1; }
    [ "$(_calls jq)" -eq 0 ] || { echo "a jq was started on the prompt path: $(_calls jq)"; return 1; }
}

@test "in-time: the daily refresh is still decided, off the prompt's path, and at most once in its interval" {
    _seed_lines 3
    # A configured account whose set is a year old: a refresh is due.
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"test-key","foundationReinject":"true","foundationRefreshSeconds":60}\n' > "$MMRY_CONFIG_FILE"
    touch -t 202501010000 "$SET"
    _fire 1
    _ctx 1
    [[ "$PART_TEXT" == *"Directive 0003"* ]] || { echo "the prompt did not deliver: ${PART_TEXT:0:200}"; return 1; }
    # Decided by a detached process, so it is waited for, up to 30 s.
    local i; for (( i = 0; i < 150; i++ )); do [ -f "$TEST_TMPDIR/.mmry-foundation-refresh" ] && break; sleep 0.2; done
    [ -f "$TEST_TMPDIR/.mmry-foundation-refresh" ] || { echo "no refresh was decided"; return 1; }
    # Once decided, the next prompt inside the interval does not start the decision again.
    rm -f "$TEST_TMPDIR/.mmry-foundation-refresh"
    : > "$CALLS"
    _fire 1
    sleep 3
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-refresh" ] || { echo "decided again inside the interval"; return 1; }
    [ "$(_calls jq)" -eq 0 ] || { echo "the decision was started again: $(_calls jq) jq"; return 1; }
}

@test "in-time R2: while the set is unchanged, later prompts only read: no cksum, no jq, and still whole" {
    _seed_lines 600
    _fire_all
    : > "$CALLS"
    _fire_all
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "second prompt: $NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
    [ "$(_calls cksum)" -eq 0 ] || { echo "an unchanged set was verified again: $(_calls cksum) cksum"; return 1; }
    [ "$(_calls jq)" -eq 0 ] || { echo "jq on the read path: $(_calls jq)"; return 1; }
    # Silent on a healthy turn.
    local k; for k in 1 2 3 4 5 6; do [ -z "$(_sysmsg "$k")" ] || { echo "part $k told the person something"; return 1; }; done
}

@test "in-time R2: a part that starts while the set is being prepared waits for it rather than preparing again" {
    _seed_lines 600
    # Verification takes two seconds, so every part starts before the first has finished preparing.
    _cksum_shim 2
    _fire_all
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "$NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
    [ "$(_calls cksum)" -eq 1 ] || { echo "verified $(_calls cksum) times while the parts waited"; return 1; }
}

@test "in-time R4: a set replaced since it was prepared is verified again and sent as the new version, never the old" {
    _seed_lines 600
    _fire_all
    local old; old="$(_setid)"
    _seed_lines 600 "the replacement set, a different version of every directive"
    local new; new="$(_setid)"
    [ "$old" != "$new" ]
    : > "$CALLS"
    _fire_all
    _rejoin; _want
    [ "$JOINED" = "$WANT" ] || { echo "the new set did not arrive whole: ${#JOINED} of ${#WANT} bytes"; return 1; }
    [[ "$JOINED" != *"keep every sentence short"* ]] || { echo "text of the old version was served"; return 1; }
    local v; for v in $VERSIONS; do [ "$v" = "$new" ] || { echo "a part named version $v, not $new"; return 1; }; done
    [ "$(_calls cksum)" -eq 1 ] || { echo "the new version was verified $(_calls cksum) times"; return 1; }
}

@test "in-time R4: a set damaged under an intact record line is refused, not served from the earlier preparation" {
    _seed_lines 600
    _fire_all
    # Same length, same record line, one byte changed in the body.
    local raw; raw="$(cat "$SET")"
    printf '%s' "${raw/Directive 0300: keep/Directive 0300: KEEP}" > "$SET"
    _fire_all
    _ctx 1
    [[ "$PART_TEXT" == *"could not verify"* ]] || { echo "part 1 did not refuse: ${PART_TEXT:0:200}"; return 1; }
    local k; for k in 1 2 3 4 5 6; do
        _ctx "$k"
        [[ "$PART_TEXT" != *"Directive 0001"* && "$PART_TEXT" != *"Directive 0599"* ]] || { echo "part $k served directives from a damaged set"; return 1; }
    done
}

@test "in-time R4: a prepared copy that no longer matches, or cuts that no longer fit, are prepared again, never served" {
    _seed_lines 600
    _fire_all
    local f="$TEST_TMPDIR/.mmry-foundation-prepared.S1" p idx
    [ -f "$f" ] || { echo "no prepared copy was written"; ls -la "$TEST_TMPDIR"; return 1; }
    # 1. The copy altered under an intact record line, the same length: it no longer reads as the set.
    p="$(cat "$f")"
    printf '%s' "${p/Directive 0400: keep/Directive 0400: KEEP}" > "$f"
    : > "$CALLS"
    _fire_all
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "after altering the copy: $NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
    [ "$(_calls cksum)" -eq 1 ] || { echo "an altered copy was believed: $(_calls cksum) cksum"; return 1; }
    # 2. The cuts moved so that part 1 would be far over the cap: not served as cut.
    # The record ends in the six cut ends; the first is moved to one byte short of the second, so the
    # cuts still rise and still end at the set's length, and part 1 is about two parts long.
    p="$(cat "$f")"; idx="${p%%$'\n'*}"
    [[ "$idx" =~ ^(.*)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]] || { echo "unexpected record: $idx"; return 1; }
    printf '%s %s %s %s %s %s %s\n%s' "${BASH_REMATCH[1]}" $(( BASH_REMATCH[3] - 1 )) "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" \
        "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" "${BASH_REMATCH[7]}" "${p#*$'\n'}" > "$f"
    : > "$CALLS"
    _fire_all
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "after moving a cut: $NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
    local k; for k in 1 2 3 4 5 6; do _ctx "$k"; (( ${#PART_TEXT} < 10000 )) || { echo "part $k is ${#PART_TEXT} characters"; return 1; }; done
    [ "$(_calls cksum)" -eq 1 ] || { echo "cuts over the cap were believed: $(_calls cksum) cksum"; return 1; }
    # 3. The record names another version than the set it sits beside: not served under that name.
    p="$(cat "$f")"; idx="${p%%$'\n'*}"
    [[ "$idx" =~ ^mmry-fnd-prepared\ v1\ ([0-9]+)\ (.*)$ ]] || { echo "unexpected record: $idx"; return 1; }
    printf 'mmry-fnd-prepared v1 %s %s\n%s' "4242" "${BASH_REMATCH[2]}" "${p#*$'\n'}" > "$f"
    : > "$CALLS"
    _fire_all
    _rejoin; _want
    [ "$JOINED" = "$WANT" ] || { echo "after renaming the version: ${#JOINED} of ${#WANT} bytes"; return 1; }
    local v; for v in $VERSIONS; do [ "$v" = "$(_setid)" ] || { echo "a part named version $v"; return 1; }; done
    [ "$(_calls cksum)" -eq 1 ] || { echo "a record naming another version was believed: $(_calls cksum) cksum"; return 1; }
}

@test "in-time R4: a one-part set is sent exactly as one hook always sent it, from the prepared copy too" {
    printf -- '- Identity: Eric builds MMRY.\n- Value: clarity.\n' > "$CACHE"; fnd_seal "$CACHE" "" "$SET"
    _fire_all
    _fire_all
    _ctx 1
    local stored; stored="$(<"$CACHE")"
    [ "$PART_TEXT" = "${HEAD_ONE}"$'\n\n'"${stored}" ] || { echo "part 1: ${PART_TEXT:0:300}"; return 1; }
    local k; for k in 2 3 4 5 6; do [ ! -s "$TEST_TMPDIR/part$k.json" ] || { echo "part $k spoke"; return 1; }; done
}

@test "in-time R3/TC3: past its deadline the prompt shows the person nothing, the assistant is told, and so is the next turn" {
    _seed_lines 600
    _cksum_shim 60
    local start elapsed budget
    budget="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("userpromptsubmit-foundation")) | .timeout] | unique | .[0]' "$PLUGIN_ROOT/hooks/hooks.json" | tr -d '\r')"
    start=$SECONDS
    MMRY_FOUNDATION_DEADLINE_SECS=3 _fire_all
    elapsed=$(( SECONDS - start ))
    (( elapsed < budget )) || { echo "the prompt took ${elapsed}s against ${budget}s"; return 1; }
    local k; for k in 1 2 3 4 5 6; do
        [ -z "$(_sysmsg "$k")" ] || { echo "part $k showed the person: $(_sysmsg "$k")"; return 1; }
        jq -e . "$TEST_TMPDIR/part$k.json" >/dev/null 2>&1 || [ ! -s "$TEST_TMPDIR/part$k.json" ] || { echo "part $k is not JSON"; return 1; }
    done
    _ctx 1
    [[ "$PART_TEXT" == *"cut short"* ]] || { echo "the assistant was not told: ${PART_TEXT:0:300}"; return 1; }
    [[ "$PART_TEXT" != *"Directive 0001"* ]] || { echo "an unverified set was sent"; return 1; }
    # The next turn, on a machine that keeps up again. Its verification still takes two seconds, so the
    # parts waiting on it read the result file in the meantime, where the cut-short turn left its own
    # "deadline": they must not take that as this turn's.
    _cksum_shim 2
    _fire_all
    _ctx 1
    [[ "$PART_TEXT" == *"PREVIOUS turn"*"cut short"* ]] || { echo "the next turn was not told: ${PART_TEXT:0:300}"; return 1; }
    for k in 1 2 3 4 5 6; do [ -z "$(_sysmsg "$k")" ] || { echo "next turn, part $k showed the person: $(_sysmsg "$k")"; return 1; }; done
    _rejoin; _want
    [ "$JOINED" = "$WANT" ] || { echo "the next turn did not deliver the set whole"; return 1; }
}

@test "in-time R3: a part left waiting on a preparation that never finishes stops at its deadline, quietly to the person" {
    _seed_lines 600
    # Another firing of this prompt holds the claim and is alive, and never writes anything.
    sleep 120 & local holder=$!
    printf '%s %s' "$holder" "$(date +%s)" > "$TEST_TMPDIR/.mmry-foundation-claim.S1"
    local start=$SECONDS
    MMRY_FOUNDATION_DEADLINE_SECS=3 _fire 2
    local elapsed=$(( SECONDS - start ))
    kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
    (( elapsed >= 3 && elapsed < 15 )) || { echo "waited ${elapsed}s"; return 1; }
    [ -z "$(_sysmsg 2)" ] || { echo "showed the person: $(_sysmsg 2)"; return 1; }
    _ctx 2
    [[ "$PART_TEXT" == *"PART 2"*"cut short"* ]] || { echo "the assistant was not told: ${PART_TEXT:0:300}"; return 1; }
}

@test "in-time R3: a claim left by a firing that has died is taken over at once, not waited out" {
    _seed_lines 600
    # A pid that is not running, on a claim stamped now.
    sleep 0 & local gone=$!; wait "$gone" 2>/dev/null
    printf '%s %s' "$gone" "$(date +%s)" > "$TEST_TMPDIR/.mmry-foundation-claim.S1"
    local start=$SECONDS
    MMRY_FOUNDATION_DEADLINE_SECS=8 _fire_all
    (( SECONDS - start < 8 )) || { echo "waited out the deadline: $(( SECONDS - start ))s"; return 1; }
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "$NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
}

@test "in-time R4: each session prepares its own copy, so two sessions never read each other's parts" {
    _seed_lines 600
    _fire_all S1
    [ -f "$TEST_TMPDIR/.mmry-foundation-prepared.S1" ] || { echo "no parts for S1"; return 1; }
    _fire_all S2
    [ -f "$TEST_TMPDIR/.mmry-foundation-prepared.S2" ] || { echo "S2 read S1's parts"; return 1; }
    _rejoin; _want
    [ "$JOINED" = "$WANT" ]
}

@test "in-time R3: a firing the harness kills outright while it verifies LEAVES the marker, and the next turn is told" {
    # The #31434 end-to-end kill test, on the path an ordinary prompt takes since #31893: the supervisor
    # verifies the set itself, so it is killed while its cksum runs, with no worker in the picture.
    printf -- '- Truthfulness: never overstate evidence.\n' > "$CACHE"; fnd_seal "$CACHE" "" "$SET"
    _cksum_shim 20
    printf '{"session_id":"S1","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}' \
        | bash "$HOOK" --part 1 >/dev/null 2>&1 &
    local victim=$! i
    for (( i = 0; i < 300; i++ )); do [[ -f "$TEST_TMPDIR/.mmry-foundation-inflight.S1" ]] && break; sleep 0.1; done
    sleep 1
    kill -9 "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    [ -f "$TEST_TMPDIR/.mmry-foundation-inflight.S1" ] || { echo "the kill left no marker"; return 1; }
    _cksum_shim 0
    _fire 1
    _ctx 1
    [[ "$PART_TEXT" == *"PREVIOUS turn"* ]] || { echo "the next turn was not told: ${PART_TEXT:0:200}"; return 1; }
    [[ "$PART_TEXT" == *"never overstate evidence"* ]] || { echo "the next turn did not deliver"; return 1; }
    [ -z "$(_sysmsg 1)" ] || { echo "the person was shown: $(_sysmsg 1)"; return 1; }
    [ ! -f "$TEST_TMPDIR/.mmry-foundation-inflight.S1" ]
}

# A shim for $1 that logs each call and then runs the real one, so a count is what the hook started.
_logging_shim() {
    local real; real="$(command -v "$1")"
    printf '#!/usr/bin/env bash\nprintf "%s\n" >> "%s"\nexec "%s" "$@"\n' "$1" "$CALLS" "$real" > "$SHIMS/$1"
    chmod +x "$SHIMS/$1"
}

@test "in-time R1: a preparing prompt starts one cksum, one rename a part and one more for part 1's delivery, and no rm or sleep" {
    # QA's trace of the preparing prompt (#31893 round 2): an up-front record, a stored copy, a delivery
    # record, an outcome record and an rm on every part, each a process, and an external sleep on every
    # wait. On a loaded Windows machine each process is a second or two, and the preparing part ran past
    # the 20 s limit. The waits are counted on a bash with fractional read -t; the bash 3.2 a Mac ships
    # has none and sleeps, where a process is cheap.
    local real_sleep; real_sleep="$(command -v sleep)"
    _seed_lines 600
    # Verification takes a second, so the other five parts wait on it.
    printf '#!/usr/bin/env bash\nprintf "cksum\n" >> "%s"\n"%s" 1\nexec "%s" "$@"\n' "$CALLS" "$real_sleep" "$REAL_CKSUM" > "$SHIMS/cksum"
    chmod +x "$SHIMS/cksum"
    local c; for c in mv rm sleep; do _logging_shim "$c"; done
    # _fire_all removes the last prompt's output with rm; the parts overwrite it anyway, so it is not
    # run here and every rm counted is the hook's.
    _six() { local k pids=(); for k in 1 2 3 4 5 6; do _fire "$k" & pids+=("$!"); done; wait "${pids[@]}"; }
    : > "$CALLS"
    MMRY_FOUNDATION_REFRESH_SECONDS=0 _six
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "preparing prompt: $NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
    local ck mv rm sl
    ck="$(_calls cksum)" mv="$(_calls mv)" rm="$(_calls rm)" sl="$(_calls sleep)"
    [ "$ck" -eq 1 ] || { echo "cksum $ck times"; return 1; }
    [ "$rm" -eq 0 ] || { echo "rm started $rm times on the preparing prompt"; return 1; }
    [ "$mv" -le 7 ] || { echo "mv started $mv times on the preparing prompt, more than one a part and one for part 1's delivery"; return 1; }
    if [ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]; then
        [ "$sl" -eq 0 ] || { echo "an external sleep was started $sl times while parts waited"; return 1; }
    fi
    # The next prompt is served: no cksum, and still no rm.
    : > "$CALLS"
    MMRY_FOUNDATION_REFRESH_SECONDS=0 _six
    _rejoin
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "served prompt: $NPARTS parts"; return 1; }
    ck="$(_calls cksum)" mv="$(_calls mv)" rm="$(_calls rm)"
    [ "$ck" -eq 0 ] && [ "$rm" -eq 0 ] && [ "$mv" -le 7 ] || { echo "served prompt: cksum $ck, rm $rm, mv $mv"; return 1; }
    # The shims live in the test's temp directory, which teardown removes with rm: put the real ones back.
    "$SHIMS/rm" -f "$SHIMS/mv" "$SHIMS/sleep" "$SHIMS/rm"
    hash -r
}

@test "in-time R1: a part 2-6 that refuses waits for part 1's word only until the deadline, not a fixed 8 s past it" {
    _seed_lines 600
    # Same length, same record line, one byte changed: a contents refusal.
    local raw; raw="$(cat "$SET")"
    printf '%s' "${raw/Directive 0300: keep/Directive 0300: KEEP}" > "$SET"
    # Part 2 alone: it prepares, refuses, and asks what part 1 said, which never comes.
    local start=$SECONDS
    MMRY_FOUNDATION_DEADLINE_SECS=3 _fire 2
    local elapsed=$(( SECONDS - start ))
    (( elapsed < 6 )) || { echo "part 2 took ${elapsed}s against a 3 s deadline"; return 1; }
    # Part 1 said nothing, so part 2 names itself, as it always has.
    [[ "$(_sysmsg 2)" == *"part 2"* ]] || { echo "part 2 said: $(_sysmsg 2)"; return 1; }
}

@test "in-time R3: where read -t reports a timeout as 1, as macOS bash 3.2 does, a slow check is cut short in silence, not refused" {
    _seed_lines 600
    _cksum_shim 60
    # bash 3.2 returns 1 for a read -t that runs out of time, not a status above 128. Every read the
    # hook makes goes through this, exported to the hook's bash, so it sees what a Mac's bash returns.
    (
        read() { builtin read "$@"; local _r32=$?; (( _r32 > 128 )) && return 1; return "$_r32"; }
        export -f read
        MMRY_FOUNDATION_DEADLINE_SECS=3 _fire_all
    )
    local k; for k in 1 2 3 4 5 6; do
        [ -z "$(_sysmsg "$k")" ] || { echo "part $k showed the person: $(_sysmsg "$k")"; return 1; }
    done
    _ctx 1
    [[ "$PART_TEXT" == *"cut short"* ]] || { echo "the assistant was not told it was cut short: ${PART_TEXT:0:300}"; return 1; }
    [[ "$PART_TEXT" != *"could not verify"* ]] || { echo "a slow check was reported as a refusal"; return 1; }
}

@test "in-time R4: a claim older than the deadline is taken over even when its pid now belongs to a live, unrelated process" {
    _seed_lines 600
    # The claimant died long ago and an unrelated process has its pid: kill -0 says alive.
    sleep 300 & local other=$!
    printf '%s %s' "$other" "$(( $(date +%s) - 600 ))" > "$TEST_TMPDIR/.mmry-foundation-claim.S1"
    local start=$SECONDS
    MMRY_FOUNDATION_DEADLINE_SECS=8 _fire_all
    local elapsed=$(( SECONDS - start ))
    kill "$other" 2>/dev/null || true; wait "$other" 2>/dev/null || true
    (( elapsed < 8 )) || { echo "the parts waited out the deadline on a stale claim: ${elapsed}s"; return 1; }
    _rejoin; _want
    [ "$NPARTS" -eq 6 ] && [ "$JOINED" = "$WANT" ] || { echo "$NPARTS parts, ${#JOINED} of ${#WANT} bytes"; return 1; }
}
