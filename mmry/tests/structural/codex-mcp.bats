#!/usr/bin/env bats
# codex-mcp.bats - how Codex finds and starts MMRY's MCP server, and that Claude Code never does
# (#31743).
#
# WHERE THE EXPECTED VALUES COME FROM: openai/codex at rust-v0.160.0, the installed codex-cli.
#   manifest "mcpServers" path, ./ form   codex-rs/core-plugins/src/manifest.rs resolve_manifest_path
#   the file's shape (mcpServers object)  codex-rs/codex-mcp/src/plugin_config.rs PluginMcpFile
#   relative cwd joined to the plugin root codex-rs/codex-mcp/src/plugin_config.rs
#   the server's environment is an allowlist, extended only by env_vars
#                                         codex-rs/rmcp-client/src/utils.rs create_env_for_mcp_server
#   one command for every platform; Windows resolves it with PATHEXT
#                                         codex-rs/rmcp-client/src/program_resolver.rs
# Measured, not only read: docs/evidence/31743 has the real Codex starting this server on Windows.

load '../helpers/test-helper'

setup() {
    CODEX_MANIFEST="$PLUGIN_ROOT/.codex-plugin/plugin.json"
    MCP_CONFIG="$PLUGIN_ROOT/codex-mcp.json"
    REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
}

@test "codex mcp: the Codex manifest names codex-mcp.json, in the ./ form the parser requires" {
    [ "$(jq -r '.mcpServers' "$CODEX_MANIFEST")" = "./codex-mcp.json" ]
    [ -f "$MCP_CONFIG" ]
}

@test "codex mcp: codex-mcp.json is one mcpServers object holding exactly one server, mmry_plugin" {
    [ "$(jq -r '.mcpServers | keys | join(",")' "$MCP_CONFIG")" = "mmry_plugin" ]
}

@test "codex mcp: the server is NOT called mmry, the name a customer may give the MMRY connector" {
    # Codex resolves two servers with one name by precedence, and the customer's own config.toml
    # outranks a plugin (codex-rs/codex-mcp/src/catalog.rs, RegistrationPrecedence: Plugin < Config).
    # A customer who added the MMRY connector as [mcp_servers.mmry] would silently replace these
    # tools with the connector's, whose formation join enrols an identity the hooks never poll.
    [ "$(jq -r '.mcpServers | has("mmry")' "$MCP_CONFIG")" = "false" ]
}

@test "codex mcp: the server is started by the launcher, from the plugin root" {
    [ "$(jq -r '.mcpServers.mmry_plugin.command' "$MCP_CONFIG")" = "./mcp/mmry-mcp" ]
    [ "$(jq -r '.mcpServers.mmry_plugin.cwd' "$MCP_CONFIG")" = "." ]
    [ "$(jq -r '.mcpServers.mmry_plugin.args | length' "$MCP_CONFIG")" = "0" ]
}

@test "codex mcp: the host is declared, and CODEX_HOME reaches the server, or the credential is not found" {
    [ "$(jq -r '.mcpServers.mmry_plugin.env.MMRY_HOST' "$MCP_CONFIG")" = "codex" ]
    jq -e '.mcpServers.mmry_plugin.env_vars | index("CODEX_HOME")' "$MCP_CONFIG" >/dev/null
}

@test "codex mcp: no credential VALUE is written into the registration, only variable names" {
    [ "$(jq -r '.mcpServers.mmry_plugin.env | keys | join(",")' "$MCP_CONFIG")" = "MMRY_HOST" ]
    [ "$(jq -r '[.mcpServers.mmry_plugin.env_vars[] | type] | unique | join(",")' "$MCP_CONFIG")" = "string" ]
}

@test "codex mcp: Codex's own limit on a call is above the server's limit on a handler" {
    local codex_limit server_limit
    codex_limit="$(jq -r '.mcpServers.mmry_plugin.tool_timeout_sec' "$MCP_CONFIG" | tr -d '\r')"
    server_limit="$(sed -n 's/^MMRY_MCP_HANDLER_TIMEOUT="\${MMRY_MCP_HANDLER_TIMEOUT:-\([0-9]*\)}"$/\1/p' "$PLUGIN_ROOT/hooks-handlers/mcp-server.sh")"
    [ -n "$server_limit" ]
    (( codex_limit > server_limit )) || return 1
}

@test "codex mcp: both launchers exist beside each other, the name Codex is given with and without .cmd" {
    [ -f "$PLUGIN_ROOT/mcp/mmry-mcp" ]
    [ -f "$PLUGIN_ROOT/mcp/mmry-mcp.cmd" ]
}

@test "codex mcp: the macOS and Linux launcher is executable in git, POSIX sh, LF, and hands over to codex-hook.sh" {
    [ "$(git -C "$REPO_ROOT" ls-files -s mmry/mcp/mmry-mcp | cut -c1-6)" = "100755" ]
    [ "$(head -1 "$PLUGIN_ROOT/mcp/mmry-mcp")" = "#!/bin/sh" ]
    ! grep -q $'\r' "$PLUGIN_ROOT/mcp/mmry-mcp" || return 1
    grep -q 'exec sh "$here/../hooks-handlers/codex-hook.sh" mcp-server' "$PLUGIN_ROOT/mcp/mmry-mcp"
}

@test "codex mcp: the Windows launcher starts @echo off and goes through codex-hook.cmd, never a bare bash" {
    [ "$(head -1 "$PLUGIN_ROOT/mcp/mmry-mcp.cmd" | tr -d '\r')" = "@echo off" ]
    grep -q 'codex-hook.cmd" mcp-server' "$PLUGIN_ROOT/mcp/mmry-mcp.cmd"
    ! grep -iq '^[^r]*\bbash\b' <(grep -iv '^rem' "$PLUGIN_ROOT/mcp/mmry-mcp.cmd") || return 1
}

@test "codex mcp: the launcher's checkout line endings are pinned in .gitattributes" {
    [ "$(git -C "$REPO_ROOT" check-attr eol -- mmry/mcp/mmry-mcp | awk '{print $NF}')" = "lf" ]
    [ "$(git -C "$REPO_ROOT" check-attr eol -- mmry/mcp/mmry-mcp.cmd | awk '{print $NF}')" = "crlf" ]
}

@test "codex mcp: the launcher, run as Codex runs it, answers MCP on stdout" {
    run bash -c 'cd "$1" && printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}" | env CODEX_HOME="$2" ./mcp/mmry-mcp' _ "$PLUGIN_ROOT" "$TEST_TMPDIR"
    assert_success
    [ "$(printf '%s\n' "$output" | jq -c '.result')" = "{}" ]
}

@test "codex mcp: on Windows the .cmd launcher, started by cmd as Codex starts it, answers MCP on stdout" {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "Windows only" ;; esac
    local cmdpath; cmdpath="$(cygpath -w "$PLUGIN_ROOT/mcp/mmry-mcp.cmd")"
    run bash -c 'printf "%s\r\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}" | MSYS_NO_PATHCONV=1 cmd.exe /d /c "$1"' _ "$cmdpath"
    assert_success
    [ "$(printf '%s\n' "$output" | tr -d '\r' | jq -c '.result')" = "{}" ]
}

@test "codex mcp: the server is a handler codex-hook.sh will run (a bare name, in hooks-handlers)" {
    [ -f "$PLUGIN_ROOT/hooks-handlers/mcp-server.sh" ]
}

# ---------------------------------------------------------------------------------------------
# Requirement 4: Claude Code is unchanged. Claude Code loads a plugin's MCP servers from .mcp.json
# at the plugin root, or from "mcpServers" in .claude-plugin/plugin.json. Neither may exist.
# ---------------------------------------------------------------------------------------------

@test "req4: there is no .mcp.json at the plugin root, so Claude Code starts no MCP server" {
    [ ! -e "$PLUGIN_ROOT/.mcp.json" ]
}

@test "req4: the Claude Code manifest declares no MCP server" {
    [ "$(jq -r 'has("mcpServers")' "$PLUGIN_ROOT/.claude-plugin/plugin.json")" = "false" ]
}

@test "req4: nothing Claude Code registers names the MCP server or its launchers" {
    ! grep -q 'mcp-server\|mmry-mcp\|codex-mcp' "$PLUGIN_ROOT/hooks/hooks.json" || return 1
    ! grep -rq 'mcp-server\|mmry-mcp\|codex-mcp' "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/skills" || return 1
}
