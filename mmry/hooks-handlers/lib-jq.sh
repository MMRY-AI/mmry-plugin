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
        echo "  bash ~/.claude/mmry/setup/mmry-setup.sh"
        echo "Or install jq (https://jqlang.github.io/jq/) and put it on your PATH."
    } >&2
}
