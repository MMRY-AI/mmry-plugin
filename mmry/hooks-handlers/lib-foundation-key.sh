#!/usr/bin/env bash
# lib-foundation-key.sh - WHICH ACCOUNT, ON WHICH SERVER, does this session's Foundation copy belong to
# (#32889). ONE answer, computed with builtins only, used by every reader and writer of the copy.
#
# WHY THIS EXISTS. On 2026-10-24 at 01:16 UTC a Codex session on the Integration test account started on
# a machine where a Claude Code session on production (18 Foundation directives) was running. Both kept
# their local Foundation copy at one machine-wide name, %TEMP%\mmry-foundation-set.md, and their session
# marker at %TEMP%\mmry-foundation.session. The Codex session rewrote both. The production session's next
# prompts injected the Integration account's one directive, and /mmry:foundation-status said "VERIFIED -
# 1 directives". The server was right throughout; the local copy was keyed by neither account, server nor
# host. One account's directives were lost and another account's were injected: a privacy defect.
#
# THE KEY. The local copy and the session marker are now named for the server and the account they
# belong to: mmry-foundation-set.<key>.md and mmry-foundation.session.<key>, where <key> is sixteen hex
# characters hashed from the API base URL and the API key this session is configured with. The same key
# is written into the copy's record line, and a reader refuses a copy whose recorded key is not its own
# (mmry_read_foundation_set, state "foreign"). So two sessions on one machine never share a file unless
# they are the same account on the same server, and a copy that somehow reaches the wrong name is still
# refused rather than injected.
#
# NEVER THE RAW KEY OR AN EMAIL. A file name in a shared temp directory is readable by anything on the
# machine; the hash is one way, and the credential itself never appears on disk outside the config file.
# The hash is FNV-1a 32 beside Jenkins one-at-a-time 32, over "<url>\n<key>", in bash arithmetic: it is
# a name, not a secret, and a 64-bit name makes an accidental collision between two accounts on one
# machine as good as impossible. A 256-bit key is not recoverable from it.
#
# WITH NO PROCESS AT ALL, because the per-prompt hook's supervisor needs it before it has loaded anything
# (#31893: no jq, no config parse, nothing that starts a process, on every part of every prompt). The
# identity comes from MMRY_API_URL and MMRY_API_KEY when the environment sets them, which is also the
# client's own precedence, and otherwise from a text scan of the config file the client would load, in
# the client's own discovery order (mmry_load_config; lib-foundation-switch.sh scans the same file the
# same way for the off switch). Read with the read builtin, so not even a subshell is paid.
#
# WHAT THE SCAN IS, AND IS NOT. It takes the string between the quotes after "apiUrl" and "apiKey". For
# every config the product writes (setup writes the key the service issued, hex, and a plain URL) that
# is byte for byte what jq parses, so a session whose SessionStart keyed the copy from the parsed config
# and whose prompt hook keys it from the scan agree. A hand-edited config whose key holds a JSON escape,
# or the same field twice, could make the two disagree; the result is a copy written under one name and
# looked for under another, which reads as NOT LOADED YET, never as another account's set. Stated rather
# than hidden.
#
# Functions only. bash 3.2 (the macOS bash) runs every line. Sourced by mmry-client.sh for every handler
# and directly by the per-prompt hook's supervisor; guarded against double sourcing so the cached key
# survives.

[[ -n "${_MMRY_LIB_FND_KEY_SOURCED:-}" ]] && return 0
_MMRY_LIB_FND_KEY_SOURCED=1

# The repository convention, which file-integrity.bats enforces, then ALL THREE options put back the way
# the caller had them. This file is sourced by three kinds of caller: mmry-client.sh (errexit on), the
# per-prompt hook (errexit off on purpose, because nothing in Foundation re-injection may fail a prompt)
# and the test helpers (bats' own options, pipefail off). Restoring errexit alone, as
# lib-foundation-switch.sh can because its two callers already set -u and pipefail, left pipefail on in
# the test shell and four Foundation suites failed with SIGPIPE (141) on `cmd | grep -q`.
# foundation-isolation.bats checks every combination.
_mmry_fkey_opts="$-"
_mmry_fkey_pipefail=0
[[ -o pipefail ]] && _mmry_fkey_pipefail=1
set -euo pipefail
case "$_mmry_fkey_opts" in *e*) ;; *) set +e ;; esac
case "$_mmry_fkey_opts" in *u*) ;; *) set +u ;; esac
(( _mmry_fkey_pipefail )) || set +o pipefail
unset _mmry_fkey_opts _mmry_fkey_pipefail

# The default the client applies when nothing names a server (mmry-client.sh, _MMRY_DEFAULT_URL).
_MMRY_FND_DEFAULT_URL="https://mmryai.com"

_MMRY_FND_HASH=""
_MMRY_FND_ID_URL=""
_MMRY_FND_ID_KEY=""
_MMRY_FND_ID_AUTH=""
_MMRY_FND_CFG=""
_MMRY_FND_ACCT=""
_MMRY_FND_ACCT_FOR=""
# Whether a server address was actually GIVEN, by the environment or the config, as opposed to the
# default applied below when none was (#32915, mmry_foundation_identity_known_v).
_MMRY_FND_ID_URL_GIVEN=0

# Lowercase ASCII with no process, as lib-foundation-switch.sh and lib-host.sh do: bash 3.2 has no ${x,,}.
_mmry_fnd_key_tolower_v() {
    local s="$1" out="" c pre i=0
    local up="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lo="abcdefghijklmnopqrstuvwxyz"
    while (( i < ${#s} )); do
        c="${s:i:1}"
        pre="${up%%"$c"*}"
        if (( ${#pre} < 26 )); then out="${out}${lo:${#pre}:1}"; else out="${out}${c}"; fi
        i=$(( i + 1 ))
    done
    _MMRY_FND_LOWER="$out"
}

# Sixteen hex characters from $1, into _MMRY_FND_HASH: FNV-1a 32 then Jenkins one-at-a-time 32, over the
# BYTES of the string (LC_ALL=C, so a multibyte character is hashed byte by byte and the same bytes give
# the same name on every platform). Every step is masked to 32 bits, so bash's 64-bit arithmetic never
# overflows and the result is the same on every bash this plugin runs on.
mmry_foundation_hash_v() {
    local LC_ALL=C
    local s="$1" i n b c f=2166136261 j=0
    n=${#s}
    for (( i = 0; i < n; i++ )); do
        c="${s:i:1}"
        printf -v b '%d' "'$c"
        (( b < 0 )) && b=$(( b + 256 ))
        f=$(( ( (f ^ b) * 16777619 ) & 0xFFFFFFFF ))
        j=$(( (j + b) & 0xFFFFFFFF ))
        j=$(( (j + (j << 10)) & 0xFFFFFFFF ))
        j=$(( j ^ (j >> 6) ))
    done
    j=$(( (j + (j << 3)) & 0xFFFFFFFF ))
    j=$(( j ^ (j >> 11) ))
    j=$(( (j + (j << 15)) & 0xFFFFFFFF ))
    printf -v _MMRY_FND_HASH '%08x%08x' "$f" "$j"
}

# The repository's one guard on the other product's credential (#31245 TC6, mmry-client.sh and
# lib-foundation-switch.sh define the same body): false on Codex, so a Codex session never keys its copy
# from the Claude Code account. Defined here only when no earlier file has, because this library is
# sourced before both of them; declare -F is a builtin, so it costs no process.
declare -F _mmry_claude_config_fallback_ok >/dev/null 2>&1 || _mmry_claude_config_fallback_ok() {
    [[ "${MMRY_HOST:-}" != "codex" ]]
}

# The config file the client would load, into _MMRY_FND_CFG (empty when there is none), in
# mmry_load_config's order: $MMRY_CONFIG_FILE while it exists, the plugin root, then the Claude Code
# file - never on Codex, which must not fall back to the other product's account (#31245 TC6).
_mmry_fnd_config_file_v() {
    local root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
    _MMRY_FND_CFG=""
    if [[ -n "${MMRY_CONFIG_FILE:-}" && -f "${MMRY_CONFIG_FILE}" ]]; then
        _MMRY_FND_CFG="$MMRY_CONFIG_FILE"
    elif [[ -n "$root" && -f "${root}/mmry-config.json" ]]; then
        _MMRY_FND_CFG="${root}/mmry-config.json"
    elif _mmry_claude_config_fallback_ok && [[ -n "${HOME:-}" && -f "${HOME}/.claude/mmry-config.json" ]]; then
        _MMRY_FND_CFG="${HOME}/.claude/mmry-config.json"
    fi
}

# The server and account this process is configured for, into _MMRY_FND_ID_URL and _MMRY_FND_ID_KEY.
# Environment first, then the config file, then the client's default URL; the key is empty when nothing
# names one (an unconfigured session, which has no copy to read anyway). The URL is lowercased and
# stripped of trailing slashes so that two spellings of one server are one key.
mmry_foundation_identity_v() {
    local url="${MMRY_API_URL:-}" key="${MMRY_API_KEY:-}" auth="${MMRY_AUTH_METHOD:-}" txt=""
    if [[ -z "$url" || -z "$key" || -z "$auth" ]]; then
        _mmry_fnd_config_file_v
        if [[ -n "$_MMRY_FND_CFG" && -r "$_MMRY_FND_CFG" ]]; then
            # read -d '' takes the whole file with no subshell; it returns 1 at end of input even when it
            # read everything, and a FIFO or a huge file is bounded by -n (a config is a few hundred bytes).
            IFS= read -r -d '' -n 65536 txt < "$_MMRY_FND_CFG" 2>/dev/null || true
            if [[ -z "$url" && "$txt" =~ \"apiUrl\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                url="${BASH_REMATCH[1]}"
            fi
            if [[ -z "$key" && "$txt" =~ \"apiKey\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                key="${BASH_REMATCH[1]}"
            fi
            if [[ -z "$auth" && "$txt" =~ \"authMethod\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                auth="${BASH_REMATCH[1]}"
            fi
        fi
    fi
    # The client's rule (mmry_load_config): a credential with no method named is an API key.
    [[ -z "$auth" && -n "$key" ]] && auth="apikey"
    _MMRY_FND_ID_AUTH="$auth"
    _MMRY_FND_ID_URL_GIVEN=0
    [[ -n "$url" ]] && _MMRY_FND_ID_URL_GIVEN=1
    [[ -n "$url" ]] || url="$_MMRY_FND_DEFAULT_URL"
    _mmry_fnd_key_tolower_v "$url"; url="$_MMRY_FND_LOWER"
    while [[ "$url" == */ && ${#url} -gt 1 ]]; do url="${url%/}"; done
    _MMRY_FND_ID_URL="$url"
    _MMRY_FND_ID_KEY="$key"
}

# THE KEY, into _MMRY_FND_ACCT. Recomputed only when the identity it was computed from has changed, so
# a handler that asks many times pays once.
mmry_foundation_account_key_v() {
    mmry_foundation_identity_v
    local id="${_MMRY_FND_ID_URL}"$'\n'"${_MMRY_FND_ID_KEY}"
    if [[ -z "$_MMRY_FND_ACCT" || "$_MMRY_FND_ACCT_FOR" != "$id" ]]; then
        mmry_foundation_hash_v "$id"
        _MMRY_FND_ACCT="$_MMRY_FND_HASH"
        _MMRY_FND_ACCT_FOR="$id"
    fi
}

# The printing form, for a caller that takes it by command substitution (tests, mostly).
mmry_foundation_account_key() {
    mmry_foundation_account_key_v
    printf '%s' "$_MMRY_FND_ACCT"
}

# The two keyed names, for callers that have only this file: "<dir>/mmry-foundation-set.<key>.md" and
# "<dir>/mmry-foundation.session.<key>". mmry-client.sh's mmry_foundation_set_path and
# mmry_foundation_session_path are these, with the client's temp directory as the default.
mmry_foundation_set_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_SET_NAME="${1}/mmry-foundation-set.${_MMRY_FND_ACCT}.md"
}
mmry_foundation_session_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_SESSION_NAME="${1}/mmry-foundation.session.${_MMRY_FND_ACCT}"
}

# WHETHER THE IDENTITY IS WHOLE (#32915): a credential AND a server address this session was actually
# given, by the environment or by its config. The default server is applied above so that the set's
# name stays stable for a config that never named one; but a session that could name neither a key nor
# a server cannot say WHOSE startup memories it would be loading, and session-start.sh then delivers
# nothing rather than guess. Independent QA of #32889 asked for exactly that (requirement 3 of #32915:
# no key, or an empty server address, delivers nothing, and no shared file is read).
mmry_foundation_identity_known_v() {
    mmry_foundation_identity_v
    local given="$_MMRY_FND_ID_URL_GIVEN"
    # When mmry-client.sh has loaded the config in this shell it has already put its default server
    # into MMRY_API_URL, so whether one was GIVEN is what it recorded at that moment, not what the
    # environment holds now. A caller without the client (the per-prompt supervisor) has no record
    # and the scan above decides.
    [[ -n "${_MMRY_CFG_URL_GIVEN:-}" ]] && given="$_MMRY_CFG_URL_GIVEN"
    [[ -n "$_MMRY_FND_ID_KEY" && "$given" == 1 ]]
}

# WHETHER THE CREDENTIAL IS AN API KEY (#32915, QA round 2, F-C), the other half of the question
# SessionStart asks before it loads anything (MMRY_AUTH_METHOD must be "apikey"). The set's name
# hashes the server address and the credential STRING, whatever the method, so an API-key session
# stores a set at the very name an OAuth session configured with that string computes; the
# per-prompt supervisor asked only whether the server was given, and served that set to a session
# SessionStart had refused (QA probe4). The method comes from the environment, else the same text
# scan of the config as above, with the client's rule that a credential with no method named is an
# API key: the same answer the client gives once it has loaded the config, with no process.
mmry_foundation_auth_apikey_v() {
    mmry_foundation_identity_v
    [[ "$_MMRY_FND_ID_AUTH" == "apikey" ]]
}

# THE STARTUP MEMORIES FILE (#32915): "<dir>/mmry-memories.<key>.<session id>.md", or without the
# session part when no usable id is given. This is the file SessionStart writes every startup memory
# to and tells the model to read. It was one machine-wide name, mmry-memories.md, and when another
# account's session started on the machine before this session's model had opened it, the model read
# that account's memories (QA of #32889, NEW-1; seen in practice on 2026-10-10). The account is in
# the name so that two accounts never share one; the session is in the name so that two sessions of
# one account do not replace each other's file either. The id is filtered as mmry_foundation_sid in
# mmry-client.sh filters it: only characters safe in a file name, and no dot, else no id at all.
mmry_foundation_memories_name_v() {
    local sid="${2:-}"
    [[ "$sid" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || sid=""
    mmry_foundation_account_key_v
    _MMRY_FND_MEMORIES_NAME="${1}/mmry-memories.${_MMRY_FND_ACCT}${sid:+.$sid}.md"
}

# THE FOUNDATION WORKING FILES, NAMED THE SAME WAY (#32915, QA of #32889 NEW-2 and NEW-3). The
# per-prompt hook's failure log, its refresh throttle stamp and refresh lock, and the by-reference
# copy it makes for a set too large to show, were machine-wide names: one account's throttle could
# hold another's refresh for up to 300 s, and with no session id and no marker the by-reference copy
# fell back to one shared mmry-foundation.byref.md. Each is now the account's own.
mmry_foundation_log_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_LOG_NAME="${1}/mmry-foundation.${_MMRY_FND_ACCT}.log"
}
mmry_foundation_refresh_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_REFRESH_NAME="${1}/.mmry-foundation-refresh.${_MMRY_FND_ACCT}"
}
mmry_foundation_refresh_checked_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_REFRESH_CHECKED_NAME="${1}/.mmry-foundation-refresh-checked.${_MMRY_FND_ACCT}"
}
# "<dir>/mmry-foundation.byref.<key>.<session id or token>.md", or without the last part when the
# caller has neither: still the account's own, never a shared name.
mmry_foundation_byref_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_BYREF_NAME="${1}/mmry-foundation.byref.${_MMRY_FND_ACCT}${2:+.$2}.md"
}

# WHAT THE SERVICE LAST SAID ABOUT ONE MOMENT'S SET (#33480, DD-172), named by the account and server
# like the set itself: "<dir>/mmry-foundation-moment.<key>.<moment>". One line, written when the
# plugin asks for a moment's memories: how many, their size as the Foundation Memories page counts it,
# whether that is over the size the service reports above, and, when none is chosen for the moment,
# how many Foundation memories the account has. The status check reads it; it needs no network.
mmry_foundation_moment_report_name_v() {
    mmry_foundation_account_key_v
    _MMRY_FND_MOMENT_REPORT_NAME="${1}/mmry-foundation-moment.${_MMRY_FND_ACCT}.${2:-none}"
}

# THE SESSION PART OF A PER-SESSION MARKER'S NAME (#32915, independent QA of round 1, requirement 2;
# #33363), into _MMRY_FND_SESSION_PART. The per-prompt hook's prepared copy, claim, result and stored
# markers are named by the session: the payload's id, else the token SessionStart left, which is the
# literal "unknown" for a session that had no id from anywhere. The delivery record, the per-part
# outcomes and the notice markers are named by the payload's id alone. "unknown", or no id at all, is
# a name every id-less session on the machine would use, whatever its account, so QA's probe saw
# account B's prompt replace account A's prepared copy, directive text and all, at
# .mmry-foundation-prepared.unknown; #32915 put the account key in front of those two.
#
# THE ACCOUNT KEY IS IN FRONT OF A REAL ID TOO (#33363, DD-176). #32915 took a real id to be unique
# to its session and let it stand alone. It is not: a session resumed under a second account, or an
# id passed in by hand, gives two accounts one id, and QA round 2 of #32915 (security scenario G)
# saw account B's prompt overwrite account A's prepared copy with 60 of B's lines at
# .mmry-foundation-prepared.<sid>. Every per-session name is built from this one function, so the
# key here covers every one of them: <key>.<sid>, <key>.unknown or <key>.none. The names an older
# plugin left under the bare id are never read again, by this account or any other (the stamp inside
# them is the session id, which the second account shares, so nothing in them proves whose they are);
# they go with session-start.sh's seven-day sweep. The id is filtered as mmry_foundation_sid filters
# it: only characters safe in a file name, no dot, else no id at all. The key is sixteen hex
# characters and the id at most a hundred, so the longest name stays well inside every platform's
# limit, as the by-reference copy's name (mmry-foundation.byref.<key>.<sid>.md) already did.
#   mmry_foundation_session_part_v [sid-or-token]   -> <key>.<sid>, or <key>.unknown, or <key>.none
mmry_foundation_session_part_v() {
    local v="${1:-}"
    [[ "$v" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || v=""
    mmry_foundation_account_key_v
    _MMRY_FND_SESSION_PART="${_MMRY_FND_ACCT}.${v:-none}"
}

# THE FULL BEFORE-SHORTENING SET, WHEN IT IS TOO LARGE TO PRINT IN PARTS (#33480). Per session, so its
# name is built by mmry_foundation_session_part_v like every per-session name (#33363): never the bare
# session id. "<dir>/mmry-foundation-shortening.<key>.<sid or none>.md".
mmry_foundation_shortening_name_v() {
    mmry_foundation_session_part_v "${2:-}"
    _MMRY_FND_SHORTENING_NAME="${1}/mmry-foundation-shortening.${_MMRY_FND_SESSION_PART}.md"
}
