#!/usr/bin/env bats
# formation-say-wrong-member.bats - a directed message that mentions another member, or a task assigned
# to another member, is held with the approved warning until the sender confirms (#34466 R4, DD-205 in
# MMRY-AI/mmry).
#
# THE CHECK IS THE SERVICE'S, ONE MATCHER FOR EVERY HOST. The plugin asks for it on every directed send
# (checkRecipient true), prints the service's warning when the send is held (409, code recipient_check),
# exits non-zero, and sends again with confirmed true when the sender passes --confirm (Claude Code) or
# confirm set to true (Codex). Broadcasts are sent as today, with no check asked for. A service older
# than the check ignores the field and answers 201, and the plugin then reads exactly as it does today.
#
# The network is a fake curl that logs each request with its body and plays the service: it holds a
# directed send that asks for the check, is not confirmed, is not to the lead (member 440) and whose text
# contains FAKE_HOLD_IF, answering FAKE_HOLD_BODY; everything else is stored. Which texts the real service
# holds is proven in xUnit (FormationRecipientCheckTests); this file proves what the plugin does with it.
# Pattern: formation-held-refusal.bats.

load '../helpers/test-helper'

CC_WARNING='Nothing was sent. This message is directed at Seat B (member 441), but it mentions Builder (member 442). If Seat B (member 441) is the right member, send it again with --confirm; if not, send it to the right member.'
CODEX_WARNING='Nothing was sent. This message is directed at Seat B (member 441), but it mentions task 34466, which is assigned to Builder (member 442). If Seat B (member 441) is the right member, send it again with confirm set to true; if not, send it to the right member.'

setup() {
    BIN="$TEST_TMPDIR/fake-bin"
    mkdir -p "$BIN" "$TEST_TMPDIR/codexhome"
    export REQLOG="$TEST_TMPDIR/requests.log"
    : > "$REQLOG"
    cat > "$BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; method="GET"; body=""; url=""; prev=""
for arg in "$@"; do
    case "$prev" in
        -o) out="$arg" ;;
        -X) method="$arg" ;;
        --data-binary) [[ "$arg" == @* ]] && body="$(cat "${arg#@}")" || body="$arg" ;;
    esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s %s\n' "$method" "$url" "$body" >> "$REQLOG"
code=200; resp='{}'
case "$method $url" in
    "POST "*/api/sessions) code=201; resp='' ;;
    "POST "*/api/formations/*/transmissions)
        code=201; resp='{"transmissionId":7,"stored":1}'
        if [[ -n "${FAKE_409_ANY+set}" ]]; then
            code=409; resp="$FAKE_409_ANY"
        elif [[ "${FAKE_SERVER:-}" != "old" && "$body" == *'"checkRecipient":true'* && "$body" != *'"confirmed":true'* \
              && "$body" != *'"recipientMemberId":440'* && -n "${FAKE_HOLD_IF:-}" && "$body" == *"$FAKE_HOLD_IF"* ]]; then
            code=409; resp="$FAKE_HOLD_BODY"
        fi ;;
    "GET "*/api/formations/*/transmissions/sent*) resp='{"member":true,"messages":[]}' ;;
    *) code=404; resp='{"error":"no fake route"}' ;;
esac
[[ -n "$out" ]] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
exit 0
FAKECURL
    chmod +x "$BIN/curl"
    export PATH="$BIN:$PATH"
    export MMRY_API_KEY="fake-key" MMRY_API_URL="http://fake.invalid" MMRY_AUTH_METHOD="apikey"
    export MMRY_NO_SELF_UPDATE=1
    unset MMRY_HOST CODEX_HOME CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID MMRY_CONFIG_FILE
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claudecfg"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    SID="aaaa4466-wrong-$$"
    export CLAUDE_CODE_SESSION_ID="$SID"
    HH="$PLUGIN_ROOT/hooks-handlers"
    bash "$HH/formation-state.sh" set 77 "$SID" >/dev/null 2>&1
    export FAKE_HOLD_IF="Builder"
    export FAKE_HOLD_BODY='{"message":"'"$CC_WARNING"'","code":"recipient_check","stored":0,"recipientMemberId":441,"mentionsMemberId":442,"mentionsTask":null}'
}

teardown() {
    bash "$HH/formation-state.sh" clear "$SID" >/dev/null 2>&1 || true
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_sends() { grep -c '^POST http://fake.invalid/api/formations/77/transmissions ' "$REQLOG" || true; }

@test "W-01 Claude Code: a message naming another member is held with the exact warning, and nothing is sent" {
    run bash "$HH/formation-say.sh" "Builder has the API half." 441
    [ "$status" -ne 0 ] || { echo "a held send exited 0: $output"; return 1; }
    [ "$output" = "$CC_WARNING" ] || { echo "printed: $output"; return 1; }
    [[ "$output" != *"Sent to"* ]] || return 1
    [ "$(_sends)" -eq 1 ]
    grep -q '"recipientMemberId":441,"checkRecipient":true}' "$REQLOG" || { cat "$REQLOG"; return 1; }
    ! grep -q '"confirmed"' "$REQLOG"
}

@test "W-02 Claude Code: sent again with --confirm, it is delivered to that member only" {
    run bash "$HH/formation-say.sh" "Builder has the API half." 441 --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "Sent to member 441 in formation 77, and to nobody else."* ]] || { echo "$output"; return 1; }
    grep -q '"recipientMemberId":441,"checkRecipient":true,"confirmed":true}' "$REQLOG" || { cat "$REQLOG"; return 1; }
}

@test "W-03 --confirm may come before the member id" {
    run bash "$HH/formation-say.sh" "Builder has the API half." --confirm 441
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '"recipientMemberId":441,"checkRecipient":true,"confirmed":true}' "$REQLOG" || { cat "$REQLOG"; return 1; }
}

@test "W-04 a message naming only its recipient is sent at once" {
    run bash "$HH/formation-say.sh" "Seat B, the API half is yours." 441
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "Sent to member 441 in formation 77, and to nobody else."* ]] || { echo "$output"; return 1; }
    [ "$(_sends)" -eq 1 ]
}

@test "W-05 a broadcast is sent at once, and asks for no check" {
    run bash "$HH/formation-say.sh" "Builder has the API half."
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "Sent to formation 77."* ]] || { echo "$output"; return 1; }
    ! grep -q '"checkRecipient"' "$REQLOG" || { cat "$REQLOG"; return 1; }
}

@test "W-06 a broadcast with --confirm is a broadcast, not a refusal" {
    run bash "$HH/formation-say.sh" "Builder has the API half." --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "Sent to formation 77."* ]] || { echo "$output"; return 1; }
    ! grep -q '"recipientMemberId"' "$REQLOG"
}

@test "W-07 a message to the lead is sent at once" {
    run bash "$HH/formation-say.sh" "Builder has the API half." 440
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "Sent to member 440 in formation 77, and to nobody else."* ]] || { echo "$output"; return 1; }
}

@test "W-08 an older service that ignores checkRecipient behaves exactly as today" {
    export FAKE_SERVER=old
    run bash "$HH/formation-say.sh" "Builder has the API half." 441
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${lines[0]}" = "Sent to member 441 in formation 77, and to nobody else. They will see it after their next tool call, marked as directed at them." ]
    [ "${#lines[@]}" -eq 2 ] || { echo "$output"; return 1; }
}

@test "W-09 the service's warning is cleaned: no control characters, no carriage return" {
    export FAKE_HOLD_BODY='{"message":"Nothing was sent.\r This \u001b[31mmessage\u0007 is held.","code":"recipient_check","stored":0}'
    run bash "$HH/formation-say.sh" "Builder has the API half." 441
    [ "$status" -ne 0 ]
    [[ "$output" != *$'\r'* && "$output" != *$'\e'* && "$output" != *$'\a'* ]] || { echo "a control character was printed"; return 1; }
    [[ "$output" == "Nothing was sent. This [31mmessage is held." ]] || { echo "$output"; return 1; }
}

@test "W-10 a 409 that is not the recipient check is not reported as a held message" {
    export FAKE_409_ANY='{"message":"The formation is busy.","stored":0}'
    run bash "$HH/formation-say.sh" "anything" 441
    [ "$status" -ne 0 ]
    [[ "$output" == *"(HTTP 409)"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"send it again with"* ]] || return 1
}

@test "W-11 Codex: formation_say is held with the exact warning, then sent with confirm set to true" {
    export MMRY_HOST=codex CODEX_HOME="$TEST_TMPDIR/codexhome"
    unset CLAUDE_CODE_SESSION_ID
    printf '77\n' > "$TMPDIR/.mmry-formation-conv-W"
    export FAKE_HOLD_IF="34466"
    export FAKE_HOLD_BODY='{"message":"'"$CODEX_WARNING"'","code":"recipient_check","stored":0,"recipientMemberId":441,"mentionsMemberId":442,"mentionsTask":"34466"}'
    local server="$HH/mcp-server.sh"
    run bash -c 'printf "%s\n" "$@" | bash "$0"' "$server" \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"formation_say","arguments":{"message":"Start on 34466 now.","to_member_id":441},"_meta":{"sessionId":"conv-W"}}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"formation_say","arguments":{"message":"Start on 34466 now.","to_member_id":441,"confirm":true},"_meta":{"sessionId":"conv-W"}}}'
    local held sent
    held="$(printf '%s\n' "$output" | jq -c 'select(.id == 1)')"
    sent="$(printf '%s\n' "$output" | jq -c 'select(.id == 2)')"
    [ "$(printf '%s' "$held" | jq -r '.result.isError')" = "true" ] || { echo "$output"; return 1; }
    [ "$(printf '%s' "$held" | jq -r '.result.content[0].text' | tr -d '\r')" = "$CODEX_WARNING" ] || { echo "$held"; return 1; }
    [ "$(printf '%s' "$sent" | jq -r '.result.isError')" = "false" ] || { echo "$sent"; return 1; }
    [[ "$(printf '%s' "$sent" | jq -r '.result.content[0].text')" == *"Sent to member 441 in formation 77, and to nobody else."* ]] || { echo "$sent"; return 1; }
    [ "$(grep -c '"recipientMemberId":441,"checkRecipient":true}' "$REQLOG")" -eq 1 ] || { cat "$REQLOG"; return 1; }
    [ "$(grep -c '"recipientMemberId":441,"checkRecipient":true,"confirmed":true}' "$REQLOG")" -eq 1 ] || { cat "$REQLOG"; return 1; }
}

@test "W-13 the command help and the Codex skill carry wording item 4 exactly, each with its own host's confirm" {
    local claude='A directed message that mentions another member, by name or member id, or a task assigned to another member, is held and not sent, with a warning naming what it mentions. If the recipient is right, send it again with --confirm. Messages to the whole Formation and to the lead are never held.'
    local codex='A directed message that mentions another member, by name or member id, or a task assigned to another member, is held and not sent, with a warning naming what it mentions. If the recipient is right, send it again with confirm set to true. Messages to the whole Formation and to the lead are never held.'
    grep -qxF "$claude" "$PLUGIN_ROOT/commands/formation.md" || { echo "commands/formation.md lacks item 4"; return 1; }
    grep -qxF "$codex" "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" || { echo "the Codex skill lacks item 4"; return 1; }
    ! grep -qF -- "--confirm" "$PLUGIN_ROOT/skills-codex/memory-system/SKILL.md" || { echo "the Codex skill names a Claude Code flag"; return 1; }
}

@test "W-12 Codex: the formation_say schema offers confirm with the approved description" {
    export MMRY_HOST=codex CODEX_HOME="$TEST_TMPDIR/codexhome"
    run bash -c 'printf "%s\n" "$1" | bash "$0"' "$HH/mcp-server.sh" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
    local prop
    prop="$(printf '%s\n' "$output" | jq -c 'select(.id == 3) | .result.tools[] | select(.name == "formation_say") | .inputSchema.properties.confirm')"
    [ "$(printf '%s' "$prop" | jq -r '.type')" = "boolean" ] || { echo "$prop"; return 1; }
    [ "$(printf '%s' "$prop" | jq -r '.description')" = "Optional: true to send a directed message that was held because it mentions another member or a task assigned to another member. Use it only when the recipient is right." ] || { echo "$prop"; return 1; }
}
