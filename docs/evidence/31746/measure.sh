#!/usr/bin/env bash
# measure.sh - time the UserPromptSubmit formation check exactly as Claude Code launches it (#31746).
#
# Usage: measure.sh OLD_HANDLER_DIR NEW_HANDLER_DIR RUNS OUTFILE
#
# For each run, alternating OLD and NEW so both see the same machine load:
#   - a fresh isolated HOME and TMPDIR, with a config pointing at a local stub service and a
#     formation state file for the session, so every run delivers one message;
#   - the registered command, verbatim from hooks.json:
#       bash -c "[ -f ~/.claude/mmry/hooks-handlers/formation-check.sh ] || exit 0;
#                bash ~/.claude/mmry/hooks-handlers/hook-guard.sh formation-check"
#     with the UserPromptSubmit payload on stdin, as Claude Code sends it;
#   - total = wall time of that command, from just before launch to exit;
#   - prep  = from launch to the moment the stub service received the request (the stub logs its
#             arrival time in ms). That is everything the check does before it asks anything.
# The stub answers at once, so total - prep is the request plus rendering and exit.
set -u
OLD="$1"; NEW="$2"; RUNS="${3:-10}"; OUT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
STUBDIR="$(mktemp -d "${HERE}/stub-XXXX")"
cat > "${STUBDIR}/stub.js" <<'STUB'
const http = require("http"), fs = require("fs"), dir = process.argv[2];
const body = JSON.stringify([{senderRole:"lead",senderSessionID:"lead-1",senderUserID:1,content:"MEASURE-MSG",sentDate:"2026-10-07T01:00:00"}]);
const srv = http.createServer((q, r) => {
    fs.appendFileSync(dir + "/arrivals", Date.now() + "\n");
    r.writeHead(200, {"Content-Type": "application/json"});
    r.end(/[?&]since=./.test(q.url) ? "[]" : body);
});
srv.listen(0, "127.0.0.1", () => fs.writeFileSync(dir + "/port", String(srv.address().port)));
STUB
node "${STUBDIR}/stub.js" "$STUBDIR" >/dev/null 2>&1 &
STUBPID=$!
for _ in $(seq 1 100); do [[ -s "${STUBDIR}/port" ]] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "${STUBDIR}/port")"

ms() { local t; t="$(date +%s%N)"; echo $(( 10#$t / 1000000 )); }

printf 'impl run total_ms prep_ms delivered\n' > "$OUT"
for i in $(seq 1 "$RUNS"); do
    for impl in old new old-codex new-codex; do
        hd="$OLD"; [[ "$impl" == new* ]] && hd="$NEW"
        sb="$(mktemp -d "${HERE}/m-XXXX")"
        mkdir -p "${sb}/home/.claude/mmry" "${sb}/tmp"
        cp -r "$hd" "${sb}/home/.claude/mmry/hooks-handlers"
        printf '{"apiUrl":"%s","authMethod":"apikey","apiKey":"k_measure"}' "$URL" > "${sb}/home/.claude/mmry-config.json"
        printf '42\n' > "${sb}/tmp/.mmry-formation-sess-measure"
        : > "${STUBDIR}/arrivals"
        payload='{"session_id":"sess-measure","hook_event_name":"UserPromptSubmit","prompt":"hi"}'
        if [[ "$impl" == *codex ]]; then
            # Codex on Windows, as codex-hooks.json registers it (commandWindows):
            #   cmd /d /c "<plugin>\hooks-handlers\codex-hook.cmd" formation-check
            mkdir -p "${sb}/plugin" "${sb}/codex"
            cp -r "$hd" "${sb}/plugin/hooks-handlers"
            printf '{"apiUrl":"%s","authMethod":"apikey","apiKey":"k_measure"}' "$URL" > "${sb}/codex/mmry-config.json"
            launcher="$(cygpath -w "${sb}/plugin/hooks-handlers/codex-hook.cmd")"
            t0="$(ms)"
            out="$(printf '%s' "$payload" \
                | env -u CLAUDE_PLUGIN_ROOT -u MMRY_CONFIG_FILE -u MMRY_JQ -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u MMRY_HOST \
                    HOME="${sb}/home" TMPDIR="${sb}/tmp" CODEX_HOME="${sb}/codex" \
                    cmd //d //c "$launcher" formation-check 2>/dev/null)"
        else
            t0="$(ms)"
            out="$(printf '%s' "$payload" \
                | env -u CLAUDE_PLUGIN_ROOT -u MMRY_CONFIG_FILE -u MMRY_JQ -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u MMRY_HOST \
                    HOME="${sb}/home" TMPDIR="${sb}/tmp" \
                    bash -c "[ -f ~/.claude/mmry/hooks-handlers/formation-check.sh ] || exit 0; bash ~/.claude/mmry/hooks-handlers/hook-guard.sh formation-check" 2>/dev/null)"
        fi
        t1="$(ms)"
        arr="$(head -1 "${STUBDIR}/arrivals")"
        prep="NA"; [[ -n "$arr" ]] && prep=$(( arr - t0 ))
        d=no; [[ "$out" == *MEASURE-MSG* ]] && d=yes
        printf '%s %s %s %s %s\n' "$impl" "$i" "$(( t1 - t0 ))" "$prep" "$d" | tee -a "$OUT"
        rm -rf "$sb"
    done
done
kill "$STUBPID" 2>/dev/null
rm -rf "$STUBDIR"
