#!/usr/bin/env bash
# #31743 live run: MMRY's MCP tools inside the REAL Codex, against the live Integration service.
#
# What it does, on whatever machine runs it (Windows Git Bash or macOS/Linux bash):
#   1. installs THIS checkout's plugin into a throwaway Codex home, exactly as a customer does
#      (codex plugin marketplace add <path>; codex plugin add mmry@mmry-plugin);
#   2. registers a throwaway subscriber on Integration (*@test.mnemo) and issues it an API key,
#      which is passed to Codex in the environment only: it is never written to a file or printed;
#   3. starts `codex app-server` (what the desktop app runs) through app-server-driver.js, opens two
#      conversations, and calls the tools: save, search, reinforce, link, retire (Requirement 1);
#      join, say, progress (Requirement 2); each conversation joins a DIFFERENT formation
#      (Requirement 3), then reload;
#   4. has each formation's lead send a marked message, then runs the plugin's own delivery hook
#      (formation-check, through codex-hook.sh, with the payload Codex gives it) once per
#      conversation, and checks each one receives its own formation's message and not the other's.
#
# What it does NOT prove: that the MODEL's call is not met with a prompt. A call made by the app
# through mcpServer/tool/call is not reviewed by the approval policy. That part is read from Codex's
# source (see README.md) and is the live check the Mac and Windows Codex members run in the app.
#
# Usage: bash live-integration.sh [API_BASE_URL]      (default: Integration)
# Needs: codex (0.160 or later) on PATH, node, curl. Nothing outside a fresh temp folder is touched.
set -uo pipefail

API="${1:-https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PLUGIN="$REPO/mmry"
JQ="${JQ:-}"
if [[ -z "$JQ" ]]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) JQ="$PLUGIN/vendor/jq/jq-windows-amd64.exe" ;;
        Darwin) [[ "$(uname -m)" == arm64 ]] && JQ="$PLUGIN/vendor/jq/jq-macos-arm64" || JQ="$PLUGIN/vendor/jq/jq-macos-amd64" ;;
        *) JQ="jq" ;;
    esac
fi
W="$(mktemp -d)"
TS="$(date +%s)"
fails=0
say()  { printf '%s\n' "$*"; }
pass() { say "PASS  $*"; }
fail() { say "FAIL  $*"; fails=$((fails+1)); }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
uuid() { node -e 'console.log(require("crypto").randomUUID())'; }

# ---- an isolated machine: home, temp and Codex home are all fresh ----------------------------
mkdir -p "$W/home" "$W/tmp" "$W/codex" "$W/proj"
export HOME="$W/home" TMPDIR="$W/tmp" CODEX_HOME="$(native "$W/codex")"
if command -v cygpath >/dev/null 2>&1; then
    export USERPROFILE="$(native "$W/home")" TEMP="$(native "$W/tmp")" TMP="$(native "$W/tmp")"
fi
unset MMRY_CONFIG_FILE CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_PLUGIN_ROOT

say "#31743 live run  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "API      $API"
say "health   $(curl -s -m 30 "$API/api/health")"
say "plugin   $(git -C "$REPO" rev-parse HEAD)"
say "codex    $(codex --version 2>&1 | head -1)"
say "os       $(uname -s) $(uname -m)"
say ""

codex plugin marketplace add "$(native "$REPO")" >/dev/null 2>&1 || { say "marketplace add failed"; exit 2; }
codex plugin add mmry@mmry-plugin >/dev/null 2>&1 || { say "plugin add failed"; exit 2; }
say "installed: $(codex mcp list 2>&1 | awk 'NR==2 {print $1, $2}')"

# ---- a throwaway subscriber; the key lives in this process's environment only ----------------
REG="$(curl -s -m 120 -X POST "$API/api/auth/register" -H 'Content-Type: application/json' \
    -d "{\"subscriberName\":\"Mcp31743_$TS\",\"firstName\":\"Mcp\",\"lastName\":\"Tester\",\"email\":\"mcp31743_$TS@test.mnemo\",\"password\":\"TestPassword123!\"}")"
TOKEN="$(printf '%s' "$REG" | "$JQ" -r '.token // empty')"
[[ -n "$TOKEN" ]] || { say "register failed: $(printf '%s' "$REG" | head -c 300)"; exit 2; }
MMRY_API_KEY="$(curl -s -m 120 -X POST "$API/api/auth/apikey" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d '{"label":"31743 live"}' | "$JQ" -r '.apiKey // empty')"
[[ -n "$MMRY_API_KEY" ]] || { say "api key failed"; exit 2; }
export MMRY_API_KEY MMRY_API_URL="$API" MMRY_NO_SELF_UPDATE=1
unset TOKEN REG
say "subscriber Mcp31743_$TS registered; API key issued (in the environment only, not shown)"

# The plugin's own scripts, as the lead of each formation runs them from a shell.
as_session() { # session-id script args...
    local sid="$1" script="$2"; shift 2
    ( cd "$W/proj" && env MMRY_HOST=codex CODEX_SESSION_ID="$sid" CODEX_THREAD_ID="$sid" \
        bash "$PLUGIN/hooks-handlers/$script" "$@" </dev/null 2>&1 )
}
LEAD1="$(uuid)"; LEAD2="$(uuid)"
F1="$(as_session "$LEAD1" formation-start.sh "31743 live F1 $TS" | sed -n 's/^Started formation \([0-9]*\).*/\1/p')"
F2="$(as_session "$LEAD2" formation-start.sh "31743 live F2 $TS" | sed -n 's/^Started formation \([0-9]*\).*/\1/p')"
[[ -n "$F1" && -n "$F2" ]] || { say "could not start the two formations"; exit 2; }
say "formations F1=$F1 (lead $LEAD1) F2=$F2 (lead $LEAD2)"
say ""

MARK="MARK31743_$TS"
cat > "$W/plan.json" <<EOF
{"cwd": $(printf '%s' "$(native "$W/proj")" | "$JQ" -Rs .), "threads": 2, "threadsOut": $(printf '%s' "$(native "$W/threads.txt")" | "$JQ" -Rs .),
 "steps": [
  {"sleep": 3000},
  {"list": 0},
  {"t": 0, "tool": "memory_save", "args": {"content": "DECISION: ${MARK}_A is the first marked test memory for the Codex MCP live run.", "working_dir": $(printf '%s' "$(native "$W/proj")" | "$JQ" -Rs .)}},
  {"t": 0, "tool": "memory_save", "args": {"content": "DECISION: ${MARK}_B is the second marked test memory for the Codex MCP live run."}},
  {"t": 0, "tool": "memory_search", "args": {"query": "${MARK}_A"}, "until": "id [0-9]+", "retries": 36, "retryDelay": 5000, "capture": {"idA": "id ([0-9]+)"}},
  {"t": 0, "tool": "memory_search", "args": {"query": "${MARK}_B"}, "until": "id [0-9]+", "retries": 36, "retryDelay": 5000, "capture": {"idB": "id ([0-9]+)"}},
  {"t": 0, "tool": "memory_reinforce", "args": {"id": "\${idA}"}},
  {"t": 0, "tool": "memory_link", "args": {"source_id": "\${idA}", "target_id": "\${idB}", "link_type": "related"}},
  {"t": 0, "tool": "memory_retire", "args": {"id": "\${idB}"}},
  {"t": 0, "tool": "memory_search", "args": {"query": "${MARK}_B"}},
  {"t": 0, "tool": "formation_join", "args": {"formation_id": $F1}},
  {"t": 1, "tool": "formation_join", "args": {"formation_id": $F2}},
  {"t": 0, "tool": "formation_roster"},
  {"t": 1, "tool": "formation_roster"},
  {"t": 0, "tool": "formation_say", "args": {"message": "FROM-T0-$TS hello from conversation 0"}},
  {"t": 1, "tool": "formation_say", "args": {"message": "FROM-T1-$TS hello from conversation 1"}},
  {"t": 0, "tool": "formation_progress", "args": {"state": "Accepted", "note": "PROGRESS-T0-$TS"}},
  {"t": 0, "tool": "memory_load", "args": {"working_dir": $(printf '%s' "$(native "$W/proj")" | "$JQ" -Rs .)}}
 ]}
EOF
node "$HERE/app-server-driver.js" "$W/plan.json" > "$W/driver.txt" 2>&1
cat "$W/driver.txt"
say ""
T0="$(sed -n 1p "$W/threads.txt" | tr -d '\r')"; T1="$(sed -n 2p "$W/threads.txt" | tr -d '\r')"
D="$(cat "$W/driver.txt")"

# ---- Requirement 1 ----------------------------------------------------------------------------
grep -q "server mmry runtimeStatus" <<< "$D" && pass "R1 Codex started the plugin's MCP server and listed its tools" || fail "R1 server not listed"
[[ "$(grep -c 'call t0 memory_save .*isError=false' <<< "$D")" == 2 ]] && pass "R1 save x2 reached MMRY AI from Codex" || fail "R1 save"
grep -q 'captured idA=' <<< "$D" && grep -q 'captured idB=' <<< "$D" && pass "R1 search found both marked memories by id" || fail "R1 search"
grep -q 'call t0 memory_reinforce .*isError=false' <<< "$D" && pass "R1 reinforce" || fail "R1 reinforce"
grep -q 'call t0 memory_link .*isError=false' <<< "$D" && pass "R1 link" || fail "R1 link"
grep -q 'call t0 memory_retire .*isError=false' <<< "$D" && pass "R1 retire" || fail "R1 retire"
# The LAST search for B, the one made after it was retired.
awk '/call t0 memory_search .*_B"} isError=/ {buf=""; f=1; next} f && /^\[[0-9.]+s\]/ {f=0} f {buf = buf $0 "\n"} END {printf "%s", buf}' <<< "$D" > "$W/after-retire.txt"
grep -q "Found 0 memories" "$W/after-retire.txt" && pass "R1 the retired memory is no longer found" || fail "R1 retired memory still found: $(head -c 200 "$W/after-retire.txt")"

# ---- Requirement 2 ----------------------------------------------------------------------------
grep -q "call t0 formation_join .*isError=false" <<< "$D" && grep -q "Joined formation $F1" <<< "$D" && pass "R2 conversation 0 joined F1 through the tool" || fail "R2 join t0"
grep -q "call t0 formation_say .*isError=false" <<< "$D" && pass "R2 say" || fail "R2 say"
grep -q "call t0 formation_progress .*isError=false" <<< "$D" && pass "R2 progress" || fail "R2 progress"
grep -q "call t0 memory_load .*isError=false" <<< "$D" && pass "reload (memory_load)" || fail "reload"

# ---- Requirement 3: each conversation is its own member, in its own formation -----------------
[[ -f "$W/tmp/.mmry-formation-$T0" ]] && [[ "$(head -1 "$W/tmp/.mmry-formation-$T0" | tr -d '\r')" == "$F1" ]] \
    && pass "R3 conversation 0's membership is recorded under its own id, in F1" || fail "R3 state t0"
[[ -f "$W/tmp/.mmry-formation-$T1" ]] && [[ "$(head -1 "$W/tmp/.mmry-formation-$T1" | tr -d '\r')" == "$F2" ]] \
    && pass "R3 conversation 1's membership is recorded under its own id, in F2" || fail "R3 state t1"
as_session "$LEAD1" formation-say.sh "FOR-F1-$TS lead one to formation one" >/dev/null
as_session "$LEAD2" formation-say.sh "FOR-F2-$TS lead two to formation two" >/dev/null
sleep 2
deliver() { # session-id -> what the delivery hook gives the model for that conversation
    printf '{"session_id":"%s","hook_event_name":"PostToolUse","cwd":"%s"}' "$1" "$(native "$W/proj" | sed 's/\\/\\\\/g')" \
        | ( cd "$W/proj" && sh "$PLUGIN/hooks-handlers/codex-hook.sh" formation-check 2>&1 )
}
O0="$(deliver "$T0")"; O1="$(deliver "$T1")"
say "delivery to conversation 0: $(printf '%s' "$O0" | head -c 600)"
say "delivery to conversation 1: $(printf '%s' "$O1" | head -c 600)"
grep -q "FOR-F1-$TS" <<< "$O0" && ! grep -q "FOR-F2-$TS" <<< "$O0" && pass "R3 conversation 0 received F1's message and not F2's" || fail "R3 delivery t0"
grep -q "FOR-F2-$TS" <<< "$O1" && ! grep -q "FOR-F1-$TS" <<< "$O1" && pass "R3 conversation 1 received F2's message and not F1's" || fail "R3 delivery t1"
L1="$(printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$LEAD1" | ( cd "$W/proj" && sh "$PLUGIN/hooks-handlers/codex-hook.sh" formation-check 2>&1 ))"
grep -q "FROM-T0-$TS" <<< "$L1" && ! grep -q "FROM-T1-$TS" <<< "$L1" && pass "R2/R3 F1's lead received conversation 0's message and not conversation 1's" || fail "R2 lead1 delivery: $(printf '%s' "$L1" | head -c 300)"

# ---- tidy up: leave, and stand the formations down -------------------------------------------
for s in "$T0" "$T1" "$LEAD1" "$LEAD2"; do as_session "$s" formation-leave.sh >/dev/null 2>&1 || true; done
say ""
say "fails=$fails  (work folder $W)"
exit $(( fails > 0 ))
