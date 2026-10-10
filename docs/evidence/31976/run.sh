#!/usr/bin/env bash
# run.sh - time the per-prompt formation check exactly as Claude Code launches it (#31976).
#
# Usage: run.sh RUNS OUTFILE [trace] -- LABEL=HANDLER_DIR,HOOKS_JSON [LABEL=HANDLER_DIR,HOOKS_JSON ...]
#
# With more than one LABEL, every round runs each in turn, so they all see the same moment's load.
#
# Each run:
#   - builds a fresh isolated HOME and TMPDIR: the handlers copied to HOME/.claude/mmry/hooks-handlers,
#     a config naming a local stub service, and a membership record for session "sess-measure"
#     that already carries a last-seen time, as a member that has been shown earlier messages does;
#   - runs the UserPromptSubmit formation-check registration VERBATIM from HOOKS_JSON, under
#     `bash -c`, with a UserPromptSubmit payload on stdin and CLAUDE_CODE_SESSION_ID set, as Claude
#     Code does: the sh membership gate, then hook-guard.sh, then formation-check.sh;
#   - total = launch to exit; prep = launch to the stub receiving the request.
# Before each run it records the machine's node.exe and bash.exe process counts (tasklist).
# With "trace", every bash in the chain writes a timestamped xtrace (tracer.bash) to OUTFILE.trace.LABEL.N.
#
# NOSYSJQ_PLUGIN=<plugin root>: the machine most Windows customers have, with no jq on PATH. Every
# PATH directory holding a jq is dropped and CLAUDE_PLUGIN_ROOT is set to the plugin root (Claude
# Code sets it for plugin hooks), so the check finds the bundled jq under vendor/jq.
set -u
RUNS="$1"; OUT="$2"; TRACE=""; shift 2
[[ "${1:-}" == "trace" ]] && { TRACE=1; shift; }
[[ "${1:-}" == "--" ]] && shift
HERE="$(cd "$(dirname "$0")" && pwd)"
labels=(); hds=(); cmds=()
for spec in "$@"; do
    l="${spec%%=*}"; rest="${spec#*=}"; hd="${rest%%,*}"; hj="${rest#*,}"
    c="$(jq -r '.hooks.UserPromptSubmit[1].hooks[0].command' "$hj")"
    [[ "$c" == *formation-check* ]] || { echo "no formation-check registration in $hj" >&2; exit 1; }
    labels+=("$l"); hds+=("$hd"); cmds+=("$c")
done
runpath="$PATH"; pr=()
if [[ -n "${NOSYSJQ_PLUGIN:-}" ]]; then
    runpath=""
    IFS=: read -r -a _dirs <<< "$PATH"
    for d in "${_dirs[@]}"; do
        [[ -e "$d/jq" || -e "$d/jq.exe" ]] && continue
        runpath="${runpath:+${runpath}:}${d}"
    done
    pr=(CLAUDE_PLUGIN_ROOT="$NOSYSJQ_PLUGIN")
fi
STUBDIR="$(mktemp -d "${TMPDIR:-/tmp}/31976-stub-XXXX")"
node "${HERE}/stub.js" "$STUBDIR" >/dev/null 2>&1 &
STUBPID=$!
for _ in $(seq 1 100); do [[ -s "${STUBDIR}/port" ]] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "${STUBDIR}/port")"
printf 'impl run total_ms prep_ms delivered node_procs bash_procs\n' > "$OUT"
for i in $(seq 1 "$RUNS"); do
  for k in "${!labels[@]}"; do
    label="${labels[$k]}"; HD="${hds[$k]}"; CMD="${cmds[$k]}"
    np="$(tasklist //FI 'IMAGENAME eq node.exe' //NH 2>/dev/null | grep -c node.exe)"
    bp="$(tasklist //FI 'IMAGENAME eq bash.exe' //NH 2>/dev/null | grep -c bash.exe)"
    sb="$(mktemp -d "${TMPDIR:-/tmp}/31976-run-XXXX")"
    mkdir -p "${sb}/home/.claude/mmry" "${sb}/tmp"
    cp -r "$HD" "${sb}/home/.claude/mmry/hooks-handlers"
    printf '{"apiUrl":"%s","authMethod":"apikey","apiKey":"k_measure"}' "$URL" > "${sb}/home/.claude/mmry-config.json"
    printf '42\n2026-10-09T23:00:00.000\n' > "${sb}/tmp/.mmry-formation-sess-measure"
    : > "${STUBDIR}/arrivals"
    payload='{"session_id":"sess-measure","hook_event_name":"UserPromptSubmit","prompt":"hi"}'
    tf="${OUT}.trace.${label}.${i}"
    benv=(); [[ -n "$TRACE" ]] && { benv=(BASH_ENV="${HERE}/tracer.bash" MMRY_PROF_LOG="$tf"); : > "$tf"; }
    t0=$(( ${EPOCHREALTIME/./} / 1000 ))
    [[ -n "$TRACE" ]] && echo "T0 ${t0}" >> "$tf"
    out="$(printf '%s' "$payload" \
        | env -u CLAUDE_PLUGIN_ROOT -u MMRY_CONFIG_FILE -u MMRY_JQ -u CLAUDE_SESSION_ID -u MMRY_HOST -u CODEX_HOME -u BASH_ENV \
            PATH="$runpath" HOME="${sb}/home" TMPDIR="${sb}/tmp" CLAUDE_CODE_SESSION_ID=sess-measure "${pr[@]}" "${benv[@]}" \
            bash -c "$CMD" 2>/dev/null)"
    t1=$(( ${EPOCHREALTIME/./} / 1000 ))
    arr="$(head -1 "${STUBDIR}/arrivals")"
    prep="NA"; [[ -n "$arr" ]] && prep=$(( arr - t0 ))
    d=no; [[ "$out" == *MEASURE-MSG* ]] && d=yes
    printf '%s %s %s %s %s %s %s\n' "$label" "$i" "$(( t1 - t0 ))" "$prep" "$d" "$np" "$bp" | tee -a "$OUT"
    rm -rf "$sb"
  done
done
kill "$STUBPID" 2>/dev/null
rm -rf "$STUBDIR"
