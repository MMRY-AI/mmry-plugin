#!/usr/bin/env bash
# lib-jq.sh — resolve a usable jq (system or bundled) for MMRY AI.
#
# #30624: MMRY bundles the official jq binaries per platform under
# mmry/vendor/jq/ so memory operations are always fast on every supported
# machine, even where jq is not installed (notably Windows Git Bash). This
# resolver prefers a working system jq, falls back to the bundled binary for
# the current platform, and only on a genuinely unsupported platform reports
# failure so callers can stop with a clear message instead of stalling.
#
# Usage:
#   source "<plugin-root>/hooks-handlers/lib-jq.sh"
#   mmry_resolve_jq || { mmry_jq_unavailable_message; exit 1; }
#   "$MMRY_JQ" -r '.foo' <<<"$json"
#
# Exports MMRY_JQ (an absolute path, or the literal string "jq"). Idempotent.
#
# Test seams: set MMRY_JQ_VENDOR_DIR to point at a fixture vendor dir, and
# MMRY_UNAME_S / MMRY_UNAME_M to simulate a platform without mocking uname.

set -euo pipefail

# #31245: resolve the host before anything reads a path or a credential.
#
# WHY HERE, OF ALL PLACES. mmry-client.sh sources this file as its very first action, before it
# loads config, and nearly every handler in the plugin reaches the client through that one line. So
# sourcing lib-host.sh here is what makes a handler invoked directly by the model - which is how
# save-memory.sh, search-memories.sh and the rest are actually run - resolve the credential of the
# assistant it is installed under. Without it those scripts fall through to
# ${HOME}/.claude/mmry-config.json on every host, which is the wrong file on Codex and no file at
# all on a machine that has only Codex.
#
# It is a no-op on Claude Code: lib-host.sh resolves the host to claude and sets nothing.
# Guarded, because a missing lib-host.sh must not take jq resolution down with it - hence the
# existence test rather than a swallowed source. STDERR IS DELIBERATELY NOT REDIRECTED HERE: the
# refusal below is the only warning a customer gets that MMRY is not set up for this host, and a
# 2>/dev/null on this line would discard it.
# DERIVED WITHOUT A PROCESS, FOR THE SAME REASON AS hook-guard.sh (#31245 QA round 6).
#
# This was `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` - two nested command substitutions, the
# identical idiom removed from hook-guard.sh in commit 7ae2464 of this branch and reintroduced
# here in the same commit that removed it there. It is not a quiet corner: formation-check.sh
# sources this file, and formation-check.sh is registered on PostToolUse WITH NO MATCHER, so it
# runs after EVERY tool call. Measured on Windows Git Bash, 20 runs: 113-151 ms on develop against
# 250-299 ms with this idiom in place - roughly double, paid by every existing Claude Code
# customer for a second host they do not have. That is a requirement-4 cost.
#
# The path only has to be good enough to source a sibling file. lib-host.sh resolves its OWN
# absolute location for the host detection it does, so nothing downstream depends on this one
# being absolute. tests/structural/hook-budgets.bats asserts the idiom is absent from every script
# on a per-tool-call or per-prompt path, so a third one cannot appear unnoticed.
_mmry_libjq_dir="${BASH_SOURCE[0]%/*}"
[[ "$_mmry_libjq_dir" == "${BASH_SOURCE[0]}" ]] && _mmry_libjq_dir="."
if [[ -f "${_mmry_libjq_dir}/lib-host.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_mmry_libjq_dir}/lib-host.sh" || true
fi

# AND THIS IS WHERE A FOREIGN CREDENTIAL IS REFUSED (#31245 QA round 2).
#
# Pointing MMRY_CONFIG_FILE at the Codex credential is not enough on its own: mmry-client.sh tests
# that the file EXISTS and, when it does not, walks on to ${HOME}/.claude/mmry-config.json - the
# other product's account. Reproduced with a sentinel on 2026-09-16.
#
# This is the one line every credential-resolving path in the plugin passes through. mmry-client.sh
# sources this file as its first executable statement, and mmry_load_config - the only function
# anywhere that opens a credential file - is defined below that point in the same file. So a
# refusal here happens before any caller can ask the question, without editing the client.
#
# On Claude Code the function returns 0 immediately, so nothing changes. The opt-out exists for
# mmry-setup.sh and uninstall.sh, the two programs that legitimately run before or after a
# credential exists.
if declare -F mmry_host_assert_own_credential >/dev/null 2>&1; then
    mmry_host_assert_own_credential || exit 1
fi
unset _mmry_libjq_dir

# Directory holding the bundled binaries.
_mmry_jq_vendor_dir() {
    if [[ -n "${MMRY_JQ_VENDOR_DIR:-}" ]]; then
        printf '%s' "$MMRY_JQ_VENDOR_DIR"
    elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}/vendor/jq" ]]; then
        printf '%s' "${CLAUDE_PLUGIN_ROOT}/vendor/jq"
    else
        printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vendor/jq"
    fi
}

# Map the current platform to a bundled binary filename. Echoes the filename,
# or nothing (return 0 with empty output) when the platform is unsupported.
_mmry_jq_bundle_name() {
    local os arch
    os="${MMRY_UNAME_S:-$(uname -s 2>/dev/null || echo unknown)}"
    arch="${MMRY_UNAME_M:-$(uname -m 2>/dev/null || echo unknown)}"
    case "$os" in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT|Windows) os=windows ;;
        *) return 0 ;;
    esac
    case "$arch" in
        x86_64|amd64) arch=amd64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) return 0 ;;
    esac
    # We do not ship a windows-arm64 build; on ARM Windows, Git Bash reports
    # x86_64 under emulation, so amd64 is the practical target there.
    local name="jq-${os}-${arch}"
    [[ "$os" == "windows" ]] && name="${name}.exe"
    printf '%s' "$name"
}

# Resolve a usable jq into MMRY_JQ. Returns 0 on success, 1 if none is usable.
mmry_resolve_jq() {
    # Already resolved and still working?
    if [[ -n "${MMRY_JQ:-}" ]] && "$MMRY_JQ" --version >/dev/null 2>&1; then
        return 0
    fi
    # 1. Prefer a working system jq. (MMRY_JQ_SKIP_SYSTEM=1 forces the bundled
    #    path; test seam only, unset in production.)
    if [[ "${MMRY_JQ_SKIP_SYSTEM:-}" != "1" ]] \
        && command -v jq >/dev/null 2>&1 && jq --version >/dev/null 2>&1; then
        MMRY_JQ="jq"; export MMRY_JQ; return 0
    fi
    # 2. Bundled binary for this platform.
    local name path
    name="$(_mmry_jq_bundle_name)"
    if [[ -n "$name" ]]; then
        path="$(_mmry_jq_vendor_dir)/${name}"
        if [[ -f "$path" ]]; then
            [[ -x "$path" ]] || chmod +x "$path" 2>/dev/null || true
            if "$path" --version >/dev/null 2>&1; then
                MMRY_JQ="$path"; export MMRY_JQ; return 0
            fi
        fi
    fi
    MMRY_JQ=""; export MMRY_JQ; return 1
}

# Print a clear, platform-specific message when no usable jq is available.
# Writes to stderr so it never contaminates a handler's JSON stdout.
mmry_jq_unavailable_message() {
    local os arch
    os="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"
    {
        echo "MMRY AI: no usable jq was found for this platform (${os} ${arch})."
        echo "jq is required for fast memory operations."
        echo "Re-run setup to restore the bundled jq:"
        # #31245: the setup path belongs to whichever host this is. lib-host.sh is sourced lazily
        # here, not at the top of the file: this library is pulled in by mmry-client.sh, which is
        # itself sourced by twenty-odd handlers, and this message is the only line in it that needs
        # to know the host. The guard keeps the previous literal if the resolver is unavailable.
        if source "${BASH_SOURCE[0]%/*}/lib-host.sh" 2>/dev/null; then
            echo "  $(mmry_host_setup_hint)"
        else
            echo "  bash ~/.claude/mmry/setup/mmry-setup.sh"
        fi
        echo "Or install jq (https://jqlang.github.io/jq/) and put it on your PATH."
    } >&2
}
