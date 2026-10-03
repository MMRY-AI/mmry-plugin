#!/usr/bin/env bash
# foundation-split-latency.sh - per-prompt cost of the Foundation hook: one process (the pre-split
# hook, from a named commit) against the shipped six --part processes started together, which is
# how Claude Code starts them (#31411 QA round 2). Not part of the test suite; a measurement tool.
#
# usage: bash tests/perf/foundation-split-latency.sh [runs] [baseline-commit]
#   run from the plugin's mmry/ directory, in a git checkout. Defaults: 5 runs, 563b178.
#
# Portable to bash 3.2 and \D tools on purpose: no date +%s%N (\D date prints a literal N), no
# python (a stock Mac has none), no mapfile. Milliseconds come from perl, which macOS ships.
set -u
RUNS="${1:-5}"; BASE="${2:-563b178}"
H="$PWD/hooks-handlers/userpromptsubmit-foundation.sh"
S="$PWD/hooks-handlers/zz-latency-baseline.sh"
[[ -f "$H" ]] || { echo "run this from the plugin's mmry/ directory"; exit 2; }
git show "${BASE}:mmry/hooks-handlers/userpromptsubmit-foundation.sh" > "$S" || { echo "cannot read $BASE"; exit 2; }
trap 'rm -f "$S"' EXIT

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
line='- Directive: keep every sentence short and every claim backed by something you ran.'
make_set() { # $1 = lines
    local d s b; d="$(mktemp -d)"; mkdir -p "$d/home"; printf 'sess-lat' > "$d/mmry-foundation.session"
    yes -- "$line" | head -n "$1" > "$d/mmry-foundation.md"
    read -r s b < <(cksum < "$d/mmry-foundation.md")
    printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s\n' "$1" "$b" "$s" > "$d/mmry-foundation.md.manifest"
    printf '%s' "$d"; }
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

for spec in "1:one directive, the common case" "400:about 34 KB, 4 parts" "650:about 55 KB, 6 parts"; do
    n="${spec%%:*}"; label="${spec#*:}"; one=""; six=""
    i=0
    while (( i < RUNS )); do
        d="$(make_set "$n")"; t0="$(now_ms)"
        ( export TMPDIR="$d" MMRY_TMPDIR="$d" HOME="$d/home"; bash "$S" >/dev/null 2>&1 ); t1="$(now_ms)"
        one="$one $(( t1 - t0 ))"
        d="$(make_set "$n")"; t0="$(now_ms)"
        ( export TMPDIR="$d" MMRY_TMPDIR="$d" HOME="$d/home"; k=1
          while (( k <= 6 )); do bash "$H" --part "$k" >/dev/null 2>&1 & k=$(( k + 1 )); done; wait ); t1="$(now_ms)"
        six="$six $(( t1 - t0 ))"
        i=$(( i + 1 ))
    done
    printf '%-30s single median %5s ms   six parts median %5s ms   (runs: single[%s ] six[%s ])\n' "$label"         "$(printf '%s\n' $one | median)" "$(printf '%s\n' $six | median)" "$one" "$six"
done
uname -a 2>/dev/null | head -1
