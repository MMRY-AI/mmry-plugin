#!/usr/bin/env bash
# plant.sh N BYTES_EACH OUTDIR - plants N Foundation memories (account A, Integration) in order.
set -u
source "$(dirname "$0")/common.sh" || exit 1
N="${1:-12}"; EACH="${2:-2000}"; OUT="${3:?outdir}"
mkdir -p "$OUT"
nonce="$(date +%Y%m%d%H%M%S)-$RANDOM"
printf '%s' "$nonce" > "$OUT/nonce"
: > "$OUT/planted.tsv"
words="alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu"
for i in $(seq 1 "$N"); do
  nn=$(printf '%02d' "$i")
  head="J016-${nn}-${nonce} Test directive ${nn} of ${N}: this is planted test text for the 33079 live proof and asks the assistant for nothing. "
  tail="END-J016-${nn}-${nonce}"
  body=""
  w=($words); k=$i
  while (( ${#head} + ${#body} + ${#tail} + 1 < EACH )); do body+="${w[$((k % 26))]} "; k=$((k+7)); done
  content="${head}${body}${tail}"
  topic="J016-${nn}-${nonce} directive ${nn}"
  id="$(live_plant "$J_KEY" "$topic" "$content")" || { echo "plant $nn failed"; exit 1; }
  printf '%s\t%s\t%s\t%s\n' "$nn" "$id" "$topic" "${#content}" >> "$OUT/planted.tsv"
  printf '%s\n' "$content" > "$OUT/planted-$nn.txt"
  echo "planted $nn id=$id len=${#content}"
done
