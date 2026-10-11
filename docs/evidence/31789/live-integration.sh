#!/usr/bin/env bash
# #31789 live run: a Codex LEAD, inside the REAL Codex, against the live Integration service.
#
# What it does, on whatever machine runs it (Windows Git Bash or macOS/Linux bash):
#   1. installs THIS checkout's plugin into a throwaway Codex home, exactly as a customer does;
#   2. registers a throwaway subscriber on Integration (*@test.mnemo) and issues it an API key,
#      which is passed to Codex in the environment only: never written to a file or printed;
#   3. starts `codex app-server` (what the desktop app runs) with two conversations, t0 the lead
#      and t1 a member, and drives the whole lead flow through MMRY's own tools:
#        TC1  t0 formation_start; the reply carries the id; t1 formation_join by that id
#        TC2  t0 formation_assign to t1; t1's delivery hook shows the assignment, directed at it
#        R0   t1 reports Done and messages the lead; the lead conversation is then left IDLE for a
#             minute and every notification the app-server sends about it is recorded: an idle
#             lead that anything woke would show a turn starting
#        TC3  the lead's next prompt (its UserPromptSubmit delivery hook) shows the Done report
#             and the message; t0 formation_roster shows the member's Done state
#        TC4  t0 formation_report, then formation_debrief; the close-out record is read back with
#             formation_report by id after the close; t1 formation_leave
#        R3   the start and assign replies carry the next-action wording
#   4. checks that no tool answer names a script for an operation a tool covers (#31743).
#
# What it does NOT prove: anything about the MODEL. A call made by the app through
# mcpServer/tool/call is not reviewed by the approval policy and runs no hooks, so the delivery
# hooks are run here exactly as Codex runs them, with the payload Codex gives them. That a model in
# Codex chooses these tools from plain words, with no Internet access prompt, is the live procedure
# in README.md, run by the Codex members on Mac and Windows.
#
# Usage: bash live-integration.sh [API_BASE_URL]      (default: Integration)
# Needs: codex (0.160 or later) on PATH, node, curl. Nothing outside a fresh temp folder is touched.
set -uo pipefail

API="${1:-https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net}"
case "$API" in
    *mnemo-dffsh5b3b6gadpcu*|*mmryai.com*) echo "refusing to run against production: $API"; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PLUGIN="$REPO/mmry"
DRIVER="$REPO/docs/evidence/31743/app-server-driver.js"
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
jstr() { printf '%s' "$1" | "$JQ" -Rs .; }

# ---- an isolated machine: home, temp and Codex home are all fresh ----------------------------
mkdir -p "$W/home" "$W/tmp" "$W/codex" "$W/proj"
export HOME="$W/home" TMPDIR="$W/tmp" CODEX_HOME="$(native "$W/codex")"
if command -v cygpath >/dev/null 2>&1; then
    export USERPROFILE="$(native "$W/home")" TEMP="$(native "$W/tmp")" TMP="$(native "$W/tmp")"
fi
unset MMRY_CONFIG_FILE CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_PLUGIN_ROOT
export BASH_BIN="$(native "$(command -v bash)")"

say "#31789 live run  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "API      $API"
say "health   $(curl -s -m 30 "$API/api/health")"
say "plugin   $(git -C "$REPO" rev-parse HEAD)"
say "codex    $(codex --version 2>&1 | head -1)"
say "os       $(uname -s) $(uname -m)"
# R0 context: the in-turn clock.sleep tool is feature-gated (Feature::SleepTool). Recorded, not relied on.
say "features naming sleep: $(codex features list 2>/dev/null | grep -i 'sleep' | tr -s ' ' | paste -sd';' - || true)"
say ""

codex plugin marketplace add "$(native "$REPO")" >/dev/null 2>&1 || { say "marketplace add failed"; exit 2; }
codex plugin add mmry@mmry-plugin >/dev/null 2>&1 || { say "plugin add failed"; exit 2; }
say "installed: $(codex mcp list 2>&1 | awk 'NR==2 {print $1, $2}')"

# ---- a throwaway subscriber; the key lives in this process's environment only ----------------
REG="$(curl -s -m 120 -X POST "$API/api/auth/register" -H 'Content-Type: application/json' \
    -d "{\"subscriberName\":\"Lead31789_$TS\",\"firstName\":\"Lead\",\"lastName\":\"Tester\",\"email\":\"lead31789_$TS@test.mnemo\",\"password\":\"TestPassword123!\"}")"
TOKEN="$(printf '%s' "$REG" | "$JQ" -r '.token // empty')"
[[ -n "$TOKEN" ]] || { say "register failed: $(printf '%s' "$REG" | head -c 300)"; exit 2; }
MMRY_API_KEY="$(curl -s -m 120 -X POST "$API/api/auth/apikey" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d '{"label":"31789 live"}' | "$JQ" -r '.apiKey // empty')"
[[ -n "$MMRY_API_KEY" ]] || { say "api key failed"; exit 2; }
export MMRY_API_KEY MMRY_API_URL="$API" MMRY_NO_SELF_UPDATE=1
unset TOKEN REG
say "subscriber Lead31789_$TS registered; API key issued (in the environment only, not shown)"
say ""

# The plugin's own delivery hook for one conversation, run through codex-hook.sh with the payload
# Codex gives it. $1 conversation id, $2 hook event (PostToolUse or UserPromptSubmit).
# The project path, escaped for JSON (Windows backslashes doubled), written single-quoted below.
CWD_JSON="$(native "$W/proj" | sed 's/\\/\\\\/g')"
cat > "$W/deliver.sh" <<EOF
#!/usr/bin/env bash
sid="\$1"; ev="\$2"
cwd='$CWD_JSON'
if [[ "\$ev" == UserPromptSubmit ]]; then
    payload="{\"session_id\":\"\$sid\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"any news from the formation?\",\"cwd\":\"\$cwd\"}"
else
    payload="{\"session_id\":\"\$sid\",\"hook_event_name\":\"PostToolUse\",\"cwd\":\"\$cwd\"}"
fi
cd "$W/proj" && printf '%s' "\$payload" | sh "$PLUGIN/hooks-handlers/codex-hook.sh" formation-check 2>&1
EOF

MARK="M31789_$TS"
PROJ_J="$(jstr "$(native "$W/proj")")"
DELIVER_J="$(jstr "$(native "$W/deliver.sh")")"
cat > "$W/plan.json" <<EOF
{"cwd": $PROJ_J, "threads": 2, "threadsOut": $(jstr "$(native "$W/threads.txt")"),
 "steps": [
  {"sleep": 3000},
  {"list": 0},
  {"t": 0, "tool": "formation_start", "args": {"objective": "31789 live lead run $MARK: ship the checkout tests", "working_dir": $PROJ_J}, "capture": {"fid": "Started formation ([0-9]+)"}},
  {"t": 1, "tool": "formation_join", "args": {"formation_id": "\${fid}", "working_dir": $PROJ_J}},
  {"t": 0, "tool": "formation_roster", "capture": {"mid": "([0-9]+)  Wingman", "lid": "([0-9]+)  Lead"}},
  {"t": 0, "tool": "formation_assign", "args": {"member_id": "\${mid}", "assignment": "ASSIGN-$MARK write the checkout tests"}},
  {"exec": [$DELIVER_J, "\${t1}", "PostToolUse"], "label": "deliver-to-member"},
  {"t": 1, "tool": "formation_progress", "args": {"state": "Done", "note": "DONE-$MARK tests written and passing"}},
  {"t": 1, "tool": "formation_say", "args": {"message": "REPORT-$MARK done: the checkout tests are written and pass", "to_member_id": "\${lid}"}},
  {"watch": 60000, "t": 0},
  {"exec": [$DELIVER_J, "\${t0}", "UserPromptSubmit"], "label": "deliver-to-lead-next-prompt"},
  {"t": 0, "tool": "formation_roster"},
  {"t": 0, "tool": "formation_report"},
  {"t": 0, "tool": "formation_debrief", "args": {"summary": "31789 live run $MARK: the member wrote and passed the checkout tests; the lead assigned, read the Done report and closed out. Nothing went wrong."}},
  {"t": 0, "tool": "formation_report", "args": {"formation_id": "\${fid}"}},
  {"t": 1, "tool": "formation_leave"}
 ]}
EOF
node "$DRIVER" "$W/plan.json" > "$W/driver.txt" 2>&1
cat "$W/driver.txt"
say ""
T0="$(sed -n 1p "$W/threads.txt" | tr -d '\r')"; T1="$(sed -n 2p "$W/threads.txt" | tr -d '\r')"
D="$(cat "$W/driver.txt")"
FID="$(sed -n 's/.*captured fid=\([0-9]*\).*/\1/p' <<< "$D" | head -1)"
MID="$(sed -n 's/.*captured mid=\([0-9]*\).*/\1/p' <<< "$D" | head -1)"
LID="$(sed -n 's/.*captured lid=\([0-9]*\).*/\1/p' <<< "$D" | head -1)"

# The text of one tool answer: everything after its "call tN tool" line up to the next log line.
answer() { # $1 thread number, $2 tool, $3 occurrence (1-based, default 1)
    awk -v t="call t$1 $2 " -v want="${3:-1}" '
        index($0, t) { n++; if (n == want) { on = 1; print; next } }
        on && /^\[[0-9.]+s\]/ { exit }
        on { print }' <<< "$D"
}
exec_out() { awk -v l="exec $1 " -v e="end exec $1" 'index($0, l) { on = 1; next } index($0, e) { exit } on { print }' <<< "$D"; }

grep -q "server mmry_plugin runtimeStatus" <<< "$D" && pass "setup Codex started the plugin's MCP server" || fail "setup server not listed"
grep -q "    formation_start " <<< "$D" && grep -q "    formation_debrief " <<< "$D" \
    && pass "setup Codex lists the lead's tools (formation_start ... formation_debrief)" || fail "setup lead tools not listed"

# ---- TC1: start in plain words is the model's part; here, the tool and its id, and a join by it --
START="$(answer 0 formation_start)"
[[ -n "$FID" ]] && grep -q 'isError=false' <<< "$START" && grep -q "Started formation $FID" <<< "$START" \
    && pass "TC1 the lead started formation $FID through formation_start and was given its id" || fail "TC1 start: $(head -c 300 <<< "$START")"
grep -q "formation_join tool with formation_id $FID" <<< "$START" && pass "TC1 the reply tells the lead how the others join, by that id" || fail "TC1 join instruction"
JOIN="$(answer 1 formation_join)"
grep -q 'isError=false' <<< "$JOIN" && grep -q "Joined formation $FID" <<< "$JOIN" && pass "TC1 a second conversation joined formation $FID by its id" || fail "TC1 join: $(head -c 300 <<< "$JOIN")"
[[ "$(head -1 "$W/tmp/.mmry-formation-$T1" 2>/dev/null | tr -d '\r')" == "$FID" || ! -e "$W/tmp/.mmry-formation-$T1" ]] \
    && pass "TC1 the member's membership was recorded under its own conversation id" || fail "TC1 member state"

# ---- R0 and R3, on the live start reply -----------------------------------------------------------
for phrase in "Codex cannot wake an idle conversation" "only on its next action" "never while it sits idle" \
    "we recommend it does not lead one" "start the formation from a Claude Code session"; do
    grep -q "$phrase" <<< "$(tr '\n' ' ' <<< "$START")" || { fail "R0/R3 the live start reply lacks: $phrase"; continue; }
done
grep -q "Codex cannot wake an idle conversation" <<< "$START" && pass "R0/R3 the live start reply states the limit, what to do instead, and recommends a Claude Code lead"

# ---- TC2 -------------------------------------------------------------------------------------------
[[ -n "$MID" && -n "$LID" ]] && pass "TC2 the roster gave the member's id ($MID) and the lead's ($LID)" || fail "TC2 roster ids"
ASSIGN="$(answer 0 formation_assign)"
grep -q 'isError=false' <<< "$ASSIGN" && grep -q "Member $MID in formation $FID is now Wingman, working on: ASSIGN-$MARK" <<< "$ASSIGN" \
    && pass "TC2 the lead assigned work to member $MID" || fail "TC2 assign: $(head -c 300 <<< "$ASSIGN")"
grep -q "reach you on your next action, not while this conversation sits idle" <<< "$ASSIGN" \
    && pass "R3 the live assign reply carries the next-action wording" || fail "R3 assign wording"
DM="$(exec_out deliver-to-member)"
say "delivery to the member: $(head -c 700 <<< "$DM")"
grep -q "ASSIGN-$MARK" <<< "$DM" && grep -q "DIRECTED TO YOU" <<< "$DM" \
    && pass "TC2 the member sees the assignment, marked as directed at it" || fail "TC2 member did not see the assignment"

# ---- R0: an idle lead ------------------------------------------------------------------------------
WATCH="$(grep 'watch t0 ' <<< "$D")"
say "idle lead: $WATCH"
grep -q 'turn/started=0 ' <<< "$WATCH" \
    && pass "R0 for 60 s after the member's report, nothing started a turn on the idle lead conversation" || fail "R0 watch: $WATCH"

# ---- TC3 -------------------------------------------------------------------------------------------
grep -q 'call t1 formation_progress .*isError=false' <<< "$D" && pass "TC3 the member reported Done" || fail "TC3 progress"
grep -q 'call t1 formation_say .*isError=false' <<< "$D" && pass "TC3 the member messaged the lead" || fail "TC3 say"
DL="$(exec_out deliver-to-lead-next-prompt)"
say "delivery to the lead on its next prompt: $(head -c 900 <<< "$DL")"
grep -q "REPORT-$MARK" <<< "$DL" && pass "TC3 the lead sees the member's report on its next prompt" || fail "TC3 lead did not see the report"
grep -q '"hookEventName":"UserPromptSubmit"' <<< "$DL" && pass "TC3 it arrived as the next prompt's context (UserPromptSubmit)" || fail "TC3 not a UserPromptSubmit delivery"
ROSTER2="$(answer 0 formation_roster 2)"
grep -q "Done" <<< "$ROSTER2" && grep -q "DONE-$MARK\|Done" <<< "$ROSTER2" \
    && pass "TC3 the lead's roster shows the member's Done" || fail "TC3 roster: $(head -c 400 <<< "$ROSTER2")"

# ---- TC4 -------------------------------------------------------------------------------------------
REP1="$(answer 0 formation_report 1)"
grep -q 'isError=false' <<< "$REP1" && grep -q "ASSIGN-$MARK" <<< "$REP1" \
    && pass "TC4 the lead read the close-out record before closing out; it names the assignment" || fail "TC4 report before: $(head -c 400 <<< "$REP1")"
DEB="$(answer 0 formation_debrief)"
grep -q 'isError=false' <<< "$DEB" && grep -q "Formation $FID closed out" <<< "$DEB" \
    && pass "TC4 the lead debriefed and formation $FID closed out" || fail "TC4 debrief: $(head -c 600 <<< "$DEB")"
[[ ! -e "$W/tmp/.mmry-formation-$T0" ]] && pass "TC4 the lead's local membership was cleared" || fail "TC4 lead state not cleared"
REP2="$(answer 0 formation_report 2)"
grep -q 'isError=false' <<< "$REP2" && grep -q "ASSIGN-$MARK" <<< "$REP2" && grep -qi "done" <<< "$REP2" \
    && pass "TC4 the close-out record of formation $FID is written: read back after the close, it names the assignment and Done" || fail "TC4 record after close: $(head -c 600 <<< "$REP2")"
LEAVE="$(answer 1 formation_leave)"
grep -q 'isError=false' <<< "$LEAVE" && pass "TC4 the member left" || fail "TC4 leave: $(head -c 300 <<< "$LEAVE")"

# ---- #31743's rule, extended to the lead's tools ------------------------------------------------------
TOOL_COVERED_RE='(save-memory|search-memories|reinforce-memory|link-memories|deactivate-memory|session-start|formation-(join|say|roster|leave|start|assign|report|debrief))[.]sh'
if grep -qE "$TOOL_COVERED_RE" <<< "$D"; then
    fail "tools-first a tool answer names a tool-covered script: $(grep -oE ".{0,80}$TOOL_COVERED_RE" <<< "$D" | head -1)"
else
    pass "tools-first no tool answer in the run names a tool-covered script"
fi

say ""
say "fails=$fails  (work folder $W)"
exit $(( fails > 0 ))
