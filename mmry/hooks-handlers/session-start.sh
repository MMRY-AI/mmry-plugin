#!/usr/bin/env bash
# SessionStart hook: loads memories from MMRY AI API via curl.
# Outputs hook JSON with path to temp file containing loaded memories.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# #31245: which assistant this session belongs to. Unset MMRY_HOST means Claude Code, so every
# value below is the one this file already used.
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/lib-host.sh"

# WHAT A SESSION WITH NO CREDENTIAL IS TOLD. Defined here, ahead of the client, because on Codex
# this message has to be delivered WITHOUT sourcing the client at all (#31245 QA round 2): an
# unconfigured Codex install used to resolve ${HOME}/.claude/mmry-config.json and run under the
# other product's account, and lib-jq.sh now refuses rather than allow that. Refusing would have
# cost the customer this message - the one that tells them how to fix it - so it is emitted from
# here instead. On Claude Code the text is identical to what this file has always printed.
_mmry_emit_setup_message() {
    local help_line setup_msg escaped
    # #31245: the setup command, the product to restart and the way to get help all differ by host.
    # A Codex customer told to type /mmry:help is being told to do something this platform does not
    # let them do - it converts plugin commands into skills and there is nothing to type.
    if [[ "$(mmry_host)" == "codex" ]]; then
        help_line='Tell them they can ask "what can MMRY do here" any time; there are no slash commands to type on this platform.'
    else
        help_line='Mention /mmry:help for a quick reference.'
    fi

    # ON WINDOWS CODEX, THE COMMAND ABOVE CANNOT BE RUN AS WRITTEN (#31245 QA round 9). Codex runs
    # the model's commands in PowerShell, where a bare `bash` is the Linux subsystem's and fails with
    # execvpe(/bin/bash). QA's evidence shows a session improvising its way round it; the message
    # now gives the working form, the same one the Codex skill teaches. The block is read with a
    # quoted heredoc so that its $, quotes, backslash and backtick reach the model untouched.
    local win_block=""
    if [[ "$(mmry_host)" == "codex" ]]; then
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*)
                IFS= read -r -d '' win_block <<'PS' || true

On Windows, do NOT type bash at the PowerShell prompt; it is the Linux subsystem's and fails. Run this whole block as one command instead, which hands the same setup script to Git Bash:

$c = @'
bash "${CODEX_HOME:-$HOME/.codex}/mmry/setup/mmry-setup.sh"
'@; $f = Join-Path $env:TEMP "mmry-$PID.sh"; [IO.File]::WriteAllText($f, $c.Replace("`r", "")); & (Join-Path (Split-Path (Split-Path (Split-Path (git --exec-path)))) 'bin\bash.exe') $f; Remove-Item $f
PS
                win_block="${win_block%$'\n'}"
                ;;
        esac
    fi
    setup_msg="MMRY AI is installed but needs to be set up. Run the setup script to authenticate via the browser.

## Setup

Run this command using the Bash tool:

$(mmry_host_setup_hint)${win_block}

This will open a browser window where the user can log in or create an account on mmryai.com. Once they authorize, the script writes the config file and permissions automatically.

If the browser does not open, the script prints a URL the user can copy and paste.

After setup completes, tell the user: \"You are all set. Restart $(mmry_host_label) and your memories will start loading automatically.\" ${help_line}

If the user does not have an account yet, direct them to https://mmryai.com to sign up first, then run setup again."

    # Escaped by parameter expansion, NOT sed (#31245 QA round 10, found on the Mac bench). The
    # sed ':a;N;$!ba' that joined lines here is GNU sed only: BSD sed on macOS rejects the label,
    # exits 0 anyway and passes the text through, so every new Mac user with no credential got a
    # setup message with raw newlines inside the JSON string, which the host rejects. The same idiom
    # was fixed for the fault note further down; this one was missed. _mmry_json_escape cannot be
    # called here because on Codex this runs BEFORE mmry-client.sh is sourced (deliberately, see
    # the credential check below), so the same expansions are written out. Output is byte-identical
    # wherever GNU sed worked, since the message holds no tab or carriage return.
    escaped="$setup_msg"
    escaped="${escaped//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//$'\n'/\\n}"
    escaped="${escaped//$'\r'/\\r}"
    escaped="${escaped//$'\t'/\\t}"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$escaped"
}

# THIS HOST HAS NO CREDENTIAL: say how to get one, and do not source the client. Sourcing it is
# what would reach for another product's account, and lib-jq.sh exits rather than do that.
if ! mmry_host_assert_own_credential 2>/dev/null; then
    _mmry_emit_setup_message
    exit 0
fi

# Self-update check — runs before anything else, debounced to once per hour
bash "${PLUGIN_ROOT}/hooks-handlers/self-update.sh" 2>/dev/null || true

source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# jq is required and bundled by setup. If none is usable (unsupported platform
# or a broken install), fail fast with a clear message rather than stalling on a
# slow fallback (#30624 absorbs #30319).
if [[ -z "${MMRY_JQ:-}" ]]; then
    mmry_jq_unavailable_message
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI could not find a usable jq on this machine, so memories were not loaded. Ask the user to re-run setup to restore the bundled jq: %s"}}' "$(mmry_host_setup_hint)"
    exit 0
fi

WORK_DIR="$PWD"

# Bug #9 (Intervals #29949): read session_id from the SessionStart hook stdin
# payload (always present per the Claude Code hook spec). The CLAUDE_SESSION_ID
# env var is not reliably exported across hook and Bash-tool environments, so
# we treat stdin as the canonical source. The fallback chain ends at "unknown"
# only when the script is invoked outside a hook context (e.g., manual tests).
#
# #31385: the read used to be `timeout 2 cat`. GNU `timeout` is absent from a stock macOS (and the
# Homebrew coreutils build names it `gtimeout`), so on a Mac that line ran a command that does not
# exist, `2>/dev/null || true` swallowed exit 127, and the payload came back empty. The session id
# then fell through to CLAUDE_SESSION_ID and finally to the literal "unknown", and that is the id
# this session was REGISTERED UNDER below - an entry against this workspace carrying no real
# identifier. lib-hookread.sh reads it with the `read -t` builtin instead, which needs nothing
# installed and works on the bash 3.2 macOS ships.
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/lib-hookread.sh"

HOOK_PAYLOAD='{}'
HOOK_READ_STATUS="notty"
if [[ ! -t 0 ]]; then
    mmry_read_hook_payload "${MMRY_HOOK_READ_TIMEOUT:-2}" || true
    HOOK_READ_STATUS="${MMRY_HOOK_READ_STATUS:-empty}"
    HOOK_PAYLOAD="${MMRY_HOOK_PAYLOAD:-}"
    [[ -z "$HOOK_PAYLOAD" ]] && HOOK_PAYLOAD='{}'
fi

# AN EMPTY READ MUST SAY SO (#31385). The defect was not only the missing binary: it was that a
# payload which came back empty was indistinguishable from a hook that legitimately had nothing to
# say, so a total failure looked healthy from every angle. This handler is the one place in the
# plugin that always has a channel to the model, so it is where the fault gets stated. Anything
# formation-check.sh recorded while it was obliged to stay silent is picked up here too.
MMRY_HOOK_FAULT_NOTE=""
if [[ "$HOOK_READ_STATUS" == "empty" || "$HOOK_READ_STATUS" == "timeout" ]]; then
    mmry_note_hook_read_fault "session-start" "$HOOK_READ_STATUS" || true
    # The host is named rather than assumed. Telling a Codex customer that "the Claude Code hook
    # payload" failed sends them looking for a product they are not running (#31245). The report
    # route differs too: there is no /mmry:feedback to type on Codex.
    if [[ "$(mmry_host)" == "codex" ]]; then
        _mmry_report_hint="ask them to report it by saying so - the memory system's feedback script will be used"
    else
        _mmry_report_hint="ask them to report it with /mmry:feedback"
    fi
    MMRY_HOOK_FAULT_NOTE="WARNING FROM MMRY AI: the $(mmry_host_label) hook payload could not be read from stdin (${HOOK_READ_STATUS}), so this session could not learn its own session id and coordination features will not work correctly. Tell the user, and ${_mmry_report_hint}. "
fi

# stdin may not be JSON outside a hook context; jq returns empty and we fall
# back to the env vars, then "unknown". This is a data fallback, not a jq one.
# CLAUDE_CODE_SESSION_ID is what the Bash tool sets: /mmry:load-memories runs this script there with
# no payload, and its Foundation marker must be filed under the real session (#31597 QA round 3, R3).
SESSION_ID="$(printf '%s' "$HOOK_PAYLOAD" | "$MMRY_JQ" -r '.session_id // empty' 2>/dev/null || true)"

# AND IF THE PAYLOAD ARRIVED BUT DID NOT CARRY session_id, SAY SO (#31245 QA round 2).
#
# "session_id" is CLAUDE CODE's field name. It is an assumption about Codex, not a fact: no
# captured Codex hook payload exists yet, and every Codex delivery test in this suite bypasses the
# question by setting MMRY_FORMATION_MODE, a variable whose own comment says it exists for the test
# suite. If Codex names the field differently, registration silently degrades to the literal
# "unknown" and formation delivery silently does nothing - installed, quiet, useless.
#
# So a payload that arrived and parsed but does not contain the field is reported through the one
# channel this handler has. The KEYS are named and no value is printed: a hook payload can carry a
# prompt or a tool result, and this note goes to the model verbatim.
if [[ -z "$SESSION_ID" && "$HOOK_READ_STATUS" == "ok" ]]; then
    _mmry_keys="$(printf '%s' "$HOOK_PAYLOAD" | "$MMRY_JQ" -r 'if type=="object" then (keys | join(", ")) else "not a JSON object" end' 2>/dev/null || true)"
    mmry_note_hook_read_fault "session-start-session-id-absent" "${_mmry_keys:-unparsable}" || true
    MMRY_HOOK_FAULT_NOTE="${MMRY_HOOK_FAULT_NOTE}WARNING FROM MMRY AI: the $(mmry_host_label) hook payload was read successfully but carried no 'session_id' field (fields present: ${_mmry_keys:-none - it did not parse as JSON}). MMRY assumes the Claude Code payload field names; this session is being registered without a real id, so coordination features will not work. Tell the user and ask them to report it. "
fi

# LEFTOVER FORMATION MEMBERSHIPS (#31844). Other sessions' records that are stale, unwatched, and
# that the service says are no longer members are removed here; the rule, its bounds and why a
# genuine member is never removed are in formation-state.sh. ONLY WITH THE PAYLOAD'S OWN ID (QA
# round 2, D1): the id that protects this session's own record must be this session's, so the
# environment fallback below is deliberately not used, and a start without a payload id sweeps
# nothing. Before the memory load, whose failure paths exit early. In-process and best-effort.
if [[ -n "$SESSION_ID" && -f "${PLUGIN_ROOT}/hooks-handlers/formation-state.sh" ]]; then
    { source "${PLUGIN_ROOT}/hooks-handlers/formation-state.sh" 2>/dev/null \
        && mmry_formation_sweep "$SESSION_ID"; } 2>/dev/null || true
fi

SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}}"

# THE AGENT THIS SESSION RUNS AS (#30320). Claude Code puts agent_type in the SessionStart payload
# when the session was started with `claude --agent <name>`. Saves are made by save-memory.sh in a
# Bash tool shell, which never sees this payload, so the name is handed over through
# CLAUDE_ENV_FILE, which Claude Code sources before each Bash tool command. Only from a payload
# that was actually read: /mmry:load-memories runs this script with no payload, and treating that
# as "no agent" would clear the name the real SessionStart recorded.
if [[ "$HOOK_READ_STATUS" == "ok" ]]; then
    _mmry_agent_type="$(printf '%s' "$HOOK_PAYLOAD" | "$MMRY_JQ" -r '.agent_type // empty' 2>/dev/null || true)"
    mmry_record_session_agent "$_mmry_agent_type" || true
fi

# SESSION-SCOPE THE FOUNDATION DELIVERY RECORD (#31583 QA round 4, finding 4c).
#
# The per-prompt hook records each verified delivery so it can tell two states apart that
# look identical on disk: a session that has never had its directives built, which has lost
# nothing and must stay silent, and a session that HAD them and finds them gone, which must
# say so. The record lived at a fixed name in the shared temp directory and nothing ever
# cleared it, so its presence meant "some session on this machine once delivered", not "this
# session did". A brand new session whose fetch failed - offline, API down, expired key - on a
# machine an earlier session had used was therefore told, on every prompt, that its directives
# had disappeared, when nothing had been delivered and so nothing had disappeared. Reviewers
# reproduced it at 932 characters a prompt, indefinitely.
#
# The record now carries the id of the session that wrote it, and this is the only place that
# id is known: it comes off the hook payload above. The per-prompt hook cannot read stdin
# cheaply enough to ask on every prompt, so it reads this file instead, which costs one
# redirect and no process.
#
# UNCONDITIONAL AND EARLY, before any fetch, because the failure being closed is precisely a
# session whose fetch did not happen. A clear that only ran on success would leave the exact
# case it exists for untouched.
#
# WHAT THIS DOES NOT FIX, stated rather than implied, and CORRECTED (#31583 QA round 5): the
# token is one file in a shared temp directory, so it means "the most recent SessionStart in this
# temp directory", not "this session". Two concurrent sessions overwrite each other's token, and
# that errs in BOTH directions. The older session stops recognising its own record, which turns a
# true disappearance into silence. And a delivery by session A is stamped with session B's token,
# so B can be told "Last sent: 1 second ago" having sent nothing; three reviewers reproduced that
# one. An earlier version of this comment claimed only the first, safer direction could happen.
# Real per-session scoping needs the per-prompt hook to know its own session id, which it does
# not today; that is its own piece of work.
printf '%s' "$SESSION_ID" > "${MMRY_TMPDIR}/mmry-foundation.session" 2>/dev/null || true
rm -f "${MMRY_TMPDIR}/mmry-foundation.status" 2>/dev/null || true
# Records named by session id (#31583 QA round 6) are never cleared by the session that wrote them,
# because it cannot know it has ended. They are a few dozen bytes each; anything a week old is from
# a session that is over. find -mtime and -delete behave the same on GNU and BSD find.
# The per-prompt hook's prepared set, claim, result and cut-short markers (#31893) are one each per
# session (a claim also leaves one small file per change of the set), and go the same way.
find "${MMRY_TMPDIR}" -maxdepth 1 -type f \( -name 'mmry-foundation.status.*' -o -name 'mmry-foundation.outcome.*' -o -name 'mmry-foundation.stored.*' -o -name 'mmry-foundation.byref.*' -o -name '.mmry-foundation-byref-told.*' -o -name '.mmry-foundation-empty-told.*' -o -name '.mmry-foundation-inflight.*' -o -name '.mmry-foundation-prepared.*' -o -name '.mmry-foundation-claim.*' -o -name '.mmry-foundation-result.*' -o -name '.mmry-foundation-cutshort*' \) -mtime +7 -delete 2>/dev/null || true

# NOTE: Bug #9 fix removed the /tmp/mmry-session-dir and
# /tmp/mmry-session-dir-${SESSION_ID} writes that previously lived here.
# Working directory is now persisted server-side via the /api/sessions POST
# below; save-memory.sh resolves it back from the API when needed.

# Check if config is loaded — guide unconfigured users to run setup
if [[ -z "${MMRY_API_KEY:-}" ]]; then
    _mmry_emit_setup_message
    exit 0
fi

MEM_FILE="${MMRY_TMPDIR}/mmry-memories.md"

# Load startup memories
if ! mmry_get_startup_memories "$WORK_DIR"; then
    if [[ "${MMRY_HTTP_CODE:-}" == "403" ]]; then
        # #31195: this used to state the expired trial as fact. A 403 says access was refused; it
        # does not say which of the things gating access is the one that fired, and telling a
        # subscriber whose payment lapsed that their free trial has ended points them at a trial
        # they finished months ago. The trial is still named first because it is the most common
        # cause and the message is more useful for saying so - it is just no longer the only
        # explanation on offer, and the assistant is told to let the user establish which it is.
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI refused the memory read (HTTP 403), which means this account is not currently entitled to it. The usual cause is an expired free trial; a lapsed or cancelled subscription does the same thing. Tell the user memories are unavailable for that reason, name both possibilities rather than asserting one, and point them at https://mmryai.com to check or restore their plan."}}'
        exit 0
    fi
    if [[ "${MMRY_HTTP_CODE:-}" == "402" ]]; then
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI credits exhausted. Inform the user their API credits have run out. Visit https://mmryai.com to add more credits or upgrade their plan."}}'
        exit 0
    fi
    if [[ "${MMRY_HTTP_CODE:-}" == "401" ]]; then
        # #30321: the stored credential is present but invalid or expired. Tell the assistant
        # so it warns the user, instead of falling through to the generic failure below.
        #
        # #31245 QA round 3: this was the last line in the file still naming a Claude Code slash
        # command unconditionally, three host-branched messages after the others were fixed. A
        # Codex customer told to run /mmry:setup is being told to type something this platform does
        # not give them - Codex converts plugin commands into skills and there is nothing to type -
        # so the fix that re-authenticates them is the one instruction they cannot follow.
        if [[ "$(mmry_host)" == "codex" ]]; then
            _mmry_reauth_hint="ask the assistant to run $(mmry_host_setup_hint)"
        else
            _mmry_reauth_hint="run /mmry:setup"
        fi
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI: the stored sign-in credential is invalid or expired. Tell the user that their memories may not be saved or loaded, and direct them to %s to re-authenticate."}}' "$_mmry_reauth_hint"
        exit 0
    fi
    escaped_err="$(echo "$MMRY_RESPONSE" | sed "s/\"/'/g" | sed 's/\\/\\\\/g')"
    printf '{"error":"session-start failed: %s"}' "$escaped_err"
    exit 0
fi

# Parse JSON response into markdown using the resolved jq (#30624).
{
    echo "# MMRY AI — Loaded Memories"
    echo ""
    "$MMRY_JQ" -r '.[] | to_entries | map(.key + ": " + (.value | tostring)) | join("\n"), "---"' <<<"$MMRY_RESPONSE"
} > "$MEM_FILE" 2>/dev/null

# Count memories
count="$(printf '%s' "$MMRY_RESPONSE" | "$MMRY_JQ" 'length' 2>/dev/null || echo 0)"

# Write the Foundation-only cache the UserPromptSubmit hook re-injects each turn (#30579).
# Presentation/framing is applied at inject time; this file holds just the data.
#
# GUARDED, AND REPORTED (#31411 QA). This call used to be bare, and the comment here used to
# say "Best-effort", which was true while mmry_write_foundation_cache ended in `|| true` and
# had no failing path. #31583 gave it six. This file runs under `set -euo pipefail` with no
# trap, so from that point a bare call meant any writer failure terminated the hook HERE,
# before it printed its JSON: the session then ran with no Foundation directives and nobody
# was told. That is precisely the failure this release exists to remove, arriving through the
# code written to remove it. The neighbouring mmry_register_session call was already guarded,
# so the difference sat in the same screenful.
#
# Two things are therefore true of the line below. It cannot kill the hook, and it cannot be
# silent. `if !` is exempt from errexit, and the fault note is the channel this file already
# uses to put a warning in front of the model before it decides anything about the turn.
#
# The session id goes to the writer, which on success leaves the evidence that a set was stored for
# this session, so a set deleted before its first delivery is reported as missing (#31597, and r2:
# the writer does it, so the per-prompt refresh does it too). See mmry_foundation_stored_path.
EMPTY_SYSMSG=""
if ! mmry_write_foundation_cache "$MMRY_RESPONSE" "$(mmry_foundation_set_path "$MMRY_TMPDIR")" "$SESSION_ID"; then
    # The remedy is the host's own (#31245 merged onto #31411): on Codex there is nothing to type,
    # so the assistant is told it can run the script itself, as the other Codex hints here do.
    if [[ "$(mmry_host)" == "codex" ]]; then
        _mmry_fnd_retry_hint="offer to run $(mmry_host_command_ref load-memories) to try again, or $(mmry_host_command_ref foundation-status) to check"
    else
        _mmry_fnd_retry_hint="ask them to run /mmry:load-memories to try again, or /mmry:foundation-status to check"
    fi
    MMRY_HOOK_FAULT_NOTE="${MMRY_HOOK_FAULT_NOTE}WARNING FROM MMRY AI: your Foundation directives could not be stored for this session, so they will NOT be applied on each prompt. Nothing partial was kept and nothing was guessed at. Tell the user, and ${_mmry_fnd_retry_hint}. "
elif [[ "${MMRY_FND_WRITTEN_ENTRIES:-}" == "0" ]]; then
    # AN EMPTY SET IS TOLD TO THE CUSTOMER, ONCE A SESSION (#31597 r2, TC4). systemMessage is the
    # channel the customer sees. The marker stops the per-prompt hook saying it again this session;
    # it is written in both the session-id form and the token form the hook falls back to.
    # shellcheck source=/dev/null
    source "${PLUGIN_ROOT}/hooks-handlers/lib-foundation-switch.sh"
    EMPTY_SYSMSG=",\"systemMessage\":\"$(_mmry_json_escape "$MMRY_FND_EMPTY_NOTICE")\""
    _fnd_esid="$(mmry_foundation_sid "$SESSION_ID")"
    _fnd_ekey="$(mmry_foundation_session_key "$MMRY_TMPDIR" "$SESSION_ID" || true)"
    [[ -n "$_fnd_esid" ]] && { printf '%s' "$_fnd_ekey" > "${MMRY_TMPDIR}/.mmry-foundation-empty-told.${_fnd_esid}" 2>/dev/null || true; }
    printf '%s' "$(mmry_foundation_session_token "$MMRY_TMPDIR" || true)" > "${MMRY_TMPDIR}/.mmry-foundation-empty-told" 2>/dev/null || true
fi

# Register session — uses session_id read from hook stdin (see top of file).
# WORK_DIR is persisted server-side here; subsequent save calls reference it
# via session_id rather than reading a (collidable) /tmp file.
# #31245: the client name is the host's, not a constant. A Codex session listed as "claude-code" is
# a session the customer cannot find in their own session list.
mmry_register_session "$SESSION_ID" "$(mmry_host_client_name)" "$WORK_DIR" "" 2>/dev/null || true

# Escape path for JSON.
#
# The path shown to the model is spelled for the MODEL's shell, not for this handler's. On Codex
# for Windows that shell is PowerShell and cannot resolve a POSIX path, so the one instruction
# attached to every memory load used to name a file the reader could not open. The file itself is
# still written to MEM_FILE; only the spelling in the message changes.
model_path="$(mmry_host_path_for_model "$MEM_FILE")"
escaped_path="$(printf '%s' "$model_path" | sed 's/\\/\\\\/g')"

# AND THE FAULT NOTE IS ESCAPED TOO, WHICH IT WAS NOT (#31245 QA round 4).
#
# MMRY_HOOK_FAULT_NOTE was interpolated into the JSON below raw. It is not a fixed string: it
# carries ${HOOK_READ_STATUS} and the list of field names found in the hook payload, both of
# which come from OUTSIDE this script. A payload whose keys contain a double quote or a
# backslash therefore produced invalid JSON, and a host discards an additionalContext it cannot
# parse - so the one message whose entire purpose is to report that something went wrong was
# silently dropped by the thing going wrong. The path beside it has been escaped since before
# this ticket; the note never was.
#
# Escaped in ONE place, so both emit sites below are covered by construction rather than by
# remembering to do it twice. With _mmry_json_escape from mmry-client.sh, sourced above, and NOT
# with sed (#31245 QA round 9): the first version joined lines with sed ':a;N;$!ba', which is GNU
# sed only. BSD sed on macOS rejects it, prints a warning on every session start, and leaves the
# newlines unescaped, so a multi-line note produced invalid JSON there and was discarded. That is
# what failed tests 415, 663, 739 and 741 on the macOS CI leg. Parameter expansion behaves the same
# on bash 3.2 and 5, with no external tool at all.
MMRY_HOOK_FAULT_NOTE="$(_mmry_json_escape "$MMRY_HOOK_FAULT_NOTE")"

# First-session onboarding: detect zero memories
# The fault note, when there is one, goes FIRST. Appended to the end of a long instruction block it
# would be read after the model has already decided what to do with the turn (#31385).
if [[ "$count" == "0" ]]; then
    # #31245: the closing hint differs by host. There is no slash command to type on Codex.
    if [[ "$(mmry_host)" == "codex" ]]; then
        _mmry_onboard_hint="they can always say remember this to save something new, or ask what MMRY can do here"
    else
        _mmry_onboard_hint="they can always say remember this to save something new, or /mmry:help for a quick reference"
    fi
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sWelcome to MMRY AI. This is a fresh start — no memories yet. Help the user create their first Foundation memories through natural conversation. Ask them to tell you about themselves: who they are, what they build, what tools they use, and what matters to them. Listen, then save each piece as a Foundation/Initialization memory with an appropriate scope. Keep it conversational — not a checklist. Use save-memory.sh with --working-dir and --session-id for each one. When done, let them know %s."}%s}' "$MMRY_HOOK_FAULT_NOTE" "$_mmry_onboard_hint" "$EMPTY_SYSMSG"
else
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sMMRY AI loaded %s memories. Read them now: %s"}%s}' "$MMRY_HOOK_FAULT_NOTE" "$count" "$escaped_path" "$EMPTY_SYSMSG"
fi
