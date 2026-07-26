#!/usr/bin/env bats
# lib-jq.bats — resolver that guarantees a usable jq (system or bundled). #30624

load '../helpers/test-helper'

setup() {
    unset MMRY_JQ MMRY_UNAME_S MMRY_UNAME_M MMRY_JQ_SKIP_SYSTEM MMRY_JQ_VENDOR_DIR
    source "$PLUGIN_ROOT/hooks-handlers/lib-jq.sh"
    VENDOR="$PLUGIN_ROOT/mmry/vendor/jq"
    # In the worktree the plugin root already ends in /mmry, so vendor is here:
    [[ -d "$VENDOR" ]] || VENDOR="$PLUGIN_ROOT/vendor/jq"
}

# --- platform -> bundled filename mapping (the core selection logic) ---

@test "bundle-name: Linux x86_64 -> jq-linux-amd64" {
    MMRY_UNAME_S=Linux MMRY_UNAME_M=x86_64 run _mmry_jq_bundle_name
    [ "$output" = "jq-linux-amd64" ]
}
@test "bundle-name: Linux aarch64 -> jq-linux-arm64" {
    MMRY_UNAME_S=Linux MMRY_UNAME_M=aarch64 run _mmry_jq_bundle_name
    [ "$output" = "jq-linux-arm64" ]
}
@test "bundle-name: Darwin arm64 -> jq-macos-arm64" {
    MMRY_UNAME_S=Darwin MMRY_UNAME_M=arm64 run _mmry_jq_bundle_name
    [ "$output" = "jq-macos-arm64" ]
}
@test "bundle-name: Darwin x86_64 -> jq-macos-amd64" {
    MMRY_UNAME_S=Darwin MMRY_UNAME_M=x86_64 run _mmry_jq_bundle_name
    [ "$output" = "jq-macos-amd64" ]
}
@test "bundle-name: MINGW x86_64 -> jq-windows-amd64.exe" {
    MMRY_UNAME_S="MINGW64_NT-10.0" MMRY_UNAME_M=x86_64 run _mmry_jq_bundle_name
    [ "$output" = "jq-windows-amd64.exe" ]
}
@test "bundle-name: unsupported OS -> empty" {
    MMRY_UNAME_S=Plan9 MMRY_UNAME_M=x86_64 run _mmry_jq_bundle_name
    [ -z "$output" ]
}
@test "bundle-name: unsupported arch -> empty" {
    MMRY_UNAME_S=Linux MMRY_UNAME_M=riscv64 run _mmry_jq_bundle_name
    [ -z "$output" ]
}

# --- vendored binaries exist for every supported platform ---

@test "vendor: all five platform binaries are present" {
    for f in jq-linux-amd64 jq-linux-arm64 jq-macos-amd64 jq-macos-arm64 jq-windows-amd64.exe; do
        [ -f "$VENDOR/$f" ] || { echo "missing $VENDOR/$f"; return 1; }
    done
}

@test "vendor: license and checksums are present" {
    [ -f "$VENDOR/LICENSE" ]
    [ -f "$VENDOR/CHECKSUMS.txt" ]
}

# --- resolution ---

@test "resolve: prefers a working system jq when present" {
    if ! command -v jq >/dev/null 2>&1; then skip "no system jq on this host"; fi
    mmry_resolve_jq
    [ "$MMRY_JQ" = "jq" ]
}

@test "resolve: falls back to the bundled binary for this host (system skipped)" {
    export MMRY_JQ_SKIP_SYSTEM=1
    export MMRY_JQ_VENDOR_DIR="$VENDOR"
    run mmry_resolve_jq
    [ "$status" -eq 0 ]
    # And the resolved binary actually runs on this host.
    mmry_resolve_jq
    [ -n "$MMRY_JQ" ]
    "$MMRY_JQ" --version | grep -q '^jq-'
}

@test "resolve: bundled selection returns non-zero on an unsupported platform" {
    export MMRY_JQ_SKIP_SYSTEM=1
    export MMRY_JQ_VENDOR_DIR="$VENDOR"
    export MMRY_UNAME_S=Plan9 MMRY_UNAME_M=x86_64
    run mmry_resolve_jq
    [ "$status" -eq 1 ]
}

@test "resolve: idempotent — re-resolving keeps the same working jq" {
    export MMRY_JQ_SKIP_SYSTEM=1
    export MMRY_JQ_VENDOR_DIR="$VENDOR"
    mmry_resolve_jq
    first="$MMRY_JQ"
    mmry_resolve_jq
    [ "$MMRY_JQ" = "$first" ]
}

@test "message: unavailable message names jq and points to setup" {
    run mmry_jq_unavailable_message
    [[ "$output" == *"jq"* ]]
    [[ "$output" == *"setup"* ]]
}
