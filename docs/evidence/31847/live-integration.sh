#!/usr/bin/env bash
# #31847 live run: corrections saved through the plugin's own save-memory.sh, against a live API.
#
#   TC1 (live part)  save a memory, save a correction with --supersedes; the earlier memory is no
#                    longer readable and search returns only the correction. Claude Code layout.
#   TC2 (script leg) the same through a Codex install layout (MMRY_HOST=codex, handlers under
#                    ${CODEX_HOME}/mmry, the Codex config file). This is the plugin half of Codex;
#                    it does not drive the Codex CLI itself.
#   TC3              correct a private memory and a group memory; each correction keeps the
#                    original visibility and group (read back through the API). A correction that
#                    asks for a different visibility is refused and saves nothing.
#
# Uses a throwaway subscriber registered for this run, the convention of testing/backend in the
# API repo. Writes only that subscriber's memories. Deploys nothing. Secrets are never printed.
#
# Usage: bash live-integration.sh [API_BASE_URL]   (default: Integration)
#        MMRY_PLUGIN_DIR=<a checkout>/mmry runs another plugin version (the control run uses develop
#        before the port, a58acb6, where the correction is NOT expected to replace anything).
set -uo pipefail

API="${1:-https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="${MMRY_PLUGIN_DIR:-$(cd "$HERE/../../../mmry" && pwd)}"
W="$(mktemp -d)"
TS="$(date +%s)"
JQ="${JQ:-jq}"
fails=0

say()  { printf '%s\n' "$*"; }
pass() { say "PASS  $*"; }
fail() { say "FAIL  $*"; fails=$((fails+1)); }

api() { # method path [json]
    local m="$1" p="$2" d="${3:-}"
    if [[ -n "$d" ]]; then
        curl -s -m 120 -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$d"
    else
        curl -s -m 120 -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN"
    fi
}
code() { curl -s -m 60 -o /dev/null -w '%{http_code}' "$API$1" -H "Authorization: Bearer $TOKEN"; }

say "#31847 live run  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "API      $API"
say "health   $(curl -s -m 30 "$API/api/health")"
say "plugin   $(git -C "$PLUGIN" rev-parse HEAD)"
say ""

# --- a throwaway subscriber ------------------------------------------------------------------
REG="$(curl -s -m 120 -X POST "$API/api/auth/register" -H 'Content-Type: application/json' \
    -d "{\"subscriberName\":\"Corr31847_$TS\",\"firstName\":\"Corr\",\"lastName\":\"Tester\",\"email\":\"corr31847_$TS@test.mnemo\",\"password\":\"TestPassword123!\"}")"
TOKEN="$(printf '%s' "$REG" | "$JQ" -r '.token // empty')"
[[ -n "$TOKEN" ]] || { say "register failed: $(printf '%s' "$REG" | head -c 300)"; exit 2; }
KEY="$(api POST /api/auth/apikey '{"label":"31847 live"}' | "$JQ" -r '.apiKey // empty')"
[[ -n "$KEY" ]] || { say "api key failed"; exit 2; }
say "subscriber Corr31847_$TS registered; API key issued (not shown)"

# Claude Code layout: its own HOME, config file named directly.
mkdir -p "$W/home" "$W/tmp"
printf '{"apiUrl":"%s","authMethod":"apikey","apiKey":"%s"}' "$API" "$KEY" > "$W/home/mmry-config.json"
# Codex layout: handlers copied under ${CODEX_HOME}/mmry, as session-init.sh installs them.
CX="$W/codexhome"
mkdir -p "$CX/mmry/hooks-handlers" "$CX/mmry/setup"
cp "$PLUGIN"/hooks-handlers/* "$CX/mmry/hooks-handlers/"
cp "$PLUGIN"/setup/*.sh "$CX/mmry/setup/" 2>/dev/null || true
cp "$W/home/mmry-config.json" "$CX/mmry-config.json"

save_claude() { # prints output, returns exit
    env -u CLAUDE_SESSION_ID HOME="$W/home" TMPDIR="$W/tmp" MMRY_CONFIG_FILE="$W/home/mmry-config.json" \
        MMRY_NO_SELF_UPDATE=1 bash "$PLUGIN/hooks-handlers/save-memory.sh" --working-dir "/live/31847" "$@" 2>&1
}
save_codex() {
    env -u CLAUDE_SESSION_ID -u MMRY_CONFIG_FILE HOME="$W/home" TMPDIR="$W/tmp" MMRY_HOST=codex CODEX_HOME="$CX" \
        MMRY_NO_SELF_UPDATE=1 bash "$CX/mmry/hooks-handlers/save-memory.sh" --source codex --working-dir "/live/31847" "$@" 2>&1
}
# The plugin's own search with --ids, on each host layout: how the assistant finds the id.
search_claude() {
    env -u CLAUDE_SESSION_ID HOME="$W/home" TMPDIR="$W/tmp" MMRY_CONFIG_FILE="$W/home/mmry-config.json" \
        MMRY_NO_SELF_UPDATE=1 bash "$PLUGIN/hooks-handlers/search-memories.sh" --ids "$@" 2>&1
}
search_codex() {
    env -u CLAUDE_SESSION_ID -u MMRY_CONFIG_FILE HOME="$W/home" TMPDIR="$W/tmp" MMRY_HOST=codex CODEX_HOME="$CX" \
        MMRY_NO_SELF_UPDATE=1 bash "$CX/mmry/hooks-handlers/search-memories.sh" --ids "$@" 2>&1
}
# The id of the one active memory whose content contains a marker.
find_ids() { api GET "/api/memories/search?q=$1" | "$JQ" -r --arg m "$1" '[.[] | select(.content | contains($m)) | .id] | join(",")'; }
show() { api GET "/api/memories/$1" | "$JQ" -c '{id, visibility, permissionGroupID, memoryTier, content}'; }

# A correction run: original, then correction with --supersedes; checks exit 0, old gone,
# search returns only the correction. Echoes the correction's id on fd 3.
correction_case() { # label saver marker "original" "correction" [extra flags for the original...]
    local label="$1" saver="$2" mk="$3" orig="$4" corr="$5"; shift 5
    say ""; say "== $label"
    local out rc old new="" ids; LAST_NEW=""
    out="$($saver --context "$orig $mk" "$@")"; rc=$?
    say "original save: exit $rc: $out"
    old="$(find_ids "$mk")"
    [[ "$old" =~ ^[0-9]+$ ]] || { fail "$label: original not found exactly once (ids: '$old')"; return 1; }
    say "original id $old: $(show "$old")"
    local found; found="$(${saver/save_/search_} "$mk")"
    say "plugin search --ids '$mk': $(printf '%s' "$found" | grep '^id ' | tr '\n' ' ')"
    [[ "$found" == *"id $old |"* ]] && pass "$label: the plugin's search --ids shows id $old" || fail "$label: search --ids did not show id $old"
    out="$($saver --context "$corr $mk" --supersedes "$old")"; rc=$?
    say "correction save --supersedes $old: exit $rc: $out"
    [[ $rc -eq 0 ]] && pass "$label: correction save exit 0" || fail "$label: correction exit $rc"
    local oc; oc="$(code "/api/memories/$old")"
    [[ "$oc" == "404" ]] && pass "$label: earlier memory $old no longer readable (GET 404)" || fail "$label: earlier memory GET $oc"
    ids="$(find_ids "$mk")"
    say "search '$mk' -> ids [$ids]"
    if [[ "$ids" =~ ^[0-9]+$ && "$ids" != "$old" ]]; then
        new="$ids"; pass "$label: search returns only the correction ($new)"
        say "correction: $(show "$new")"
    else
        fail "$label: search returned [$ids]"
    fi
    LAST_OLD="$old"; LAST_NEW="${new:-}"
}

# --- TC1: Claude Code layout ---------------------------------------------------------------------
correction_case "TC1 Claude Code layout" save_claude "M31847a$TS" \
    "FACT: The Corr31847 office is on the third floor." \
    "FACT: The Corr31847 office is on the fourth floor, it moved this week."

# --- TC2: Codex layout -----------------------------------------------------------------------------
correction_case "TC2 Codex layout" save_codex "M31847b$TS" \
    "FACT: The Corr31847 build server is named atlas." \
    "FACT: The Corr31847 build server is named zephyr, atlas was retired."

# --- TC3: audience kept --------------------------------------------------------------------------
correction_case "TC3 private memory" save_claude "M31847c$TS" \
    "FACT: Corr31847 private note, my review is on Tuesday." \
    "FACT: Corr31847 private note, my review moved to Thursday." --visibility private
if [[ -n "${LAST_NEW:-}" ]]; then
    v="$(api GET "/api/memories/$LAST_NEW" | "$JQ" -r '.visibility')"
    [[ "${v,,}" == "private" ]] && pass "TC3 private: correction is Private" || fail "TC3 private: correction visibility '$v'"
fi

GID="$(api POST /api/groups "{\"groupName\":\"Corr31847_$TS\"}" | "$JQ" -r '.id // empty')"
# The group owner is not a member until added; a group save by a non-member stores nothing.
USERID="$(printf "%s" "$TOKEN" | cut -d. -f2 | tr "_-" "/+" | { base64 -d 2>/dev/null; true; } | "$JQ" -r ".sub // empty" 2>/dev/null)"
MC="$(curl -s -m 60 -o /dev/null -w "%{http_code}" -X POST "$API/api/groups/$GID/members" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"userId\":$USERID}")"
say ""; say "group created: $GID; tester added as member: HTTP $MC"
correction_case "TC3 group memory" save_claude "M31847d$TS" \
    "FACT: Corr31847 group note, the team standup is at 9." \
    "FACT: Corr31847 group note, the team standup is now at 10." --visibility group --permission-group-id "$GID"
if [[ -n "${LAST_NEW:-}" ]]; then
    r="$(api GET "/api/memories/$LAST_NEW" | "$JQ" -r '"\(.visibility)|\(.permissionGroupID)"')"
    [[ "${r,,}" == "group|$GID" ]] && pass "TC3 group: correction is Group, group $GID" || fail "TC3 group: correction is '$r'"
fi

# A correction asking for a wider audience is refused and saves nothing.
say ""; say "== TC3 a different visibility is refused"
MK="M31847e$TS"
out="$(save_claude --context "FACT: Corr31847 private salary note. $MK" --visibility private)"; say "original: $out"
old="$(find_ids "$MK")"; say "original id $old: $(show "$old")"
out="$(save_claude --context "FACT: Corr31847 salary note, now shared. $MK" --visibility global --supersedes "$old")"; rc=$?
say "correction --visibility global --supersedes $old: exit $rc: $out"
[[ $rc -eq 1 ]] && pass "TC3 refuse: exit 1, nothing saved" || fail "TC3 refuse: exit $rc"
ids="$(find_ids "$MK")"
[[ "$ids" == "$old" ]] && pass "TC3 refuse: only the original exists, still private: $(show "$old")" || fail "TC3 refuse: ids [$ids]"

say ""
say "RESULT: $fails failure(s)"
rm -rf "$W"
exit $(( fails > 0 ))
