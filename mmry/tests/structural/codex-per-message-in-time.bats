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
    # A POSIX spelling, whatever TMPDIR looks like: a PATH entry spelled C:/... is split at its colon,
    # and the slow stand-ins below would then never be found, so every held condition would pass empty.
    mkdir -p "$TEST_TMPDIR/shims"
    SHIMS="$(cd "$TEST_TMPDIR/shims" && pwd)"
    unset MMRY_HOST MMRY_JQ CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_CODEX_HOOK_STARTED MMRY_HOOK_LAUNCH_SECS
    export MMRY_NO_SELF_UPDATE=1
    SID="cdx33967-$$-${BATS_TEST_NUMBER}"
}

teardown() {
    _load_stop
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

# THE LAUNCH STAMP NEEDS BASH'S OWN CLOCK (QA round 2, macOS CI). Only codex-hook.cmd writes the stamp,
# on Windows, and codex-hook.sh reads it with printf %(...)T, which bash has from 4.2. On the bash 3.2
# a Mac ships there is no stamp in real use and none can be read, so the launch is 0 and the deadlines
# are as before, by design. A held launch cannot be set up there, so these tests say so and skip; they
# run on Windows and Linux.
_needs_launch_clock() {
    (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 ) )) && return 0
    skip "bash ${BASH_VERSION}: no builtin clock to read a launch stamp, which only Windows writes"
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
    # THE PREMISE: the handler, run with this PATH, finds the slow one. A held condition the handler
    # never meets passes for the wrong reason.
    [[ "$(PATH="$SHIMS:$PATH" command -v "$name")" == "$SHIMS/$name" ]] || {
        echo "premise: PATH does not resolve $name to the slow stand-in"; return 1; }
}

# =============================================================================================
# R1 + R2 (every platform): THE HELD CONDITION ENDS QUIETLY INSIDE ITS LIMIT
# =============================================================================================

@test "33967 R1+R2: Foundation parts whose launch used 12 s, with a set check that never finishes, end quietly inside 20 s" {
    _needs_launch_clock
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

@test "33967 R1: a Foundation part whose launch used 17 s ends at once, says nothing, and the next prompt is told" {
    _needs_launch_clock
    # Too late to do anything inside 20 s with Codex's own launch in hand: no work at all this turn.
    _seed_set
    _slow cksum 60
    local launch=17 stamp; stamp="$(_stamp_ago "$launch")"
    local start=$SECONDS
    _codex_fire "userpromptsubmit-foundation --part 1" "$stamp" "$TEST_TMPDIR/p1.json"; local rc=$?
    local elapsed=$(( SECONDS - start ))
    echo "launch ${launch}s + part 1 ${elapsed}s" >&3
    (( rc == 0 )) || { echo "exited $rc"; return 1; }
    (( launch + elapsed + CODEX_LAUNCH_MARGIN <= 20 )) || { echo "part 1 ended $(( launch + elapsed ))s after launch"; return 1; }
    [[ ! -s "$TEST_TMPDIR/p1.json" ]] || { echo "a part with no time left still spoke: $(head -c 300 "$TEST_TMPDIR/p1.json")"; return 1; }
    rm -f "$SHIMS/cksum"
    _codex_fire "userpromptsubmit-foundation --part 1" "" "$TEST_TMPDIR/next1.json"
    local ctx; ctx="$(_ctx "$TEST_TMPDIR/next1.json")"
    [[ "$ctx" == *"PREVIOUS turn"*"cut short"* ]] || { echo "the next prompt was not told: ${ctx:0:300}"; return 1; }
    [[ "$ctx" == *"This is PART 1 OF "* ]] || { echo "the next prompt did not restate the set: ${ctx:0:300}"; return 1; }
}

@test "33967 R1: a Foundation part with a launch of 8 s still gives the set its whole time from launch, not 10 s on top" {
    _needs_launch_clock
    # The deadline counts from the launch, so the part ends about 10 s after launch plus its tail; a
    # deadline that ignored the launch would end 18 s after it plus the same tail.
    _seed_set
    _slow cksum 60
    local launch=8 stamp; stamp="$(_stamp_ago "$launch")"
    local start=$SECONDS
    _codex_fire "userpromptsubmit-foundation --part 1" "$stamp" "$TEST_TMPDIR/p1.json"
    local elapsed=$(( SECONDS - start ))
    echo "launch ${launch}s + part 1 ${elapsed}s" >&3
    # THE PREMISE: the set check really never finished, so the part ran to its deadline and told the
    # assistant. A part that finished early would pass the bound below whatever the deadline counts.
    local ctx; ctx="$(_ctx "$TEST_TMPDIR/p1.json")"
    [[ "$ctx" == *"cut short"* ]] || { echo "premise: part 1 did not reach its deadline: ${ctx:0:300}"; return 1; }
    (( launch + elapsed <= 10 + 5 )) || { echo "part 1 ended $(( launch + elapsed ))s after launch: its deadline did not count the launch"; return 1; }
    [[ -z "$(_sysmsg "$TEST_TMPDIR/p1.json")" ]] || { echo "showed the person: $(_sysmsg "$TEST_TMPDIR/p1.json")"; return 1; }
}

@test "33967 R1: stop-check with every process start slowed to 1.5 s still ends inside its 10 s limit" {
    _needs_launch_clock
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
    _needs_launch_clock
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
# Each registered commandWindows run the way Codex's PowerShell runs it (cmd /d /c ... with the payload
# on stdin), inside a job object that counts every process the OS creates.
#
# THE BUDGETS, and where each process goes after #33967:
#   cmd 1, Git's bin\bash.exe wrapper 1, bash 1, codex-hook.sh's subshell for the handler 1 = 4
#   stop-check inside its quiet time (most messages): cmd alone = 1. Round 4: codex-hook.cmd answers it
#     from the record stop-check leaves beside its marker. On the 3db1d57 head it was 4.
#   stop-check when it prompts: cmd, the wrapper and bash = 3, because round 4 runs it in codex-hook.sh's
#     own shell, not a subshell. On the 3db1d57 head it was 4.
#   Foundation parts 2-6, no set (TC5's account): 4, and the rename of the outcome record (mv: fork
#     and exec) 2 = 6
#   Foundation part 1, no set: 6, and three forks for the host's command names in its notice = 9
#   codex-first-prompt and formation-check: cmd alone, their gates = 1
# Before #33967 (develop beb0b24), the same count: 1, 13, 10 x5, 1, 18; 83 for all nine.
# Exact, so one helper process added back to the launcher, codex-hook.sh or stop-check turns this red
# (run-codex-mutations.sh, the [33967 budget] experiments).
_budget() {
    case "$1" in
        codex-first-prompt|formation-check) echo 1 ;;
        "userpromptsubmit-foundation --part 1") echo 9 ;;
        "userpromptsubmit-foundation --part "[2-6]) echo 6 ;;
        stop-check) echo 1 ;;
        "stop-check firing") echo 3 ;;
        *) echo "" ;;
    esac
}
# With a prepared Foundation set (a customer who has Foundation memories), on an ordinary prompt: the
# launcher 4, and the served path 5. Before #33967 (develop beb0b24): 13 a part, 78 for six.
_budget_set() {
    case "$1" in
        "userpromptsubmit-foundation --part 1") echo 9 ;;
        "userpromptsubmit-foundation --part "[2-6]) echo 9 ;;
        *) echo "" ;;
    esac
}

# The plugin as Codex installs it, in a private Codex home; sets WROOT.
_install_codex_copy() {
    local root="$CODEX_DIR/plugins/cache/mmry-plugin/mmry/local"
    mkdir -p "$root"
    ( cd "$PLUGIN_ROOT" && tar -cf - --exclude=./tests . ) | ( cd "$root" && tar -xf - )
    WROOT="$(cygpath -w "$root")"
}

# Count one registered commandWindows; $1 the registration, $2 where its stdout goes. Echoes the count.
_count_registered() {
    local c="$1" out="$2" counter wpay
    counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    _payload > "$TEST_TMPDIR/payload.json"
    wpay="$(cygpath -w "$TEST_TMPDIR/payload.json")"
    c="${c//\$\{PLUGIN_ROOT\}/$WROOT}"
    env -u MMRY_CONFIG_FILE CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$(cygpath -w "$TMPDIR")" HOME="$(cygpath -w "$HOME")" \
        pwsh -NoProfile -File "$counter" -CommandLine "cmd.exe /d /s /c \"${c#cmd /d /c } < \"$wpay\" > \"$(cygpath -w "$out")\"\"" \
        < /dev/null 2>/dev/null | tr -d '\r' | sed -n 's/.*PROCESSES=\([0-9]*\).*/\1/p' | tail -1
}

_registrations_windows() {
    node -e '
        const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        for (const g of d.hooks.UserPromptSubmit) for (const h of g.hooks) console.log(h.commandWindows);
    ' "$HOOKS" | tr -d '\r'
}

@test "33967 budget windows: every per-message Codex hook starts no more processes than its budget" {
    # TC5's condition: a configured Codex install, no Foundation set, no Formation. One firing first,
    # uncounted, so the counted one is an ordinary prompt and not the first.
    _is_windows || skip "Windows only: counts processes with a Windows job object"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    _install_codex_copy
    local c label got want total=0 n=0 over=""
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        n=$(( n + 1 ))
        label="${c##*codex-hook.cmd\" }"
        want="$(_budget "$label")"
        [[ -n "$want" ]] || { echo "no budget for [$label]"; return 1; }
        _count_registered "$c" "$TEST_TMPDIR/first.out" >/dev/null
        got="$(_count_registered "$c" "$TEST_TMPDIR/counted.out")"
        [[ "$got" =~ ^[0-9]+$ ]] || { echo "the counter did not answer for [$label]"; return 1; }
        echo "$(printf '%-40s' "$label") ${got} processes (budget ${want})" >&3
        total=$(( total + got ))
        (( got <= want )) || over="${over} [$label: $got > $want]"
    done < <(_registrations_windows)
    echo "all nine: ${total} processes" >&3
    (( n == 9 )) || { echo "expected 9 per-message registrations, found $n"; return 1; }
    # stop-check above was counted on its quiet path (the uncounted firing had just prompted). Its other
    # path, the firing that prompts and stamps its marker, has its own budget (round 4).
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at" "$TMPDIR/.mmry-stop-count"
    got="$(_count_registered "$(_registered UserPromptSubmit stop-check commandWindows)" "$TEST_TMPDIR/firing.out")"
    echo "$(printf '%-40s' "stop-check, firing") ${got} processes (budget $(_budget "stop-check firing"))" >&3
    [[ "$(_ctx "$TEST_TMPDIR/firing.out")" == *"Save what is new since the last memory"* ]] || {
        echo "premise: the counted stop-check did not fire: $(cat "$TEST_TMPDIR/firing.out")"; return 1; }
    (( got <= $(_budget "stop-check firing") )) || over="${over} [stop-check firing: $got > $(_budget "stop-check firing")]"
    [[ -z "$over" ]] || { echo "over budget:$over"; return 1; }
}

@test "33967 budget windows: with a Foundation set, an ordinary prompt's parts start no more than their budget, and deliver it whole" {
    _is_windows || skip "Windows only: counts processes with a Windows job object"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    _install_codex_copy
    _seed_set
    local k c pids=()
    # The prompt that prepares the set, uncounted, all six together as Codex starts them.
    for k in 1 2 3 4 5 6; do
        c="$(_registered UserPromptSubmit "--part $k" commandWindows)"
        _count_registered "$c" "$TEST_TMPDIR/prep$k.json" >/dev/null &
        pids+=("$!")
    done
    wait "${pids[@]}"
    local got want over="" total=0 joined="" ctx
    for k in 1 2 3 4 5 6; do
        c="$(_registered UserPromptSubmit "--part $k" commandWindows)"
        got="$(_count_registered "$c" "$TEST_TMPDIR/served$k.json")"
        want="$(_budget_set "userpromptsubmit-foundation --part $k")"
        [[ "$got" =~ ^[0-9]+$ ]] || { echo "the counter did not answer for part $k"; return 1; }
        echo "with a set, part $k: ${got} processes (budget ${want})" >&3
        total=$(( total + got ))
        (( got <= want )) || over="${over} [part $k: $got > $want]"
        ctx="$(_ctx "$TEST_TMPDIR/served$k.json")"; ctx="${ctx%.}"
        joined="${joined}${ctx#*if their versions differ, tell the user.$'\n\n'}"
    done
    echo "with a set, six parts: ${total} processes" >&3
    [[ -z "$over" ]] || { echo "over budget:$over"; return 1; }
    local wantset; wantset="$(cat "$CACHE"; printf .)"; wantset="${wantset%.}"; wantset="${wantset%$'\n'}"
    [[ "$joined" == "$wantset" ]] || { echo "the counted prompt did not deliver the set whole (${#joined} of ${#wantset} bytes)"; return 1; }
}

@test "33967 stamp windows: the launch time reaches the per-message handlers through cmd and codex-hook.sh" {
    # The real launcher and the real codex-hook.sh, with stand-ins for the two per-message handlers that
    # only report what they were handed. Without the stamp a handler on Windows cannot know how much of
    # its limit the launch already used.
    _is_windows || skip "Windows only: needs cmd.exe"
    local root="$TEST_TMPDIR/stamp root" h out
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$root/"
    for h in stop-check userpromptsubmit-foundation; do
        printf '#!/usr/bin/env bash\necho "HANDED %s LAUNCH=[${MMRY_HOOK_LAUNCH_SECS:-unset}] STAMP=[${MMRY_CODEX_HOOK_STARTED:-unset}]"\n' "$h" > "$root/hooks-handlers/$h.sh"
    done
    local wroot; wroot="$(cygpath -w "$root")"
    for h in "stop-check" "userpromptsubmit-foundation --part 1"; do
        # shellcheck disable=SC2086
        out="$(_payload | env -u MMRY_CODEX_HOOK_STARTED -u MMRY_HOOK_LAUNCH_SECS CODEX_HOME="$(cygpath -w "$CODEX_DIR")" \
            cmd //d //c "${wroot}\\hooks-handlers\\codex-hook.cmd" $h 2>&1 | tr -d '\r')"
        echo "$h: $out" >&3
        [[ "$out" =~ HANDED\ ${h%% *}\ LAUNCH=\[([0-9]+)\]\ STAMP=\[\ ?[0-9]{1,2}:[0-9]{2}:[0-9]{2} ]] || {
            echo "$h was not handed the launch time: $out"; return 1; }
        (( BASH_REMATCH[1] <= 60 )) || { echo "$h was handed an implausible launch: ${BASH_REMATCH[1]}"; return 1; }
    done
}

# =============================================================================================
# SECURITY (Windows): THE BUILTIN PATH SCAN NEVER CHOOSES A GIT IN THE CUSTOMER'S PROJECT
# =============================================================================================
# where.exe $PATH:git.exe searched PATH only. Its replacement walks PATH with builtins, and a PATH entry
# that is not absolute ("." or "tools") names a folder in the project Codex runs the hook from. A
# git.exe and a bin\bash.exe planted there must never be chosen; only absolute entries count.

@test "33967 security windows: a relative PATH entry naming a folder in the project never chooses its bash" {
    _is_windows || skip "Windows only: needs cmd.exe"
    local jq="$PLUGIN_ROOT/vendor/jq/jq-windows-amd64.exe"
    [[ -f "$jq" ]] || skip "vendored Windows jq not present"
    local root="$TEST_TMPDIR/plugin root"
    mkdir -p "$root/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" "$root/hooks-handlers/"
    printf '#!/usr/bin/env bash\necho "REACHED handler=[$1]"\n' > "$root/hooks-handlers/codex-hook.sh"
    # The plant: tools\git.exe and bin\bash.exe in the project; the bash is a copy of the vendored jq,
    # which announces itself with "jq: error" when handed a script path.
    local project="$TEST_TMPDIR/customer project"
    mkdir -p "$project/tools" "$project/sub/tools" "$project/bin"
    cp "$jq" "$project/tools/git.exe"; cp "$jq" "$project/sub/tools/git.exe"; cp "$jq" "$project/bin/bash.exe"
    local gitcmd winroot out f
    gitcmd="$(cygpath -w "$(dirname "$(command -v git)")")"
    winroot="$(cygpath -w "$root")"
    # Relative entries first on PATH, a real Git after them; run from the project, then a subfolder.
    # PATH and the folder are set inside cmd, so nothing converts them on the way.
    printf '@echo off\r\ncd /d "%s"\r\nset "PATH=tools;.;sub\\tools;%%SystemRoot%%\\System32;%s"\r\ncall "%s\\hooks-handlers\\codex-hook.cmd" stop-check\r\n' \
        "$(cygpath -w "$project")" "$gitcmd" "$winroot" > "$TEST_TMPDIR/from-project.cmd"
    printf '@echo off\r\ncd /d "%s"\r\nset "PATH=tools;..\\tools;%%SystemRoot%%\\System32;%s"\r\ncall "%s\\hooks-handlers\\codex-hook.cmd" stop-check\r\n' \
        "$(cygpath -w "$project/sub")" "$gitcmd" "$winroot" > "$TEST_TMPDIR/from-sub.cmd"
    for f in from-project from-sub; do
        out="$(env -u NoDefaultCurrentDirectoryInExePath cmd //d //c "$(cygpath -w "$TEST_TMPDIR/$f.cmd")" < /dev/null 2>&1 | tr -d '\r')"
        echo "$f: $out" >&3
        [[ "$out" != *"jq: error"* ]] || { echo "$f: the launcher ran the bash planted in the project: $out"; return 1; }
        [[ "$out" == *"REACHED handler=[stop-check]"* ]] || { echo "$f: the launcher did not reach the handler: $out"; return 1; }
    done
}

# A ! IN A PATH ENTRY IS A CHARACTER, NEVER A VARIABLE (QA round 2, new requirement 1). The round-2 walk
# copied each entry with delayed expansion on, so cmd expanded !NAME! inside it: !CD!\tools became the
# project's own tools folder, and a git.exe and bin\bash.exe planted there ran as the hook, which
# develop's where.exe never did. A lone ! was dropped, so C:\...\pl!ain\cmd was read as C:\...\plain\cmd.
# Every entry below must be read as written: none is an absolute folder that holds git.exe, so the real
# Git after them must run the handler.
@test "33967 security windows: a PATH entry holding !NAME! or a lone ! is read as written, never as a folder in the project" {
    _is_windows || skip "Windows only: needs cmd.exe"
    local jq="$PLUGIN_ROOT/vendor/jq/jq-windows-amd64.exe"
    [[ -f "$jq" ]] || skip "vendored Windows jq not present"
    local gitcmd; gitcmd="$(_git_cmd_dir)" || skip "no Git for Windows cmd folder at /cmd"
    local root="$TEST_TMPDIR/plugin root"
    mkdir -p "$root/hooks-handlers"
    cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" "$root/hooks-handlers/"
    printf '#!/usr/bin/env bash\necho "REACHED handler=[$1]"\n' > "$root/hooks-handlers/codex-hook.sh"
    # The plant: tools\git.exe and bin\bash.exe in the project (bash is the vendored jq, which says
    # "jq: error" when handed a script), and the same under a sibling "plain" for the lone-! case.
    local project="$TEST_TMPDIR/customer project"
    mkdir -p "$project/tools" "$project/sub" "$project/bin" "$TEST_TMPDIR/plain/cmd" "$TEST_TMPDIR/plain/bin" "$TEST_TMPDIR/pl!ain/cmd"
    cp "$jq" "$project/tools/git.exe"; cp "$jq" "$project/bin/bash.exe"
    cp "$jq" "$TEST_TMPDIR/plain/cmd/git.exe"; cp "$jq" "$TEST_TMPDIR/plain/bin/bash.exe"
    local wproject wtmp drive winroot
    wproject="$(cygpath -w "$project")"; wtmp="$(cygpath -w "$TEST_TMPDIR")"; winroot="$(cygpath -w "$root")"
    drive="${wproject:0:2}"
    # label | folder the hook runs from | the entry, as a batch file spells it
    local -a cases=(
        "cd|$wproject|!CD!\\tools"
        "cd-dot|$wproject|!CD!\\.\\tools"
        "cd-substring|$wproject|!CD:~0!\\tools"
        "cd-trailing|$wproject|!__CD__!tools"
        "drive-cwd|$wproject|!=$drive!\\tools"
        "cd-parent|$wproject\\sub|!CD!\\..\\tools"
        "cd-alone|$wproject\\tools|!CD!"
        "lone-bang|$wproject|$wtmp\\pl!ain\\cmd"
        "cd-delayed-default|$wproject|!CD!\\tools|von"
    )
    # cd-delayed-default: the launcher started by a cmd whose delayed expansion is on, as on a machine
    # whose registry turns it on by default (cmd /v:on stands in for that).
    local c label from entry how start f out bad=0
    for c in "${cases[@]}"; do
        IFS='|' read -r label from entry how <<< "$c"
        start="call"; [[ "$how" == von ]] && start="cmd /v:on /d /c"
        f="$TEST_TMPDIR/bang-$label.cmd"
        printf '%s\r\n' '@echo off' "cd /d \"$from\"" "set \"PATH=$entry;%SystemRoot%\\System32;$gitcmd\"" \
            "$start \"$winroot\\hooks-handlers\\codex-hook.cmd\" stop-check" 'echo EXIT=%ERRORLEVEL%' > "$f"
        out="$(env -u NoDefaultCurrentDirectoryInExePath cmd //d //c "$(cygpath -w "$f")" < /dev/null 2>&1 | tr -d '\r')"
        echo "$label ($entry): $out" >&3
        [[ "$out" != *"jq: error"* ]] || { echo "$label: the launcher ran a planted bash for the entry $entry: $out"; bad=1; continue; }
        [[ "$out" == *"REACHED handler=[stop-check]"* ]] || { echo "$label: the launcher did not reach the handler: $out"; bad=1; continue; }
        [[ "$out" == *"EXIT=0"* ]] || { echo "$label: the launcher did not exit 0: $out"; bad=1; continue; }
    done
    (( bad == 0 ))
}

# =============================================================================================
# PATH AS IT REALLY IS (Windows, QA round 1): QUOTED, UNBALANCED, OR HOLDING % OR ^
# =============================================================================================
# The builtin PATH walk must read PATH as written. In round 1 it expanded %PATH% while cmd was still
# parsing the line and then re-parsed each entry through `call`, so a quoted Git entry
# ("C:\Program Files\Git\cmd";...) made every hook exit 255 with `=1" was unexpected at this time.`,
# a quoted or unbalanced entry before Git's made every hook exit 0 without running, and an entry
# holding % or ^ was changed before it was looked in. where.exe, which it replaced, read all of these.

_git_cmd_dir() { [[ -f /cmd/git.exe ]] && cygpath -w /cmd; }

# The real launcher, a stand-in codex-hook.sh that only reports, and PATH set inside cmd so nothing
# converts it on the way. $1 the PATH as a batch file must spell it (a literal % written %%), $2 a label,
# $3 how the launcher is started (default call; "cmd /v:on /d /c" for a cmd whose delayed expansion is on).
_launch_with_path() {
    local root="$TEST_TMPDIR/plugin root" f="$TEST_TMPDIR/path-$2.cmd"
    if [[ ! -f "$root/hooks-handlers/codex-hook.sh" ]]; then
        mkdir -p "$root/hooks-handlers"
        cp "$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" "$root/hooks-handlers/"
        printf '#!/usr/bin/env bash\necho "REACHED handler=[$1]"\n' > "$root/hooks-handlers/codex-hook.sh"
    fi
    printf '%s\r\n' '@echo off' "set \"PATH=$1\"" \
        "${3:-call} \"$(cygpath -w "$root")\\hooks-handlers\\codex-hook.cmd\" stop-check" 'echo EXIT=%ERRORLEVEL%' > "$f"
    cmd //d //c "$(cygpath -w "$f")" < /dev/null 2>&1 | tr -d '\r'
}

@test "33967 path windows: a quoted Git entry, or a quoted or unbalanced entry before Git's, still runs the handler" {
    _is_windows || skip "Windows only: needs cmd.exe"
    local gitcmd; gitcmd="$(_git_cmd_dir)" || skip "no Git for Windows cmd folder at /cmd"
    mkdir -p "$TEST_TMPDIR/some tools"
    local tools; tools="$(cygpath -w "$TEST_TMPDIR/some tools")"
    local -a labels=(quoted-git quoted-before unbalanced-before)
    local -a paths=(
        "\"$gitcmd\";%SystemRoot%\\System32;%SystemRoot%"
        "%SystemRoot%\\System32;\"$tools\";$gitcmd;%SystemRoot%"
        "%SystemRoot%\\System32;C:\\odd\"dir;$gitcmd;%SystemRoot%"
    )
    local i out bad=0
    for i in 0 1 2; do
        out="$(_launch_with_path "${paths[$i]}" "${labels[$i]}")"
        echo "${labels[$i]}: $out" >&3
        [[ "$out" != *"was unexpected at this time"* ]] || { echo "${labels[$i]}: cmd could not parse the launcher: $out"; bad=1; continue; }
        [[ "$out" == *"REACHED handler=[stop-check]"* ]] || { echo "${labels[$i]}: the launcher did not run the handler: $out"; bad=1; continue; }
        [[ "$out" == *"EXIT=0"* ]] || { echo "${labels[$i]}: the launcher did not exit 0: $out"; bad=1; continue; }
    done
    (( bad == 0 ))
}

@test "33967 path windows: the walk itself reads a quoted entry, and entries holding % or ^ or !, as written" {
    # Each fake Git root comes before the real one, and its bin\bash.exe is a copy of the vendored jq,
    # which says "jq: error" when handed a script. Seeing that proves the PATH walk chose the entry; the
    # registry and the standard folders, which come after it, would choose the real Git instead.
    # bang!git (QA round 2): a Git installed under a folder holding ! is found where it is, as
    # where.exe on develop found it, because the entry is read as written; also when the cmd that starts
    # the launcher has delayed expansion on (a machine whose registry turns it on by default).
    _is_windows || skip "Windows only: needs cmd.exe"
    local jq="$PLUGIN_ROOT/vendor/jq/jq-windows-amd64.exe"
    [[ -f "$jq" ]] || skip "vendored Windows jq not present"
    local gitcmd; gitcmd="$(_git_cmd_dir)" || skip "no Git for Windows cmd folder at /cmd"
    local -a labels=(quoted percent caret bang bang-delayed-default) dirs=("fake git" "pct%OS%git" "caret^git" "bang!git" "bang!git")
    local i d w entry how out bad=0
    for i in 0 1 2 3 4; do
        d="$TEST_TMPDIR/${dirs[$i]}"
        mkdir -p "$d/cmd" "$d/bin"
        cp "$jq" "$d/cmd/git.exe"; cp "$jq" "$d/bin/bash.exe"
        w="$(cygpath -w "$d")\\cmd"
        [[ -f "$d/cmd/git.exe" && -f "$d/bin/bash.exe" ]] || { echo "premise: could not build $d"; bad=1; continue; }
        case "${labels[$i]}" in
            quoted) entry="\"$w\"" ;;
            percent) entry="${w//%/%%}" ;;
            *) entry="$w" ;;
        esac
        how="call"; [[ "${labels[$i]}" == *-delayed-default ]] && how="cmd /v:on /d /c"
        out="$(_launch_with_path "$entry;$gitcmd;%SystemRoot%\\System32" "${labels[$i]}" "$how")"
        echo "${labels[$i]}: $out" >&3
        [[ "$out" != *"was unexpected at this time"* ]] || { echo "${labels[$i]}: cmd could not parse the launcher: $out"; bad=1; continue; }
        [[ "$out" == *"jq: error"* ]] || { echo "${labels[$i]}: the walk did not choose the entry as written ($w): $out"; bad=1; continue; }
    done
    (( bad == 0 ))
}

# =============================================================================================
# THE sh FORM (every platform, QA round 1): A SOURCED HANDLER RUNS WITH POSIX MODE OFF
# =============================================================================================
# The `command` form in codex-hooks.json starts codex-hook.sh with sh. On macOS sh is bash 3.2 in
# POSIX mode, where process substitution does not parse, and userpromptsubmit-foundation.sh uses it.
# A child bash used to clear POSIX mode; a sourced subshell inherits it unless it turns it off.

_sh_fire() { # $1 plugin root, $2 handler args (word-split), $3 output file
    # shellcheck disable=SC2086
    _payload | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_CODEX_HOOK_STARTED CODEX_HOME="$CODEX_DIR" \
        sh "$1/hooks-handlers/codex-hook.sh" $2 > "$3" 2>/dev/null
}

@test "33967 sh form: the sourced per-message handlers run with POSIX mode off" {
    local root="$TEST_TMPDIR/probe root" h out
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$root/"
    for h in stop-check userpromptsubmit-foundation; do
        printf '#!/usr/bin/env bash\ncase ":$SHELLOPTS:" in *:posix:*) echo "%s POSIX=on" ;; *) echo "%s POSIX=off" ;; esac\n' "$h" "$h" > "$root/hooks-handlers/$h.sh"
    done
    # Where sh is bash it arrives in POSIX mode (macOS, Git for Windows); where it is dash, codex-hook.sh
    # starts bash itself and this test cannot see the difference, which is said, not hidden.
    if sh -c '[ -n "${BASH_VERSION:-}" ]'; then echo "sh is bash here: the probe can tell" >&3
    else echo "sh is not bash here: codex-hook.sh re-runs itself in bash, POSIX mode is off either way" >&3; fi
    for h in "stop-check" "userpromptsubmit-foundation --part 1"; do
        _sh_fire "$root" "$h" "$TEST_TMPDIR/probe.out"
        out="$(tr -d '\r' < "$TEST_TMPDIR/probe.out")"
        echo "$h: $out" >&3
        [[ "$out" == *"${h%% *} POSIX=off"* ]] || { echo "$h ran with POSIX mode on, or not at all: $out"; return 1; }
    done
}

@test "33967 sh form: Foundation parts started by sh, as the command form registers them, deliver the whole set" {
    _seed_set
    local k pids=()
    for k in 1 2 3 4 5 6; do _sh_fire "$PLUGIN_ROOT" "userpromptsubmit-foundation --part $k" "$TEST_TMPDIR/sh$k.json" & pids+=("$!"); done
    wait "${pids[@]}"
    local joined="" ctx n=0
    for k in 1 2 3 4 5 6; do
        [[ -z "$(_sysmsg "$TEST_TMPDIR/sh$k.json")" ]] || { echo "part $k showed the person: $(_sysmsg "$TEST_TMPDIR/sh$k.json")"; return 1; }
        ctx="$(_ctx "$TEST_TMPDIR/sh$k.json")"; ctx="${ctx%.}"
        [[ "$ctx" == *"This is PART $k OF "* ]] || continue
        joined+="${ctx#*if their versions differ, tell the user.$'\n\n'}"
        n=$(( n + 1 ))
    done
    local want; want="$(cat "$CACHE"; printf .)"; want="${want%.}"; want="${want%$'\n'}"
    echo "sh form: ${n} parts, ${#joined} of ${#want} bytes" >&3
    [[ "$joined" == "$want" ]] || { echo "the sh form did not deliver the whole set (${n} parts, ${#joined} of ${#want} bytes)"; return 1; }
}

# =============================================================================================
# LOAD (Windows, opt-in, round 4): STOP-CHECK INSIDE ITS 10 s AT THE LIVE PROOF'S LOAD
# =============================================================================================
# THE FINDING (33967 live proof, 2026-11-18, Codex 0.169.0, head 3db1d57). Under a load of 1.48 to 1.65 s
# per process start (`cmd /d /c exit 0` timed from Git Bash, the median of 5), a message sent mid-turn
# started the nine per-message hooks, and stop-check failed at its 10 s limit in both windows, on the
# turn's first message and on the steer. The other eight completed.
#
# This test does what that proof did, without Codex. It holds the machine at that load, then starts all
# nine per-message hooks at once the way Codex does (powershell.exe -NoProfile -Command with each
# registered commandWindows, the payload on stdin: helpers/codex-hook-group.ps1), and judges stop-check
# by the clock against its limit in codex-hooks.json. The first group is uncounted: it is the turn's
# first message, after which stop-check is in its quiet time, as it was for the steer. Then come
# LOAD_QUIET_ROUNDS groups like the steer, and LOAD_FIRING_ROUNDS with stop-check's marker removed, so
# that its prompting path is judged too. Every stop-check must end inside its limit, either silent or
# with a whole save prompt. Each round also prints what the two hooks that start nothing past cmd took
# (formation-check and codex-first-prompt with no Formation and no late start): that is Codex's own
# PowerShell and cmd at this load, which no change to MMRY can make faster.
#
# OPT-IN (MMRY_TEST_LOAD=1): it loads this machine for about five minutes on purpose, so an ordinary run
# skips it. The load workers are stopped in teardown, by pid, whatever the result. The window is
# 1500 to 1650 ms, the live proof's; MMRY_TEST_LOAD_LOW and MMRY_TEST_LOAD_HIGH move it, for characterising
# only: a run booked against the proof uses the default.
LOAD_LOW="${MMRY_TEST_LOAD_LOW:-1500}"
LOAD_HIGH="${MMRY_TEST_LOAD_HIGH:-1650}"
LOAD_QUIET_ROUNDS=5
LOAD_FIRING_ROUNDS=3

# The live proof's measure: the median of 5 timed `cmd /d /c exit 0` starts, in ms.
_load_sample() {
    local i s e v=()
    for i in 1 2 3 4 5; do
        s=$(date +%s%N); cmd //d //c exit 0; e=$(date +%s%N)
        v+=( $(( (e - s) / 1000000 )) )
    done
    printf '%s\n' "${v[@]}" | sort -n | sed -n 3p
}
_load_add() {
    local i
    for (( i = 0; i < $1; i++ )); do
        ( while :; do cmd //d //c exit 0; done ) >/dev/null 2>&1 3>&- 4>&- &
        echo "$!" >> "$TEST_TMPDIR/load.pids"
    done
}
_load_drop_one() {
    local p; p="$(tail -1 "$TEST_TMPDIR/load.pids")"
    kill "$p" 2>/dev/null
    sed -i '$d' "$TEST_TMPDIR/load.pids"
}
_load_stop() {
    [[ -n "${TEST_TMPDIR:-}" && -f "$TEST_TMPDIR/load.pids" ]] || return 0
    local p left=0
    while read -r p; do kill "$p" 2>/dev/null; done < "$TEST_TMPDIR/load.pids"
    sleep 2
    while read -r p; do kill -0 "$p" 2>/dev/null && left=$(( left + 1 )); done < "$TEST_TMPDIR/load.pids"
    echo "load workers left after stop: $left" >&3
    rm -f "$TEST_TMPDIR/load.pids"
}
# Starts MMRY_TEST_LOAD_WORKERS workers (12) and adds or drops one at a time until the median is inside
# the window. Sets LOAD_MS. Fails if the window is not reached in 14 samples.
_load_calibrate() {
    local n="${MMRY_TEST_LOAD_WORKERS:-12}" try
    : > "$TEST_TMPDIR/load.pids"
    _load_add "$n"
    for (( try = 0; try < 14; try++ )); do
        LOAD_MS="$(_load_sample)"
        echo "load: $n workers, median ${LOAD_MS} ms per process start" >&3
        if (( LOAD_MS < LOAD_LOW )); then _load_add 1; n=$(( n + 1 )); continue; fi
        if (( LOAD_MS > LOAD_HIGH )); then _load_drop_one; n=$(( n - 1 )); sleep 2; continue; fi
        return 0
    done
    return 1
}

# One message: the nine hooks at once. Sets SC_MS, SC_RC and SC_OUT (a POSIX path), and prints the round.
_group() {
    local label="$1" dir="$TEST_TMPDIR/group-$1" helper name ms lim rc file floor="" said
    mkdir -p "$dir"
    helper="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/codex-hook-group.ps1")"
    env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_CODEX_HOOK_STARTED -u MMRY_HOOK_LAUNCH_SECS \
        CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$(cygpath -w "$TMPDIR")" HOME="$(cygpath -w "$HOME")" \
        pwsh -NoProfile -File "$helper" -Root "$WROOT" -Payload "$(cygpath -w "$TEST_TMPDIR/payload.json")" \
        -OutDir "$(cygpath -w "$dir")" < /dev/null 2>/dev/null | tr -d '\r' > "$dir/times"
    SC_MS="" SC_RC="" SC_OUT=""
    while IFS='|' read -r name ms lim rc file; do
        case "$name" in
            stop-check) SC_MS="$ms" SC_RC="$rc" SC_OUT="$(cygpath -u "$file")" ;;
            formation-check|codex-first-prompt) floor="${floor}${floor:+, }${name} ${ms} ms" ;;
        esac
    done < "$dir/times"
    said="silent"
    [[ -s "$SC_OUT" ]] && said="a save prompt"
    echo "$(printf '%-8s' "$label") stop-check ${SC_MS:-?} ms, exit ${SC_RC:-?}, ${said}; PowerShell and cmd alone: ${floor}" >&3
}

@test "33967 load windows: at the live proof's load, stop-check started with the other eight hooks as Codex starts them ends inside its 10 s limit" {
    _is_windows || skip "Windows only: Codex's PowerShell launch, on a loaded Windows machine"
    [[ "${MMRY_TEST_LOAD:-}" == 1 ]] || skip "opt-in (MMRY_TEST_LOAD=1): it loads this machine for about five minutes"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    local limit; limit="$(_registered UserPromptSubmit stop-check timeout)"
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "no stop-check limit: $limit"; return 1; }
    _install_codex_copy
    _payload > "$TEST_TMPDIR/payload.json"
    _load_calibrate || { echo "premise: the load did not settle at ${LOAD_LOW} to ${LOAD_HIGH} ms per process start (last ${LOAD_MS} ms)"; return 1; }
    local before="$LOAD_MS" r over="" bad=""
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at" "$TMPDIR/.mmry-stop-checked.cmd"
    # The turn's first message: stop-check prompts and starts its quiet time.
    _group first
    [[ -f "$TMPDIR/.mmry-stop-checked" ]] || { echo "premise: the first message's stop-check did not stamp its marker"; return 1; }
    for (( r = 1; r <= LOAD_QUIET_ROUNDS; r++ )); do
        _group "steer$r"
        [[ "$SC_MS" =~ ^[0-9]+$ ]] || { echo "the group helper did not report stop-check: $(cat "$TEST_TMPDIR/group-steer$r/times")"; return 1; }
        (( SC_MS < limit * 1000 )) || over="${over} [steer $r: ${SC_MS} ms]"
        (( SC_RC == 0 )) || bad="${bad} [steer $r exited ${SC_RC}]"
        # Premise: inside its quiet time it says nothing. A prompt here means the round tested the wrong path.
        [[ ! -s "$SC_OUT" ]] || bad="${bad} [steer $r prompted inside the quiet time: $(head -c 120 "$SC_OUT")]"
    done
    for (( r = 1; r <= LOAD_FIRING_ROUNDS; r++ )); do
        rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at" "$TMPDIR/.mmry-stop-checked.cmd"
        _group "prompt$r"
        [[ "$SC_MS" =~ ^[0-9]+$ ]] || { echo "the group helper did not report stop-check: $(cat "$TEST_TMPDIR/group-prompt$r/times")"; return 1; }
        (( SC_MS < limit * 1000 )) || over="${over} [prompting $r: ${SC_MS} ms]"
        (( SC_RC == 0 )) || bad="${bad} [prompting $r exited ${SC_RC}]"
        # Ending silently is allowed (a launch that used the time); speaking is allowed only whole.
        if [[ -s "$SC_OUT" ]]; then
            [[ "$(_ctx "$SC_OUT")" == *"Save what is new since the last memory"* ]] || bad="${bad} [prompting $r: not a whole save prompt: $(head -c 120 "$SC_OUT")]"
        fi
    done
    LOAD_MS="$(_load_sample)"
    echo "load: median ${before} ms per process start before the groups, ${LOAD_MS} ms after" >&3
    [[ -z "$bad" ]] || { echo "stop-check misbehaved:$bad"; return 1; }
    [[ -z "$over" ]] || { echo "stop-check took ${limit} s or more, its limit:$over"; return 1; }
}

# =============================================================================================
# ROUND 4: STOP-CHECK'S QUIET MESSAGE ENDS IN CMD, AND ITS PROMPT STARTS NO SUBSHELL
# =============================================================================================
# codex-hook.cmd ends stop-check in cmd, starting no process, when the record stop-check leaves beside its
# marker (.mmry-stop-checked.cmd: this launch's seconds of the day and cmd's %DATE%) shows it is inside
# its quiet time. Everything else goes on to stop-check. These pin both halves: the launcher is quiet
# only when stop-check would be, and stop-check writes the record only from values the launcher handed it.

# The real launcher for stop-check, as Codex's PowerShell runs it, counted by a job object. $1 the TMPDIR
# the hook sees, $2 the stdout file, $3 the stderr file. Echoes "<processes> <exit code>".
_sc_count() {
    local tmp="$1" out="$2" err="$3" counter wpay c
    counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    _payload > "$TEST_TMPDIR/payload.json"
    wpay="$(cygpath -w "$TEST_TMPDIR/payload.json")"
    c="$(_registered UserPromptSubmit stop-check commandWindows)"
    c="${c//\$\{PLUGIN_ROOT\}/$WROOT}"
    env -u MMRY_CONFIG_FILE -u MMRY_CODEX_HOOK_STARTED -u MMRY_CODEX_HOOK_SECS -u MMRY_CODEX_HOOK_DATE \
        CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$tmp" HOME="$(cygpath -w "$HOME")" \
        pwsh -NoProfile -File "$counter" -CommandLine "cmd.exe /d /s /c \"${c#cmd /d /c } < \"$wpay\" > \"$(cygpath -w "$out")\" 2> \"$(cygpath -w "$err")\"\"" \
        < /dev/null 2>/dev/null | tr -d '\r' | sed -n 's/.*PROCESSES=\([0-9]*\) EXIT=\([0-9]*\).*/\1 \2/p' | tail -1
}
# cmd's own date, and the seconds of the day now, as the launcher computes them.
_cmd_date() { cmd //d //c "echo %DATE%" | tr -d '\r'; }
_sod_now() {
    local h m s; printf -v h '%(%H)T' -1; printf -v m '%(%M)T' -1; printf -v s '%(%S)T' -1
    echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}
# Stop-check inside its quiet time by its own reckoning: a marker stamped now, with its time beside it.
_sc_quiet_marker() {
    local now; printf -v now '%(%s)T' -1
    printf '%s\n' "$now" > "$TMPDIR/.mmry-stop-checked.at"
    : > "$TMPDIR/.mmry-stop-checked"
}

@test "33967 quiet windows: the launcher ends stop-check in cmd only when the record shows its quiet time, and otherwise runs it" {
    _is_windows || skip "Windows only: needs cmd.exe and a Windows job object"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    _install_codex_copy
    local sod; sod="$(_sod_now)"
    (( sod > 1000 && sod < 86400 - 1000 )) || skip "too near midnight for a same-day record"
    local date; date="$(_cmd_date)"
    [[ -n "$date" ]] || { echo "premise: cmd gave no %DATE%"; return 1; }
    local wtmp; wtmp="$(cygpath -w "$TMPDIR")"
    local got rc n fails="" name rec
    # name | record ("" for none) | marker (1 or 0) | expect: cmd (ends in cmd) or run (stop-check ran)
    local -a cases=(
        "fresh, 5 s old|$(printf '%05d %s' $(( sod - 5 )) "$date")|1|cmd"
        "875 s old, inside the 880 s the launcher allows|$(printf '%05d %s' $(( sod - 875 )) "$date")|1|cmd"
        "885 s old, past the 880 s the launcher allows|$(printf '%05d %s' $(( sod - 885 )) "$date")|1|run"
        "from the future (a clock set back)|$(printf '%05d %s' $(( sod + 60 )) "$date")|1|run"
        "another day's date|$(printf '%05d %s' $(( sod - 5 )) "Mon 01/01/2001")|1|run"
        "no marker beside it|$(printf '%05d %s' $(( sod - 5 )) "$date")|0|run"
        "no record|NONE|1|run"
        "an empty record||1|run"
        "letters for seconds|abcde ${date}|1|run"
        "no space after the seconds|$(printf '%05d' $(( sod - 5 )))${date}|1|run"
        "four digits|$(printf '%04d' $(( (sod - 5) % 10000 ))) ${date}|1|run"
        "a quote and an ampersand|1\"2&3 ${date}|1|run"
        "percent signs|%PATH% ${date}|1|run"
        "bangs|!CD!! ${date}|1|run"
        "carets|^^^^^ ${date}|1|run"
    )
    local c
    for c in "${cases[@]}"; do
        IFS='|' read -r name rec n want <<< "$c"
        rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at" "$TMPDIR/.mmry-stop-checked.cmd" "$TMPDIR"/.mmry-renewal-turn-*
        (( n == 1 )) && _sc_quiet_marker
        [[ "$rec" == NONE ]] || printf '%s' "$rec" > "$TMPDIR/.mmry-stop-checked.cmd"
        read -r got rc < <(_sc_count "$wtmp" "$TEST_TMPDIR/q.out" "$TEST_TMPDIR/q.err")
        echo "$(printf '%-48s' "$name") ${got} process(es), exit ${rc}" >&3
        [[ "$got" =~ ^[0-9]+$ ]] || { fails="${fails} [${name}: the counter did not answer]"; continue; }
        (( rc == 0 )) || fails="${fails} [${name}: exit ${rc}: $(head -c 200 "$TEST_TMPDIR/q.err")]"
        [[ ! -s "$TEST_TMPDIR/q.err" ]] || fails="${fails} [${name}: cmd wrote an error: $(head -c 200 "$TEST_TMPDIR/q.err")]"
        if [[ "$want" == cmd ]]; then
            (( got == 1 )) || fails="${fails} [${name}: stop-check ran (${got} processes), cmd should have ended it]"
            [[ ! -s "$TEST_TMPDIR/q.out" ]] || fails="${fails} [${name}: said something: $(head -c 120 "$TEST_TMPDIR/q.out")]"
        else
            (( got > 1 )) || fails="${fails} [${name}: ended in cmd, stop-check should have run]"
        fi
        if [[ "$name" == "no marker beside it" ]]; then
            [[ "$(_ctx "$TEST_TMPDIR/q.out")" == *"Save what is new since the last memory"* ]] || fails="${fails} [${name}: stop-check did not prompt]"
        fi
    done
    # A Formation renewal turn is stop-check's to spend, even inside the quiet time.
    rm -f "$TMPDIR/.mmry-stop-checked.cmd"; _sc_quiet_marker
    printf '%05d %s' $(( sod - 5 )) "$date" > "$TMPDIR/.mmry-stop-checked.cmd"
    printf '%s\n' "$(date +%s)" > "$TMPDIR/.mmry-renewal-turn-${SID}"
    read -r got rc < <(_sc_count "$wtmp" "$TEST_TMPDIR/q.out" "$TEST_TMPDIR/q.err")
    echo "$(printf '%-48s' "a renewal-turn marker waiting") ${got} process(es), exit ${rc}" >&3
    (( got > 1 )) || fails="${fails} [renewal turn: ended in cmd, stop-check should have spent the marker]"
    [[ ! -e "$TMPDIR/.mmry-renewal-turn-${SID}" ]] || fails="${fails} [renewal turn: the marker was not spent]"
    # A TMPDIR the launcher cannot read as a Windows path (Git Bash's own form) is never trusted.
    rm -f "$TMPDIR"/.mmry-renewal-turn-*; _sc_quiet_marker
    printf '%05d %s' $(( sod - 5 )) "$date" > "$TMPDIR/.mmry-stop-checked.cmd"
    read -r got rc < <(_sc_count "$TMPDIR" "$TEST_TMPDIR/q.out" "$TEST_TMPDIR/q.err")
    echo "$(printf '%-48s' "TMPDIR in Git Bash's form ($TMPDIR)") ${got} process(es), exit ${rc}" >&3
    (( got > 1 )) || fails="${fails} [POSIX TMPDIR: ended in cmd]"
    [[ -z "$fails" ]] || { echo "wrong:$fails"; return 1; }
}

@test "33967 quiet windows: the launcher's quiet time is stop-check's, less the 20 s a late stop-check could still run" {
    local launcher="$PLUGIN_ROOT/hooks-handlers/codex-hook.cmd" handler="$PLUGIN_ROOT/hooks-handlers/stop-check.sh" deb cmdq
    deb="$(sed -n 's/^DEBOUNCE_SECONDS=\([0-9]*\).*/\1/p' "$handler")"
    cmdq="$(tr -d '\r' < "$launcher" | sed -n 's/^if !MMRY_SQ_AGE! geq \([0-9]*\) goto :stop_check_loud$/\1/p')"
    echo "stop-check quiet time ${deb} s, the launcher's ${cmdq} s" >&3
    [[ "$deb" =~ ^[0-9]+$ && "$cmdq" =~ ^[0-9]+$ ]] || { echo "could not read both: [$deb] [$cmdq]"; return 1; }
    (( cmdq + 20 == deb )) || { echo "the launcher's quiet time (${cmdq} s) is not stop-check's (${deb} s) less 20 s"; return 1; }
    local limit; limit="$(_registered UserPromptSubmit stop-check timeout)"
    (( limit <= 20 )) || { echo "stop-check's limit (${limit} s) is longer than the 20 s held in hand"; return 1; }
}

@test "33967 quiet: stop-check writes the launcher's record only from the values the launcher handed it" {
    local f="$TMPDIR/.mmry-stop-checked.cmd"
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at" "$f"
    MMRY_CODEX_HOOK_SECS=00731 MMRY_CODEX_HOOK_DATE="Wed 11/18/2026" _codex_fire "stop-check" "" "$TEST_TMPDIR/a.json"
    [[ "$(_ctx "$TEST_TMPDIR/a.json")" == *"Save what is new since the last memory"* ]] || { echo "premise: stop-check did not prompt"; return 1; }
    [[ "$(cat "$f" 2>/dev/null)" == "00731 Wed 11/18/2026" ]] || { echo "record: [$(cat "$f" 2>/dev/null)]"; return 1; }
    # Not handed over (Claude Code, the sh form): the old record is emptied, never left to vouch for a new stamp.
    local bad
    for bad in "" "86400" "12a" "123456"; do
        rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at"
        printf '00731 Wed 11/18/2026' > "$f"
        MMRY_CODEX_HOOK_SECS="$bad" MMRY_CODEX_HOOK_DATE="Wed 11/18/2026" _codex_fire "stop-check" "" "$TEST_TMPDIR/b.json"
        [[ -f "$TMPDIR/.mmry-stop-checked" ]] || { echo "premise: [$bad] stop-check did not stamp"; return 1; }
        [[ ! -s "$f" ]] || { echo "seconds [$bad]: the record was left as [$(cat "$f")]"; return 1; }
    done
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at"
    printf '00731 Wed 11/18/2026' > "$f"
    MMRY_CODEX_HOOK_SECS=00731 MMRY_CODEX_HOOK_DATE="" _codex_fire "stop-check" "" "$TEST_TMPDIR/c.json"
    [[ ! -s "$f" ]] || { echo "no date: the record was left as [$(cat "$f")]"; return 1; }
    # Claude Code's stop-check, run directly, empties it too, and still prompts its own way.
    printf '00731 Wed 11/18/2026' > "$f"
    rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at"
    run env -u MMRY_HOST -u MMRY_CODEX_HOOK_SECS -u MMRY_CODEX_HOOK_DATE bash "$PLUGIN_ROOT/hooks-handlers/stop-check.sh" < /dev/null
    (( status == 2 )) || { echo "Claude Code stop-check exited $status"; return 1; }
    [[ ! -s "$f" ]] || { echo "Claude Code: the record was left as [$(cat "$f")]"; return 1; }
}

@test "33967 quiet: codex-hook.sh runs stop-check in its own shell, not a subshell, and still discards its exit code" {
    local root="$TEST_TMPDIR/sc root" out
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$root/"
    printf '#!/usr/bin/env bash\nset -euo pipefail\necho "SUBSHELL=${BASH_SUBSHELL}"\nexit 7\n' > "$root/hooks-handlers/stop-check.sh"
    out="$(_payload | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$CODEX_DIR" bash "$root/hooks-handlers/codex-hook.sh" stop-check 2>/dev/null)"; local rc=$?
    echo "exit 7: codex-hook.sh exit ${rc}, ${out}" >&3
    (( rc == 0 )) || { echo "a stop-check exit 7 came out as $rc"; return 1; }
    [[ "$out" == "SUBSHELL=0" ]] || { echo "stop-check did not run in codex-hook.sh's own shell: $out"; return 1; }
    printf '#!/usr/bin/env bash\nset -euo pipefail\necho before\nfalse\necho after\n' > "$root/hooks-handlers/stop-check.sh"
    out="$(_payload | env -u MMRY_CONFIG_FILE -u MMRY_HOST CODEX_HOME="$CODEX_DIR" bash "$root/hooks-handlers/codex-hook.sh" stop-check 2>/dev/null)"; rc=$?
    echo "set -e failure: codex-hook.sh exit ${rc}, ${out//$'\n'/ }" >&3
    (( rc == 0 )) || { echo "a stop-check set -e failure came out as $rc"; return 1; }
    [[ "$out" == "before" ]] || { echo "stop-check's own set -e did not hold: $out"; return 1; }
}
