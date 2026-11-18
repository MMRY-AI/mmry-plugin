#!/usr/bin/env bats
# codex-per-message-in-time.bats - every per-message MMRY check on Codex for Windows finishes inside its
# limit (#33967).
#
# THE FINDING (33452 TC5 live proof, 2026-11-17 00:48:45 UTC, Codex 0.169.0 on Windows). A message sent
# while Codex was working started the nine UserPromptSubmit hooks; all nine completed at the 20 s mark
# and the person saw "hook timed out" after 20 s (the Foundation parts) and after 10 s (stop-check).
# The cause, counted with a Windows job object: every hook started a chain of processes before its
# handler's clock started (the launcher's where.exe lookup, Git's bash wrapper, codex-hook.sh's own
# fork and a child bash: 8 processes), stop-check started 10 more of its own, and on a loaded Windows
# machine one process start costs about a second. The Foundation parts' 10 s deadline counted from
# the handler's bash start, so the launch was outside it; stop-check had no deadline at all.
#
# WHAT THIS FILE PROVES, one block per requirement:
#   budget  each per-message Codex registration, run the way Codex runs it on Windows, starts no more
#           than its process budget (counted by the operating system, Windows only). Adding back one
#           helper process to the launcher or to stop-check turns it red (run-codex-mutations.sh).
#   R1      held condition, every platform: a Foundation part whose launch already used most of its
#           time, and whose set check never finishes, still ends inside its 20 s limit; stop-check with
#           every process start slowed ends inside its 10 s limit.
#   R2      a check that cannot finish ends quietly: exit 0, nothing shown to the person, and the next
#           prompt restates the whole Foundation set (and tells the assistant the last turn was cut).
#
# The launch is held by MMRY_CODEX_HOOK_STARTED, the time codex-hook.cmd records as its first step on
# Windows; a stamp N seconds in the past is a launch that took N seconds.

load '../helpers/test-helper'
load '../helpers/foundation-set'

# What Codex itself spends launching a hook before codex-hook.cmd starts (its PowerShell): 1.78 s in
# the TC5 log for a hook that starts nothing else. Every bound below keeps this much in hand.
CODEX_LAUNCH_MARGIN=2

setup() {
    HOOKS="${PLUGIN_ROOT}/hooks/codex-hooks.json"
    CODEX_DIR="$TEST_TMPDIR/codexhome"
    mkdir -p "$CODEX_DIR"
    printf '{"apiUrl":"http://127.0.0.1:9","authMethod":"apikey","apiKey":"test-key","foundationReinject":"true","foundationRefreshSeconds":0}\n' > "$CODEX_DIR/mmry-config.json"
    # The same account under the Claude name too, so the set below is keyed the way the Codex run reads it.
    cp "$CODEX_DIR/mmry-config.json" "$MMRY_CONFIG_FILE"
    SET="$(fnd_set_file)"
    CACHE="$TEST_TMPDIR/mmry-foundation.md"
    SHIMS="$TEST_TMPDIR/shims"
    mkdir -p "$SHIMS"
    unset MMRY_HOST MMRY_JQ CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_CODEX_HOOK_STARTED MMRY_HOOK_LAUNCH_SECS
    export MMRY_NO_SELF_UPDATE=1
    SID="cdx33967-$$-${BATS_TEST_NUMBER}"
}

teardown() {
    mmry_teardown_tmp "$TEST_TMPDIR"
}

_is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
    return 1
}

# A %TIME%-shaped stamp N seconds ago, the way cmd writes it ("H:MM:SS.cc", the hour unpadded).
_stamp_ago() {
    local t; printf -v t '%(%s)T' -1
    t=$(( t - $1 ))
    local h m s; printf -v h '%(%H)T' "$t"; printf -v m '%(%M)T' "$t"; printf -v s '%(%S)T' "$t"
    printf '%d:%s:%s.50' "$((10#$h))" "$m" "$s"
}

_registered() { # $1 event, $2 handler text, $3 field
    node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const g of (d.hooks[process.argv[2]] || [])) for (const h of g.hooks)
            if (h.command.includes(process.argv[3])) { process.stdout.write(String(h[process.argv[4]])); process.exit(0); }
    ' "$HOOKS" "$1" "$2" "$3"
}

_payload() {
    printf '{"session_id":"%s","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"ok"}' "$SID"
}

# One Codex firing of a handler through codex-hook.sh, the Codex entry, as Codex hands it the payload.
# $1 handler args (word-split), $2 launch stamp or "", $3 output file.
_codex_fire() {
    local args="$1" stamp="$2" out="$3"
    # shellcheck disable=SC2086
    _payload | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$CODEX_DIR" MMRY_CODEX_HOOK_STARTED="$stamp" PATH="$SHIMS:$PATH" \
        bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" $args > "$out" 2>/dev/null
}

_sysmsg() { [[ -s "$1" ]] && jq -r '.systemMessage // ""' "$1" | tr -d '\r'; }
_ctx() { [[ -s "$1" ]] && { jq -j '.hookSpecificOutput.additionalContext // ""' "$1" | tr -d '\r'; printf '.'; }; }

_seed_set() {
    awk 'BEGIN { for (i = 1; i <= 600; i++) printf "- Directive %04d: keep every sentence short and every claim backed by something you ran.\n", i }' > "$CACHE"
    fnd_seal "$CACHE" "" "$SET"
}

# A stand-in for one external program whose start takes $2 seconds, as on a loaded Windows machine.
_slow() {
    local name="$1" secs="$2" real
    real="$(command -v "$name")" || return 0
    printf '#!/usr/bin/env bash\nsleep %s\nexec "%s" "$@"\n' "$secs" "$real" > "$SHIMS/$name"
    chmod +x "$SHIMS/$name"
}

# =============================================================================================
# R1 + R2 (every platform): THE HELD CONDITION ENDS QUIETLY INSIDE ITS LIMIT
# =============================================================================================

@test "33967 R1+R2: Foundation parts whose launch used 12 s, with a set check that never finishes, end quietly inside 20 s" {
    _seed_set
    # The verification of the set never finishes: cksum is slow, as every process start was in TC5.
    _slow cksum 60
    local limit; limit="$(_registered UserPromptSubmit userpromptsubmit-foundation timeout)"
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "no Foundation limit in codex-hooks.json: $limit"; return 1; }
    local launch=12 stamp; stamp="$(_stamp_ago "$launch")"
    local start=$SECONDS k pids=()
    for k in 1 2 3 4 5 6; do _codex_fire "userpromptsubmit-foundation --part $k" "$stamp" "$TEST_TMPDIR/late$k.json" & pids+=("$!"); done
    local rc=0 fail=0
    for k in "${pids[@]}"; do wait "$k" || fail=1; done
    local elapsed=$(( SECONDS - start ))
    echo "launch ${launch}s + parts ${elapsed}s = $(( launch + elapsed ))s against ${limit}s (Codex's own launch margin ${CODEX_LAUNCH_MARGIN}s)" >&3
    (( fail == 0 )) || { echo "a part exited non-zero: Codex shows that as a failed hook"; return 1; }
    (( launch + elapsed + CODEX_LAUNCH_MARGIN <= limit )) || {
        echo "the parts ended $(( launch + elapsed ))s after launch; Codex stops them at ${limit}s with a failure line"; return 1; }
    for k in 1 2 3 4 5 6; do
        [[ -z "$(_sysmsg "$TEST_TMPDIR/late$k.json")" ]] || { echo "part $k showed the person: $(_sysmsg "$TEST_TMPDIR/late$k.json")"; return 1; }
        [[ ! -s "$TEST_TMPDIR/late$k.json" ]] || jq -e . "$TEST_TMPDIR/late$k.json" >/dev/null || { echo "part $k is not JSON"; return 1; }
        [[ "$(cat "$TEST_TMPDIR/late$k.json")" != *"Directive 0001"* ]] || { echo "part $k sent an unverified set"; return 1; }
    done

    # THE NEXT MESSAGE, on a machine that keeps up again: the whole set, in order, and the assistant is
    # told the last turn went without it.
    rm -f "$SHIMS/cksum"
    pids=()
    for k in 1 2 3 4 5 6; do _codex_fire "userpromptsubmit-foundation --part $k" "" "$TEST_TMPDIR/next$k.json" & pids+=("$!"); done
    wait "${pids[@]}"
    local joined="" ctx n=0
    for k in 1 2 3 4 5 6; do
        [[ -z "$(_sysmsg "$TEST_TMPDIR/next$k.json")" ]] || { echo "next turn, part $k showed the person: $(_sysmsg "$TEST_TMPDIR/next$k.json")"; return 1; }
        ctx="$(_ctx "$TEST_TMPDIR/next$k.json")"; ctx="${ctx%.}"
        [[ "$ctx" == *"This is PART $k OF "* ]] || continue
        joined+="${ctx#*if their versions differ, tell the user.$'\n\n'}"
        n=$(( n + 1 ))
    done
    local want; want="$(cat "$CACHE"; printf .)"; want="${want%.}"; want="${want%$'\n'}"
    echo "next message: ${n} parts, ${#joined} of ${#want} bytes" >&3
    [[ "$joined" == "$want" ]] || { echo "the next message did not restate the whole set (${n} parts, ${#joined} of ${#want} bytes)"; return 1; }
    ctx="$(_ctx "$TEST_TMPDIR/next1.json")"
    [[ "$ctx" == *"PREVIOUS turn"*"cut short"* ]] || { echo "the next turn was not told the last one went without the set: ${ctx:0:300}"; return 1; }
}

@test "33967 R1: a Foundation part with a launch of 6 s still gives the set its whole time from launch, not 10 s on top" {
    # The deadline counts from the launch, so the parts end by about 10 s after launch, not 16.
    _seed_set
    _slow cksum 60
    local launch=6 stamp; stamp="$(_stamp_ago "$launch")"
    local start=$SECONDS
    _codex_fire "userpromptsubmit-foundation --part 1" "$stamp" "$TEST_TMPDIR/p1.json"
    local elapsed=$(( SECONDS - start ))
    echo "launch ${launch}s + part 1 ${elapsed}s" >&3
    (( launch + elapsed <= 10 + 4 )) || { echo "part 1 ended $(( launch + elapsed ))s after launch: its deadline did not count the launch"; return 1; }
    [[ -z "$(_sysmsg "$TEST_TMPDIR/p1.json")" ]] || { echo "showed the person: $(_sysmsg "$TEST_TMPDIR/p1.json")"; return 1; }
}

@test "33967 R1: stop-check with every process start slowed to 1.5 s still ends inside its 10 s limit" {
    local limit; limit="$(_registered UserPromptSubmit stop-check timeout)"
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "no stop-check limit: $limit"; return 1; }
    local p; for p in dirname basename stat date head tr touch sed cat mkdir rm mv awk jq cygpath uname id; do _slow "$p" 1.5; done
    local launch=3 stamp; stamp="$(_stamp_ago "$launch")"
    local start=$SECONDS
    _codex_fire "stop-check" "$stamp" "$TEST_TMPDIR/sc.json"; local rc=$?
    local elapsed=$(( SECONDS - start ))
    echo "launch ${launch}s + stop-check ${elapsed}s = $(( launch + elapsed ))s against ${limit}s" >&3
    (( rc == 0 )) || { echo "stop-check exited $rc"; return 1; }
    (( launch + elapsed + CODEX_LAUNCH_MARGIN <= limit )) || { echo "stop-check ended $(( launch + elapsed ))s after launch against ${limit}s"; return 1; }
    [[ ! -s "$TEST_TMPDIR/sc.json" ]] || jq -e . "$TEST_TMPDIR/sc.json" >/dev/null || { echo "not JSON: $(cat "$TEST_TMPDIR/sc.json")"; return 1; }
    # It still did its job: the save prompt went to the assistant.
    [[ "$(_ctx "$TEST_TMPDIR/sc.json")" == *"Save what is new since the last memory"* ]] || { echo "no save prompt: $(cat "$TEST_TMPDIR/sc.json")"; return 1; }
}

@test "33967 R2: stop-check whose launch already used most of its 10 s ends at once, quietly, and prompts on the next message" {
    local limit; limit="$(_registered UserPromptSubmit stop-check timeout)"
    local launch=$(( limit - CODEX_LAUNCH_MARGIN - 1 )) stamp; stamp="$(_stamp_ago "$launch")"
    local start=$SECONDS
    _codex_fire "stop-check" "$stamp" "$TEST_TMPDIR/late.json"; local rc=$?
    local elapsed=$(( SECONDS - start ))
    echo "launch ${launch}s + stop-check ${elapsed}s" >&3
    (( rc == 0 )) || { echo "exited $rc"; return 1; }
    [[ ! -s "$TEST_TMPDIR/late.json" ]] || { echo "a late stop-check still spoke: $(cat "$TEST_TMPDIR/late.json")"; return 1; }
    (( elapsed <= 1 )) || { echo "a late stop-check took ${elapsed}s"; return 1; }
    # Nothing was marked as prompted, so the next message prompts.
    _codex_fire "stop-check" "" "$TEST_TMPDIR/next.json"
    [[ "$(_ctx "$TEST_TMPDIR/next.json")" == *"Save what is new since the last memory"* ]] || { echo "the next message did not prompt: $(cat "$TEST_TMPDIR/next.json")"; return 1; }
}

# =============================================================================================
# BUDGET (Windows): PROCESSES PER PER-MESSAGE HOOK, COUNTED BY THE OPERATING SYSTEM
# =============================================================================================
# TC5's condition: a configured Codex install, no Foundation set, no Formation. Each registered
# commandWindows run the way Codex's PowerShell runs it (cmd /d /c ... with the payload on stdin),
# inside a job object that counts every process the OS creates. One firing first, uncounted, so the
# counted one is an ordinary prompt and not the first one.
#
# THE BUDGETS, and where each process goes after #33967:
#   cmd 1, Git's bin\bash.exe wrapper 1, bash 1, codex-hook.sh's subshell for the handler 1 = 4
#   stop-check: 4, and nothing of its own
#   Foundation parts 2-6: 4, and the rename of the outcome record (mv: fork and exec) 2 = 6
#   Foundation part 1: 6, and three forks for the host's command names in its notice = 9
#   codex-first-prompt and formation-check: cmd alone, their gates = 1
# Before #33967: 1, 13, 10 x5, 1, 18; 84 for all nine together.
declare -gA BUDGET=(
    [codex-first-prompt]=1
    ["userpromptsubmit-foundation --part 1"]=9
    ["userpromptsubmit-foundation --part 2"]=6
    ["userpromptsubmit-foundation --part 3"]=6
    ["userpromptsubmit-foundation --part 4"]=6
    ["userpromptsubmit-foundation --part 5"]=6
    ["userpromptsubmit-foundation --part 6"]=6
    [formation-check]=1
    [stop-check]=4
)

@test "33967 budget windows: every per-message Codex hook starts no more processes than its budget" {
    _is_windows || skip "Windows only: counts processes with a Windows job object"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    local counter; counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    # The plugin as Codex installs it, in a private Codex home.
    local root="$CODEX_DIR/plugins/cache/mmry-plugin/mmry/local"
    mkdir -p "$root"
    ( cd "$PLUGIN_ROOT" && tar -cf - --exclude=./tests . ) | ( cd "$root" && tar -xf - )
    local wroot wpay
    wroot="$(cygpath -w "$root")"
    _payload > "$TEST_TMPDIR/payload.json"
    wpay="$(cygpath -w "$TEST_TMPDIR/payload.json")"
    local -a lines; mapfile -t lines < <(node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const g of d.hooks.UserPromptSubmit) for (const h of g.hooks) console.log(h.commandWindows);
    ' "$HOOKS")
    (( ${#lines[@]} == 9 )) || { echo "expected 9 per-message registrations, found ${#lines[@]}"; return 1; }
    local c label cmdline got total=0 over=""
    for c in "${lines[@]}"; do
        c="${c%$'\r'}"
        label="${c##*codex-hook.cmd\" }"
        [[ -n "${BUDGET[$label]:-}" ]] || { echo "no budget for [$label]"; return 1; }
        c="${c//\$\{PLUGIN_ROOT\}/$wroot}"
        cmdline="cmd.exe /d /s /c \"${c#cmd /d /c } < \"$wpay\"\""
        env -u MMRY_CONFIG_FILE CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$(cygpath -w "$TMPDIR")" HOME="$(cygpath -w "$HOME")" \
            pwsh -NoProfile -File "$counter" -CommandLine "$cmdline" < /dev/null > /dev/null 2>&1
        got="$(env -u MMRY_CONFIG_FILE CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$(cygpath -w "$TMPDIR")" HOME="$(cygpath -w "$HOME")" \
            pwsh -NoProfile -File "$counter" -CommandLine "$cmdline" < /dev/null 2>/dev/null | tr -d '\r' | sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' | tail -1)"
        [[ "$got" =~ ^[0-9]+$ ]] || { echo "the counter did not answer for [$label]"; return 1; }
        echo "$(printf '%-40s' "$label") ${got} processes (budget ${BUDGET[$label]})" >&3
        total=$(( total + got ))
        (( got <= BUDGET[$label] )) || over+=" [$label: $got > ${BUDGET[$label]}]"
    done
    echo "all nine: ${total} processes" >&3
    [[ -z "$over" ]] || { echo "over budget:$over"; return 1; }
}
