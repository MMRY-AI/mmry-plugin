#!/usr/bin/env bash
# precompact-foundation.sh - PreCompact hook, Claude Code only (#33480, DD-172).
#
# Sends the Foundation memories the account chose for "before a long conversation is shortened",
# just before Claude Code condenses its own history, so they are kept in the summary it writes.
#
# HOW IT REACHES THE MODEL. When a PreCompact hook exits 0 and does not block, Claude Code uses its
# stdout as instructions for the compaction summary, and cuts each hook's stdout at 10,000
# characters (code.claude.com/docs/en/hooks, "PreCompact output"). So this prints plain text, never
# JSON, always exits 0, and is registered once per part in hooks/hooks.json, as the per-prompt hook
# is: --part 1 .. --part 6, each printing at most 9,500 characters of the set beside its heading, so
# a set the per-prompt hook could send in full is sent in full here too.
#
# WHAT IT SENDS. Exactly what the service answers for the moment: GET
# /api/memories/foundation?moment=before-shortening. Nothing here chooses among the memories, and
# nothing is cut out of them. The parts are cut where the per-prompt hook's parts are, by
# foundation-cut.awk, and rejoin to the whole set. A set too large for six parts, or one the
# service reports as over its size line, is written whole to one file for this session and the
# summary is told to keep the instruction to read it; the size is said in the same words the
# Foundation Memories page and the status check use. Nothing is trimmed at any size (#31411).
#
# CODEX HAS NO SUCH MOMENT. Codex gives a plugin no signal before it shortens a conversation, so
# hooks/codex-hooks.json registers nothing for this, and this file does nothing if run there.
#
# A FAILED REQUEST IS SAID, NOT GUESSED AT. Part 1 says the directives could not be fetched and
# nothing was added; no cached set stands in for the service's answer.
#
# -e is turned straight back off on the next line: a hook that fails must never fail compaction. The
# full form is written first because the repository's structural check requires every handler to
# declare it (file-integrity.bats).
set -euo pipefail 2>/dev/null || true
set +e

MMRY_FND_PART=1
if [[ "${1:-}" == "--part" && "${2:-}" =~ ^[1-9][0-9]*$ ]]; then MMRY_FND_PART="$2"; fi
_PCF_PARTS_MAX=6
_PCF_PART_CAP=9500

_pcf_self="${BASH_SOURCE[0]//\\//}"
case "$_pcf_self" in
    */hooks-handlers/precompact-foundation.sh) PLUGIN_ROOT="${_pcf_self%/hooks-handlers/precompact-foundation.sh}" ;;
    *) PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)" ;;
esac
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/lib-host.sh" >/dev/null 2>&1 || exit 0
set +e
mmry_host_assert_own_credential >/dev/null 2>&1 || exit 0
[[ "$(mmry_host)" == "codex" ]] && exit 0

# The payload, for this session's id: the by-reference file is named by it, through the session part
# (#33363), never by the bare id.
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/lib-hookread.sh" 2>/dev/null
_pcf_sid=""
if [[ ! -t 0 ]] && declare -F mmry_read_hook_payload >/dev/null 2>&1; then
    mmry_read_hook_payload "${MMRY_HOOK_READ_TIMEOUT:-2}" >/dev/null 2>&1 || true
    _pcf_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,100})"'
    [[ "${MMRY_HOOK_PAYLOAD:-}" =~ $_pcf_re ]] && _pcf_sid="${BASH_REMATCH[1]}"
fi

# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/hooks-handlers/mmry-client.sh" >/dev/null 2>&1 || exit 0
set +e +u
[[ -n "${MMRY_JQ:-}" && -n "${MMRY_API_KEY:-}" ]] || exit 0
mmry_foundation_identity_known_v || exit 0
[[ "${MMRY_AUTH_METHOD:-}" == "apikey" ]] || exit 0

# Inside the 15 seconds hooks.json gives each part.
export MMRY_HTTP_CONNECT_TIMEOUT=4 MMRY_HTTP_MAX_TIME=10

_PCF_LABEL='Before a long conversation is shortened'
_PCF_HEAD='MMRY AI: these are Foundation directives this account chose to keep when a long conversation is shortened. Keep each of them in the summary word for word, exactly as written below, so they stay in force after it.'

# EVERY PART THAT FAILS SAYS SO (#33480). Claude Code runs the parts side by side and each asks the
# service on its own, so one part's request can fail while another's succeeds. A part that then went
# silent would leave a slice out of a summary told the parts are the whole set. A part other than 1
# cannot know whether the set would have reached it, so it says the others MAY not be the whole set.
if ! mmry_get_foundation_moment before-shortening >/dev/null 2>&1; then
    if (( MMRY_FND_PART == 1 )); then
        printf '%s\n' "MMRY AI: the Foundation directives this account chose to keep when a long conversation is shortened could not be fetched (HTTP ${MMRY_HTTP_CODE:-000}), so none were added to this summary. Nothing was guessed at."
    else
        printf '%s\n' "MMRY AI: part ${MMRY_FND_PART} of the Foundation directives this account chose to keep when a long conversation is shortened could not be fetched (HTTP ${MMRY_HTTP_CODE:-000}), so those given here may not be the whole set. Nothing was guessed at."
    fi
    exit 0
fi

# One jq: the service's count, size and report, then the set, one "- topic: content" per memory, as
# the per-prompt set is written. -b where this jq would otherwise write CR LF (a native Windows jq):
# no carriage return the service did not send.
_pcf_jqb=""
_pcf_probe="$(printf '%s' '"x\ny"' | "$MMRY_JQ" -j . 2>/dev/null)"
[[ "$_pcf_probe" == *$'\r'* ]] && _pcf_jqb="-b"
_pcf_count="" _pcf_chars="" _pcf_over="" _pcf_set=""
{ IFS= read -r _pcf_count; IFS= read -r _pcf_chars; IFS= read -r _pcf_over; IFS= read -r -d '' _pcf_set; } < <(
    "$MMRY_JQ" ${_pcf_jqb:+"$_pcf_jqb"} -r '(.count // 0), (.characters // 0), (.overReportedSize // false), (.memories[] | "- \(.topic): \(.content)")' <<<"$MMRY_RESPONSE" 2>/dev/null)
_pcf_count="${_pcf_count%$'\r'}" _pcf_chars="${_pcf_chars%$'\r'}" _pcf_over="${_pcf_over%$'\r'}"
# The newline jq puts after the last memory is the writer's, not the service's.
_pcf_set="${_pcf_set%$'\n'}"
[[ "$_pcf_count" =~ ^[0-9]+$ ]] || _pcf_count=0
[[ "$_pcf_chars" =~ ^[0-9]+$ ]] || _pcf_chars=0
mmry_foundation_note_moment before-shortening "${_pcf_count} ${_pcf_chars} ${_pcf_over}" "" 2>/dev/null

# Nothing chosen for this moment: nothing to keep, and nothing is said.
(( _pcf_count > 0 )) && [[ "$_pcf_set" =~ [^[:space:]] ]] || exit 0

# Where the set is cut: the lengths of its parts, in bytes, one per line, at most six plus one.
_pcf_lens="$(LC_ALL=C awk -v BINMODE=1 -v cap="$_PCF_PART_CAP" -v max="$_PCF_PARTS_MAX" \
    -f "${PLUGIN_ROOT}/hooks-handlers/foundation-cut.awk" <<<"$_pcf_set" 2>/dev/null)"
_pcf_n=0
_pcf_lines=()
while IFS= read -r _pcf_l; do
    _pcf_l="${_pcf_l%$'\r'}"
    [[ "$_pcf_l" =~ ^[0-9]+$ ]] || continue
    _pcf_lines+=("$_pcf_l")
    _pcf_n=$(( _pcf_n + 1 ))
done <<<"$_pcf_lens"

# By reference: over six parts, over the service's size line, or a cut that could not be made.
if (( _pcf_n == 0 || _pcf_n > _PCF_PARTS_MAX )) || [[ "$_pcf_over" == "true" ]]; then
    (( MMRY_FND_PART == 1 )) || exit 0
    mmry_foundation_shortening_name_v "${MMRY_TMPDIR:-${TMPDIR:-/tmp}}" "$_pcf_sid"
    _pcf_file="$_MMRY_FND_SHORTENING_NAME"
    if ! { printf '%s\n' "$_pcf_set" > "${_pcf_file}.w.$$" && mv -f "${_pcf_file}.w.$$" "$_pcf_file"; } 2>/dev/null; then
        rm -f "${_pcf_file}.w.$$" 2>/dev/null
        printf '%s\n' "MMRY AI: the Foundation directives this account chose to keep when a long conversation is shortened come to ${_pcf_chars} characters, more than about 57,000, and could not be written to a file for this session, so none were added to this summary. MMRY never shortens them."
        exit 0
    fi
    _pcf_path="$(mmry_host_path_for_model "$_pcf_file" 2>/dev/null)"
    [[ -n "$_pcf_path" ]] || _pcf_path="$_pcf_file"
    printf '%s\n' "MMRY AI: the directives chosen for \"${_PCF_LABEL}\" come to ${_pcf_chars} characters, more than about 57,000. MMRY sends them whole and never shortens them, but an assistant may not take in that much at once, so they are in one file: ${_pcf_path}. Keep this instruction in the summary word for word: after the summary, read that whole file and follow every directive in it."
    exit 0
fi

# This part's share, or nothing when the set has fewer parts.
(( MMRY_FND_PART <= _pcf_n )) || exit 0
_pcf_off=0 _pcf_k=1
while (( _pcf_k < MMRY_FND_PART )); do
    _pcf_off=$(( _pcf_off + _pcf_lines[_pcf_k - 1] ))
    _pcf_k=$(( _pcf_k + 1 ))
done
_pcf_label=""
(( _pcf_n > 1 )) && _pcf_label=" This is part ${MMRY_FND_PART} of ${_pcf_n}; the parts together are the whole set, in order."
LC_ALL=C
printf '%s%s\n\n%s\n' "$_PCF_HEAD" "$_pcf_label" "${_pcf_set:_pcf_off:_pcf_lines[MMRY_FND_PART - 1]}"
exit 0
