#!/usr/bin/env bash
# foundation-under-load.sh - the six Foundation parts, prompt after prompt, on a machine under seeded
# load, timing every part against its registered limit (#31893 TC1). Not part of the suite; a
# measurement tool, for Windows Git Bash: the clock is /proc/uptime, read by the read builtin, so taking a
# time starts no process and adds nothing to what it measures on a loaded machine.
#
# usage: bash tests/perf/foundation-under-load.sh <hook.sh> [prompts] [spinners] [churners] [lines]
#   run from the plugin's mmry/ directory. Defaults: 20 prompts, 128 CPU spinners, 128 process
#   churners, 600 lines (about 53 KB, six parts). spinners=0 churners=0 runs with no load.
#
# Load: <spinners> bash loops that never yield and <churners> loops that start /usr/bin/true
# without pause. Before the first prompt and after the last it times an empty command, which is
# what the ticket's "starting an empty command takes at least one second" is measured by.
#
# Every part's elapsed time runs from just before the driver starts it to just after it exits, so
# it includes this driver's own fork, which is slower than the native spawn Claude Code uses. The
# limit is the one hooks.json registers. A part over it is what Claude Code reports as a hook
# timeout. For each prompt it also reports what the assistant was given: the parts that arrived,
# whether they rejoin into the set whole and in order, and any notice.
set -u
HOOK="${1:?usage: foundation-under-load.sh <hook.sh> [prompts] [spinners] [churners] [lines]}"
RUNS="${2:-20}"; SPIN="${3:-128}"; CHURN="${4:-128}"; LINES="${5:-600}"
LIMIT="${MMRY_LOAD_LIMIT_SECS:-20}"
HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
W="$(mktemp -d)"; STOP="$W/stop"
cleanup() { : > "$STOP"; sleep 3; rm -rf "$W"; }
# On any way out, including a timeout or Ctrl-C: the load loops stop only when the stop file exists.
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$W/home/.claude" "$W/t"
d="$W/t"
awk -v n="$LINES" 'BEGIN { for (i = 1; i <= n; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$W/body"
read -r s b < <(cksum < "$W/body")
{ printf 'mmry-foundation v2 entries=%s bytes=%s cksum=%s\n' "$LINES" "$b" "$s"; cat "$W/body"; printf 'END OF FOUNDATION SET'; } > "$d/mmry-foundation-set.md"
printf 'sess-load' > "$d/mmry-foundation.session"
printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"load-key","foundationReinject":"true"}' > "$d/mmry-config.json"
export TMPDIR="$d" MMRY_TMPDIR="$d" HOME="$W/home" MMRY_CONFIG_FILE="$d/mmry-config.json"
PAYLOAD='{"session_id":"sess-load-1","transcript_path":"/x","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"MMRY TEST DATA"}'
want="$(cat "$W/body"; printf .)"; want="${want%.}"; want="${want%$'\n'}"

# Seconds since boot, to the hundredth, into the named variable, with no process.
now_up() { local u _; read -r u _ < /proc/uptime; printf -v "$1" "%s" "$u"; }
[[ -r /proc/uptime ]] || { echo "needs /proc/uptime (Windows Git Bash, Linux)"; exit 2; }
empty_ms() { local a b; now_up a; bash -c "exit 0"; now_up b; awk -v a="$a" -v b="$b" "BEGIN { printf \"%d\", (b - a) * 1000 }"; }

i=0
while (( i < SPIN )); do bash -c 'while [ ! -e "$0" ]; do :; done' "$STOP" & i=$(( i + 1 )); done
i=0
while (( i < CHURN )); do bash -c 'while [ ! -e "$0" ]; do /usr/bin/true; done' "$STOP" & i=$(( i + 1 )); done
(( SPIN + CHURN > 0 )) && sleep 10
e1="$(empty_ms) $(empty_ms) $(empty_ms)"
echo "load: $SPIN spinners, $CHURN churners; empty command before: $e1 ms"

over=0; full=0; worst=0
p=1
while (( p <= RUNS )); do
    rm -f "$W"/out.* "$W"/end.* "$W"/start.*
    pids=()
    for k in 1 2 3 4 5 6; do
        now_up t; printf "%s" "$t" > "$W/start.$k"
        ( printf '%s' "$PAYLOAD" | bash "$HOOK" --part "$k" > "$W/out.$k" 2>/dev/null; now_up t; printf "%s" "$t" > "$W/end.$k" ) &
        pids+=("$!")
    done
    # These six only: a bare wait would also wait for the load, which never ends on its own.
    wait "${pids[@]}"
    line="prompt $p:"; got=""; notes=""; n=0
    for k in 1 2 3 4 5 6; do
        ms=$(awk -v a="$(<"$W/start.$k")" -v b="$(<"$W/end.$k")" 'BEGIN { printf "%d", (b - a) * 1000 }')
        (( ms > worst )) && worst=$ms
        flag=""; (( ms >= LIMIT * 1000 )) && { flag="!TIMEOUT"; over=$(( over + 1 )); }
        line+=" p$k=${ms}ms$flag"
        if [[ -s "$W/out.$k" ]]; then
            ctx="$(jq -j '(.hookSpecificOutput.additionalContext // "") + "."' "$W/out.$k" 2>/dev/null | tr -d '\r')"; ctx="${ctx%.}"
            sm="$(jq -j '.systemMessage // ""' "$W/out.$k" 2>/dev/null)"
            [[ -n "$sm" ]] && notes+=" [p$k shows the person: ${sm:0:90}]"
            if [[ "$ctx" == *"This is PART $k OF "* ]]; then got+="${ctx#*$'\n\n'}"; n=$(( n + 1 ))
            elif [[ -n "$ctx" ]]; then notes+=" [p$k tells the assistant: ${ctx:0:110}]"; fi
        fi
    done
    if [[ "$got" == "$want" ]]; then line+=" | set arrived whole, in order, $n parts"; full=$(( full + 1 ))
    else line+=" | set NOT whole ($n parts, ${#got} of ${#want} bytes)"; fi
    echo "$line$notes"
    p=$(( p + 1 ))
done
e2="$(empty_ms) $(empty_ms) $(empty_ms)"
echo "empty command after: $e2 ms"
echo "SUMMARY: $RUNS prompts, parts over the ${LIMIT}s limit: $over, slowest part ${worst} ms, prompts whose set arrived whole: $full"
