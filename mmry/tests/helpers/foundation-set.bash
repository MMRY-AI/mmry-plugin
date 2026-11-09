#!/usr/bin/env bash
# foundation-set.bash - write and read the Foundation set file the way the plugin does (#31597, #32889).
#
# The set is ONE file: a record line, the set, a trailer (see mmry-client.sh). Tests that put a set
# in place by hand stage the directives in a plain file first and then SEAL it, which writes the
# record exactly as mmry_write_foundation_cache would. A test that skips the seal is testing the
# refusal path by accident.
#
# Since #32889 the file is NAMED BY THE ACCOUNT AND SERVER the test's environment or config names, and
# the record carries the same key. A test therefore takes the set's path from fnd_set_file, AFTER it
# has written whatever config or exported whatever MMRY_API_URL / MMRY_API_KEY the handler under test
# will see: a path taken before that is keyed for "no account" and the handler will not find it.
#
#   fnd_acct
#       Prints the account-and-server key for the current environment and config, as the handlers
#       compute it (hooks-handlers/lib-foundation-key.sh).
#   fnd_set_file [dir]        -> <dir>/mmry-foundation-set.<key>.md       (dir defaults to $TEST_TMPDIR)
#   fnd_session_file [dir]    -> <dir>/mmry-foundation.session.<key>
#   fnd_seal [staged-body] [entries] [set-file] [acct]
#       Defaults: $CACHE (the staged body), entries = lines beginning "- ", $SET, the current key.
#       Entries default to a line count, which is good enough for fixtures; the production writer
#       counts from the API response instead, because memory content can contain such lines.
#   fnd_set_body [set-file]
#       Prints the set held in the file: the bytes after the record line, without the trailer.
#   fnd_set_record [set-file]
#       Prints the record line.

FND_TRAILER='END OF FOUNDATION SET'

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/hooks-handlers/lib-foundation-key.sh"

fnd_acct() {
    # Recomputed every call: a test changes its environment between calls. FND_CONFIG_OVERRIDE names
    # the config the HANDLER will read when it is not the one this shell would (a Codex home the
    # handler is pointed at with CODEX_HOME while MMRY_CONFIG_FILE is unset for it).
    if [[ -n "${FND_CONFIG_OVERRIDE:-}" ]]; then
        ( export MMRY_CONFIG_FILE="$FND_CONFIG_OVERRIDE" MMRY_API_URL="" MMRY_API_KEY=""; unset MMRY_HOST
          _MMRY_FND_ACCT=""; mmry_foundation_account_key )
        return 0
    fi
    _MMRY_FND_ACCT=""
    mmry_foundation_account_key
}

# What fnd_seal last sealed, so fnd_follow_config can seal it again under a new identity.
_FND_LAST_BODY="" _FND_LAST_N="" _FND_LAST_SET="" _FND_LAST_ACCT=""

# AFTER A TEST CHANGES THE ACCOUNT THE HANDLER WILL SEE - writes a config, exports a key - the set it
# sealed sits under the old account's name, which since #32889 is correctly another account's file.
# This moves it: the old file goes, SET is recomputed, the session marker is copied across, and the
# staged body is sealed again under the new key. A test that sealed nothing, or whose identity did
# not change, is unchanged. Call it right after the config write.
fnd_follow_config() {
    local acct dir newset oldsess newsess
    acct="$(fnd_acct)"
    [[ -n "$_FND_LAST_BODY" && -f "$_FND_LAST_BODY" ]] || return 0
    [[ "$acct" != "$_FND_LAST_ACCT" ]] || return 0
    dir="${_FND_LAST_SET%/*}"
    newset="${dir}/mmry-foundation-set.${acct}.md"
    oldsess="${dir}/mmry-foundation.session.${_FND_LAST_ACCT}"
    newsess="${dir}/mmry-foundation.session.${acct}"
    [[ -f "$oldsess" && ! -f "$newsess" ]] && cp "$oldsess" "$newsess"
    rm -f "$_FND_LAST_SET"
    [[ "${SET:-}" == "$_FND_LAST_SET" ]] && SET="$newset"
    fnd_seal "$_FND_LAST_BODY" "$_FND_LAST_N" "$newset" "$acct"
}

fnd_set_file() {
    printf '%s/mmry-foundation-set.%s.md' "${1:-$TEST_TMPDIR}" "$(fnd_acct)"
}

fnd_session_file() {
    printf '%s/mmry-foundation.session.%s' "${1:-$TEST_TMPDIR}" "$(fnd_acct)"
}

fnd_seal() {
    local body="${1:-$CACHE}" n="${2:-}" set="${3:-$SET}" acct="${4:-}" s b
    [[ -n "$acct" ]] || acct="$(fnd_acct)"
    read -r s b < <(cksum < "$body")
    if [[ -z "$n" ]]; then
        n="$(grep -c '^- ' "$body" 2>/dev/null || true)"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
    fi
    { printf 'mmry-foundation v3 entries=%s bytes=%s cksum=%s acct=%s\n' "$n" "$b" "$s" "$acct"
      cat "$body"
      printf '%s' "$FND_TRAILER"; } > "${set}.seal.$$" && mv -f "${set}.seal.$$" "$set"
    _FND_LAST_BODY="$body" _FND_LAST_N="${2:-}" _FND_LAST_SET="$set" _FND_LAST_ACCT="$acct"
}

fnd_set_body() {
    local set="${1:-$SET}" raw
    raw="$(cat "$set"; printf .)"; raw="${raw%.}"
    raw="${raw#*$'\n'}"
    printf '%s' "${raw%"$FND_TRAILER"}"
}

fnd_set_record() {
    local set="${1:-$SET}" line=""
    IFS= read -r line < "$set"
    printf '%s' "$line"
}

# Write a set file with any record line and body, for tests that build a damaged or foreign set.
#   fnd_set_with "<record line>" "<body>" [set-file]
fnd_set_with() {
    printf '%s\n%s%s' "$1" "$2" "$FND_TRAILER" > "${3:-$SET}"
}

# THE STARTUP MEMORIES FILE AND THE FOUNDATION WORKING FILES, NAMED BY THE ACCOUNT (#32915). Each is
# the plugin's name for the current environment and config, taken the same way the set's name is
# above: AFTER the test has put in place whatever identity the handler under test will see.
#
#   fnd_memories_file [sid] [dir]  -> <dir>/mmry-memories.<key>.<sid>.md, or mmry-memories.<key>.md
#                                     with no sid (the file SessionStart tells the model to read)
#   fnd_log_file [dir]             -> <dir>/mmry-foundation.<key>.log
#   fnd_debug_log_file [dir]       -> <dir>/mmry-foundation-debug.<key>.log
#   fnd_refresh_file [dir]         -> <dir>/.mmry-foundation-refresh.<key>          (the worker's lock)
#   fnd_refresh_checked_file [dir] -> <dir>/.mmry-foundation-refresh-checked.<key>  (the supervisor's stamp)
#   fnd_byref_file [sid] [dir]     -> <dir>/mmry-foundation.byref.<key>.<sid>.md, or .byref.<key>.md
fnd_memories_file() {
    printf '%s/mmry-memories.%s%s.md' "${2:-$TEST_TMPDIR}" "$(fnd_acct)" "${1:+.$1}"
}
fnd_log_file() {
    printf '%s/mmry-foundation.%s.log' "${1:-$TEST_TMPDIR}" "$(fnd_acct)"
}
fnd_debug_log_file() {
    printf '%s/mmry-foundation-debug.%s.log' "${1:-$TEST_TMPDIR}" "$(fnd_acct)"
}
fnd_refresh_file() {
    printf '%s/.mmry-foundation-refresh.%s' "${1:-$TEST_TMPDIR}" "$(fnd_acct)"
}
fnd_refresh_checked_file() {
    printf '%s/.mmry-foundation-refresh-checked.%s' "${1:-$TEST_TMPDIR}" "$(fnd_acct)"
}
fnd_byref_file() {
    printf '%s/mmry-foundation.byref.%s%s.md' "${2:-$TEST_TMPDIR}" "$(fnd_acct)" "${1:+.$1}"
}

# THE PER-SESSION MARKERS, NAMED SO THAT TWO ACCOUNTS NEVER SHARE ONE (#32915, QA round 1,
# requirement 2; #33363). The prepared copy, claim, result and stored markers are named by the
# session: the payload's id, else the token SessionStart left, which is the literal "unknown" for a
# session that had no id. The delivery record and the per-part outcomes take the payload's id only
# (they never carried the token). Since #33363 EVERY part carries the account key in front, a real id
# included: two accounts can share one real id (a session resumed under a second account, an id
# passed by hand), so <sid> alone named a shared file. The parts are <key>.<sid>, <key>.unknown and
# <key>.none, as the plugin's mmry_foundation_session_part_v spells them.
#
#   fnd_session_part [sid-or-token]      -> <key>.<sid>, or <key>.unknown / <key>.none
#   fnd_prepared_file [sid-or-token] [dir] -> <dir>/.mmry-foundation-prepared.<part>
#   fnd_claim_file    [sid-or-token] [dir] -> <dir>/.mmry-foundation-claim.<part>
#   fnd_result_file   [sid-or-token] [dir] -> <dir>/.mmry-foundation-result.<part>
#   fnd_stored_file   [sid-or-token] [dir] -> <dir>/mmry-foundation.stored.<part>
#   fnd_status_file   [sid] [dir]          -> <dir>/mmry-foundation.status.<part>
#   fnd_outcome_file  [sid] [part] [dir]   -> <dir>/mmry-foundation.outcome.<part>[.<part number>]
fnd_session_part() {
    local v="${1:-}"
    [[ "$v" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || v=""
    printf '%s.%s' "$(fnd_acct)" "${v:-none}"
}
fnd_prepared_file() { printf '%s/.mmry-foundation-prepared.%s' "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
fnd_claim_file()    { printf '%s/.mmry-foundation-claim.%s'    "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
fnd_result_file()   { printf '%s/.mmry-foundation-result.%s'   "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
fnd_stored_file()   { printf '%s/mmry-foundation.stored.%s'    "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
fnd_status_file()   { printf '%s/mmry-foundation.status.%s'    "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
fnd_outcome_file() {
    local n="${2:-1}" sfx=""
    (( n > 1 )) && sfx=".$n"
    printf '%s/mmry-foundation.outcome.%s%s' "${3:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")" "$sfx"
}
# THE NOTICE MARKERS, NAMED THE SAME WAY (#32915, QA round 2, F-B). The in-flight marker (a turn the
# harness killed), the cut-short marker (a turn stopped at the deadline), the empty-set told marker
# and the by-reference told marker were bare names with no session id, one for every id-less session
# on the machine whatever its account: one account's user went untold of a by-reference set, and was
# told of the other account's lost turn. Each takes the session part above: the id, else <key>.none.
#   fnd_inflight_file   [sid] [part number] [dir] -> <dir>/.mmry-foundation-inflight.<part>[.<n>]
#   fnd_cutshort_file   [sid] [part number] [dir] -> <dir>/.mmry-foundation-cutshort.<part>[.<n>]
#   fnd_empty_told_file [sid] [dir]               -> <dir>/.mmry-foundation-empty-told.<part>
#   fnd_byref_told_file [sid] [dir]               -> <dir>/.mmry-foundation-byref-told.<part>
fnd_inflight_file() {
    local n="${2:-1}" sfx=""
    (( n > 1 )) && sfx=".$n"
    printf '%s/.mmry-foundation-inflight.%s%s' "${3:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")" "$sfx"
}
fnd_cutshort_file() {
    local n="${2:-1}" sfx=""
    (( n > 1 )) && sfx=".$n"
    printf '%s/.mmry-foundation-cutshort.%s%s' "${3:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")" "$sfx"
}
fnd_empty_told_file() { printf '%s/.mmry-foundation-empty-told.%s' "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
fnd_byref_told_file() { printf '%s/.mmry-foundation-byref-told.%s' "${2:-$TEST_TMPDIR}" "$(fnd_session_part "${1:-}")"; }
