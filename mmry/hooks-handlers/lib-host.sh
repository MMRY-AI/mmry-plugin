#!/usr/bin/env bash
# lib-host.sh - resolve which assistant this plugin is running inside, and where its files live.
#
# WHY THIS EXISTS (#31245). Twenty-eight handler scripts and the installer were written when there
# was exactly one host, so "the config directory" and "~/.claude" were the same sentence. Adding
# OpenAI Codex as a second host means every one of those places has to answer a question it never
# had to ask. This file is the single place that answers it.
#
# THE GOVERNING RULE: THE CLAUDE CODE ANSWER MUST NOT CHANGE. Requirement 4 of #31245 is that the
# existing Claude Code experience is preserved unchanged while these scripts are reworked. Every
# function below returns, for the default host, exactly the literal string the caller used to have
# hard-coded. That is not a convention, it is the acceptance criterion, and tests/unit/lib-host.bats
# asserts it string by string so a future edit that drifts the Claude path fails rather than ships.
#
# HOST DETECTION IS DECLARED FIRST, AND OTHERWISE READ OFF THIS FILE'S OWN LOCATION. MMRY_HOST is
# set by the Codex entry point (codex-hook.sh); when it is absent the block below asks whether this
# copy of the plugin is installed inside a Codex home, which is a fact about the install rather
# than a guess about the machine.
#
# It is deliberately NOT inferred from the presence of CODEX_HOME in the environment or a codex
# binary on PATH. A developer who has Codex installed still runs Claude Code sessions, and a
# resolver that guessed from the machine would relocate that developer's Claude config the day they
# installed the other product. Anything that is neither declared nor installed under a Codex home
# is Claude Code, which is the behaviour every existing install already has.

# set -euo pipefail is the repository convention for every script in this directory
# (structural/file-integrity.bats enforces it). It is safe in a sourced library here because
# every conditional below is written as an `if` or as a `&&` list, both of which bash exempts
# from -e, so a false test can never terminate the shell that sourced this file.
set -euo pipefail

# Guard against double-sourcing. Handlers source this both directly and transitively.
[[ -n "${_MMRY_LIB_HOST_SOURCED:-}" ]] && return 0
_MMRY_LIB_HOST_SOURCED=1

# ---------------------------------------------------------------------------------------------
# WHEN NOBODY DECLARED A HOST, THIS FILE'S OWN LOCATION IS THE ANSWER.
#
# The scripts a customer's assistant runs are NOT run through codex-hook.sh. session-init.sh copies
# every handler into the host's MMRY directory, and the model then invokes, say,
# ~/.codex/mmry/hooks-handlers/save-memory.sh in a shell of its own where MMRY_HOST is not set and
# never will be.
#
# Before this block that was a silent defect, reproduced on 2026-09-15: sourcing mmry-client.sh
# from the Codex copy with no MMRY_CONFIG_FILE resolved the credential at
# ${HOME}/.claude/mmry-config.json - the OTHER product's. On a machine with both installed a Codex
# save went out under whatever account the Claude file named; on a Codex-only machine there is no
# such file, so every model-invoked save failed with "No API key configured. Run /mmry:setup",
# naming a command Codex customers cannot type.
#
# THIS IS A LOCATION TEST, NOT MACHINE SNIFFING. It asks where this copy of the file is installed,
# which is a fact about the install, not a guess about the machine. A Claude Code install lives
# under ${HOME}/.claude or the Claude plugin cache and is unaffected; the check below can only ever
# answer "codex" for a file sitting inside a Codex home.
# PUT A PATH IN ONE SPELLING, SO THAT TWO OF THEM CAN BE COMPARED (#31245 QA round 3).
#
# The prefix test below compares a path this file derived with `pwd` against one a customer or
# Codex put in CODEX_HOME. On Windows those are routinely different spellings of the same
# directory: `pwd` under Git Bash answers /c/Users/x/codexhome while CODEX_HOME is very likely
# C:\Users\x\codexhome. The previous version flipped the backslashes and stopped there, so
# "C:/Users/x/codexhome" was still compared against "/c/Users/x/codexhome" and never matched - the
# variable was set, the customer had done everything right, and the comparison was dead. Reproduced
# on 2026-09-16 with sentinel credentials: the handler resolved the host as Claude and loaded the
# other product's key.
#
# The string half is its own function so it can be tested on a machine where cygpath exists and
# would otherwise mask it. It is also the only half Linux and macOS ever run.
# Lowercase an ASCII string with no process at all. `tr` is a fork, and on Windows Git Bash a
# fork measured ~300 ms; this is on the per-prompt path (#31245 QA round 4). bash 3.2, which
# macOS still ships, has no ${x,,}, so the mapping is done by hand: the index of the character
# within the uppercase alphabet is the length of the prefix before it, and a character that is
# absent leaves the alphabet unchanged at length 26. Same technique, and the same reason, as
# _mmry_tolower in userpromptsubmit-foundation.sh.
# It RETURNS THROUGH A GLOBAL rather than by printing, because `$(f)` is a fork and forks are
# the entire thing being avoided. bash 3.2 has no namerefs, so a well-known output variable is
# the portable way to get a value out of a function for free.
_MMRY_LC=""
_mmry_host_tolower() {
    local s="$1" out="" c pre i=0
    local up="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lo="abcdefghijklmnopqrstuvwxyz"
    while (( i < ${#s} )); do
        c="${s:i:1}"
        pre="${up%%"$c"*}"
        if (( ${#pre} < 26 )); then out="${out}${lo:${#pre}:1}"; else out="${out}${c}"; fi
        i=$(( i + 1 ))
    done
    _MMRY_LC="$out"
}

# A TRAILING SEPARATOR IS NOT PART OF THE PATH, IN EITHER SPELLING (#31245 QA round 4).
# The loop below stripped a trailing "/" but the flip above now feeds it a trailing backslash
# too, so CODEX_HOME=C:\Users\x\codexhome\ normalises the same as without it.
_mmry_norm_path_str() {
    local p="${1//\\//}"
    if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
        local _d="${BASH_REMATCH[1]}" _r="${BASH_REMATCH[2]:-/}"
        _mmry_host_tolower "$_d"
        p="/${_MMRY_LC}${_r}"
    fi
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    printf '%s' "$p"
}

# WINDOWS PATHS ARE CASE-INSENSITIVE, AND THE COMPARISON HAS TO BE TOO (#31245 QA round 4).
#
# The normaliser above handles separators and the drive letter but not SEGMENT case, so
# CODEX_HOME=c:\users\x\codexhome normalised to /c/users/x/codexhome while `pwd` answered
# /c/Users/x/codexhome. The same directory - on a filesystem where those are not merely
# equivalent spellings but literally the same name - and the prefix test compared them byte for
# byte, failed, and the handler resolved the host as Claude and loaded the Claude credential.
#
# Case is folded ONLY where the platform is genuinely case-insensitive. On Linux /home/A and
# /home/a are different directories, and folding them would let this resolver claim a Codex
# install that is not there. $OSTYPE is a bash variable, so asking costs nothing.
_mmry_host_ci_paths() {
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) return 0 ;;
    esac
    return 1
}

# "a is b, or a is inside b", for two already-normalised paths, honouring the platform's case
# rules. Returns 0 on match.
_mmry_path_is_within() {
    local a="$1" b="$2"
    if _mmry_host_ci_paths; then
        _mmry_host_tolower "$a"; a="$_MMRY_LC"
        _mmry_host_tolower "$b"; b="$_MMRY_LC"
    fi
    [[ "$a" == "$b" || "$a" == "${b}"/* ]]
}

_mmry_norm_path() {
    local p="$1"
    # AND WHERE THE MOUNT TABLE MATTERS, ASK THE TOOL THAT HAS IT. Under Git Bash
    # C:\Users\x\AppData\Local\Temp\t and /tmp/t are the same directory, and no amount of string
    # surgery will make those two match. cygpath knows; when it is absent - Linux, macOS - the
    # string form above is the whole answer and is correct there.
    if [[ "$p" == *\\* || "$p" =~ ^[A-Za-z]: ]] && command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    _mmry_norm_path_str "$p"
}

if [[ -z "${MMRY_HOST:-}" ]]; then
    # ONE FORK, NOT TWO (#31245 QA round 4). This used to be
    # `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`, two nested command substitutions on a
    # path that is very often already absolute. Handlers source this file as
    # "${HANDLER_DIR}/lib-host.sh" with HANDLER_DIR already resolved, so the common case needs
    # no process at all. `cd`/`pwd` is kept for the relative and dot-laden spellings, where it
    # is doing real work rather than restating what we were handed.
    _mmry_self_dir="${BASH_SOURCE[0]%/*}"
    [[ "$_mmry_self_dir" == "${BASH_SOURCE[0]}" ]] && _mmry_self_dir="."
    # The dot tests match "." and ".." as whole SEGMENTS. They must not match a hidden
    # directory: nearly every path this file sees contains "/.claude" or "/.codex", and a
    # pattern like */.* matches those, which would fork on exactly the paths this is for.
    _mmry_needs_resolve=0
    [[ "$_mmry_self_dir" != /* && ! "$_mmry_self_dir" =~ ^[A-Za-z]: ]] && _mmry_needs_resolve=1
    case "/${_mmry_self_dir//\\//}/" in
        */./*|*/../*) _mmry_needs_resolve=1 ;;
    esac
    if (( _mmry_needs_resolve == 1 )); then
        _mmry_self_dir="$(cd "$_mmry_self_dir" && pwd 2>/dev/null)" || _mmry_self_dir=""
    fi
    if [[ -n "$_mmry_self_dir" ]]; then
        _mmry_self_dir="$(_mmry_norm_path "$_mmry_self_dir")"

        # 1. THE MARKER THE INSTALL WROTE ABOUT ITSELF, WHICH IS THE ONLY ANSWER THAT SURVIVES A
        #    RELOCATED HOME NOBODY EXPORTED.
        #
        # The two tests after this one are guesses read off a path, and both fail on the install a
        # customer is most likely to have: a Codex home moved somewhere with no ".codex" segment,
        # in a shell where CODEX_HOME is not set. Codex sets CODEX_HOME for its own hook processes;
        # the shell the MODEL runs save-memory.sh in is not one of those, and that is the shell
        # every model-invoked handler runs in. Reproduced on 2026-09-16: the handler resolved the
        # host as Claude and loaded the Claude account's key.
        #
        # session-init.sh knows the answer - it runs as a Codex hook, with MMRY_HOST set, at the
        # moment it copies these files - so it writes the answer down beside them. Reading it back
        # is not a guess about the machine; it is the install stating what it is.
        #
        # ONLY "codex" IS ACTED ON. A marker reading "claude", an empty marker, a directory, or no
        # marker at all all leave MMRY_HOST unset, which is the answer every existing Claude Code
        # install already has. head -c bounds what a corrupt or hostile file can do.
        _mmry_marker="${_mmry_self_dir}/../.mmry-host"
        if [[ -f "$_mmry_marker" ]]; then
            # READ WITH NO PROCESS AT ALL (#31245 QA round 4). This was
            # `head -c 64 ... | head -1 | tr -d '[:space:]'` - three forks and a pipeline, paid
            # on EVERY hook firing on EVERY install, because session-init.sh writes this marker
            # for both hosts and a Claude install therefore has one. `read` is a builtin; it
            # stops at the first newline by itself, and the substring bounds what a corrupt or
            # hostile file can do exactly as head -c 64 did. The trailing strip covers the CR of
            # a CRLF file and any stray spaces, which is all `tr -d` was achieving here.
            _mmry_marker_host=""
            read -r _mmry_marker_host < "$_mmry_marker" 2>/dev/null || _mmry_marker_host=""
            _mmry_marker_host="${_mmry_marker_host:0:64}"
            _mmry_marker_host="${_mmry_marker_host//[[:space:]]/}"
            if [[ "$_mmry_marker_host" == "codex" ]]; then
                MMRY_HOST="codex"
                # AND WHERE, NOT JUST WHICH. The marker sits at <config-dir>/mmry/.mmry-host, so
                # its own location names the config directory - which is the part CODEX_HOME would
                # otherwise have had to supply. Without this, a relocated home resolved the host
                # correctly and then looked for the credential in ~/.codex, where there is none,
                # and refused. Two directories up from the marker is where these files actually
                # are, which beats any guess.
                _MMRY_HOST_DIR_FROM_MARKER="$(cd "${_mmry_self_dir}/../.." && pwd 2>/dev/null)" || _MMRY_HOST_DIR_FROM_MARKER=""
                [[ -n "$_MMRY_HOST_DIR_FROM_MARKER" ]] && export _MMRY_HOST_DIR_FROM_MARKER
            fi
        fi

        # 2. AN EXPORTED CODEX_HOME THIS FILE SITS INSIDE.
        if [[ -z "${MMRY_HOST:-}" && -n "${CODEX_HOME:-}" ]]; then
            _mmry_codex_home="$(_mmry_norm_path "$CODEX_HOME")"
            if [[ -n "$_mmry_codex_home" && "$_mmry_codex_home" != "/" ]]; then
                # Case-folded on Windows, byte-exact elsewhere. A lowercase spelling of
                # CODEX_HOME used to miss here and silently resolve the host as Claude
                # (#31245 QA round 4).
                if _mmry_path_is_within "$_mmry_self_dir" "$_mmry_codex_home"; then
                    MMRY_HOST="codex"
                fi
            fi
        fi

        # 3. The default Codex home, and any path segment that is literally ".codex".
        [[ -z "${MMRY_HOST:-}" && "$_mmry_self_dir" == */.codex/* ]] && MMRY_HOST="codex"
    fi
    unset _mmry_self_dir _mmry_codex_home _mmry_marker _mmry_marker_host 2>/dev/null || true
fi

# ---------------------------------------------------------------------------------------------
# THE ANSWERS ARE COMPUTED ONCE, NOT ONCE PER QUESTION (#31245 QA round 4).
#
# WHY. Every accessor below used to be written as `[[ "$(mmry_host)" == "codex" ]]`, and
# mmry_host_state_dir was `printf '%s/mmry' "$(mmry_host_config_dir)"`. Command substitution is a
# fork. So a single `$(mmry_host_state_dir)` in hook-guard.sh cost THREE nested forks, and on
# Windows Git Bash a fork measured ~300 ms. Measured end to end, hook-guard.sh went from 205 ms
# to 1026 ms - a five times regression paid by every existing Claude Code customer, for a second
# host they do not have. That is a requirement-4 cost, not a rounding error.
#
# The recompute is keyed on the inputs rather than done once at source time, so a caller that
# changes MMRY_HOST or CODEX_HOME after sourcing still gets a correct answer - which the test
# suite and mmry-setup.sh both rely on. Comparing the key is string work in the current shell:
# no process, no subshell.
_MMRY_HOST_KEY=$'\x01unset'
_MMRY_HOST_V=""; _MMRY_HOST_DIR_V=""; _MMRY_HOST_CLIENT_V=""; _MMRY_HOST_LABEL_V=""

_mmry_host_resolve() {
    local key="${MMRY_HOST:-}|${CODEX_HOME:-}|${HOME:-}|${_MMRY_HOST_DIR_FROM_MARKER:-}"
    [[ "$key" == "$_MMRY_HOST_KEY" ]] && return 0
    _MMRY_HOST_KEY="$key"
    case "${MMRY_HOST:-}" in
        codex) _MMRY_HOST_V="codex" ;;
        *)     _MMRY_HOST_V="claude" ;;
    esac
    if [[ "$_MMRY_HOST_V" == "codex" ]]; then
        # The install marker's own location first, when there is one: it is where these files
        # demonstrably are, rather than where a variable says they should be. CODEX_HOME next,
        # because it is Codex's documented override and the only signal available to a copy
        # running from the plugin cache. The default last (#31245 QA round 3).
        if [[ -n "${_MMRY_HOST_DIR_FROM_MARKER:-}" ]]; then
            _MMRY_HOST_DIR_V="${_MMRY_HOST_DIR_FROM_MARKER}"
        else
            _MMRY_HOST_DIR_V="${CODEX_HOME:-${HOME}/.codex}"
            # A TRAILING SEPARATOR IS NOT PART OF THE DIRECTORY (#31245 QA round 4). A customer
            # who set CODEX_HOME=C:\Users\x\codexhome\ - which is what tab-completion in cmd
            # hands you - produced a credential path of "...\codexhome\/mmry-config.json".
            # Stripped in BOTH spellings, and never down to nothing.
            while [[ "$_MMRY_HOST_DIR_V" == */ || "$_MMRY_HOST_DIR_V" == *\\ ]]; do
                [[ "${#_MMRY_HOST_DIR_V}" -le 1 ]] && break
                _MMRY_HOST_DIR_V="${_MMRY_HOST_DIR_V%[/\\]}"
            done
        fi
        _MMRY_HOST_CLIENT_V="codex"
        _MMRY_HOST_LABEL_V="Codex"
    else
        _MMRY_HOST_DIR_V="${HOME}/.claude"
        _MMRY_HOST_CLIENT_V="claude-code"
        _MMRY_HOST_LABEL_V="Claude Code"
    fi
}

# The host this process is serving. "claude" or "codex"; anything else is treated as "claude".
mmry_host() {
    _mmry_host_resolve
    printf '%s' "$_MMRY_HOST_V"
}

# The host's own configuration directory - the one the host itself owns, not one MMRY invents.
#
# Claude Code: ${HOME}/.claude, which is what every caller hard-coded before this file existed.
# Codex:       ${CODEX_HOME} when the host set it, else ${HOME}/.codex. CODEX_HOME is Codex's own
#              documented override (codex exec --ignore-user-config: "auth still uses CODEX_HOME"),
#              so honouring it is how a customer who relocated their Codex home gets MMRY in the
#              place they put it rather than in the place we assumed.
mmry_host_config_dir() {
    _mmry_host_resolve
    printf '%s' "$_MMRY_HOST_DIR_V"
}

# Where session-init.sh copies the handler scripts to, and where hook-guard.sh looks for them.
# This is MMRY's own subdirectory of the host config directory.
mmry_host_state_dir() {
    _mmry_host_resolve
    printf '%s/mmry' "$_MMRY_HOST_DIR_V"
}

# The credential file. mmry-client.sh already discovers ${MMRY_CONFIG_FILE} ahead of any hard-coded
# path, which is why the client needs no edit to serve a second host: the Codex entry point exports
# this value and the client finds it first.
mmry_host_config_file() {
    _mmry_host_resolve
    printf '%s/mmry-config.json' "$_MMRY_HOST_DIR_V"
}

# What this host calls itself when a session is registered with the API. This shows up in the
# customer's own session list, so it has to be the truth rather than a default: a Codex session
# listed as "claude-code" is a session the customer cannot find.
mmry_host_client_name() {
    _mmry_host_resolve
    printf '%s' "$_MMRY_HOST_CLIENT_V"
}

# The product name as a customer reads it, for messages the model relays to them.
mmry_host_label() {
    _mmry_host_resolve
    printf '%s' "$_MMRY_HOST_LABEL_V"
}

# The setup command to tell a customer to run, as a literal string they can copy.
# Home is spelled "~" rather than expanded because this is display text, not a path to execute.
# THE HINT IS DERIVED FROM THE DIRECTORY, NOT GUESSED ALONGSIDE IT (#31245 QA round 4).
#
# This used to print a hardcoded "~/.codex/mmry/setup/mmry-setup.sh". The refusal message that
# carries it prints the REAL config path on the line above, so for the one customer this whole
# feature exists for - the relocated Codex home - the message contradicted itself: "looked for
# D:/work/codexhome/mmry-config.json", then "create it: bash ~/.codex/mmry/setup/mmry-setup.sh",
# a path that does not exist on that machine. Following the instruction produced "No such file or
# directory", and the customer had no way to know the first line was the true one.
#
# Both lines now come from the same resolved directory, so they cannot disagree.
#
# "~" IS STILL USED WHERE IT IS HONEST. When the config dir is exactly the default under $HOME,
# the tilde spelling is the friendlier one and is the literal every existing message carried; the
# Claude string is unchanged byte for byte, which tests/unit/lib-host.bats asserts. Anywhere else
# the absolute path is printed, because that is the one that works when pasted.
mmry_host_setup_hint() {
    _mmry_host_resolve
    local dir="$_MMRY_HOST_DIR_V" shown
    if [[ -n "${HOME:-}" && "$dir" == "${HOME}/"* ]]; then
        shown="~/${dir#"${HOME}/"}"
    else
        shown="$dir"
    fi
    printf 'bash %s/mmry/setup/mmry-setup.sh' "$shown"
}

# How the model should refer to MMRY's own scripts in text it is asked to act on.
#
# This one is not cosmetic. stop-check.sh tells the model to run
# "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh", relying on the model expanding a variable
# that exists in ITS environment. Codex does export CLAUDE_PLUGIN_ROOT to hook processes for
# compatibility (codex-rs/hooks/src/engine/discovery.rs line 267), but that is the HOOK's
# environment, not the shell the model runs its own commands in. On Codex the directive therefore
# names an absolute path resolved at hook time, which works in any shell the model reaches for.
mmry_host_script_ref() {
    # Usage: mmry_host_script_ref <script-name.sh>
    local script="$1"
    _mmry_host_resolve
    if [[ "$_MMRY_HOST_V" == "codex" ]]; then
        printf '%s/mmry/hooks-handlers/%s' "$_MMRY_HOST_DIR_V" "$script"
    else
        printf '${CLAUDE_PLUGIN_ROOT}/hooks-handlers/%s' "$script"
    fi
}

# ---------------------------------------------------------------------------------------------
# POINT THE CLIENT AT THE RIGHT CREDENTIAL, ONCE, AT SOURCE TIME.
#
# mmry-client.sh discovers its config as ${MMRY_CONFIG_FILE}, then ${CLAUDE_PLUGIN_ROOT}, then
# ${HOME}/.claude/mmry-config.json. Only the first of those can be right on a second host, and
# mmry-client.sh is not ours to change in this task. Setting it here means every consumer of the
# client - which is nearly every handler, through lib-jq.sh - resolves the correct credential
# without a single edit to the client.
#
# ON CLAUDE CODE THIS DOES NOTHING. mmry_host() is "claude", the branch is not taken, and the
# client's existing discovery order runs exactly as it always has.
_mmry_host_resolve
if [[ -z "${MMRY_CONFIG_FILE:-}" ]] && [[ "$_MMRY_HOST_V" == "codex" ]]; then
    export MMRY_CONFIG_FILE="${_MMRY_HOST_DIR_V}/mmry-config.json"
fi

# ---------------------------------------------------------------------------------------------
# AND WHEN THAT FILE IS NOT THERE, REFUSE - DO NOT LET THE CLIENT WALK ON TO THE CLAUDE FILE.
#
# Setting MMRY_CONFIG_FILE is only half an answer, and the missing half is what a sentinel found
# in QA round 2. mmry-client.sh's discovery is:
#
#     if   [[ -n "$MMRY_CONFIG_FILE" && -f "$MMRY_CONFIG_FILE" ]]   # ours, on Codex
#     elif [[ -n "$CLAUDE_PLUGIN_ROOT" && -f ".../mmry-config.json" ]]
#     elif [[ -f "${HOME}/.claude/mmry-config.json" ]]              # THE OTHER PRODUCT'S ACCOUNT
#
# The first branch tests that the file EXISTS. On a Codex install that has not been set up - or
# whose credential was moved, renamed or removed - that test is false and the chain walks on to
# the third branch, which is the Claude account. Reproduced with a sentinel key on 2026-09-16:
# the Codex copy loaded ${HOME}/.claude/mmry-config.json and would have saved this customer's
# Codex memories into whatever account that file names.
#
# mmry-client.sh cannot be edited in this task, so the refusal has to happen before it is asked
# the question. Every path that resolves a credential reaches mmry_load_config, every path that
# reaches mmry_load_config sources mmry-client.sh, and mmry-client.sh sources lib-jq.sh as its
# first executable line, which sources this file. So this function is called from there, at the
# one point every credential-resolving path in the plugin passes through.
#
# IT IS LOUD, AND IT IS NOT A CRASH. It names the host, names the file it looked for, and names
# the command that creates it. A hook that refuses this way exits 1 with a sentence on stderr,
# which Codex reports without blocking the session - unlike silently borrowing another account,
# which nothing anywhere reports.
#
# ON CLAUDE CODE IT IS A NO-OP: the host is "claude" and the function returns 0 before looking at
# anything, so the existing discovery order runs exactly as it always has.

mmry_host_credential_present() {
    _mmry_host_resolve
    [[ -f "${_MMRY_HOST_DIR_V}/mmry-config.json" ]]
}

# Return 0 to proceed, 1 to refuse. MMRY_ALLOW_NO_CREDENTIAL=1 is the documented opt-out for the
# one program that legitimately runs before a credential exists: mmry-setup.sh, which creates it.
mmry_host_assert_own_credential() {
    _mmry_host_resolve
    [[ "$_MMRY_HOST_V" == "codex" ]] || return 0
    [[ "${MMRY_ALLOW_NO_CREDENTIAL:-}" != "1" ]] || return 0
    [[ -n "${MMRY_CONFIG_FILE:-}" && -f "${MMRY_CONFIG_FILE}" ]] && return 0
    # A credential supplied through the environment is a credential. mmry_load_config only fills
    # values that are EMPTY, so a key set here cannot be replaced by one read from a file, and the
    # leak this function exists to stop cannot happen. The URL is pinned to the same default the
    # client applies, so that nothing at all is taken from the other product's file.
    if [[ -n "${MMRY_API_KEY:-}" ]]; then
        export MMRY_API_URL="${MMRY_API_URL:-https://mmryai.com}"
        return 0
    fi
    {
        printf 'MMRY AI: no %s credential was found, and MMRY will not fall back to another product'"'"'s account.
' "$(mmry_host_label)"
        printf '  looked for: %s
' "${MMRY_CONFIG_FILE:-$(mmry_host_config_file)}"
        printf '  create it:  %s
' "$(mmry_host_setup_hint)"
    } >&2
    return 1
}
