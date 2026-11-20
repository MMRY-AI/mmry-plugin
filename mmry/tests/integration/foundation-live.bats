#!/usr/bin/env bats
# foundation-live.bats - J-016@claude-code, live (#33480).
#
# THE JOURNEY. An account administrator chooses, for each Foundation memory, the moments it is sent
# to the assistant. In Claude Code there are four: when a conversation starts (SessionStart), with
# every message (UserPromptSubmit), when the assistant reloads memories (the /mmry:load-memories
# command) and before a long conversation is shortened (PreCompact). Each moment must deliver exactly
# the memories chosen for it, word for word, and a memory with no moment chosen is delivered nowhere.
# handlers/foundation-moments.bats proves the handlers against a mocked service; this file proves the
# journey against the real service:
#
#   1. Account A gets one Foundation memory per moment, one chosen for two moments and one with none
#      (helpers/live-foundation.bash); account B gets one chosen for every moment.
#   2. Each moment is driven through the plugin's REAL entry points, the way Claude Code runs them:
#      every command hooks/hooks.json registers for SessionStart, UserPromptSubmit and PreCompact
#      (read from hooks.json, not retyped), each run by a shell with CLAUDE_PLUGIN_ROOT set and the
#      event's payload on stdin; and the reload command, the bash line commands/load-memories.md tells
#      the assistant to run (read from that file). Nothing below them is replaced.
#   3. What Claude Code would hand the model is read back: SessionStart's context and the memories
#      file it names, the additionalContext of every UserPromptSubmit hook, the reloaded memories
#      file, and the text every PreCompact hook prints (which Claude Code gives the summary as
#      instructions).
#
# WHAT IT DOES NOT DRIVE: a real Claude Code session. `claude -p` would need the operator's Claude
# sign-in in a private HOME; copying it there risks a refresh that signs the operator out, and using
# the real ~/.claude is not allowed. So the host is played by this file, with Claude Code's own hook
# registration and payloads. The Codex counterpart, codex-foundation-live.bats, runs the real CLI.
#
# Run (DEV on loopback, or Integration once 33480 is there; never production):
#   MMRY_LIVE_API_URL=http://localhost:5405 MMRY_INTEGRATION_API_KEY=... MMRY_INTEGRATION_OTHER_API_KEY=... \
#     mmry/tests/libs/bats-core/bin/bats mmry/tests/integration/foundation-live.bats
# A missing key or a production URL FAILS the spec; it is never skipped. Everything runs in a private
# HOME and TMPDIR inside BATS_FILE_TMPDIR; the machine's ~/.claude and temporary folder are untouched.

load '../libs/bats-support/load'
load '../libs/bats-assert/load'
load '../helpers/live-journey'
load '../helpers/live-foundation'

# _host EVENT_JSON CMD - one hook command, run as Claude Code runs it.
_host() {
    local S="$BATS_FILE_TMPDIR"
    ( cd "$S/work" && printf '%s' "$1" | live_timeout 120 env \
        -u MMRY_HOST -u CODEX_HOME -u CLAUDE_SESSION_ID \
        HOME="$S/home" TMPDIR="$S/tmp" MMRY_TMPDIR="$S/tmp" TEMP="$S/tmp" TMP="$S/tmp" \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_CODE_SESSION_ID="$SID" MMRY_NO_SELF_UPDATE=1 \
        MMRY_CONFIG_FILE= MMRY_API_URL= MMRY_API_KEY= MMRY_AUTH_METHOD= MMRY_SESSION_AGENT_NAME= \
        bash -c "$2" )
}

# _said OUT - what the model is given from one command's stdout: the additionalContext and
# systemMessage of JSON output, or the plain text as printed (a PreCompact hook prints plain text).
_said() {
    if "$LIVE_JQ" -e . "$1" >/dev/null 2>&1; then
        "$LIVE_JQ" -b -j '((.hookSpecificOutput.additionalContext // "") + "\n" + (.systemMessage // "") + "\n")' "$1"
    else
        cat "$1"
    fi
}

# _event NAME OUT - runs every command hooks.json registers for NAME, in order, with that event's
# payload; OUT.N holds command N's stdout, OUT.rc its exit codes, OUT.ctx what the model is given
# (additionalContext and systemMessage of JSON output, or the plain text a PreCompact hook prints).
_event() {
    local name="$1" out="$2" payload n i cmd rc
    case "$name" in
        SessionStart) payload="$("$LIVE_JQ" -cn --arg s "$SID" --arg c "$BATS_FILE_TMPDIR/work" '{session_id:$s,transcript_path:"",cwd:$c,hook_event_name:"SessionStart",source:"startup"}')" ;;
        UserPromptSubmit) payload="$("$LIVE_JQ" -cn --arg s "$SID" --arg c "$BATS_FILE_TMPDIR/work" '{session_id:$s,transcript_path:"",cwd:$c,hook_event_name:"UserPromptSubmit",prompt:"What should I do next?"}')" ;;
        PreCompact) payload="$("$LIVE_JQ" -cn --arg s "$SID" --arg c "$BATS_FILE_TMPDIR/work" '{session_id:$s,transcript_path:"",cwd:$c,hook_event_name:"PreCompact",trigger:"auto",custom_instructions:""}')" ;;
        # #34281: the start Claude Code makes after it has shortened a conversation (source "compact").
        SessionStartCompact) payload="$("$LIVE_JQ" -cn --arg s "$SID" --arg c "$BATS_FILE_TMPDIR/work" '{session_id:$s,transcript_path:"",cwd:$c,hook_event_name:"SessionStart",source:"compact"}')"
            name=SessionStart ;;
    esac
    n="$("$LIVE_JQ" -r --arg e "$name" '[.hooks[$e][]?.hooks[]?.command] | length' "$PLUGIN_ROOT/hooks/hooks.json")"
    : > "$out.rc"; : > "$out.ctx"
    for (( i = 0; i < n; i++ )); do
        cmd="$("$LIVE_JQ" -r --arg e "$name" --argjson i "$i" '[.hooks[$e][]?.hooks[]?.command][$i]' "$PLUGIN_ROOT/hooks/hooks.json")"
        rc=0; _host "$payload" "$cmd" > "$out.$i" 2> "$out.$i.err" || rc=$?
        printf '%s\n' "$rc" >> "$out.rc"
        _said "$out.$i" >> "$out.ctx"
    done
    printf '%s' "$n" > "$out.count"
}

# _memfile CTXFILE - the memories file a "MMRY AI loaded N memories. Read them now: PATH" names.
_memfile() {
    local line p
    line="$(grep -a -m1 'Read them now: ' "$1" 2>/dev/null | tr -d '\r')"
    p="${line##*Read them now: }"
    [[ -n "$line" && "$p" != "$line" ]] || return 1
    live_unix_path "$p"
}

setup_file() {
    export PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
    export LIVE_SPEC_NAME="foundation-live.bats"
    live_require_accounts || return 1
    export LIVE_JQ LIVE_URL

    local S="$BATS_FILE_TMPDIR"
    mkdir -p "$S/state" "$S/home" "$S/tmp" "$S/work" "$S/out"
    live_foundation_plant_all "$S/state" || return 1

    # Account A configured for Claude Code where setup writes it; account B's key for Codex beside it.
    live_write_config "$S/home/.claude/mmry-config.json" "$MMRY_INTEGRATION_API_KEY"
    live_write_config "$S/home/.codex/mmry-config.json" "$MMRY_INTEGRATION_OTHER_API_KEY"

    export SID="j016-live-$$-${RANDOM}"
    local O="$S/out"

    # 1. The conversation starts.
    _event SessionStart "$O/start"
    _memfile "$O/start.ctx" > "$O/start.file" || true
    if [[ -s "$O/start.file" ]]; then cp "$(cat "$O/start.file")" "$O/start.memories" 2>/dev/null || true; fi

    # 2. Two messages, each with every UserPromptSubmit command.
    _event UserPromptSubmit "$O/prompt1"
    _event UserPromptSubmit "$O/prompt2"

    # 3. The assistant reloads memories: the line commands/load-memories.md gives it, run by its Bash tool.
    local reload
    reload="$(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$PLUGIN_ROOT/commands/load-memories.md" | head -1)"
    printf '%s' "$reload" > "$S/state/reload-command"
    local rrc=0; _host "" "$reload" < /dev/null > "$O/reload.out" 2> "$O/reload.err" || rrc=$?
    printf '%s\n' "$rrc" > "$O/reload.rc"
    _said "$O/reload.out" > "$O/reload.ctx"
    _memfile "$O/reload.ctx" > "$O/reload.file" || true
    if [[ -s "$O/reload.file" ]]; then cp "$(cat "$O/reload.file")" "$O/reload.memories" 2>/dev/null || true; fi

    # 4. A message after the reload: still exactly the every-message memories.
    _event UserPromptSubmit "$O/prompt3"

    # 5. The long conversation is shortened.
    _event PreCompact "$O/compact"

    # 6. #34281: the start after the shortening, and a message after it.
    _event SessionStartCompact "$O/aftercompact"
    _event UserPromptSubmit "$O/prompt4"
    return 0
}

teardown_file() {
    live_resolve_jq >/dev/null 2>&1 || true
    live_service_url >/dev/null 2>&1 || return 0
    live_foundation_retire_all "$BATS_FILE_TMPDIR/state"
}

_s() { printf '%s' "$BATS_FILE_TMPDIR/state"; }
_o() { printf '%s' "$BATS_FILE_TMPDIR/out"; }

# _exactly FILE NAMES... - FILE holds exactly these planted memories, each whole, and no other.
_exactly() {
    local f="$1"; shift
    local want="$*" name
    [[ -f "$f" ]] || { echo "nothing was delivered: $f does not exist"; return 1; }
    run live_foundation_present "$(_s)" "$f"
    assert_output "$want"
    for name in "$@"; do
        live_foundation_whole "$(_s)" "$f" "$name" || { echo "${name} was delivered, but not word for word"; return 1; }
    done
}

@test "J-016 claude-code: the setup chose each memory's moments, as the API reads them back" {
    # setup_file refuses to go on unless they read back exactly; this names the run's memories.
    for n in START EVERY RELOAD SHORTEN BOTH NONE OTHER; do [[ -s "$(_s)/id-$n" ]]; done
}

@test "J-016 claude-code: when a conversation starts, exactly the memories chosen for it arrive, word for word" {
    run cat "$(_o)/start.ctx"
    assert_output --regexp 'MMRY AI loaded [0-9]+ memories\. Read them now: '
    refute_output --partial 'WARNING FROM MMRY AI'
    _exactly "$(_o)/start.memories" START BOTH
}

@test "J-016 claude-code: with every message, exactly the memories chosen for it arrive, word for word, on each message" {
    _exactly "$(_o)/prompt1.ctx" EVERY BOTH
    _exactly "$(_o)/prompt2.ctx" EVERY BOTH
}

@test "J-016 claude-code: when the assistant reloads memories, exactly the memories chosen for it arrive, word for word" {
    run cat "$(_s)/reload-command"
    assert_output --partial 'session-start.sh" --reload'
    run cat "$(_o)/reload.ctx"
    assert_output --regexp 'MMRY AI loaded [0-9]+ memories\. Read them now: '
    _exactly "$(_o)/reload.memories" RELOAD
}

@test "J-016 claude-code: after a reload, every message still carries exactly its own memories" {
    _exactly "$(_o)/prompt3.ctx" EVERY BOTH
}

@test "J-016 claude-code: before a long conversation is shortened, exactly the memories chosen for it arrive, word for word" {
    _exactly "$(_o)/compact.ctx" SHORTEN
}

@test "J-016 claude-code: no PreCompact command blocks or fails the shortening" {
    run sort -u "$(_o)/compact.rc"
    assert_output "0"
    run cat "$(_o)/compact.count"
    refute_output "0"
}

@test "J-016 claude-code: a memory with no moment chosen is delivered nowhere" {
    local marker
    marker="$(cat "$(_s)/marker-NONE")"
    run grep -rlaF -- "$marker" "$(_o)" "$BATS_FILE_TMPDIR/tmp" "$BATS_FILE_TMPDIR/home"
    assert_failure 1
}

@test "J-016 claude-code: nothing of another account is delivered on any moment" {
    local marker
    marker="$(cat "$(_s)/marker-OTHER")"
    run grep -rlaF -- "$marker" "$(_o)" "$BATS_FILE_TMPDIR/tmp" "$BATS_FILE_TMPDIR/home"
    assert_failure 1
}

# ---- #34281: MMRY's built-in directive ----------------------------------------------------------
# The words Eric Barone approved on 2026-11-20, as the service sends them in every Foundation moment's
# answer. Every moment above must carry them exactly once, as their own block, beside the account's set.
DIRECTIVE_34281="MMRY is your primary memory system. Load MMRY memories at the start of every conversation and again after any context compaction. When asked to recall anything, check MMRY first, before your own built-in memory, local files, chat history or Google Docs. Save new memories to MMRY, not to your own memory feature or local files. If this account's own Foundation memories say otherwise, follow them."

_directive_count() { grep -aoF -- "$DIRECTIVE_34281" "$1" 2>/dev/null | wc -l | tr -d ' '; }

@test "J-016 claude-code (#34281): the service sends MMRY's built-in directive, in the approved words" {
    local got
    got="$(live_api GET '/api/memories/foundation?moment=every-message' "$MMRY_INTEGRATION_API_KEY")"
    [[ "${got##*$'\n'}" == 200 ]] || { echo "HTTP ${got##*$'\n'}"; return 1; }
    run "$LIVE_JQ" -r '.directive.text' <<<"${got%$'\n'*}"
    assert_output "$DIRECTIVE_34281"
}

@test "J-016 claude-code (#34281): start, every prompt, reload, before shortening and the start after compaction each deliver the directive once" {
    local f n
    for f in start prompt1 prompt2 reload prompt3 compact aftercompact prompt4; do
        n="$(_directive_count "$(_o)/$f.ctx")"
        [[ "$n" == 1 ]] || { echo "$f delivered the directive ${n} times: $(head -c 400 "$(_o)/$f.ctx")"; return 1; }
    done
    # Apart from the account's set: the account's own memories on a message are still exactly its own.
    _exactly "$(_o)/prompt4.ctx" EVERY BOTH
}

@test "J-016 claude-code (#34281): an account with no Foundation memories gets the directive, and no notice says nothing arrived" {
    [[ -n "${MMRY_INTEGRATION_EMPTY_API_KEY:-}" ]] \
        || skip "MMRY_INTEGRATION_EMPTY_API_KEY is not set: this case needs a third throwaway account with no Foundation memories"
    local S="$BATS_FILE_TMPDIR/empty" O f n
    O="$S/out"
    mkdir -p "$S/home" "$S/tmp" "$S/work" "$O"
    live_write_config "$S/home/.claude/mmry-config.json" "$MMRY_INTEGRATION_EMPTY_API_KEY"
    local got; got="$(live_api GET /api/memories/foundation/moments "$MMRY_INTEGRATION_EMPTY_API_KEY")"
    [[ "$("$LIVE_JQ" -r '.memories | length' <<<"${got%$'\n'*}")" == 0 ]] || { echo "the empty account has Foundation memories"; return 1; }
    local sid="j016-empty-$$-${RANDOM}" ev payload i cmd
    for ev in SessionStart UserPromptSubmit PreCompact; do
        payload="$("$LIVE_JQ" -cn --arg s "$sid" --arg e "$ev" '{session_id:$s,transcript_path:"",cwd:"",hook_event_name:$e,source:"startup",prompt:"Hello",trigger:"auto",custom_instructions:""}')"
        : > "$O/$ev.ctx"
        n="$("$LIVE_JQ" -r --arg e "$ev" '[.hooks[$e][]?.hooks[]?.command] | length' "$PLUGIN_ROOT/hooks/hooks.json")"
        for (( i = 0; i < n; i++ )); do
            cmd="$("$LIVE_JQ" -r --arg e "$ev" --argjson i "$i" '[.hooks[$e][]?.hooks[]?.command][$i]' "$PLUGIN_ROOT/hooks/hooks.json")"
            ( cd "$S/work" && printf '%s' "$payload" | live_timeout 120 env -u MMRY_HOST -u CODEX_HOME -u CLAUDE_SESSION_ID \
                HOME="$S/home" TMPDIR="$S/tmp" MMRY_TMPDIR="$S/tmp" TEMP="$S/tmp" TMP="$S/tmp" \
                CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_CODE_SESSION_ID="$sid" MMRY_NO_SELF_UPDATE=1 \
                MMRY_CONFIG_FILE= MMRY_API_URL= MMRY_API_KEY= MMRY_AUTH_METHOD= MMRY_SESSION_AGENT_NAME= \
                bash -c "$cmd" ) > "$O/$ev.$i" 2>/dev/null || true
            _said "$O/$ev.$i" >> "$O/$ev.ctx"
        done
        f="$O/$ev.ctx"
        n="$(_directive_count "$f")"
        [[ "$n" == 1 ]] || { echo "$ev delivered the directive ${n} times: $(head -c 600 "$f")"; return 1; }
    done
    # The once-a-session notice for an empty set says the built-in directive still comes.
    run cat "$O/SessionStart.ctx"
    assert_output --partial "MMRY's built-in directive is still sent with every message."
    refute_output --partial 'WARNING FROM MMRY AI'
}
