#!/usr/bin/env bash
# live-foundation.bash - what the live J-016 specs share (#33480).
#
# integration/foundation-live.bats (J-016@claude-code) and integration/codex-foundation-live.bats
# (J-016@codex) prove one thing on two hosts: each moment an account administrator chose for a
# Foundation memory delivers exactly the memories chosen for it, word for word, and a memory with no
# moment chosen is delivered nowhere. Both use the guards, accounts and calls of live-journey.bash
# (load it first); this file adds the planting of one memory per moment and the reading back.
#
# THE PLANTED SET, in account A (the account the session is configured for):
#   START   chosen for conversation-start only
#   EVERY   chosen for every-message only
#   RELOAD  chosen for reload only
#   SHORTEN chosen for before-shortening only
#   BOTH    chosen for conversation-start and every-message
#   NONE    created, nothing chosen (a new memory starts with none)
# and in account B, one memory chosen for all four moments (OTHER), which must never reach A.
#
# Every text carries a tab, double quotes, a backslash, accented letters, an emoji, an internal new
# line and trailing spaces, so a delivery that escapes, trims, re-encodes or re-flows a memory fails
# the word-for-word comparison. Each marker ends in a colon, so no marker is a prefix of another.
#
# NEVER A CREDENTIAL IN OUTPUT: keys are only ever passed to live_api, which never prints them.

LIVE_FOUNDATION_NAMES="START EVERY RELOAD SHORTEN BOTH NONE"

# live_foundation_moments NAME - the moments chosen for a planted memory, as the API's JSON list.
live_foundation_moments() {
    case "$1" in
        START)   printf '%s' '["conversation-start"]' ;;
        EVERY)   printf '%s' '["every-message"]' ;;
        RELOAD)  printf '%s' '["reload"]' ;;
        SHORTEN) printf '%s' '["before-shortening"]' ;;
        BOTH)    printf '%s' '["conversation-start","every-message"]' ;;
        NONE)    printf '%s' '' ;;
        OTHER)   printf '%s' '["conversation-start","every-message","reload","before-shortening"]' ;;
    esac
}

# live_foundation_text NONCE NAME - the exact text planted for NAME.
live_foundation_text() {
    local t=$'\t' nl=$'\n'
    printf '%s' "J016-${1}-${2}: keeps${t}\"quoted\", back\\slash, café naïve über 📜${nl}second line of ${2}   "
}

# live_foundation_marker NONCE NAME - the marker that identifies NAME in any text.
live_foundation_marker() { printf '%s' "J016-${1}-${2}:"; }

# live_foundation_plant KEY TOPIC CONTENT - one Foundation memory; prints its id.
live_foundation_plant() {
    local key="$1" topic="$2" content="$3" body resp code id
    body="$("$LIVE_JQ" -cn --arg t "$topic" --arg c "$content" \
        '{memoryTier:"Foundation",category:"Convention",scope:"global",topic:$t,content:$c,source:"bats-33480"}')"
    # The body goes on stdin, not as an argument: on Windows an argument passes through the
    # console code page, and the accents and emoji would reach the service as something else.
    resp="$(printf '%s' "$body" | curl -s -w '\n%{http_code}' --connect-timeout 15 --max-time 60 -X POST \
        -H "X-Api-Key: ${key}" -H "Content-Type: application/json; charset=utf-8" --data-binary @- "${LIVE_URL}/api/memories")"
    code="${resp##*$'\n'}"
    [[ "$code" == "201" ]] || { echo "planting the Foundation memory '${topic}' returned HTTP ${code}" >&2; return 1; }
    id="$(printf '%s' "${resp%$'\n'*}" | "$LIVE_JQ" -r '.id // empty')"
    [[ -n "$id" ]] || { echo "planting '${topic}' returned no id" >&2; return 1; }
    printf '%s' "$id"
}

# live_foundation_choose KEY ID MOMENTS_JSON - chooses the moments, as the Foundation Memories page
# does (PUT /api/memories/{id}/foundation-moments, an administrator's key, no agent source).
live_foundation_choose() {
    local resp code
    resp="$(live_api PUT "/api/memories/$2/foundation-moments" "$1" "{\"moments\":$3}")"
    code="${resp##*$'\n'}"
    [[ "$code" == "200" ]] || { echo "choosing $3 for memory $2 returned HTTP ${code}" >&2; return 1; }
}

# live_foundation_plant_all STATE - plants the set above; writes, per NAME, id-NAME, text-NAME
# (the exact text) and marker-NAME into STATE, and nonce. Then reads the account's choices back from
# the API and refuses to go on unless they are exactly what was chosen.
live_foundation_plant_all() {
    local state="$1" nonce name id m got want
    nonce="$(live_nonce | tr -d '-' | cut -c5-)"
    printf '%s' "$nonce" > "$state/nonce"
    for name in $LIVE_FOUNDATION_NAMES; do
        live_foundation_text "$nonce" "$name" > "$state/text-$name"
        live_foundation_marker "$nonce" "$name" > "$state/marker-$name"
        # The text ends in spaces, not a new line, so $(cat) gives it back whole.
        id="$(live_foundation_plant "$MMRY_INTEGRATION_API_KEY" "J016 ${name} ${nonce}" "$(cat "$state/text-$name")")" || return 1
        printf '%s' "$id" > "$state/id-$name"
        m="$(live_foundation_moments "$name")"
        [[ -z "$m" ]] || live_foundation_choose "$MMRY_INTEGRATION_API_KEY" "$id" "$m" || return 1
    done
    # Account B: one memory chosen for every moment.
    live_foundation_text "$nonce" OTHER > "$state/text-OTHER"
    live_foundation_marker "$nonce" OTHER > "$state/marker-OTHER"
    id="$(live_foundation_plant "$MMRY_INTEGRATION_OTHER_API_KEY" "J016 OTHER ${nonce}" "$(cat "$state/text-OTHER")")" || return 1
    printf '%s' "$id" > "$state/id-OTHER"
    live_foundation_choose "$MMRY_INTEGRATION_OTHER_API_KEY" "$id" "$(live_foundation_moments OTHER)" || return 1

    # The account's own record of the choices, read back.
    got="$(live_api GET /api/memories/foundation/moments "$MMRY_INTEGRATION_API_KEY")"
    [[ "${got##*$'\n'}" == "200" ]] || { echo "GET /api/memories/foundation/moments returned HTTP ${got##*$'\n'}" >&2; return 1; }
    for name in $LIVE_FOUNDATION_NAMES; do
        id="$(cat "$state/id-$name")"
        want="$(live_foundation_moments "$name")"; want="${want:-[]}"
        m="$(printf '%s' "${got%$'\n'*}" | "$LIVE_JQ" -c --argjson i "$id" '.memories[] | select(.id==$i) | .moments')"
        [[ "$m" == "$want" ]] || { echo "the API holds ${m:-nothing} for ${name}, not ${want}" >&2; return 1; }
    done
    # And each memory's stored text is exactly what was planted.
    for name in $LIVE_FOUNDATION_NAMES; do
        live_foundation_stored "$MMRY_INTEGRATION_API_KEY" "$(cat "$state/id-$name")" > "$state/stored-$name" || return 1
        cmp -s "$state/stored-$name" "$state/text-$name" || { echo "the API stored ${name} differently from what was planted" >&2; return 1; }
    done
}

# live_foundation_stored KEY ID - the memory's stored text, raw bytes.
live_foundation_stored() {
    local resp
    resp="$(live_api GET "/api/memories/$2" "$1")"
    [[ "${resp##*$'\n'}" == "200" ]] || { echo "GET /api/memories/$2 returned HTTP ${resp##*$'\n'}" >&2; return 1; }
    printf '%s' "${resp%$'\n'*}" | "$LIVE_JQ" -b -j '.content'
}

# live_foundation_retire_all STATE - best effort.
live_foundation_retire_all() {
    local state="$1" name
    for name in $LIVE_FOUNDATION_NAMES; do
        [[ -f "$state/id-$name" ]] && live_retire "$MMRY_INTEGRATION_API_KEY" "$(cat "$state/id-$name")"
    done
    [[ -f "$state/id-OTHER" ]] && live_retire "$MMRY_INTEGRATION_OTHER_API_KEY" "$(cat "$state/id-OTHER")"
    return 0
}

# live_foundation_present STATE FILE - the names whose marker FILE holds, space separated, in the
# order of LIVE_FOUNDATION_NAMES then OTHER. FILE holds the text as delivered (decoded).
live_foundation_present() {
    local state="$1" f="$2" name out=""
    for name in $LIVE_FOUNDATION_NAMES OTHER; do
        grep -qaF -- "$(cat "$state/marker-$name")" "$f" 2>/dev/null && out+="${out:+ }${name}"
    done
    printf '%s' "$out"
}

# live_foundation_whole STATE FILE NAME - succeeds when FILE holds NAME's planted text whole, byte for
# byte (tab, quotes, backslash, accents, emoji, new line and trailing spaces included).
live_foundation_whole() {
    local want have
    want="$(cat "$1/text-$3"; printf x)"; want="${want%x}"
    have="$(cat "$2"; printf x)"; have="${have%x}"
    [[ -n "$want" && "$have" == *"$want"* ]]
}
