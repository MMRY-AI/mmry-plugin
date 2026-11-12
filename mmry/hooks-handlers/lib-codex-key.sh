#!/usr/bin/env bash
# lib-codex-key.sh - THE ACCOUNT KEY BEFORE ANYTHING IS LOADED, on Codex (#33617, DD-179).
#
# WHY THIS EXISTS. When a Codex session start runs past its budget its memories are handed to the
# conversation's first prompt through two files, the late marker and the hand-off (codex-hook.sh,
# codex-first-prompt.sh). Both were named by the bare session id. Two MMRY accounts on one machine can
# share a session id (a conversation resumed under a second account, an id passed by hand), and the
# independent QA of #33363 (finding S1, 2026-11-09) saw account B's first prompt handed account A's
# memories path, A's Foundation directives included, and A's hand-off consumed. #33363 had put the
# account key in front of every Foundation file's session part (lib-foundation-key.sh,
# mmry_foundation_session_part_v); this gives the two hand-off files the same part, <key>.<sid>.
#
# WHY A FILE OF ITS OWN. The two places that name those files run before anything else is loaded, on
# purpose and measured (#33062): codex-hook.sh arms the marker at its top, before lib-host.sh is
# sourced, because a marker written later reached the first prompt too late; and codex-first-prompt.sh
# loads no host, no library and no credential, because on a loaded Windows machine the path through
# them took it past its limit. Neither has lib-host.sh, which is where the Codex credential file is
# otherwise resolved. So the rule is kept HERE, once, for both, and tests/structural/
# codex-late-handoff-isolation.bats pins the key this file computes to the key lib-host.sh then
# lib-foundation-key.sh compute for the same account, so the two cannot drift unnoticed.
#
# WITH NO PROCESS AT ALL. On Windows the cost of these paths is processes (#33062 fix round 7), so this
# file is builtins only: string work, a file test, `source`, and lib-foundation-key.sh, which reads the
# config with the read builtin and hashes in bash arithmetic. The structural suite counts the processes
# of a call with a Windows job object: one, the shell itself.
#
# Functions only. bash 3.2 (the macOS bash) runs every line. Guarded against double sourcing.

[[ -n "${_MMRY_LIB_CODEX_KEY_SOURCED:-}" ]] && return 0
_MMRY_LIB_CODEX_KEY_SOURCED=1

# The repository convention, which file-integrity.bats enforces, then every option put back the way the
# caller had them, exactly as lib-foundation-key.sh does and for the same reason: codex-hook.sh sources
# this with errexit on, codex-first-prompt.sh is sourced into that shell with errexit off.
_mmry_ck_opts="$-"
_mmry_ck_pipefail=0
[[ -o pipefail ]] && _mmry_ck_pipefail=1
set -euo pipefail
case "$_mmry_ck_opts" in *e*) ;; *) set +e ;; esac
case "$_mmry_ck_opts" in *u*) ;; *) set +u ;; esac
(( _mmry_ck_pipefail )) || set +o pipefail
unset _mmry_ck_opts _mmry_ck_pipefail

_MMRY_CODEX_KEY_READY=0
_MMRY_CODEX_CFG=""
_MMRY_CODEX_SESSION_PART=""
_MMRY_CODEX_KEY=""

# lib-foundation-key.sh, from beside this file. Forward slashes first: codex-hook.cmd starts codex-hook.sh
# by its Windows path, C:\...\codex-hook.sh, and this file is found from it. Only when there is a
# backslash: bash 3.2 (macOS sh) does not read that expansion the same way. [[ -f ]] first: bash 3.2
# aborts under set -e when a sourced file is missing, even inside an if.
_mmry_ck_self="${BASH_SOURCE[0]}"
case "$_mmry_ck_self" in *\\*) _mmry_ck_self="${_mmry_ck_self//\\//}" ;; esac
[[ "$_mmry_ck_self" == */* ]] || _mmry_ck_self="./${_mmry_ck_self}"
if [[ -f "${_mmry_ck_self%/*}/lib-foundation-key.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_mmry_ck_self%/*}/lib-foundation-key.sh"
    declare -F mmry_foundation_session_part_v >/dev/null 2>&1 && _MMRY_CODEX_KEY_READY=1
fi
unset _mmry_ck_self

# THE CREDENTIAL FILE THE CODEX HOOK PATH RESOLVES AFTER lib-host.sh, BY THE SAME RULE, into
# _MMRY_CODEX_CFG. lib-host.sh (_mmry_host_resolve, and the export at its end) gives a hook on Codex
#   $MMRY_CONFIG_FILE when it is set (the documented override, which lib-host.sh leaves alone), else
#   <CODEX_HOME, else <home>/.codex>/mmry-config.json, with trailing separators stripped in both
#   spellings and never down to nothing (#31245 QA round 4).
# <home> is HOME, else what mmry_home answers (USERPROFILE, else HOMEDRIVE and HOMEPATH). The spelling
# is not normalised here, because only the file's CONTENT is hashed and bash reads a Windows spelling
# as well as a POSIX one. The one branch not mirrored is the install marker's own directory
# (_MMRY_HOST_DIR_FROM_MARKER), which lib-host.sh reaches only when MMRY_HOST was NOT exported, and
# codex-hook.sh exports it before lib-host.sh is sourced: never on a hook firing, which is the only
# place these two files are named.
# The Codex home, into _MMRY_CODEX_HOME: CODEX_HOME, else <home>/.codex, trailing separators stripped
# and never down to nothing. Shared by the credential file below and the hand-off folder (#33231).
_mmry_codex_home_v() {
    local dir home
    home="${HOME:-}"
    [[ -n "$home" ]] || home="${USERPROFILE:-}"
    if [[ -z "$home" && -n "${HOMEDRIVE:-}" && -n "${HOMEPATH:-}" ]]; then home="${HOMEDRIVE}${HOMEPATH}"; fi
    dir="${CODEX_HOME:-${home}/.codex}"
    while [[ "$dir" == */ || "$dir" == *\\ ]]; do
        [[ "${#dir}" -le 1 ]] && break
        dir="${dir%[/\\]}"
    done
    _MMRY_CODEX_HOME="$dir"
}
mmry_codex_config_file_v() {
    if [[ -n "${MMRY_CONFIG_FILE:-}" ]]; then
        _MMRY_CODEX_CFG="$MMRY_CONFIG_FILE"
        return 0
    fi
    _mmry_codex_home_v
    _MMRY_CODEX_CFG="${_MMRY_CODEX_HOME}/mmry-config.json"
}

# THE PER-USER FOLDER THE HAND-OFF LIVES IN (#33231, DD-182), into _MMRY_CODEX_DIR:
# <CODEX_HOME, else <home>/.codex>/mmry-handoff. It holds the late marker, the hand-off
# (.out/.ready/.pid/.claim), the saved payload and the two fixed-name logs that used to sit in
# ${TMPDIR:-/tmp}, where on a shared Linux machine another user could read them, plant a .ready/.out
# pair to inject text into a conversation, or put a link at a path the hook would write through
# (independent QA of #33062, new requirement 1). Under the Codex home, not the temp folder: a name
# under /tmp could be squatted by another user before the owner's first start, and USER and LOGNAME,
# which could name a per-user temp folder, are not reliably set in a hook. Beside ~/.codex/mmry, not
# inside it: self-update prunes that tree against release-files.txt. MMRY_CONFIG_FILE is deliberately
# NOT consulted: the sh gate in hooks/codex-hooks.json and codex-hook.cmd resolve this same folder from
# CODEX_HOME and HOME alone, with no process, so the rule must need nothing else.
mmry_codex_private_dir_v() {
    _mmry_codex_home_v
    _MMRY_CODEX_DIR="${_MMRY_CODEX_HOME}/mmry-handoff"
}

# WHETHER THE FOLDER IS THE CALLER'S OWN: a directory, not a link, owned by the effective user
# (-d, ! -L, -O: builtins, no process). Anything else is refused, and the caller arms, writes and
# reads NOTHING there, and falls back to no other folder. Another user cannot write into a 700
# folder the owner made; a folder they made first is not the owner's; a link is refused wherever it
# stands. Reading only: the first prompt has nothing to read where there is no folder.
mmry_codex_private_dir_ok() {
    local d="${_MMRY_CODEX_DIR:-}"
    [[ -n "$d" && -d "$d" && ! -L "$d" && -O "$d" ]]
}

# THE FOLDER, CREATED EXCLUSIVELY WITH OWNER-ONLY PERMISSIONS WHEN IT IS ABSENT, then checked as above.
# mkdir -m 700 without -p: it fails if the name exists, so a name squatted between the test and the
# create is never adopted, and it is the one process this costs, once per user, never on a later
# start (the folder persists under the home). A name that exists and is not the owner's directory is
# refused as it stands; nothing is removed or replaced.
mmry_codex_private_dir_ready() {
    local d="${_MMRY_CODEX_DIR:-}"
    [[ -n "$d" ]] || return 1
    if [[ ! -e "$d" && ! -L "$d" ]]; then
        mkdir -m 700 "$d" 2>/dev/null || return 1
    fi
    mmry_codex_private_dir_ok
}

# WHETHER ONE FILE IN IT IS THE CALLER'S OWN: a regular file, not a link, owned by the effective user.
mmry_codex_own_file() {
    [[ -n "${1:-}" && -f "$1" && ! -L "$1" && -O "$1" ]]
}

# <key>.<sid> FOR THE CODEX ACCOUNT THIS HOOK SERVES, into _MMRY_CODEX_SESSION_PART, and the key alone
# into _MMRY_CODEX_KEY: mmry_foundation_session_part_v, the function that names every Foundation file,
# computed from the credential file above. MMRY_CONFIG_FILE and MMRY_HOST are set for the call only
# (local to this function), so the caller's environment is left as it was and lib-host.sh, sourced
# later by codex-hook.sh, still applies its own rule and makes its own export. MMRY_HOST is "codex" for
# the call so that lib-foundation-key.sh never falls back to the Claude Code account's file (#31245
# TC6). With no credential file at all the key is the client's default identity, as the Foundation
# path's is: two unconfigured accounts are one identity, and there is nothing to keep apart.
#
# Returns 1 when lib-foundation-key.sh could not be loaded, and (#33620) when the identity it names is
# REFUSED, a control character in the server address or the sign-in, which gives no key at all. A
# caller then has no key, and must arm or read NOTHING rather than fall back to a bare name, which
# would be the defect under another spelling.
#   mmry_codex_session_part_v <sid>
mmry_codex_session_part_v() {
    (( _MMRY_CODEX_KEY_READY == 1 )) || return 1
    mmry_codex_config_file_v
    local MMRY_CONFIG_FILE="$_MMRY_CODEX_CFG" MMRY_HOST="codex"
    mmry_foundation_session_part_v "${1:-}"
    _MMRY_CODEX_SESSION_PART=""
    _MMRY_CODEX_KEY=""
    [[ -n "$_MMRY_FND_ACCT" && -n "$_MMRY_FND_SESSION_PART" ]] || return 1
    _MMRY_CODEX_SESSION_PART="$_MMRY_FND_SESSION_PART"
    _MMRY_CODEX_KEY="$_MMRY_FND_ACCT"
}
