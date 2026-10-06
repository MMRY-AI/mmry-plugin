#!/usr/bin/env bash
# foundation-swap-race.sh - what the per-prompt hook delivers while the Foundation set is being
# replaced underneath it (#31597).
#
# A writer loop replaces the stored set over and over, alternating between two different sets A and
# B, using the plugin's own writer. Meanwhile the REAL hook is fired again and again, the way Claude
# Code fires it, and each firing's output is classified:
#
#   A, B      the hook delivered exactly set A or exactly set B, byte for byte
#   refused   the hook refused the set and said so (that turn runs without it)
#   partial   the hook delivered set text that is neither exactly A nor exactly B - the worst case
#   silent    the hook emitted nothing at all
#
# The ticket's bar is zero refused and zero partial over at least 250 reads, measured, not argued.
# This drives the hook rather than an internal function, so it runs unchanged against any version
# of the code and reports what a customer would actually have been sent.
#
# Usage: bash mmry/tests/perf/foundation-swap-race.sh [reads] [plugin-root]
#   reads        default 300
#   plugin-root  default: the mmry/ directory this script lives under
#
# Isolated: its own temp directory, HOME and config. It never reads the real config, never calls the
# API, and writes nothing outside its temp directory, which it removes on exit. Exit 0 only when
# every read delivered A or B exactly and both were seen.
set -u
READS="${1:-300}"
ROOT="${2:-$(cd "$(dirname "$0")/../.." && pwd)}"
HOOK="$ROOT/hooks-handlers/userpromptsubmit-foundation.sh"
[[ -f "$HOOK" ]] || { echo "no hook at $HOOK"; exit 2; }

W="$(mktemp -d)"
WPID=""
trap '[[ -n "$WPID" ]] && kill "$WPID" 2>/dev/null; wait 2>/dev/null; rm -rf "$W"' EXIT
export HOME="$W/home" TMPDIR="$W" MMRY_TMPDIR="$W" MMRY_CONFIG_FILE="$W/mmry-config.json"
mkdir -p "$HOME/.claude"
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID MMRY_API_KEY MMRY_API_URL
printf '{"foundationReinject": true, "foundationRefreshSeconds": 0}\n' > "$MMRY_CONFIG_FILE"
printf 'race-session' > "$W/mmry-foundation.session"

# Two sets that differ in size and on every line, so any mixture of them is detectable.
_set_json() {
    awk -v t="$1" -v n="$2" 'BEGIN {
        printf "["
        for (i = 1; i <= n; i++) {
            if (i > 1) printf ","
            printf "{\"memoryTier\":\"Foundation\",\"topic\":\"%s directive %03d\",\"content\":\"Set %s, line %03d: keep every sentence short and every claim backed by something you ran.\"}", t, i, t, i
        }
        printf "]"
    }'
}
_set_json A 40 > "$W/A.json"
_set_json B 70 > "$W/B.json"

# The cache path the hook under test reads, taken from the hook itself so this runs on any version.
CACHE_NAME="$(grep -o 'CACHE="${MMRY_TMPDIR}/[^"]*"' "$HOOK" | head -1 | sed 's|.*/||; s|"$||')"
[[ -n "$CACHE_NAME" ]] || { echo "could not find the cache path in $HOOK"; exit 2; }
CACHE="$W/$CACHE_NAME"

# The writer, in its own process, using the plugin's writer exactly as SessionStart and the refresh do.
cat > "$W/writer.sh" <<'WRITER'
source "$1/hooks-handlers/mmry-client.sh" >/dev/null 2>&1
A="$(cat "$2/A.json")"; B="$(cat "$2/B.json")"
if [[ "${4:-}" == "once" ]]; then mmry_write_foundation_cache "$(cat "$2/$5.json")" "$3"; exit $?; fi
while :; do
    mmry_write_foundation_cache "$A" "$3"
    mmry_write_foundation_cache "$B" "$3"
done
WRITER

_ctx() { jq -j '.hookSpecificOutput.additionalContext // ""' "$1" 2>/dev/null | tr -d '\r'; printf '.'; }

# Control: what exactly A and exactly B look like when the hook delivers them.
for s in A B; do
    bash "$W/writer.sh" "$ROOT" "$W" "$CACHE" once "$s" || { echo "control: could not write set $s"; exit 2; }
    bash "$HOOK" < /dev/null > "$W/ctl-$s.json" 2>/dev/null
    x="$(_ctx "$W/ctl-$s.json")"; x="${x%.}"
    [[ "$x" == *"Set $s, line 001"* ]] || { echo "control: set $s alone was not delivered: $(head -c 300 "$W/ctl-$s.json")"; exit 2; }
    printf '%s' "$x" > "$W/expect-$s"
done
EXP_A="$(cat "$W/expect-A"; printf .)"; EXP_A="${EXP_A%.}"
EXP_B="$(cat "$W/expect-B"; printf .)"; EXP_B="${EXP_B%.}"

bash "$W/writer.sh" "$ROOT" "$W" "$CACHE" >/dev/null 2>&1 &
WPID=$!

a=0; b=0; refused=0; partial=0; silent=0
t0="$(date +%s)"
for (( i = 1; i <= READS; i++ )); do
    bash "$HOOK" < /dev/null > "$W/out.json" 2>/dev/null
    if [[ ! -s "$W/out.json" ]]; then silent=$(( silent + 1 )); continue; fi
    x="$(_ctx "$W/out.json")"; x="${x%.}"
    if [[ "$x" == "$EXP_A" ]]; then a=$(( a + 1 ))
    elif [[ "$x" == "$EXP_B" ]]; then b=$(( b + 1 ))
    elif [[ "$x" == *"Set A, line"* || "$x" == *"Set B, line"* ]]; then
        partial=$(( partial + 1 ))
        (( partial <= 3 )) && cp "$W/out.json" "$W/partial-$partial.json"
    else
        refused=$(( refused + 1 ))
        (( refused <= 3 )) && cp "$W/out.json" "$W/refused-$refused.json"
    fi
done
t1="$(date +%s)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=""

echo "reads=$READS A=$a B=$b refused=$refused partial=$partial silent=$silent seconds=$(( t1 - t0 ))"
for f in "$W/refused-1.json" "$W/partial-1.json"; do
    [[ -f "$f" ]] || continue
    echo "first ${f##*/}, customer channel:"
    jq -r '.systemMessage // "(none)"' "$f" 2>/dev/null | head -c 400; echo
done
(( refused == 0 && partial == 0 && silent == 0 && a > 0 && b > 0 ))
