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

# The repository convention, which file-integrity.bats enforces, put back the way the caller had it:
# the per-prompt hook runs without errexit on purpose, because nothing in Foundation re-injection may
# fail a prompt, and this file is sourced by it first of all (the same dance as lib-foundation-switch.sh).
_mmry_fkey_had_errexit=0
case "$-" in *e*) _mmry_fkey_had_errexit=1 ;; esac
set -euo pipefail
(( _mmry_fkey_had_errexit )) || set +e
unset _mmry_fkey_had_errexit

# The default the client applies when nothing names a server (mmry-client.sh, _MMRY_DEFAULT_URL).
_MMRY_FND_DEFAULT_URL="https://mmryai.com"

_MMRY_FND_HASH=""
_MMRY_FND_ID_URL=""
_MMRY_FND_ID_KEY=""
_MMRY_FND_CFG=""
_MMRY_FND_ACCT=""
_MMRY_FND_ACCT_FOR=""

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
    elif [[ "${MMRY_HOST:-}" != "codex" && -n "${HOME:-}" && -f "${HOME}/.claude/mmry-config.json" ]]; then
        _MMRY_FND_CFG="${HOME}/.claude/mmry-config.json"
    fi
}

# The server and account this process is configured for, into _MMRY_FND_ID_URL and _MMRY_FND_ID_KEY.
# Environment first, then the config file, then the client's default URL; the key is empty when nothing
# names one (an unconfigured session, which has no copy to read anyway). The URL is lowercased and
# stripped of trailing slashes so that two spellings of one server are one key.
mmry_foundation_identity_v() {
    local url="${MMRY_API_URL:-}" key="${MMRY_API_KEY:-}" txt=""
    if [[ -z "$url" || -z "$key" ]]; then
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
        fi
    fi
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
