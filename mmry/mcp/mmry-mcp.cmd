@echo off
rem mmry-mcp.cmd - how Codex starts MMRY's MCP server on Windows (#31743).
rem
rem codex-mcp.json names "./mcp/mmry-mcp". Codex resolves that name on Windows with PATHEXT and
rem runs this file; on macOS and Linux it runs mmry-mcp, the sh file beside it. This hands over to
rem codex-hook.cmd, the launcher every MMRY hook on Windows Codex already uses: it finds Git for
rem Windows' own bash (never the Linux subsystem's) without trusting the project folder, and starts
rem hooks-handlers\mcp-server.sh through codex-hook.sh with stdin and stdout passed through.
rem
rem `@echo off` is load-bearing: stdout is the MCP protocol channel, and an echoed command line
rem would corrupt it.
call "%~dp0..\hooks-handlers\codex-hook.cmd" mcp-server %*
exit /b %ERRORLEVEL%
