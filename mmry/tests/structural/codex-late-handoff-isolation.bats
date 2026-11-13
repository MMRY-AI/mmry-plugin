#!/usr/bin/env bats
# codex-late-handoff-isolation.bats - on Codex, a late start's hand-off reaches only its own account's
# first prompt, even when two accounts share one session id (#33617, DD-179).
#
# THE DEFECT, finding S1 of the independent QA of #33363 (security reviewer, 2026-11-09). When a Codex
# session start runs past its budget, its memories are handed to the conversation's first prompt
# through two files named by the bare session id: .mmry-codex-late.<sid> (the marker, holding the
# start's pid) and .mmry-codex-start.<sid>.<pid>.{out,ready,pid,claim} (the hand-off). Two MMRY
# accounts on one machine can share a session id (a conversation resumed under a second account, an
# id passed by hand). QA planted account A's late start and ran the first prompt as account B with the
# same id: B was handed "Read them now: ...mmry-memories.<A key>.<sid>.md", A's memories, and A's
# hand-off was consumed, so A got nothing. #33363 had keyed every Foundation file; this was the same
# threat in the Codex start path.
#
# Since #33617 both names carry the account key in front of the id, <key>.<sid>, the part
# mmry_foundation_session_part_v (lib-foundation-key.sh) gives every Foundation file, so a shared id
# never names a shared hand-off. The key is computed before anything is loaded, by lib-codex-key.sh,
# the one place both early paths (codex-hook.sh arming the marker before lib-host.sh is sourced, and
# codex-first-prompt.sh, which loads no host and no library) resolve the Codex credential, with no
# process. As a second guard the reader refuses a hand-off whose memories path does not carry its own
# key. The old bare names are never read again (DD-179, as DD-176) and go with the 12-hour sweep.
#
# Every test drives the real entry points, the command lines codex-hooks.json registers, by sh, with a
# mock curl standing in for the service. The two accounts share only the temp folder and the session
# id, which is exactly what they share on a real machine. Tests 1 and 2 were run against develop
# 2818e45b before the fix and failed there (the red run is in the handback).

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    export HOME="$TEST_TMPDIR/fakehome"
    mkdir -p "$HOME"
    unset MMRY_HOST CODEX_HOME || true
    # Two accounts on two servers. Keys are throwaway strings, never real credentials.
    A_URL="https://prod.example.test"        A_KEY="prod-account-key-000000000000000000000001"
    B_URL="https://integration.example.test" B_KEY="integration-account-key-00000000000002"
    HA="$(_codex_home a "$A_URL" "$A_KEY")"
    HB="$(_codex_home b "$B_URL" "$B_KEY")"
    KA="$(FND_CONFIG_OVERRIDE="$HA/mmry-config.json" fnd_acct)"
    KB="$(FND_CONFIG_OVERRIDE="$HB/mmry-config.json" fnd_acct)"
    [[ "$KA" =~ ^[0-9a-f]{16}$ && "$KB" =~ ^[0-9a-f]{16}$ && "$KA" != "$KB" ]]
    # The ONE id both accounts use: the id QA's probe used.
    SID="shared-sid-1"
    ROOT="$(_installed_plugin_root)"
    SS_CMD="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/codex-hooks.json")"
    FP_CMD="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("codex-first-prompt"))][0].command // empty' "$ROOT/hooks/codex-hooks.json")"
    [[ -n "$SS_CMD" && -n "$FP_CMD" ]]
    STARTS=0
}

# Nothing a test started may outlive it: each start's deferred work ends with the probe self-update,
# and a late start's drain ends when its slow curl does. Both are waited for (bounded), then whatever
# slow stand-in is left is stopped, and the folder goes.
teardown() {
    local i=0 n
    while (( i < 240 )); do
        n=0
        [[ -f "$TEST_TMPDIR/su-finished-list" ]] && n="$(wc -l < "$TEST_TMPDIR/su-finished-list" | tr -d ' ')"
        [[ "${n:-0}" -ge "${STARTS:-0}" ]] && break
        sleep 0.25; i=$((i + 1))
    done
    _wait_drains 60 || true
    local p
    for p in $(cat "$TEST_TMPDIR/slow-pids" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    mmry_teardown_tmp "$TEST_TMPDIR"
}

# True once every drain a start recorded (.mmry-codex-start.*.pid) has ended, or after $1 seconds.
_wait_drains() {
    local i=0 f p alive
    while (( i < $1 * 4 )); do
        alive=0
        for f in "$HA"/mmry-handoff/.mmry-codex-start.*.pid "$HB"/mmry-handoff/.mmry-codex-start.*.pid; do
            [[ -f "$f" ]] || continue
            p="$(cat "$f" 2>/dev/null | tr -d '\r\n')"
            [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && alive=1
        done
        (( alive == 0 )) && return 0
        sleep 0.25; i=$((i + 1))
    done
    return 1
}

# A Codex home for one account: its own mmry-config.json, as /mmry:setup writes it on Codex.
#   _codex_home <name> <url> <key>   -> prints the home
_codex_home() {
    local dir="$TEST_TMPDIR/codexhome-$1"
    mkdir -p "$dir/mmry"
    printf '{\n  "apiUrl": "%s",\n  "authMethod": "apikey",\n  "apiKey": "%s",\n  "foundationRefreshSeconds": 0\n}\n' "$2" "$3" > "$dir/mmry-config.json"
    printf '%s' "$dir"
}

# A copy of the plugin where Codex installs one (no .git), with the update check replaced by a probe
# that records each finish, so teardown can wait for every start's deferred work.
_installed_plugin_root() {
    local root="$TEST_TMPDIR/plugins/cache/mmry-plugin/mmry/test"
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/setup" "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_ROOT/hooks" "$root/"
    cp "$PLUGIN_ROOT/release-files.txt" "$root/"
    cat > "$root/hooks-handlers/self-update.sh" <<EOF
#!/usr/bin/env bash
echo done >> "$TEST_TMPDIR/su-finished-list"
EOF
    printf '%s' "$root"
}

# A curl that is slow for one endpoint: _slow_curl PATTERN SECONDS. Its pid goes to slow-pids so
# teardown can stop it. The stand-in lives in this test's own scratch folder.
_slow_curl() {
    local dir="$TEST_TMPDIR/slow-bin"
    mkdir -p "$dir"
    cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"$1"*)
        echo \$\$ >> "$TEST_TMPDIR/slow-pids"
        sleep $2
        exec "$TEST_TMPDIR/mock-bin/curl" "\$@" ;;
esac
exec "$TEST_TMPDIR/mock-bin/curl" "\$@"
EOF
    chmod +x "$dir/curl"
    export PATH="$dir:$PATH"
}

# The Codex session start for one account, run the way Codex runs it on macOS and Linux: the registered
# command from codex-hooks.json, by sh, with the SessionStart payload on stdin and that account's home
# in CODEX_HOME. Nothing about the account is in the environment. Sets JSON (the hook's JSON line).
#   _start <codex-home> <sid>
_start() {
    local payload stamp=""
    payload="{\"session_id\":\"$2\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$TEST_TMPDIR\"}"
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) printf -v stamp '%(%H:%M:%S)T.00' -1 ;; esac
    STARTS=$((STARTS + 1))
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$1" PLUGIN_ROOT="$ROOT" MMRY_CODEX_HOOK_STARTED="$stamp" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$SS_CMD" "$TEST_TMPDIR"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
}

# That account's first prompt: the UserPromptSubmit entry of codex-hooks.json that delivers late startup
# memories, by sh, gate included. Sets JSON.
#   _prompt <codex-home> <sid>
_prompt() {
    local payload
    payload="{\"session_id\":\"$2\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\",\"cwd\":\"$TEST_TMPDIR\"}"
    run env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_NO_SELF_UPDATE \
        HOME="$HOME" CODEX_HOME="$1" PLUGIN_ROOT="$ROOT" \
        bash -c 'cd "$3" && printf "%s" "$1" | sh -c "$2"' _ "$payload" "$FP_CMD" "$TEST_TMPDIR"
    JSON="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
}

# That account's per-prompt Foundation hook, part 1, through codex-hook.sh: the other reader of the
# account key on Codex, after lib-host.sh.
#   _fprompt <codex-home> <sid>
_fprompt() {
    printf '{"session_id":"%s","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"hi"}' "$2" \
        | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u CLAUDE_PLUGIN_ROOT -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$1" PLUGIN_ROOT="$ROOT" \
              bash "$ROOT/hooks-handlers/codex-hook.sh" userpromptsubmit-foundation --part 1 2>/dev/null
}

_context() { printf '%s' "$JSON" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
_file() { local t; t="$(cat "$1"; printf x)"; printf '%s' "${t%x}"; }
# Every late file of both accounts: in each account's own folder (#33231, DD-182) and, for the bare
# names a previous plugin wrote, the temp folder.
_codex_files() {
    local d
    for d in "$HA/mmry-handoff" "$HB/mmry-handoff" "$TMPDIR"; do
        ls -a "$d" 2>/dev/null | grep -E '^\.mmry-codex-(late|start)' | sed "s|^|${d##*/}/|" | tr '\n' ' '
    done
}

# The keyed names for one account and id, as the plugin spells them, in that account's own folder
# <codex-home>/mmry-handoff (#33231, DD-182). _dir makes the folder as the start would (700).
#   _part <codex-home> <sid>   -> <key>.<sid>
#   _late <codex-home> <sid>   -> <codex-home>/mmry-handoff/.mmry-codex-late.<key>.<sid>
#   _hand <codex-home> <sid> <pid> -> <codex-home>/mmry-handoff/.mmry-codex-start.<key>.<sid>.<pid>
_part() { FND_CONFIG_OVERRIDE="$1/mmry-config.json" fnd_session_part "$2"; }
_dir() { [[ -d "$1/mmry-handoff" ]] || (umask 077 && mkdir "$1/mmry-handoff"); printf '%s/mmry-handoff' "$1"; }
_late() { printf '%s/.mmry-codex-late.%s' "$(_dir "$1")" "$(_part "$1" "$2")"; }
_hand() { printf '%s/.mmry-codex-start.%s.%s' "$(_dir "$1")" "$(_part "$1" "$2")" "$3"; }

# The bare names the previous plugin used for $SID: none may ever be written.
_no_bare_written() {
    [[ ! -e "$TMPDIR/.mmry-codex-late.$SID" ]] || { echo "the bare late marker .mmry-codex-late.$SID was written: $(_codex_files)"; return 1; }
    local f
    for f in "$TMPDIR"/.mmry-codex-start."$SID".*; do
        [[ -e "$f" ]] || continue
        echo "a bare hand-off file ${f##*/} was written: $(_codex_files)"; return 1
    done
    return 0
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 1: each account's late hand-off reaches only its own first prompt. The 33363 QA probe,
# through the real writer: A's start is late, and B's first prompt comes, with the same id, while A's
# memories are still on their way.
# ---------------------------------------------------------------------------------------------
@test "shared id: account B's first prompt is handed nothing of account A's late start, and A's first prompt gets A's memories (the 33363 S1 probe)" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 8
    _start "$HA" "$SID"
    assert_success
    run _context
    assert_output --partial "could not load your memories in time"
    # B, at once, as `codex exec` does, while A's work is still running.
    _prompt "$HB" "$SID"
    assert_success
    [[ "$output" != *"$KA"* ]] || { echo "B's first prompt was handed A's memories path (S1): $output"; return 1; }
    [[ "$output" != *"Read them now"* ]] || { echo "B's first prompt was handed a memories file: $output"; return 1; }
    [ -z "$JSON" ] || { echo "B's first prompt spoke about a start that was not B's: $JSON"; return 1; }
    # A's own first prompt still gets A's memories: the hand-off was not consumed.
    _prompt "$HA" "$SID"
    assert_success
    run _context
    assert_output --regexp "^MMRY AI loaded 1 memories\. Read them now: .*mmry-memories\.${KA}\.${SID}\.md" || { echo "late files: $(_codex_files)"; return 1; }
    refute_output --partial "$KB"
    _no_bare_written
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 2: one account's late start never consumes, replaces or delays another's. B's start
# comes while A's is still late: A's marker and hand-off are byte for byte what they were.
# ---------------------------------------------------------------------------------------------
@test "shared id: account B's session start while A's start is late leaves A's marker and hand-off untouched, and each first prompt gets its own memories" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 10
    _start "$HA" "$SID"
    assert_success
    local la lb m0 pid_a ha p0
    la="$(_late "$HA" "$SID")"; lb="$(_late "$HB" "$SID")"
    [[ "$la" != "$lb" ]] || { echo "one marker name for two accounts: ${la##*/}"; return 1; }
    [ -f "$la" ] || { echo "A's late marker is not at its keyed name ${la##*/}; late files: $(_codex_files)"; return 1; }
    m0="$(_file "$la")"; pid_a="${m0%%$'\n'*}"
    [[ "$pid_a" =~ ^[0-9]+$ ]] || { echo "A's marker holds no pid: ${m0:0:40}"; return 1; }
    ha="$(_hand "$HA" "$SID" "$pid_a")"
    [ -f "$ha.pid" ] || { echo "A's hand-off is not at its keyed name ${ha##*/}.pid; late files: $(_codex_files)"; return 1; }
    p0="$(_file "$ha.pid")"
    # B's start, with the same id, while A's work is still running.
    _start "$HB" "$SID"
    assert_success
    [[ "$(_file "$la")" == "$m0" ]] || { echo "B's start rewrote A's late marker: was '${m0//$'\n'/\\n}', now '$(_file "$la" | tr '\n' ' ')'"; return 1; }
    [[ "$(_file "$ha.pid")" == "$p0" ]] || { echo "B's start rewrote A's hand-off pid file"; return 1; }
    [ -f "$lb" ] || { echo "B's late marker is not at its keyed name ${lb##*/}; late files: $(_codex_files)"; return 1; }
    _no_bare_written
    # Each first prompt gets its own account's memories, and only those.
    _prompt "$HB" "$SID"
    assert_success
    run _context
    assert_output --regexp "^MMRY AI loaded 1 memories\. Read them now: .*mmry-memories\.${KB}\.${SID}\.md" || { echo "B: late files: $(_codex_files)"; return 1; }
    refute_output --partial "$KA"
    _prompt "$HA" "$SID"
    assert_success
    run _context
    assert_output --regexp "^MMRY AI loaded 1 memories\. Read them now: .*mmry-memories\.${KA}\.${SID}\.md" || { echo "A: late files: $(_codex_files)"; return 1; }
    refute_output --partial "$KB"
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 3: a single account's late start works exactly as it does now, under the keyed names,
# and nothing is left behind once its first prompt has delivered.
# ---------------------------------------------------------------------------------------------
@test "one account: a late start delivers with the first prompt once, under keyed names only, and leaves nothing behind" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _start "$HA" "$SID"
    assert_success
    [ -f "$(_late "$HA" "$SID")" ] || { echo "the late marker is not at its keyed name; late files: $(_codex_files)"; return 1; }
    _no_bare_written
    _prompt "$HA" "$SID"
    assert_success
    run _context
    assert_output --regexp "^MMRY AI loaded 1 memories\. Read them now: .*mmry-memories\.${KA}\.${SID}\.md" || { echo "late files: $(_codex_files)"; return 1; }
    assert_output --partial "These memories were late"
    _wait_drains 30 || true
    sleep 1
    local left; left="$(ls -a "$TMPDIR" 2>/dev/null | grep -E "^\.mmry-codex-(late|start)\..*${SID}" | tr '\n' ' ')"
    [ -z "$left" ] || { echo "left behind after delivery: $left"; return 1; }
    _prompt "$HA" "$SID"
    assert_success
    [ -z "$JSON" ] || { echo "the second prompt delivered the startup memories again: $JSON"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# THE GATES look for .mmry-codex-late.*, which a keyed name still matches, in the account's own folder
# since #33231 (DD-182). Proved against the gate's own command line.
# ---------------------------------------------------------------------------------------------
@test "gate: the sh gate in codex-hooks.json opens for a keyed late marker and stays shut with none" {
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    # The gate looks in the account's own folder, <CODEX_HOME>/mmry-handoff (#33231, DD-182).
    run env PLUGIN_ROOT="$ROOT" CODEX_HOME="$HA" sh -c "$FP_CMD" </dev/null
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate let the hook run with nothing pending"; return 1; }
    : > "$(_late "$HA" "$SID")"
    run env PLUGIN_ROOT="$ROOT" CODEX_HOME="$HA" sh -c "$FP_CMD" </dev/null
    assert_success
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "the gate stayed shut with a keyed late marker pending"; return 1; }
}

@test "gate (Windows): codex-hook.cmd opens for a keyed late marker and stays shut with none" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "codex-hook.cmd runs only on Windows" ;; esac
    printf '#!/bin/sh\n: > "%s/probe-ran"\n' "$TEST_TMPDIR" > "$ROOT/hooks-handlers/codex-hook.sh"
    # The launcher looks in the account's own folder, %CODEX_HOME%\mmry-handoff (#33231, DD-182).
    local wha; wha="$(cygpath -w "$HA")"
    run env CODEX_HOME="$wha" cmd //d //c "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")" codex-first-prompt </dev/null 3>&-
    assert_success
    [ ! -e "$TEST_TMPDIR/probe-ran" ] || { echo "codex-hook.cmd started bash with nothing pending"; return 1; }
    : > "$(_late "$HA" "$SID")"
    run env CODEX_HOME="$wha" cmd //d //c "$(cygpath -w "$ROOT/hooks-handlers/codex-hook.cmd")" codex-first-prompt </dev/null 3>&-
    [ -e "$TEST_TMPDIR/probe-ran" ] || { echo "codex-hook.cmd stayed shut with a keyed late marker pending"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# KEY PARITY: the key the early paths compute, before lib-host.sh, is the key the Foundation path
# computes after it, for the same account. The one rule lives in lib-codex-key.sh; this is the check
# that it cannot drift from lib-host.sh.
# ---------------------------------------------------------------------------------------------
# The credential file and key the early helper resolves, and the ones lib-host.sh then
# lib-foundation-key.sh resolve on the hook path (MMRY_HOST exported, as codex-hook.sh does).
_early() {
    bash -c 'source "$1/hooks-handlers/lib-codex-key.sh" && mmry_codex_session_part_v "$2" && printf "%s|%s" "$_MMRY_CODEX_CFG" "$_MMRY_CODEX_SESSION_PART"' _ "$ROOT" "$SID" 2>/dev/null
}
_hostpath() {
    bash -c 'export MMRY_HOST=codex; source "$1/hooks-handlers/lib-host.sh" && source "$1/hooks-handlers/lib-foundation-key.sh" && mmry_foundation_session_part_v "$2" && printf "%s|%s" "$MMRY_CONFIG_FILE" "$_MMRY_FND_SESSION_PART"' _ "$ROOT" "$SID" 2>/dev/null
}
_same_identity() {
    local e h
    e="$(_early)"; h="$(_hostpath)"
    [[ -n "$e" && "$e" == *"|"*.* ]] || { echo "$1: the early helper gave no answer: '$e'"; return 1; }
    [[ "${e#*|}" == "${h#*|}" ]] || { echo "$1: early part ${e#*|} but the Foundation path's part is ${h#*|} (files ${e%|*} and ${h%|*})"; return 1; }
    [[ "${e#*|}" == "$2.$SID" ]] || { echo "$1: part ${e#*|} is not the expected key $2"; return 1; }
}

@test "key parity: the early key equals the Foundation hook's key for the same account, for every spelling of the Codex home and for the config override" {
    export -n CODEX_HOME MMRY_CONFIG_FILE 2>/dev/null || true
    unset CODEX_HOME MMRY_CONFIG_FILE
    CODEX_HOME="$HA" _same_identity "CODEX_HOME plain" "$KA"
    CODEX_HOME="$HA/" _same_identity "CODEX_HOME with a trailing slash" "$KA"
    CODEX_HOME="$HA//" _same_identity "CODEX_HOME with two trailing slashes" "$KA"
    CODEX_HOME="$HB" _same_identity "CODEX_HOME of the other account" "$KB"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            CODEX_HOME="$(cygpath -w "$HA")\\" _same_identity "CODEX_HOME as a Windows path with a trailing backslash" "$KA" ;;
    esac
    # No CODEX_HOME: the default home, $HOME/.codex.
    mkdir -p "$HOME/.codex"; cp "$HB/mmry-config.json" "$HOME/.codex/mmry-config.json"
    _same_identity "no CODEX_HOME (default \$HOME/.codex)" "$KB"
    # MMRY_CONFIG_FILE set is the documented override, honoured by both.
    CODEX_HOME="$HB" MMRY_CONFIG_FILE="$HA/mmry-config.json" _same_identity "MMRY_CONFIG_FILE override" "$KA"
    # An unconfigured Codex: no credential file anywhere. Both give the client's default identity.
    rm -f "$HOME/.codex/mmry-config.json"
    local e h
    e="$(CODEX_HOME="$TEST_TMPDIR/no-such-home" _early)"; h="$(CODEX_HOME="$TEST_TMPDIR/no-such-home" _hostpath)"
    [[ -n "$e" && "${e#*|}" == "${h#*|}" ]] || { echo "unconfigured: early '${e#*|}' but Foundation '${h#*|}'"; return 1; }
    [[ "${e#*|}" != "$KA.$SID" && "${e#*|}" != "$KB.$SID" ]] || { echo "unconfigured Codex took a configured account's key"; return 1; }
}

@test "key parity, end to end: the real session start's marker and the real Foundation hook's prepared copy carry the same key for the same account" {
    export MMRY_CODEX_START_BUDGET=3
    _slow_curl "/api/memories/startup" 6
    _start "$HA" "$SID"
    assert_success
    local mk fk m f
    m="$(ls -a "$HA/mmry-handoff" | grep -E "^\.mmry-codex-late\.[0-9a-f]{16}\.${SID}$" | head -1)"
    [ -n "$m" ] || { echo "no keyed late marker for $SID: $(_codex_files)"; return 1; }
    mk="${m#.mmry-codex-late.}"; mk="${mk%.$SID}"
    # A's first prompt collects the hand-off, so the start's work is complete before the Foundation hook runs.
    _prompt "$HA" "$SID"
    assert_success
    _fprompt "$HA" "$SID" >/dev/null || true
    f="$(ls -a "$TMPDIR" | grep -E "^\.mmry-foundation-prepared\.[0-9a-f]{16}\.${SID}$" | head -1)"
    [ -n "$f" ] || { echo "no keyed prepared copy for $SID: $(ls -a "$TMPDIR" | grep foundation | tr '\n' ' ')"; return 1; }
    fk="${f#.mmry-foundation-prepared.}"; fk="${fk%.$SID}"
    [[ "$mk" == "$fk" ]] || { echo "the marker's key $mk is not the Foundation hook's key $fk"; return 1; }
    [[ "$mk" == "$KA" ]] || { echo "the key $mk is not account A's $KA"; return 1; }
}

@test "no process (Windows): the early helper computes the keyed part in the shell alone" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "Windows only: counts processes with a Windows job object" ;; esac
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    cat > "$TEST_TMPDIR/early.sh" <<EOF
export CODEX_HOME="$HA" HOME="$HOME"
unset MMRY_CONFIG_FILE MMRY_HOST
source "$ROOT/hooks-handlers/lib-codex-key.sh" && mmry_codex_session_part_v "$SID" && printf '%s' "\$_MMRY_CODEX_SESSION_PART" > "$TEST_TMPDIR/early.out"
EOF
    local counter wb n
    counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    wb="$(cygpath -w "$(command -v bash)")"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$counter" \
        -CommandLine "\"$wb\" \"$(cygpath -w "$TEST_TMPDIR/early.sh")\"" < /dev/null > "$TEST_TMPDIR/count.txt" 2>&1 3>&- || true
    n="$(tr -d '\r' < "$TEST_TMPDIR/count.txt" | sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p')"
    echo "# lib-codex-key.sh: ${n:-?} process(es), the shell itself included" >&3
    [[ "$n" == "1" ]] || { echo "the early helper started a process: $n in all ($(cat "$TEST_TMPDIR/count.txt"))"; return 1; }
    [[ "$(_file "$TEST_TMPDIR/early.out")" == "$KA.$SID" ]] || { echo "the helper gave $(_file "$TEST_TMPDIR/early.out"), not $KA.$SID"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# THE READER'S OWN GUARD: a hand-off under this account's name whose memories path is another
# account's is refused, not delivered. Cheap, and it holds even if a future writer forgets the key.
# ---------------------------------------------------------------------------------------------
_plant_handoff() {
    # _plant_handoff <late file> <hand-off prefix> <memories path in the answer>
    printf '4242\n' > "$1"
    printf '%s' "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"MMRY AI loaded 3 memories. Read them now: $3\"}}" > "$2.out"
    : > "$2.ready"
}

@test "guard: the first prompt refuses a hand-off under its own name whose memories path is another account's, says they were not loaded, and clears it" {
    local lb hb
    lb="$(_late "$HB" "$SID")"; hb="$(_hand "$HB" "$SID" 4242)"
    _plant_handoff "$lb" "$hb" "/x/mmry-memories.${KA}.${SID}.md"
    export MMRY_CODEX_FIRST_PROMPT_BUDGET=2
    _prompt "$HB" "$SID"
    assert_success
    [[ "$output" != *"$KA"* ]] || { echo "B was handed A's memories path from a hand-off under B's name: $output"; return 1; }
    [[ "$output" != *"Read them now"* ]] || { echo "a foreign memories file was delivered: $output"; return 1; }
    run _context
    assert_output --partial "were not loaded"
    grep -q 'refused' "$HB/mmry-handoff/mmry-codex-first-prompt.log" || { echo "the refusal was not logged: $(tail -3 "$HB/mmry-handoff/mmry-codex-first-prompt.log")"; return 1; }
    [ ! -e "$lb" ] && [ ! -e "$hb.out" ] && [ ! -e "$hb.ready" ] || { echo "the refused hand-off was left behind: $(_codex_files)"; return 1; }
}

@test "guard control: a hand-off naming the account's own memories file is delivered, and an answer with no memories file is passed on as it stands" {
    local lb hb
    lb="$(_late "$HB" "$SID")"; hb="$(_hand "$HB" "$SID" 4242)"
    _plant_handoff "$lb" "$hb" "/x/mmry-memories.${KB}.${SID}.md"
    _prompt "$HB" "$SID"
    assert_success
    run _context
    assert_output --regexp "^MMRY AI loaded 3 memories\. Read them now: /x/mmry-memories\.${KB}\.${SID}\.md"
    [ ! -e "$lb" ] || { echo "the late marker was left behind"; return 1; }
    # No memories file in the answer (no account set up says so in plain text): passed on unchanged.
    printf '4242\n' > "$lb"
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI: no account is set up for Codex on this machine."}}' > "$hb.out"
    : > "$hb.ready"
    _prompt "$HB" "$SID"
    assert_success
    run _context
    assert_output "MMRY AI: no account is set up for Codex on this machine."
}

# ---------------------------------------------------------------------------------------------
# DD-179: the first prompt after an upgrade. A conversation armed under the previous plugin has its
# marker and hand-off under the bare id. They are NEVER read, not even once for the same account:
# nothing in them proves whose they are. The first prompt says nothing, the late notice the start
# already gave stands, and the files are left for the 12-hour sweep.
# ---------------------------------------------------------------------------------------------
@test "upgrade (DD-179): a bare-named marker and hand-off from the previous plugin are never read or delivered, and are left for the sweep" {
    local bl bh l0 o0
    bl="$TMPDIR/.mmry-codex-late.$SID"; bh="$TMPDIR/.mmry-codex-start.$SID.4242"
    _plant_handoff "$bl" "$bh" "/x/mmry-memories.${KA}.${SID}.md"
    l0="$(_file "$bl")"; o0="$(_file "$bh.out")"
    export MMRY_CODEX_FIRST_PROMPT_BUDGET=2
    _prompt "$HA" "$SID"
    assert_success
    [ -z "$JSON" ] || { echo "the bare-named hand-off was delivered: $JSON"; return 1; }
    [[ -f "$bl" && -f "$bh.out" && -f "$bh.ready" ]] || { echo "the bare-named files were removed: $(_codex_files)"; return 1; }
    [[ "$(_file "$bl")" == "$l0" && "$(_file "$bh.out")" == "$o0" ]] || { echo "a bare-named file was rewritten"; return 1; }
    [ ! -e "$bh.claim" ] || { echo "the bare-named hand-off was claimed"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# THE SWEEP covers keyed and bare names alike: half a day on, an uncollected marker or hand-off is
# nobody's. Fresh files are kept.
# ---------------------------------------------------------------------------------------------
@test "sweep: keyed and bare late files half a day old are removed by the first prompt's sweep, in the account's folder and under the old temp-folder names, and fresh ones are kept" {
    # The gate opens only for a marker in the account's own folder (#33231), so the fresh marker that
    # lets the sweep run sits there; the old files sit both there and in the temp folder.
    local f d; d="$(_dir "$HA")"
    for f in ".mmry-codex-late.${KA}.old-1" ".mmry-codex-start.${KA}.old-1.77.out" ".mmry-codex-late.old-2" ".mmry-codex-start.old-2.78.ready"; do
        printf 'old\n' > "$TMPDIR/$f"; touch -t 202001010000 "$TMPDIR/$f"
        printf 'old\n' > "$d/$f"; touch -t 202001010000 "$d/$f"
    done
    printf 'fresh\n' > "$d/.mmry-codex-late.${KA}.fresh-1"
    _prompt "$HA" "nothing-late-here"
    assert_success
    for f in ".mmry-codex-late.${KA}.old-1" ".mmry-codex-start.${KA}.old-1.77.out" ".mmry-codex-late.old-2" ".mmry-codex-start.old-2.78.ready"; do
        [ ! -e "$TMPDIR/$f" ] || { echo "the half-day-old $f was kept in the temp folder"; return 1; }
        [ ! -e "$d/$f" ] || { echo "the half-day-old $f was kept in the account's folder"; return 1; }
    done
    [ -f "$d/.mmry-codex-late.${KA}.fresh-1" ] || { echo "the fresh marker was swept"; return 1; }
}
