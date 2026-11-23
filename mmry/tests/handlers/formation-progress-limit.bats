#!/usr/bin/env bats
# #34089 (DD-203 in MMRY-AI/mmry): the progress-limit command, formation-progress-limit.sh.
#
# How long a member with an assignment can go without progress before the lead is told: 5 to 1440
# minutes, 5 by default. Any member can read it; only the lead, the person who created the Formation or
# an account administrator can set it, and the server decides that. The words are cmo-mmry's
# (wording-34088-34089-cmo.md, C2, C4, C5 and C6 as revised to 5 to 1440). The service is a fake
# transport: no network, every call answered with FAKE_BODY, each request logged with its body.
#
# B16 (the script half). The connector tool in mcp-server.sh and the /mmry:formation progress-limit
# route in commands/formation.md wait for Seat A's merge (both files are fenced in this round).

setup() {
    HANDLERS="${BATS_TEST_DIRNAME}/../../hooks-handlers"
    export TMPDIR="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    export MMRY_CONFIG_FILE="${BATS_TEST_TMPDIR}/no-such-config.json"
    SID="bats-progress-limit-$$"
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
    LOG="${BATS_TEST_TMPDIR}/limit.log"
    : > "$LOG"
    HELP="progress-limit <minutes> sets how long a member with an assignment can go without progress before the lead is told, from 5 to 1440 minutes (5 by default). Use progress-limit default to go back to 5, or progress-limit alone to see the current limit."
    RANGE="The progress limit is between 5 and 1440 minutes. Leave it unset to use the default of 5 minutes."
    STANDING="Only the lead of this Formation, the person who created it, or an account administrator can set its progress limit. Nothing was changed."
}

teardown() {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
}

_curl_dir() {
    local dir="${BATS_TEST_TMPDIR}/limit-bin"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; prev=""; url=""; method="GET"; data=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "-X" ]] && method="$arg"
    [[ "$prev" == "-d" || "$prev" == "--data" || "$prev" == "--data-binary" ]] && data="$arg"
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
[[ "$data" == @* ]] && data="$(cat "${data#@}" 2>/dev/null)"
[[ -n "${FAKE_URL_LOG:-}" ]] && printf '%s %s %s\n' "$method" "$url" "$data" >> "$FAKE_URL_LOG"
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit 0
FAKECURL
    chmod +x "${dir}/curl"
    printf '%s' "$dir"
}

# _limit HOST CODE BODY [ARGS...]: run the script on HOST ("claude" or "codex") against the fake service.
_limit() {
    local host="$1" code="$2" body="$3"; shift 3
    local bin; bin="$(_curl_dir)"
    bash "${HANDLERS}/formation-state.sh" set 4242 "$SID"
    local hostenv=(env -u MMRY_HOST)
    [[ "$host" == "codex" ]] && hostenv=(env MMRY_HOST=codex CODEX_SESSION_ID="$SID")
    PATH="${bin}:${PATH}" FAKE_CODE="$code" FAKE_BODY="$body" FAKE_URL_LOG="$LOG" \
        CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        run "${hostenv[@]}" bash "${HANDLERS}/formation-progress-limit.sh" "$@"
}

@test "B16: progress-limit 20 asks the server to set 20 minutes and prints its sentence" {
    _limit claude 200 '{"formationId":4242,"progressAfterMinutes":20,"progressNoticeAfterSeconds":1200,"message":"This Formation'"'"'s progress limit is now 20 minutes."}' 20
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "This Formation's progress limit is now 20 minutes." ] || { echo "$output"; return 1; }
    grep -q '^PUT http://fake.invalid/api/formations/4242/progress-limit {"minutes":20}$' "$LOG" || { cat "$LOG"; return 1; }
}

@test "B16: 5 and 1440 are sent; default sends null and prints the server's sentence" {
    _limit claude 200 '{"message":"This Formation'"'"'s progress limit is now 5 minutes."}' 5
    _limit claude 200 '{"message":"This Formation'"'"'s progress limit is now 1440 minutes."}' 1440
    _limit claude 200 '{"formationId":4242,"progressAfterMinutes":null,"progressNoticeAfterSeconds":300,"message":"This Formation'"'"'s progress limit is now 5 minutes."}' default
    [ "$output" = "This Formation's progress limit is now 5 minutes." ] || { echo "$output"; return 1; }
    grep -q '{"minutes":5}$' "$LOG" && grep -q '{"minutes":1440}$' "$LOG" && grep -q '{"minutes":null}$' "$LOG" || { cat "$LOG"; return 1; }
}

@test "B16: 4, 0 and 1441 are refused with the approved range sentence before the server is asked, on Claude Code and on Codex" {
    for host in claude codex; do
        for m in 4 0 1441; do
            _limit "$host" 200 '{}' "$m"
            [ "$status" -ne 0 ] || { echo "$host $m accepted: $output"; return 1; }
            [ "$output" = "$RANGE" ] || { echo "$host $m: $output"; return 1; }
        done
    done
    [ ! -s "$LOG" ] || { cat "$LOG"; return 1; }
}

@test "B16: abc is refused with the command's help line (C2), and the server is not asked" {
    for host in claude codex; do
        _limit "$host" 200 '{}' abc
        [ "$status" -ne 0 ] && [ "$output" = "$HELP" ] || { echo "$host: $output"; return 1; }
    done
    [ ! -s "$LOG" ] || { cat "$LOG"; return 1; }
}

@test "B16: help prints the approved help line and exits 0" {
    _limit claude 200 '{}' help
    [ "$status" -eq 0 ] && [ "$output" = "$HELP" ] || { echo "$output"; return 1; }
}

@test "B16: a set whose reply has no message reads progressNoticeAfterSeconds for its sentence" {
    _limit claude 200 '{"formationId":4242,"progressAfterMinutes":20,"progressNoticeAfterSeconds":1200}' 20
    [ "$status" -eq 0 ] && [ "$output" = "This Formation's progress limit is now 20 minutes." ] || { echo "$output"; return 1; }
}

@test "B16: a member is refused with the server's approved sentence (C5)" {
    _limit claude 403 "{\"error\":\"${STANDING}\"}" 20
    [ "$status" -ne 0 ] && [ "$output" = "$STANDING" ] || { echo "$output"; return 1; }
}

@test "B16: a read says 'is', from the Formation's progressNoticeAfterSeconds, and a server without it reads the default of 5" {
    _limit claude 200 '{"formation":{"id":4242},"members":[],"progressNoticeAfterSeconds":1200}'
    [ "$status" -eq 0 ] && [ "$output" = "This Formation's progress limit is 20 minutes." ] || { echo "$output"; return 1; }
    grep -q '^GET http://fake.invalid/api/formations/4242?sessionId=' "$LOG" || { cat "$LOG"; return 1; }
    _limit claude 200 '{"formation":{"id":4242},"members":[]}'
    [ "$status" -eq 0 ] && [ "$output" = "This Formation's progress limit is 5 minutes." ] || { echo "$output"; return 1; }
}

@test "B16: a session not in a Formation is told so, and asks nothing" {
    bash "${HANDLERS}/formation-state.sh" clear "$SID" || true
    CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" run env -u MMRY_HOST bash "${HANDLERS}/formation-progress-limit.sh"
    [ "$status" -ne 0 ] && [ "$output" = "This session is not in a Formation, so it has no progress limit. Run /mmry:formation list to see what is active." ] || { echo "$output"; return 1; }
}

@test "B16: no answer names MMRY AI, and says how to check the limit" {
    _limit claude 503 '' 20
    [ "$status" -ne 0 ] && [ "$output" = "MMRY AI did not answer (HTTP 503), so nothing is confirmed. Run /mmry:formation progress-limit to check the limit before trying again." ] || { echo "$output"; return 1; }
}

@test "B16: the script is in the release file list" {
    grep -qx 'hooks-handlers/formation-progress-limit.sh' "${HANDLERS}/../release-files.txt"
}

# ---- Finish round, item 12: the set call is the client's mmry_set_formation_progress_limit ------------

# Call the client function with these arguments through the fake transport; prints its exit status.
_client_set() {
    local bin; bin="$(_curl_dir)"
    PATH="${bin}:${PATH}" FAKE_CODE=200 FAKE_BODY='{}' FAKE_URL_LOG="$LOG" \
        MMRY_AUTH_METHOD=apikey MMRY_API_KEY=fake-key MMRY_API_URL="http://fake.invalid" \
        bash -c 'unset MMRY_HOST; source "$1/mmry-client.sh"; shift; mmry_set_formation_progress_limit "$@"; echo "rc=$?"' _ "$HANDLERS" "$@" 2>/dev/null | tr -d '\r' | tail -n 1
}

@test "B16 item 12: mmry_set_formation_progress_limit PUTs minutes, or null, to the progress-limit route" {
    [ "$(_client_set 4242 20)" = "rc=0" ] || { cat "$LOG"; return 1; }
    [ "$(_client_set 4242 null)" = "rc=0" ] || { cat "$LOG"; return 1; }
    [ "$(sed -n 1p "$LOG" | tr -d '\r')" = 'PUT http://fake.invalid/api/formations/4242/progress-limit {"minutes":20}' ] || { cat "$LOG"; return 1; }
    [ "$(sed -n 2p "$LOG" | tr -d '\r')" = 'PUT http://fake.invalid/api/formations/4242/progress-limit {"minutes":null}' ] || { cat "$LOG"; return 1; }
}

@test "B16 item 12: mmry_set_formation_progress_limit refuses a value that is not a whole number or null, and asks nothing" {
    local v
    for v in abc "" "20; rm" -5 2.5; do
        [ "$(_client_set 4242 "$v")" = "rc=1" ] || { echo "accepted: '$v'"; cat "$LOG"; return 1; }
    done
    [ ! -s "$LOG" ] || { cat "$LOG"; return 1; }
}

# ---- Finish round, items 13 and 15: the command page, the help command and the Codex skills -----------
#
# The words are cmo-mmry's: C2 (Revision 1) on Claude Code, C3 (Revision 1) on Codex, and D1 (as settled:
# "if it leaves or is removed") for the lead's notices. The five command answers (the approved lines
# 110 to 114) are printed by the script only and stay off every help text.

PLUGIN_DIR_PL="${BATS_TEST_DIRNAME}/../.."
C3_TOOL="Read or set how many minutes a member with an assignment can go without progress before the lead is told. Any member can read it; only the lead of this Formation, the person who created it, or an account administrator can set it. 5 to 1440 minutes; leave it unset for the default of 5."
D1_LEAD="If the lead of a Formation shows no activity for the Formation's quiet limit, every member and the person who created the Formation are told once, and told again when the lead is active or if it leaves or is removed while work is still open. A lead waiting on approval is shown as waiting, not quiet."

@test "item 13: the command page's usage line names progress-limit, right after idle-limit" {
    local usage; usage="$(tr -d '\r' < "${PLUGIN_DIR_PL}/commands/formation.md" | grep -m1 '^Usage:')"
    [[ "$usage" == *'`/mmry:formation idle-limit [<minutes>|default]` | `/mmry:formation progress-limit [<minutes>|default]`'* ]] || { echo "$usage"; return 1; }
}

@test "item 13: the command page's progress-limit section follows idle-limit, runs the script, and carries C2 on one line" {
    local page; page="$(tr -d '\r' < "${PLUGIN_DIR_PL}/commands/formation.md")"
    local idle_at pl_at next_at
    idle_at="$(printf '%s\n' "$page" | grep -n -x '### idle-limit' | cut -d: -f1)"
    pl_at="$(printf '%s\n' "$page" | grep -n -x '### progress-limit' | cut -d: -f1)"
    [ -n "$idle_at" ] && [ -n "$pl_at" ] && [ "$pl_at" -gt "$idle_at" ] || { echo "idle-limit at ${idle_at:-none}, progress-limit at ${pl_at:-none}"; return 1; }
    # No other section sits between them.
    next_at="$(printf '%s\n' "$page" | sed -n "$((idle_at + 1)),\$p" | grep -n '^### ' | head -n 1 | cut -d: -f1)"
    [ "$((idle_at + next_at))" -eq "$pl_at" ] || { echo "a section sits between idle-limit and progress-limit"; return 1; }
    local section; section="$(printf '%s\n' "$page" | sed -n "$((pl_at + 1)),\$p" | awk '/^### /{exit} {print}')"
    [[ "$section" == *'bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-progress-limit.sh" [<minutes>|default]'* ]] || { echo "$section"; return 1; }
    [ "$(printf '%s\n' "$section" | grep -c -x -F -- "$HELP")" -eq 1 ] || { echo "$section"; return 1; }
}

@test "item 13: the help command carries the progress-limit entry with C2, after the idle-limit entry" {
    local help; help="$(tr -d '\r' < "${PLUGIN_DIR_PL}/commands/help.md")"
    local idle_at pl_at
    idle_at="$(printf '%s\n' "$help" | grep -n -F -- '`/mmry:formation idle-limit [<minutes>|default]`' | head -n 1 | cut -d: -f1)"
    pl_at="$(printf '%s\n' "$help" | grep -n -x -F -- "  - \`/mmry:formation progress-limit [<minutes>|default]\`: ${HELP}" | cut -d: -f1)"
    [ -n "$pl_at" ] || { echo "no progress-limit entry with C2"; return 1; }
    [ "$pl_at" -eq "$((idle_at + 1))" ] || { echo "idle-limit at $idle_at, progress-limit at $pl_at"; return 1; }
}

@test "item 13: the script's help line is C2, the same text as the pages" {
    local held; held="$(bash -c "$(grep -m1 '^PROGRESS_LIMIT_HELP=' "${HANDLERS}/formation-progress-limit.sh"); printf '%s' \"\$PROGRESS_LIMIT_HELP\"")"
    [ "$held" = "$HELP" ] || { echo "$held"; return 1; }
}

@test "item 13: the five progress-limit command answers stay off every help text" {
    local f s
    local -a answers=(
        "This Formation is no longer active, so it has no progress limit to set."
        "This session is not in a Formation, so it has no progress limit."
        "so nothing is confirmed. Run /mmry:formation progress-limit to check the limit"
        "MMRY AI refused the change (HTTP"
        "curl is not available, so the progress limit cannot be reached."
    )
    for f in commands/help.md commands/formation.md skills-codex/help/SKILL.md skills-codex/memory-system/SKILL.md; do
        for s in "${answers[@]}"; do
            ! grep -n -F -- "$s" "${PLUGIN_DIR_PL}/${f}" || { echo "in $f: $s"; return 1; }
        done
    done
}

@test "item 15: the Codex skill's tool table names formation_progress_limit with C3, after the idle-limit row, and never the script" {
    local skill="${PLUGIN_DIR_PL}/skills-codex/memory-system/SKILL.md" row idle_at pl_at
    row="| ${C3_TOOL} | \`formation_progress_limit\` | optional \`minutes\` (5 to 1440); optional \`use_default\` (true for 5) |"
    pl_at="$(tr -d '\r' < "$skill" | grep -n -x -F -- "$row" | cut -d: -f1)"
    idle_at="$(tr -d '\r' < "$skill" | grep -n -F -- '| `formation_idle_limit` |' | head -n 1 | cut -d: -f1)"
    [ -n "$pl_at" ] || { echo "no row: $row"; return 1; }
    [ "$pl_at" -eq "$((idle_at + 1))" ] || { echo "idle-limit at $idle_at, progress-limit at $pl_at"; return 1; }
    ! grep -n 'formation-progress-limit.sh' "$skill" || return 1
}

@test "item 15: the Codex help lists the progress limit as its tool, with C3, after the idle limit" {
    local help="${PLUGIN_DIR_PL}/skills-codex/help/SKILL.md" line idle_at pl_at
    line="- **Read or set how many minutes a member with an assignment can go without progress before the lead is told.** Any member can read it; only the lead of this Formation, the person who created it, or an account administrator can set it. 5 to 1440 minutes; leave it unset for the default of 5. (formation_progress_limit)"
    pl_at="$(tr -d '\r' < "$help" | grep -n -x -F -- "$line" | cut -d: -f1)"
    idle_at="$(tr -d '\r' < "$help" | grep -n -F -- '(formation_idle_limit)' | head -n 1 | cut -d: -f1)"
    [ -n "$pl_at" ] || { echo "no line: $line"; return 1; }
    [ "$pl_at" -eq "$((idle_at + 1))" ] || { echo "idle-limit at $idle_at, progress-limit at $pl_at"; return 1; }
}

@test "item 15: the Codex skill and the command page carry D1 for the lead's notices, once, after the quiet-member paragraph" {
    local f para_at d1_at after
    for f in skills-codex/memory-system/SKILL.md commands/formation.md; do
        [ "$(tr -d '\r' < "${PLUGIN_DIR_PL}/${f}" | grep -c -x -F -- "$D1_LEAD")" -eq 1 ] || { echo "$f: D1 not there once"; return 1; }
        after="$(tr -d '\r' < "${PLUGIN_DIR_PL}/${f}" | awk '/^\*\*The lead hears who has gone quiet\.\*\*/{getline; while ($0 == "") getline; print; exit}')"
        [ "$after" = "$D1_LEAD" ] || { echo "$f: after the quiet paragraph: $after"; return 1; }
    done
}

@test "B16 item 12: formation-progress-limit.sh sets through the client, with no request of its own" {
    local script="${HANDLERS}/formation-progress-limit.sh"
    grep -q 'mmry_set_formation_progress_limit "$formation_id" "$minutes"' "$script" || return 1
    ! grep -n -e '_mmry_request' -e '_set_progress_limit' "$script" || return 1
}
