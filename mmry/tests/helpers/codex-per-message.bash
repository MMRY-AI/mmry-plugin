# codex-per-message.bash - helpers shared by structural/codex-per-message-in-time.bats and
# structural/codex-stop-check-in-cmd.bats (#33967). Moved unchanged from the first when the round 5 tests
# took it past the 64000 bytes bats can gather on Windows (structural/test-file-size.bats). Load it after
# test-helper and foundation-set: setup() reads fnd_set_file.

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

# The plugin as Codex installs it, in a private Codex home; sets WROOT.
_install_codex_copy() {
    local root="$CODEX_DIR/plugins/cache/mmry-plugin/mmry/local"
    mkdir -p "$root"
    ( cd "$PLUGIN_ROOT" && tar -cf - --exclude=./tests . ) | ( cd "$root" && tar -xf - )
    WROOT="$(cygpath -w "$root")"
}

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
        -OutDir "$(cygpath -w "$dir")" < /dev/null 2>"$dir/err" | tr -d '\r' > "$dir/times"
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

# The real launcher for stop-check, as Codex's PowerShell runs it, counted by a job object. $1 the TMPDIR
# the hook sees, $2 the stdout file, $3 the stderr file. Echoes "<processes> <exit code>".
_sc_count() {
    local tmp="$1" out="$2" err="$3" pre="" counter wpay c
    # $4: a TMPDIR set inside cmd itself. Git Bash makes any TMPDIR it passes on absolute.
    [[ -n "${4:-}" ]] && pre="set \"TMPDIR=$4\" & "
    counter="$(cygpath -w "${BATS_TEST_DIRNAME}/../helpers/count-processes.ps1")"
    _payload > "$TEST_TMPDIR/payload.json"
    wpay="$(cygpath -w "$TEST_TMPDIR/payload.json")"
    c="$(_registered UserPromptSubmit stop-check commandWindows)"
    c="${c//\$\{PLUGIN_ROOT\}/$WROOT}"
    env -u MMRY_CONFIG_FILE -u MMRY_CODEX_HOOK_STARTED -u MMRY_CODEX_HOOK_SECS -u MMRY_CODEX_HOOK_DATE \
        CODEX_HOME="$(cygpath -w "$CODEX_DIR")" TMPDIR="$tmp" HOME="$(cygpath -w "$HOME")" \
        pwsh -NoProfile -File "$counter" -CommandLine "cmd.exe /d /s /c \"${pre}${c#cmd /d /c } < \"$wpay\" > \"$(cygpath -w "$out")\" 2> \"$(cygpath -w "$err")\"\"" \
        < /dev/null 2>/dev/null | tr -d '\r' | sed -n 's/.*PROCESSES=\([0-9]*\) EXIT=\([0-9]*\).*/\1 \2/p' | tail -1
}
# cmd's own date, and the seconds of the day now, as the launcher computes them.
_cmd_date() { cmd //d //c "echo %DATE%" | tr -d '\r'; }
_sod_now() {
    local h m s; printf -v h '%(%H)T' -1; printf -v m '%(%M)T' -1; printf -v s '%(%S)T' -1
    echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}
