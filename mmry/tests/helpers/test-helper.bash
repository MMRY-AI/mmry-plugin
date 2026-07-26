#!/usr/bin/env bash
# test-helper.sh — Common setup for all BATS test files.
# Source via: load '../helpers/test-helper'

# Load BATS libraries
load '../libs/bats-support/load'
load '../libs/bats-assert/load'

# Set plugin root to the repo's mmry/ directory
# Allow override via env var (set in run-tests.sh or manually)
if [[ -z "${PLUGIN_ROOT:-}" ]]; then
    PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
fi
export PLUGIN_ROOT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Ensure a jq is on PATH for the whole suite. #30624: the plugin bundles jq, so a
# jq-less host (e.g. Windows Git Bash) can still run tests that shell out to bare
# `jq`. Prefer a system jq; otherwise shim the bundled binary onto PATH. Inlined
# (not sourced from lib-jq.sh) so lib-jq's `set -euo pipefail` never leaks into
# test shells.
if ! command -v jq >/dev/null 2>&1; then
    _mmry_os="$(uname -s 2>/dev/null || echo unknown)"
    _mmry_arch="$(uname -m 2>/dev/null || echo unknown)"
    case "$_mmry_os" in
        Linux) _mmry_os=linux ;;
        Darwin) _mmry_os=macos ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT) _mmry_os=windows ;;
    esac
    case "$_mmry_arch" in
        x86_64|amd64) _mmry_arch=amd64 ;;
        arm64|aarch64) _mmry_arch=arm64 ;;
    esac
    _mmry_name="jq-${_mmry_os}-${_mmry_arch}"
    [[ "$_mmry_os" == "windows" ]] && _mmry_name="${_mmry_name}.exe"
    _mmry_bundled="$PLUGIN_ROOT/vendor/jq/${_mmry_name}"
    if [[ -f "$_mmry_bundled" ]]; then
        chmod +x "$_mmry_bundled" 2>/dev/null || true
        _mmry_shim="$(mktemp -d)"
        printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$_mmry_bundled" > "$_mmry_shim/jq"
        chmod +x "$_mmry_shim/jq"
        export PATH="$_mmry_shim:$PATH"
    fi
fi

# Temp directory for test artifacts
export TEST_TMPDIR
TEST_TMPDIR="$(mktemp -d)"

# Override TMPDIR so scripts write to test-controlled location
export TMPDIR="$TEST_TMPDIR"
export MMRY_TMPDIR="$TEST_TMPDIR"

# Disable any real config from interfering
export MMRY_CONFIG_FILE="$TEST_TMPDIR/mmry-config.json"
export MMRY_API_URL=""
export MMRY_API_KEY=""
export MMRY_AUTH_METHOD=""

# Clean up after each test
teardown() {
    rm -rf "$TEST_TMPDIR"
}
