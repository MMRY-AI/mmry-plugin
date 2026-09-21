#!/usr/bin/env bash
# SessionStart hook: loads memories from MMRY AI API via curl.
# Outputs hook JSON with path to temp file containing loaded memories.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Self-update check — runs before anything else, debounced to once per hour
bash "${PLUGIN_ROOT}/hooks-handlers/self-update.sh" 2>/dev/null || true

source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# jq is required and bundled by setup. If none is usable (unsupported platform
# or a broken install), fail fast with a clear message rather than stalling on a
# slow fallback (#30624 absorbs #30319).
if [[ -z "${MMRY_JQ:-}" ]]; then
    mmry_jq_unavailable_message
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI could not find a usable jq on this machine, so memories were not loaded. Ask the user to re-run setup to restore the bundled jq: bash ~/.claude/mmry/setup/mmry-setup.sh"}}'
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
    MMRY_HOOK_FAULT_NOTE="WARNING FROM MMRY AI: the Claude Code hook payload could not be read from stdin (${HOOK_READ_STATUS}), so this session could not learn its own session id and coordination features will not work correctly. Tell the user, and ask them to report it with /mmry:feedback. "
fi

# stdin may not be JSON outside a hook context; jq returns empty and we fall
# back to the env var, then "unknown". This is a data fallback, not a jq one.
SESSION_ID="$(printf '%s' "$HOOK_PAYLOAD" | "$MMRY_JQ" -r '.session_id // empty' 2>/dev/null || true)"
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"

# NOTE: Bug #9 fix removed the /tmp/mmry-session-dir and
# /tmp/mmry-session-dir-${SESSION_ID} writes that previously lived here.
# Working directory is now persisted server-side via the /api/sessions POST
# below; save-memory.sh resolves it back from the API when needed.

# Check if config is loaded — guide unconfigured users to run setup
if [[ -z "${MMRY_API_KEY:-}" ]]; then
    API_URL="https://mmryai.com"
    # shellcheck disable=SC2016
    SETUP_MSG='MMRY AI is installed but needs to be set up. Run the setup script to authenticate via the browser.

## Setup

Run this command using the Bash tool:

bash ~/.claude/mmry/setup/mmry-setup.sh

This will open a browser window where the user can log in or create an account on mmryai.com. Once they authorize, the script writes the config file and permissions automatically.

If the browser does not open, the script prints a URL the user can copy and paste.

After setup completes, tell the user: "You are all set. Restart Claude Code and your memories will start loading automatically." Mention /mmry:help for a quick reference.

If the user does not have an account yet, direct them to https://mmryai.com to sign up first, then run setup again.'

    # Escape for JSON output
    SETUP_MSG_ESCAPED="$(printf '%s' "$SETUP_MSG" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$SETUP_MSG_ESCAPED"
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
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MMRY AI: the stored sign-in credential is invalid or expired. Tell the user that their memories may not be saved or loaded, and direct them to run /mmry:setup to re-authenticate."}}'
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
if ! mmry_write_foundation_cache "$MMRY_RESPONSE" "${MMRY_TMPDIR}/mmry-foundation.md"; then
    MMRY_HOOK_FAULT_NOTE="${MMRY_HOOK_FAULT_NOTE}WARNING FROM MMRY AI: your Foundation directives could not be stored for this session, so they will NOT be applied on each prompt. Nothing partial was kept and nothing was guessed at. Tell the user, and ask them to run /mmry:load-memories to try again, or /mmry:foundation-status to check. "
fi

# Register session — uses session_id read from hook stdin (see top of file).
# WORK_DIR is persisted server-side here; subsequent save calls reference it
# via session_id rather than reading a (collidable) /tmp file.
mmry_register_session "$SESSION_ID" "claude-code" "$WORK_DIR" "" 2>/dev/null || true

# Escape path for JSON
escaped_path="$(echo "$MEM_FILE" | sed 's/\\/\\\\/g')"

# First-session onboarding: detect zero memories
# The fault note, when there is one, goes FIRST. Appended to the end of a long instruction block it
# would be read after the model has already decided what to do with the turn (#31385).
if [[ "$count" == "0" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sWelcome to MMRY AI. This is a fresh start — no memories yet. Help the user create their first Foundation memories through natural conversation. Ask them to tell you about themselves: who they are, what they build, what tools they use, and what matters to them. Listen, then save each piece as a Foundation/Initialization memory with an appropriate scope. Keep it conversational — not a checklist. Use save-memory.sh with --working-dir and --session-id for each one. When done, let them know they can always say remember this to save something new, or /mmry:help for a quick reference."}}' "$MMRY_HOOK_FAULT_NOTE"
else
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%sMMRY AI loaded %s memories. Read them now: %s"}}' "$MMRY_HOOK_FAULT_NOTE" "$count" "$escaped_path"
fi
