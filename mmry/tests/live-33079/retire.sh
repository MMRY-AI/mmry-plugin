#!/usr/bin/env bash
# retire.sh OUTDIR - removes every memory in OUTDIR/planted.tsv and verifies each is gone.
set -u
source "$(dirname "$0")/common.sh" || exit 1
OUT="${1:?outdir}"; : > "$OUT/cleanup.txt"
while IFS=$'\t' read -r nn id topic len; do
  d="$(live_api DELETE "/api/memories/$id" "$J_KEY" | tail -1)"
  g="$(live_api GET "/api/memories/$id" "$J_KEY" | tail -1)"
  echo "$nn id=$id DELETE=$d then GET=$g" | tee -a "$OUT/cleanup.txt"
done < "$OUT/planted.tsv"
