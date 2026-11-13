#!/usr/bin/env bats
# foundation-private-files.bats - every Foundation working file the plugin writes is readable only by
# its owner (#33652).
#
# THE DEFECT, finding (b)6 of the independent QA of #33480 (privacy and security reviewers, 2026-11-09).
# On a Linux machine where several people share one temporary folder, the before-shortening file
# (mmry-foundation-shortening.<key>.<sid>.md) and its staging copy (<file>.w.<pid>) were created with
# the invoking umask, commonly 022, so another user of the machine could read a customer's Foundation
# directives. The same held for every other Foundation working file: the memories file SessionStart
# tells the model to read, the set, the session marker and the per-prompt markers.
#
# THE RULE: every entry that writes a Foundation working file narrows its umask to 077 before it writes
# anything (mmry-client.sh, which every handler sources; userpromptsubmit-foundation.sh, whose
# supervisor writes before it loads the client; precompact-foundation.sh; and the two Codex entry
# files). umask is a builtin, so no budgeted path pays a process for it. The staging copy is renamed
# into place, so its mode IS the final file's mode.
#
# WHERE THE MODE CAN BE SEEN. Git Bash on Windows does not implement POSIX modes (chmod is a no-op and
# stat reports 644 regardless; tests/e2e/codex-setup.bats says so and skips the same way), so the mode
# checks run on Linux and macOS, which CI covers, and SKIP on Windows, saying so. The source-order check
# runs everywhere.

load '../helpers/test-helper'
load '../helpers/mock-config'
load '../helpers/foundation-set'

setup() {
    setup_mock_curl
    create_test_config "http://localhost:5291" "test-api-key" "apikey" >/dev/null
    export MMRY_NO_SELF_UPDATE=1
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID MMRY_HOST CODEX_HOME || true
    export MMRY_HOOK_READ_TIMEOUT=2
    # The umask a shared Linux machine commonly has. The plugin must not depend on the caller's.
    umask 022
    _write_account
}

_modes_observable() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 1 ;; esac
    return 0
}
_mode() {
    case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}

# One memory per moment (as foundation-moments.bats), plus an oversized before-shortening set so the
# PreCompact handler takes the by-reference path and writes the shortening file.
_write_account() {
    jq -n --arg f "$(printf 'z%.0s' $(seq 1 8000))" '[
      {id: 11, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Start only",
       content: "START-11 opens", moments: ["conversation-start"]},
      {id: 12, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Every only",
       content: "EVERY-12 holds", moments: ["every-message"]},
      {id: 15, memoryTier: "Foundation", scope: "global", category: "Directive", topic: "Start and every",
       content: "BOTH-15 applies at the start and on every message.", moments: ["conversation-start", "every-message"]},
      {id: 17, memoryTier: "Strategic", scope: "global", category: "Fact", topic: "Not foundation",
       content: "STRATEGIC-17 is an ordinary memory."}
    ] + [range(1;9) | {id: (100 + .), memoryTier: "Foundation", scope: "global", topic: "Big \(.)", content: "BIG-\(.)-START \($f) BIG-\(.)-END", moments: ["before-shortening"]}]' \
        > "$TEST_TMPDIR/mock-moments.json"
}

_cc_start() {
    printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "${1:-cc-priv-1}" \
        | bash "${2:-$PLUGIN_ROOT}/hooks-handlers/session-start.sh" 2>/dev/null
}
_cc_prompt() {
    local k
    for k in 1 2 3 4 5 6; do
        printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "${1:-cc-priv-1}" \
            | bash "${2:-$PLUGIN_ROOT}/hooks-handlers/userpromptsubmit-foundation.sh" --part "$k" >/dev/null 2>&1
    done
}
_cc_precompact() {
    printf '{"session_id":"%s","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}' "${1:-cc-priv-1}" \
        | bash "${2:-$PLUGIN_ROOT}/hooks-handlers/precompact-foundation.sh" --part 1 2>/dev/null
}

# Every Foundation working file in the temp folder: "<mode> <name>" per line.
_foundation_files() {
    local f
    for f in "$TEST_TMPDIR"/mmry-foundation* "$TEST_TMPDIR"/.mmry-foundation* "$TEST_TMPDIR"/mmry-memories*; do
        [[ -e "$f" ]] || continue
        printf '%s %s\n' "$(_mode "$f")" "${f##*/}"
    done
}

# Fails, naming each offender, unless every listed file is 600 (a directory 700).
_all_owner_only() {
    local line bad="" n=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n=$((n + 1))
        case "$line" in
            "600 "*) ;;
            "700 "*) [[ -d "$TEST_TMPDIR/${line#700 }" ]] || bad+="$line; " ;;
            *) bad+="$line; " ;;
        esac
    done
    (( n > 0 )) || { echo "no Foundation working file was found to check"; return 1; }
    [[ -z "$bad" ]] || { echo "not owner-only: $bad"; return 1; }
    echo "# $n files checked, all owner-only" >&3
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 1, TEST CASE 1: the before-shortening file and its staging copy
# ---------------------------------------------------------------------------------------------
@test "#33652: the before-shortening file, written as its staging copy and renamed into place, is owner-only (600)" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    run _cc_precompact
    assert_success
    assert_output --partial "more than about 57,000"
    local f n=0
    for f in "$TEST_TMPDIR"/mmry-foundation-shortening.*.md; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        [[ "$(_mode "$f")" == "600" ]] || { echo "${f##*/} has mode $(_mode "$f"), not 600"; return 1; }
    done
    (( n == 1 )) || { echo "expected one shortening file, found $n: $(ls -a "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    # No staging copy is left behind at any mode.
    for f in "$TEST_TMPDIR"/mmry-foundation-shortening.*.w.*; do
        [[ -e "$f" ]] && { echo "a staging copy was left: ${f##*/}"; return 1; }
    done
    return 0
}

@test "#33652: precompact-foundation.sh narrows its umask before it writes the staging copy (source order, checkable everywhere)" {
    local f="$PLUGIN_ROOT/hooks-handlers/precompact-foundation.sh" umask_line write_line
    umask_line="$(grep -n '^umask 077' "$f" | head -1 | cut -d: -f1)"
    write_line="$(grep -n '\.w\.\$\$' "$f" | head -1 | cut -d: -f1)"
    [[ "$write_line" =~ ^[0-9]+$ ]] || { echo "the staging write was not found"; return 1; }
    [[ "$umask_line" =~ ^[0-9]+$ ]] || { echo "precompact-foundation.sh sets no umask 077"; return 1; }
    (( umask_line < write_line )) || { echo "umask 077 at line $umask_line comes after the staging write at $write_line"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 1, the other Foundation working files (the ticket's "check the other Foundation working
# files"): everything a Claude Code session writes at its start and on a prompt.
# ---------------------------------------------------------------------------------------------
@test "#33652: every Foundation working file a Claude Code session writes is owner-only: memories file, set, session marker, stored marker, prepared copy, claim, result, status, outcome, moment report" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _cc_start >/dev/null
    _cc_prompt
    _cc_precompact >/dev/null
    local listing; listing="$(_foundation_files)"
    echo "$listing" | grep -q ' mmry-memories\.' || { echo "no memories file was written: $listing"; return 1; }
    echo "$listing" | grep -q ' mmry-foundation-set\.' || { echo "no set was written: $listing"; return 1; }
    echo "$listing" | grep -q ' \.mmry-foundation-prepared\.' || { echo "no prepared copy was written: $listing"; return 1; }
    printf '%s\n' "$listing" | _all_owner_only
}

@test "#33652: the per-prompt hook on Codex writes its markers owner-only too" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local cx="$TEST_TMPDIR/codexhome"
    mkdir -p "$cx"
    cp "$MMRY_CONFIG_FILE" "$cx/mmry-config.json"
    # The set, as the Codex session start would have stored it for this account.
    MMRY_HOST=codex CODEX_HOME="$cx" _cc_start cx-priv-1 >/dev/null
    local k
    for k in 1 2; do
        printf '{"session_id":"cx-priv-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' \
            | env -u MMRY_CONFIG_FILE -u MMRY_API_URL -u MMRY_API_KEY CODEX_HOME="$cx" PLUGIN_ROOT="$PLUGIN_ROOT" \
                  bash "$PLUGIN_ROOT/hooks-handlers/codex-hook.sh" userpromptsubmit-foundation --part "$k" >/dev/null 2>&1
    done
    local listing; listing="$(_foundation_files)"
    echo "$listing" | grep -q ' \.mmry-foundation-prepared\.' || { echo "no prepared copy was written on Codex: $listing"; return 1; }
    printf '%s\n' "$listing" | _all_owner_only
}

# ---------------------------------------------------------------------------------------------
# REQUIREMENT 1 ON THE UPGRADE PATH (QA round 1 of PR #138, 33652 R1 FAILED). umask 077 narrows only
# the files the plugin CREATES. These per-account files are rewritten IN PLACE at a name that persists
# across prompts and sessions (a plain redirect or an append), and an open with O_TRUNC or O_APPEND
# leaves an existing file's mode as it was: a copy the previous plugin created at 644 on a shared
# Linux machine kept 644 after the upgrade, and kept receiving the account's directives on every
# prompt. Each case below plants the file at 644 BEFORE the session start, as an older plugin left it,
# then runs one session start and one prompt (all six parts), and requires 600.
# ---------------------------------------------------------------------------------------------
_U_SID=cc-upg-1

# The per-account names, as the handlers build them (lib-foundation-key.sh): <account key> for the
# account's own files, <account key>.<session id> for the per-session part of the name.
_u_name() {
    local a; a="$(fnd_acct)"
    case "$1" in
        prepared) printf '.mmry-foundation-prepared.%s.%s' "$a" "$_U_SID" ;;
        result)   printf '.mmry-foundation-result.%s.%s' "$a" "$_U_SID" ;;
        claim)    printf '.mmry-foundation-claim.%s.%s' "$a" "$_U_SID" ;;
        session)  printf 'mmry-foundation.session.%s' "$a" ;;
        log)      printf 'mmry-foundation.%s.log' "$a" ;;
        moment)   printf 'mmry-foundation-moment.%s.every-message' "$a" ;;
        checked)  printf '.mmry-foundation-refresh-checked.%s' "$a" ;;
        memories) printf 'mmry-memories.%s.%s.md' "$a" "$_U_SID" ;;
        stored)   printf 'mmry-foundation.stored.%s.%s' "$a" "$_U_SID" ;;
        status)   printf 'mmry-foundation.status.%s.%s' "$a" "$_U_SID" ;;
    esac
}
_U_ALL="prepared result claim session log moment checked memories stored status"

# Every name above, planted at 644 the way an older plugin left it.
_u_plant_old() {
    local k p
    for k in $_U_ALL; do
        p="$TEST_TMPDIR/$(_u_name "$k")"
        case "$k" in
            claim)   printf '1 1' > "$p" ;;
            checked) printf '0' > "$p" ;;
            stored)  printf '1' > "$p" ;;
            log)     printf '2026-01-01T00:00:00 an older plugin wrote this line\n' > "$p" ;;
            *)       printf 'written by an older plugin' > "$p" ;;
        esac
        chmod 644 "$p"
        [[ "$(_mode "$p")" == "644" ]] || { echo "could not plant $k at 644"; return 1; }
    done
}

_u_start_and_prompt() {
    _cc_start "$_U_SID" >/dev/null
    _cc_prompt "$_U_SID"
}

# Fails unless the planted file $1 is still there as a regular file and is now 600.
_u_assert_600() {
    local p; p="$TEST_TMPDIR/$(_u_name "$1")"
    [[ -f "$p" && ! -L "$p" ]] || { echo "$1 ($(_u_name "$1")) is gone or not a regular file: $(ls -lA "$TEST_TMPDIR" | tr '\n' ' ')"; return 1; }
    [[ "$(_mode "$p")" == "600" ]] || { echo "$1 ($(_u_name "$1")) planted at 644 by an older plugin is still $(_mode "$p") after a session start and a prompt"; return 1; }
}

@test "#33652 upgrade: the prepared copy (.mmry-foundation-prepared), planted at 644 by an older plugin, is 600 after one session start and one prompt, and was rewritten" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _u_plant_old
    _u_start_and_prompt
    _u_assert_600 prepared
    # The prompt really wrote it (an in-place rewrite, the path QA named), not merely left it.
    local first; IFS= read -r first < "$TEST_TMPDIR/$(_u_name prepared)" || true
    [[ "$first" == "mmry-fnd-prepared v1 "* ]] || { echo "the prepared copy was not rewritten by the prompt: '$first'"; return 1; }
}

@test "#33652 upgrade: the session marker (mmry-foundation.session), planted at 644 by an older plugin, is 600 after one session start and one prompt" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _u_plant_old
    _u_start_and_prompt
    _u_assert_600 session
    [[ "$(<"$TEST_TMPDIR/$(_u_name session)")" == "$_U_SID" ]] || { echo "the session start did not write its marker"; return 1; }
}

@test "#33652 upgrade: the result file (.mmry-foundation-result), planted at 644 by an older plugin, is 600 after one session start and one prompt" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _u_plant_old
    _u_start_and_prompt
    _u_assert_600 result
}

@test "#33652 upgrade: the account's log (mmry-foundation.<key>.log), planted at 644 by an older plugin, is 600 after one session start and one prompt, its lines kept" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _u_plant_old
    _u_start_and_prompt
    _u_assert_600 log
    grep -q 'an older plugin wrote this line' "$TEST_TMPDIR/$(_u_name log)" || { echo "the log lost its earlier lines"; return 1; }
}

@test "#33652 upgrade: the moment report (mmry-foundation-moment), planted at 644 by an older plugin, is 600 after one session start and one prompt" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _u_plant_old
    _u_start_and_prompt
    _u_assert_600 moment
}

@test "#33652 upgrade: every other per-account file written in place (claim, refresh check, memories file, stored marker, delivery record), planted at 644, is 600 after one session start and one prompt" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    _u_plant_old
    _u_start_and_prompt
    local k bad=""
    for k in claim checked memories stored status; do
        _u_assert_600 "$k" >/dev/null 2>&1 || bad+="$k=$(_mode "$TEST_TMPDIR/$(_u_name "$k")" 2>/dev/null || echo gone) "
    done
    [[ -z "$bad" ]] || { echo "still not owner-only after a session start and a prompt: $bad"; return 1; }
    # And every Foundation working file in the folder, whoever's name it carries, is owner-only now.
    _foundation_files | _all_owner_only
}

@test "#33652 upgrade: a link planted at a per-account name is never written through or chmodded through, and the Foundation is still delivered" {
    _modes_observable || skip "POSIX modes and real symlinks are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local k p v bad=""
    for k in prepared result session moment log checked; do
        v="$TEST_TMPDIR/victim-$k"
        printf 'VICTIM %s' "$k" > "$v"
        chmod 644 "$v"
        p="$TEST_TMPDIR/$(_u_name "$k")"
        ln -s "$v" "$p"
    done
    _cc_start "$_U_SID" >/dev/null
    run bash -c 'printf "{\"session_id\":\"%s\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}" "$1" | bash "$2/hooks-handlers/userpromptsubmit-foundation.sh" --part 1 2>/dev/null' _ "$_U_SID" "$PLUGIN_ROOT"
    local out="$output"
    _cc_prompt "$_U_SID"
    for k in prepared result session moment log checked; do
        v="$TEST_TMPDIR/victim-$k"
        p="$TEST_TMPDIR/$(_u_name "$k")"
        [[ "$(<"$v")" == "VICTIM $k" ]] || bad+="$k: written through the link; "
        [[ "$(_mode "$v")" == "644" ]] || bad+="$k: the link's target was chmodded to $(_mode "$v"); "
    done
    [[ -z "$bad" ]] || { echo "$bad"; return 1; }
    [[ "$out" == *"EVERY-12 holds"* ]] || { echo "the Foundation was not delivered with links at the account's names: $out"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# MUTATION CONTROL (the ticket: "it fails with the change removed"). A copy of the plugin with every
# umask line removed, driven the same way: the checks above must then fail. Pure string replacement
# on the copy, as tests/mutation/run-33617-mutations.sh does.
# ---------------------------------------------------------------------------------------------
_copy_without_umask() {
    local root="$TEST_TMPDIR/mutant" f t n=0
    mkdir -p "$root"
    cp -R "$PLUGIN_ROOT/hooks-handlers" "$PLUGIN_ROOT/hooks" "$root/"
    for f in "$root"/hooks-handlers/*.sh; do
        t="$(cat "$f"; printf x)"; t="${t%x}"
        while [[ "$t" == *$'\numask 077'* ]]; do t="${t/$'\numask 077'/$'\n: umask-removed'}"; n=$((n + 1)); done
        printf '%s' "$t" > "$f"
    done
    (( n > 0 )) || { echo "no umask 077 line to remove: the mutation is a no-op" >&2; return 1; }
    printf '%s' "$root"
}

@test "#33652 control: with the umask narrowing removed from a copy of the plugin, the before-shortening file is NOT owner-only (the check bites)" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local root; root="$(_copy_without_umask)" || return 1
    run _cc_precompact cc-mut-1 "$root"
    assert_success
    assert_output --partial "more than about 57,000"
    local f seen=0
    for f in "$TEST_TMPDIR"/mmry-foundation-shortening.*.md; do
        [[ -f "$f" ]] || continue
        seen=1
        [[ "$(_mode "$f")" != "600" ]] || { echo "the mutant still wrote ${f##*/} as 600: the mode check would not notice the umask going"; return 1; }
    done
    (( seen == 1 )) || { echo "the mutant wrote no shortening file"; return 1; }
}

@test "#33652 control: with the umask narrowing removed from a copy of the plugin, the session's memories file is NOT owner-only (the check bites)" {
    _modes_observable || skip "POSIX modes are not observable under Git Bash on Windows; this runs on the Linux and macOS CI legs"
    local root; root="$(_copy_without_umask)" || return 1
    _cc_start cc-mut-2 "$root" >/dev/null
    local f seen=0
    for f in "$TEST_TMPDIR"/mmry-memories.*.cc-mut-2.md; do
        [[ -f "$f" ]] || continue
        seen=1
        [[ "$(_mode "$f")" != "600" ]] || { echo "the mutant still wrote ${f##*/} as 600"; return 1; }
    done
    (( seen == 1 )) || { echo "the mutant wrote no memories file"; return 1; }
}
