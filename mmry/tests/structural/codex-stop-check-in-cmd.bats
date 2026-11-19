#!/usr/bin/env bats
# codex-stop-check-in-cmd.bats - on Codex for Windows, stop-check's prompt is said in cmd, at the floor
# (#33967 round 5). Split from codex-per-message-in-time.bats, which holds rounds 1 to 4, under the 64000
# bytes bats can gather on Windows; the helpers both use are in helpers/codex-per-message.bash.

load '../helpers/test-helper'
load '../helpers/foundation-set'
load '../helpers/codex-per-message'

# =============================================================================================
# ROUND 5: STOP-CHECK'S PROMPT IS SAID IN CMD TOO
# =============================================================================================
# The round 4 live measurement (Codex 0.169.0, a load of 496 ms per process start): on the first message
# stop-check failed at its 10 s limit while formation-check, which ends in cmd, took 9.5 s. The quiet path
# was at that floor; the prompting path was the floor plus Git's bash. So codex-hook.cmd now says the
# prompt itself, with builtins only, whenever it can be sure what stop-check would say, and leaves the
# same files stop-check leaves. cmd has no clock in seconds since 1970, so codex-hook.sh, which every
# session start and every Foundation part runs through, leaves it one: .mmry-codex-clock.cmd, "SSSSS
# EEEEEEEEEE <%DATE%>", bash's seconds of the day and its epoch read at one instant, with cmd's own date.
# Anything cmd cannot be sure of goes on to stop-check as before.

R5_CLOCK=".mmry-codex-clock.cmd"

# A file's text, or nothing when it is not there (bats runs each test under set -e).
_r5_cat() { [[ -f "$1" ]] && cat "$1" || true; }
_r5_trim() { [[ -f "$1" ]] && tr -d ' \r\n' < "$1" || true; }

# A launch that reaches codex-hook.sh, as every session start does, through the real launcher. $1 the
# TMPDIR it sees (Windows form). The handler name has no handler file, so nothing else runs.
_r5_launch() {
    env -u MMRY_CONFIG_FILE -u MMRY_CODEX_HOOK_STARTED -u MMRY_CODEX_HOOK_SECS -u MMRY_CODEX_HOOK_DATE -u MMRY_HOOK_LAUNCH_SECS \
        CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$1" HOME="$(cygpath -w "$HOME")" \
        cmd //d //c "${WROOT}\\hooks-handlers\\codex-hook.cmd" r5-session-start < /dev/null > /dev/null 2>&1
}
# stop-check through codex-hook.sh in bash, as before round 5, handed what the launcher hands it. $1 its
# TMPDIR (POSIX form), $2 the stdout file.
_r5_bash() {
    _payload | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_CODEX_HOOK_STARTED -u MMRY_HOOK_LAUNCH_SECS \
        CODEX_HOME="$CODEX_DIR" TMPDIR="$1" MMRY_CODEX_HOOK_SECS="$(_sod_now)" MMRY_CODEX_HOOK_DATE="$R5_DATE" \
        bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" stop-check > "$2" 2>/dev/null
}
# A marker stamped $2 seconds ago in $1, with its time and the launcher's record, as stop-check leaves it.
_r5_marker() {
    local d="$1" e s; printf -v e '%(%s)T' -1; s="$(_sod_now)"
    printf '%s\n' "$(( e - $2 ))" > "$d/.mmry-stop-checked.at"
    : > "$d/.mmry-stop-checked"
    printf '%05d %s' "$(( s - $2 ))" "$R5_DATE" > "$d/.mmry-stop-checked.cmd"
}
# The state stop-check reads, written into $1 for case $2. Times are relative to now.
_r5_state() {
    local d="$1" e s; printf -v e '%(%s)T' -1; s="$(_sod_now)"
    rm -f "$d/.mmry-stop-checked" "$d/.mmry-stop-checked.at" "$d/.mmry-stop-checked.cmd" "$d/.mmry-stop-count" "$d/.mmry-last-save" "$d"/.mmry-renewal-turn-*
    case "$2" in
        fresh) ;;
        "saved 30 s ago") printf '%s\n' "$(( e - 30 ))" > "$d/.mmry-last-save" ;;
        "saved 125 minutes ago") printf '%s\n' "$(( e - 7530 ))" > "$d/.mmry-last-save" ;;
        "a save stamped 10 minutes ahead") printf '%s\n' "$(( e + 600 ))" > "$d/.mmry-last-save" ;;
        "the third firing without a save") printf '2\n' > "$d/.mmry-stop-count" ;;
        "a count written with spaces and CRLF") printf ' 7 \r\n' > "$d/.mmry-stop-count" ;;
        "past its quiet time") _r5_marker "$d" 950; printf '4\n' > "$d/.mmry-stop-count" ;;
        "past its quiet time, saved before it") _r5_marker "$d" 950; printf '%s\n' "$(( e - 2000 ))" > "$d/.mmry-last-save" ;;
        "past its quiet time, saved since") _r5_marker "$d" 950; printf '%s\n' "$(( e - 100 ))" > "$d/.mmry-last-save"; printf '5\n' > "$d/.mmry-stop-count" ;;
        "stamped yesterday")
            printf '%s\n' "$(( e - 86400 ))" > "$d/.mmry-stop-checked.at"; : > "$d/.mmry-stop-checked"
            printf '%05d %s' "$s" "Mon 01/01/2001" > "$d/.mmry-stop-checked.cmd" ;;
        # Fallbacks: cmd cannot be sure, so stop-check runs.
        "a renewal turn waiting") printf '%s\n' "$e" > "$d/.mmry-renewal-turn-${SID}" ;;
        "a count that is not a number") printf 'x7\n' > "$d/.mmry-stop-count" ;;
        "a count with a leading zero") printf '07\n' > "$d/.mmry-stop-count" ;;
        "a last save that is not a number") printf 'abc\n' > "$d/.mmry-last-save" ;;
        "a last save of 11 digits") printf '17950674310\n' > "$d/.mmry-last-save" ;;
        # Not the 10 digits stop-check's files hold, so not cmd's to read, though cmd could sum it.
        "a last save of 9 digits") printf '179506743\n' > "$d/.mmry-last-save" ;;
        "a marker with no time beside it") _r5_marker "$d" 950; rm -f "$d/.mmry-stop-checked.at" ;;
        "a marker with an empty record") _r5_marker "$d" 950; : > "$d/.mmry-stop-checked.cmd" ;;
        # 800 s by the marker's own time, 950 by the launcher's record: round 4's record check lets it through
        # (950 is past 880), and the marker's time keeps it stop-check's (under 900), with 100 s to spare
        # for a loaded machine. stop-check, reading the marker's time, stays quiet.
        "a marker 800 s old by its time") _r5_marker "$d" 950; printf '%s\n' "$(( e - 800 ))" > "$d/.mmry-stop-checked.at"; : > "$d/.mmry-stop-checked" ;;
        "a count of two lines") printf '2\n5\n' > "$d/.mmry-stop-count" ;;
        "a marker stamped 5 minutes ahead") _r5_marker "$d" -300 ;;
        *) echo "no state [$2]"; return 1 ;;
    esac
}
# Compare the two runs' outputs and files. $1 the case, $2 the cmd TMPDIR, $3 the bash TMPDIR, $4 cmd's
# stdout, $5 bash's stdout. Appends to R5_FAILS.
_r5_same() {
    local name="$1" a="$2" b="$3" ca cb x y
    ca="$(_r5_cat "$4")"; cb="$(_r5_cat "$5")"
    [[ "$ca" == "$cb" ]] || R5_FAILS="${R5_FAILS} [${name}: said [${ca:0:160}], stop-check says [${cb:0:160}]]"
    x=""; [[ -e "$a/.mmry-stop-checked" ]] && x=y
    y=""; [[ -e "$b/.mmry-stop-checked" ]] && y=y
    [[ "$x" == "$y" ]] || R5_FAILS="${R5_FAILS} [${name}: the marker differs ([$x], stop-check's [$y])]"
    x="$(_r5_trim "$a/.mmry-stop-count")"; y="$(_r5_trim "$b/.mmry-stop-count")"
    [[ "$x" == "$y" ]] || R5_FAILS="${R5_FAILS} [${name}: count [$x], stop-check's [$y]]"
    x="$(_r5_trim "$a/.mmry-stop-checked.at")"; y="$(_r5_trim "$b/.mmry-stop-checked.at")"
    if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
        (( x - y <= 5 && y - x <= 5 )) || R5_FAILS="${R5_FAILS} [${name}: marker time $x, stop-check's $y]"
    else
        [[ "$x" == "$y" ]] || R5_FAILS="${R5_FAILS} [${name}: marker time [$x], stop-check's [$y]]"
    fi
    x="$(_r5_cat "$a/.mmry-stop-checked.cmd")"; y="$(_r5_cat "$b/.mmry-stop-checked.cmd")"
    if [[ "$x" =~ ^([0-9]{5})\ (.*)$ ]]; then
        local xs="${BASH_REMATCH[1]}" xd="${BASH_REMATCH[2]}"
        [[ "$y" =~ ^([0-9]{5})\ (.*)$ ]] && [[ "$xd" == "${BASH_REMATCH[2]}" ]] && (( 10#$xs - 10#${BASH_REMATCH[1]} <= 5 && 10#${BASH_REMATCH[1]} - 10#$xs <= 5 )) \
            || R5_FAILS="${R5_FAILS} [${name}: record [$x], stop-check's [$y]]"
    else
        [[ "$x" == "$y" ]] || R5_FAILS="${R5_FAILS} [${name}: record [$x], stop-check's [$y]]"
    fi
}
_r5_setup() {
    _is_windows || skip "Windows only: needs cmd.exe and a Windows job object"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    _needs_launch_clock
    local sod; sod="$(_sod_now)"
    (( sod > 2200 && sod < 86400 - 1000 )) || skip "too near midnight for same-day stamps"
    R5_DATE="$(_cmd_date)"
    [[ -n "$R5_DATE" ]] || { echo "premise: cmd gave no %DATE%"; return 1; }
    _install_codex_copy
    R5_A="$TEST_TMPDIR/r5cmd"; R5_B="$TEST_TMPDIR/r5bash"; mkdir -p "$R5_A" "$R5_B"
    R5_WA="$(cygpath -w "$R5_A")"
    R5_FAILS=""
}

@test "33967 r5 budget windows: stop-check's prompt is said by cmd alone, after a session start, word for word and with the files stop-check leaves" {
    _r5_setup
    _r5_launch "$R5_WA"
    local clock; clock="$(_r5_cat "$R5_A/$R5_CLOCK")"
    echo "the clock a launch leaves: [${clock}]" >&3
    [[ -n "$clock" ]] || R5_FAILS="${R5_FAILS} [a launch through codex-hook.sh left cmd no clock]"
    local c got rc
    for c in "fresh" "saved 30 s ago" "saved 125 minutes ago" "a save stamped 10 minutes ahead" "the third firing without a save" \
        "a count written with spaces and CRLF" "past its quiet time" "past its quiet time, saved before it" \
        "past its quiet time, saved since" "stamped yesterday"; do
        _r5_state "$R5_A" "$c"; _r5_state "$R5_B" "$c"
        read -r got rc < <(_sc_count "$R5_WA" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5a.err")
        _r5_bash "$R5_B" "$TEST_TMPDIR/r5b.out"
        echo "$(printf '%-44s' "$c") ${got} process(es), exit ${rc}, $( [[ -s "$TEST_TMPDIR/r5a.out" ]] && echo "a save prompt" || echo silent)" >&3
        [[ "$got" =~ ^[0-9]+$ ]] || { R5_FAILS="${R5_FAILS} [${c}: the counter did not answer]"; continue; }
        (( got == 1 )) || R5_FAILS="${R5_FAILS} [${c}: ${got} processes, not cmd alone]"
        (( rc == 0 )) || R5_FAILS="${R5_FAILS} [${c}: exit ${rc}]"
        [[ ! -s "$TEST_TMPDIR/r5a.err" ]] || R5_FAILS="${R5_FAILS} [${c}: wrote an error: $(head -c 160 "$TEST_TMPDIR/r5a.err")]"
        # The premise: stop-check itself prompts in every case but "saved since", where it is silent.
        if [[ "$c" == "past its quiet time, saved since" ]]; then
            [[ ! -s "$TEST_TMPDIR/r5b.out" ]] || R5_FAILS="${R5_FAILS} [premise ${c}: stop-check spoke]"
        else
            [[ "$(_ctx "$TEST_TMPDIR/r5b.out")" == *"Save what is new since the last memory"* ]] || R5_FAILS="${R5_FAILS} [premise ${c}: stop-check did not prompt]"
        fi
        _r5_same "$c" "$R5_A" "$R5_B" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5b.out"
    done
    [[ -z "$R5_FAILS" ]] || { echo "wrong:$R5_FAILS"; return 1; }
}

@test "33967 r5 windows: where cmd cannot be sure, stop-check runs as before, and its launch leaves cmd the clock" {
    _r5_setup
    local c got rc
    # No clock at all: the launch to stop-check leaves one, so the next message can be answered in cmd.
    _r5_state "$R5_A" fresh; _r5_state "$R5_B" fresh; rm -f "$R5_A/$R5_CLOCK"
    read -r got rc < <(_sc_count "$R5_WA" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5a.err")
    _r5_bash "$R5_B" "$TEST_TMPDIR/r5b.out"
    echo "$(printf '%-44s' "no clock yet") ${got} process(es), exit ${rc}" >&3
    (( got > 1 )) || R5_FAILS="${R5_FAILS} [no clock: answered in cmd]"
    _r5_same "no clock" "$R5_A" "$R5_B" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5b.out"
    [[ -s "$R5_A/$R5_CLOCK" ]] || R5_FAILS="${R5_FAILS} [no clock: stop-check's launch left none]"
    # A clock cmd must not trust: another day's, one ahead of now, one that is not digits, a short or
    # too large epoch.
    local s e; s="$(_sod_now)"; printf -v e '%(%s)T' -1
    local -a clocks=(
        "another day's clock|$(printf '%05d %s %s' "$s" "$e" "Mon 01/01/2001")"
        "a clock 10 minutes ahead|$(printf '%05d %s %s' "$(( s + 600 ))" "$(( e + 600 ))" "$R5_DATE")"
        "a clock in letters|$(printf 'abcde %s %s' "$e" "$R5_DATE")"
        "a clock with a short epoch|$(printf '%05d %s %s' "$s" "123456789" "$R5_DATE")"
        "a clock past 2147483647|$(printf '%05d %s %s' "$s" "2200000000" "$R5_DATE")"
    )
    local k name val
    for k in "${clocks[@]}"; do
        IFS='|' read -r name val <<< "$k"
        _r5_state "$R5_A" fresh; _r5_state "$R5_B" fresh
        printf '%s' "$val" > "$R5_A/$R5_CLOCK"
        read -r got rc < <(_sc_count "$R5_WA" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5a.err")
        _r5_bash "$R5_B" "$TEST_TMPDIR/r5b.out"
        echo "$(printf '%-44s' "$name") ${got} process(es), exit ${rc}" >&3
        [[ "$got" =~ ^[0-9]+$ ]] || { R5_FAILS="${R5_FAILS} [${name}: the counter did not answer]"; continue; }
        (( got > 1 )) || R5_FAILS="${R5_FAILS} [${name}: answered in cmd]"
        (( rc == 0 )) || R5_FAILS="${R5_FAILS} [${name}: exit ${rc}]"
        _r5_same "$name" "$R5_A" "$R5_B" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5b.out"
    done
    # A good clock, and a state cmd must leave to stop-check.
    for c in "a renewal turn waiting" "a count that is not a number" "a count with a leading zero" "a last save that is not a number" \
        "a last save of 11 digits" "a last save of 9 digits" "a marker with no time beside it" "a marker with an empty record" "a marker 800 s old by its time" \
        "a marker stamped 5 minutes ahead" "a count of two lines"; do
        rm -f "$R5_A/$R5_CLOCK"; _r5_launch "$R5_WA"
        _r5_state "$R5_A" "$c"; _r5_state "$R5_B" "$c"
        read -r got rc < <(_sc_count "$R5_WA" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5a.err")
        _r5_bash "$R5_B" "$TEST_TMPDIR/r5b.out"
        echo "$(printf '%-44s' "$c") ${got} process(es), exit ${rc}, $( [[ -s "$TEST_TMPDIR/r5a.out" ]] && echo "a save prompt" || echo silent)" >&3
        [[ "$got" =~ ^[0-9]+$ ]] || { R5_FAILS="${R5_FAILS} [${c}: the counter did not answer]"; continue; }
        (( got > 1 )) || R5_FAILS="${R5_FAILS} [${c}: answered in cmd]"
        (( rc == 0 )) || R5_FAILS="${R5_FAILS} [${c}: exit ${rc}]"
        if [[ "$c" == "a renewal turn waiting" ]]; then
            [[ ! -e "$R5_A/.mmry-renewal-turn-${SID}" ]] || R5_FAILS="${R5_FAILS} [${c}: the marker was not spent]"
        fi
        _r5_same "$c" "$R5_A" "$R5_B" "$TEST_TMPDIR/r5a.out" "$TEST_TMPDIR/r5b.out"
    done
    [[ -z "$R5_FAILS" ]] || { echo "wrong:$R5_FAILS"; return 1; }
}

@test "33967 r5 windows: a stop-check that ended early is said on the next message, from cmd" {
    _r5_setup
    _r5_launch "$R5_WA"
    _r5_state "$R5_A" fresh
    # A launch that used 8 of the 10 s (round 1's R2): stop-check ends at once, says nothing, touches nothing.
    _payload | env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_CODEX_HOOK_SECS -u MMRY_CODEX_HOOK_DATE CODEX_HOME="$CODEX_DIR" TMPDIR="$R5_A" \
        MMRY_CODEX_HOOK_STARTED="$(_stamp_ago 8)" bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" stop-check > "$TEST_TMPDIR/early.out" 2>/dev/null
    [[ ! -s "$TEST_TMPDIR/early.out" ]] || { echo "premise: the late stop-check spoke: $(cat "$TEST_TMPDIR/early.out")"; return 1; }
    [[ ! -e "$R5_A/.mmry-stop-checked" ]] || { echo "premise: the late stop-check stamped its marker"; return 1; }
    local got rc
    read -r got rc < <(_sc_count "$R5_WA" "$TEST_TMPDIR/next.out" "$TEST_TMPDIR/next.err")
    echo "the next message: ${got} process(es), exit ${rc}, $(head -c 80 "$TEST_TMPDIR/next.out")" >&3
    [[ "$(_ctx "$TEST_TMPDIR/next.out")" == *"Save what is new since the last memory"*"anything not saved can be lost when the conversation is trimmed."* ]] \
        || { echo "the next message did not say the whole prompt: $(cat "$TEST_TMPDIR/next.out")"; return 1; }
    (( got == 1 )) || { echo "the next message ran stop-check (${got} processes), cmd should have said it"; return 1; }
    [[ -e "$R5_A/.mmry-stop-checked" ]] || { echo "the prompt was said but the marker not stamped"; return 1; }
}

_r5_fire() {
    env -u MMRY_CONFIG_FILE -u MMRY_HOST -u MMRY_CODEX_HOOK_STARTED -u MMRY_CODEX_HOOK_SECS -u MMRY_CODEX_HOOK_DATE CODEX_HOME="$CODEX_DIR" "$@" \
        bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" r5-session-start < /dev/null > /dev/null 2>&1
}

@test "33967 r5: codex-hook.sh leaves the launcher a clock only from the values the launcher handed it" {
    _needs_launch_clock
    local f="$TMPDIR/$R5_CLOCK" s e out
    s="$(_sod_now)"
    (( s > 200 && s < 86400 - 200 )) || skip "too near midnight"
    rm -f "$f"
    _r5_fire MMRY_CODEX_HOOK_SECS="$(( s - 3 ))" MMRY_CODEX_HOOK_DATE="Wed 11/18/2026"
    out="$(_r5_cat "$f")"; printf -v e '%(%s)T' -1
    echo "clock: [$out] at epoch $e, seconds of the day $(_sod_now)" >&3
    [[ "$out" =~ ^([0-9]{5})\ ([0-9]{10})\ Wed\ 11/18/2026$ ]] || { echo "clock: [$out]"; return 1; }
    local cs="${BASH_REMATCH[1]}" ce="${BASH_REMATCH[2]}"
    # Read at one instant: its seconds of the day and its epoch move together.
    (( 10#$cs >= s && 10#$cs <= s + 5 )) || { echo "its seconds of the day ${cs}, expected ${s} to $(( s + 5 ))"; return 1; }
    (( e - ce >= 0 && e - ce <= 5 )) || { echo "its epoch ${ce}, now ${e}"; return 1; }
    # Within a minute of a clock of the same date it is not written again (fewer writes for cmd to race).
    printf '%05d %s %s' "$(( s - 30 ))" "1700000000" "Wed 11/18/2026" > "$f"
    _r5_fire MMRY_CODEX_HOOK_SECS="$s" MMRY_CODEX_HOOK_DATE="Wed 11/18/2026"
    [[ "$(_r5_cat "$f")" == "$(printf '%05d %s %s' "$(( s - 30 ))" "1700000000" "Wed 11/18/2026")" ]] || { echo "rewritten within the minute: [$(_r5_cat "$f")]"; return 1; }
    # Another date's clock is replaced at once.
    _r5_fire MMRY_CODEX_HOOK_SECS="$s" MMRY_CODEX_HOOK_DATE="Thu 11/19/2026"
    [[ "$(_r5_cat "$f")" == *" Thu 11/19/2026" ]] || { echo "another date's clock kept: [$(_r5_cat "$f")]"; return 1; }
    # Nothing handed, or nothing usable: no clock is written.
    local bad
    for bad in "unset" "" "86400" "12a" "123456" "midnight"; do
        rm -f "$f"
        case "$bad" in
            unset) _r5_fire MMRY_CODEX_HOOK_DATE="Wed 11/18/2026" ;;
            # cmd's stamp later in the day than bash's: midnight passed between them, so the date is not today's.
            midnight) _r5_fire MMRY_CODEX_HOOK_SECS="$(( s + 100 ))" MMRY_CODEX_HOOK_DATE="Wed 11/18/2026" ;;
            *) _r5_fire MMRY_CODEX_HOOK_SECS="$bad" MMRY_CODEX_HOOK_DATE="Wed 11/18/2026" ;;
        esac
        [[ ! -e "$f" ]] || { echo "seconds [$bad]: a clock was written: [$(cat "$f")]"; return 1; }
    done
    rm -f "$f"; _r5_fire MMRY_CODEX_HOOK_SECS="$s" MMRY_CODEX_HOOK_DATE=""
    [[ ! -e "$f" ]] || { echo "no date: a clock was written"; return 1; }
    rm -f "$f"; _r5_fire MMRY_CODEX_HOOK_SECS="$s" MMRY_CODEX_HOOK_DATE=$'Wed\r11/18'
    [[ ! -e "$f" ]] || { echo "a date with a CR: a clock was written"; return 1; }
}

# OPT-IN (MMRY_TEST_LOAD=1), like round 4's load test, at the reduced load of the round 4 live
# measurement: 450 to 550 ms per process start (MMRY_TEST_LOAD_LOW and _HIGH move it). After a session
# start (a launch that leaves the clock), each round is two messages, the nine hooks at once each: a
# prompting one with no marker, as the first message of a fresh home, then a quiet one.
# It fails if stop-check takes its limit or more, exits non-zero, or says anything but a whole prompt.
# It also measures stop-check against the floor of the same message (formation-check, which ends in
# cmd) and fails if, over the prompting rounds, the median of stop-check less formation-check is over
# R5_FLOOR_MARGIN_MS: at the live reduced load the floor was 9.5 s of the 10, so a prompt that costs
# more than the floor plus a few hundred ms crosses the limit there. This harness's floor is lower than
# Codex's (5 to 6 s at this load against 9.5 s), so the 10 s line alone does not separate the heads.
R5_FLOOR_MARGIN_MS="${MMRY_TEST_R5_MARGIN_MS:-250}"
R5_ROUNDS="${MMRY_TEST_R5_ROUNDS:-5}"

@test "33967 r5 load windows: at the reduced load, stop-check's prompting and quiet paths end inside 10 s, at the floor" {
    _is_windows || skip "Windows only: Codex's PowerShell launch, on a loaded Windows machine"
    [[ "${MMRY_TEST_LOAD:-}" == 1 ]] || skip "opt-in (MMRY_TEST_LOAD=1): it loads this machine for several minutes"
    command -v pwsh >/dev/null 2>&1 || skip "no pwsh"
    command -v powershell.exe >/dev/null 2>&1 || skip "no powershell.exe"
    LOAD_LOW="${MMRY_TEST_LOAD_LOW:-450}"; LOAD_HIGH="${MMRY_TEST_LOAD_HIGH:-550}"
    local limit; limit="$(_registered UserPromptSubmit stop-check timeout)"
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "no stop-check limit: $limit"; return 1; }
    _install_codex_copy
    _payload > "$TEST_TMPDIR/payload.json"
    MMRY_TEST_LOAD_WORKERS="${MMRY_TEST_LOAD_WORKERS:-4}" _load_calibrate || { echo "premise: the load did not settle at ${LOAD_LOW} to ${LOAD_HIGH} ms per process start (last ${LOAD_MS} ms)"; return 1; }
    local before="$LOAD_MS" r over="" bad="" deltas=() fc
    _r5_launch "$(cygpath -w "$TMPDIR")"
    for (( r = 1; r <= R5_ROUNDS; r++ )); do
        rm -f "$TMPDIR/.mmry-stop-checked" "$TMPDIR/.mmry-stop-checked.at" "$TMPDIR/.mmry-stop-checked.cmd"
        _group "prompt$r"
        [[ "$SC_MS" =~ ^[0-9]+$ ]] || { echo "the group helper did not report stop-check: $(cat "$TEST_TMPDIR/group-prompt$r/times") $(head -c 400 "$TEST_TMPDIR/group-prompt$r/err" 2>/dev/null)"; return 1; }
        (( SC_MS < limit * 1000 )) || over="${over} [prompting $r: ${SC_MS} ms]"
        (( SC_RC == 0 )) || bad="${bad} [prompting $r exited ${SC_RC}]"
        if [[ -s "$SC_OUT" ]]; then
            [[ "$(_ctx "$SC_OUT")" == *"Save what is new since the last memory"*"when the conversation is trimmed."* ]] || bad="${bad} [prompting $r: not a whole save prompt: $(head -c 120 "$SC_OUT")]"
        else
            bad="${bad} [prompting $r: silent, the first message of a fresh home must prompt]"
        fi
        fc="$(sed -n 's/^formation-check|\([0-9]*\)|.*/\1/p' "$TEST_TMPDIR/group-prompt$r/times" | head -1)"
        [[ "$fc" =~ ^[0-9]+$ ]] && deltas+=( $(( SC_MS - fc )) )
        _group "quiet$r"
        [[ "$SC_MS" =~ ^[0-9]+$ ]] || { echo "the group helper did not report stop-check: $(cat "$TEST_TMPDIR/group-quiet$r/times") $(head -c 400 "$TEST_TMPDIR/group-quiet$r/err" 2>/dev/null)"; return 1; }
        (( SC_MS < limit * 1000 )) || over="${over} [quiet $r: ${SC_MS} ms]"
        (( SC_RC == 0 )) || bad="${bad} [quiet $r exited ${SC_RC}]"
        [[ ! -s "$SC_OUT" ]] || bad="${bad} [quiet $r prompted inside the quiet time]"
    done
    LOAD_MS="$(_load_sample)"
    local med; med="$(printf '%s\n' "${deltas[@]}" | sort -n | sed -n "$(( (${#deltas[@]} + 1) / 2 ))p")"
    echo "load: median ${before} ms per process start before, ${LOAD_MS} ms after" >&3
    echo "prompting rounds, stop-check less formation-check (ms): ${deltas[*]}; median ${med} (margin ${R5_FLOOR_MARGIN_MS})" >&3
    [[ -z "$bad" ]] || { echo "stop-check misbehaved:$bad"; return 1; }
    [[ -z "$over" ]] || { echo "stop-check took ${limit} s or more, its limit:$over"; return 1; }
    (( ${#deltas[@]} == R5_ROUNDS )) || { echo "formation-check was not reported in every round"; return 1; }
    (( med <= R5_FLOOR_MARGIN_MS )) || { echo "the prompting path is ${med} ms over the floor (median), more than ${R5_FLOOR_MARGIN_MS}"; return 1; }
}
