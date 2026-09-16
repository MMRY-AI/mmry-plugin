@echo off
setlocal enabledelayedexpansion
rem codex-hook.cmd - Windows entry point for MMRY AI hooks on OpenAI Codex (#31245).
rem
rem WHY THIS FILE EXISTS. On Windows, Codex runs a hook command line through cmd.exe, not through a
rem POSIX shell: codex-rs/hooks/src/engine/command_runner.rs, default_shell_command, uses COMSPEC
rem with /C on Windows and SHELL with -lc everywhere else. Two consequences follow, and this file
rem is the answer to both.
rem
rem 1. ${CLAUDE_PLUGIN_ROOT} is not expanded by cmd.exe. Hence the commandWindows entries in
rem    hooks/codex-hooks.json use %CLAUDE_PLUGIN_ROOT%, which cmd.exe does expand. Codex exports
rem    that variable to plugin hook processes itself (discovery.rs: "For OOTB compat with existing
rem    plugins that use this env var").
rem
rem 2. A bare "bash" resolved from cmd.exe is NOT necessarily Git Bash. On a machine with WSL
rem    installed, C:\Windows\System32\bash.exe can come first on PATH, and that bash runs in a
rem    Linux filesystem namespace where C:\Users\... does not exist and the customer's Windows
rem    credential file is not where the handler will look for it. The handler would then behave as
rem    though MMRY were not set up, on a machine where it is - a failure with no error message.
rem    So this file picks an interpreter deliberately instead of letting PATH order decide.
rem
rem SEARCH ORDER, most specific first:
rem   MMRY_BASH            - explicit override, for a customer with a bash somewhere unusual
rem   %PROGRAMFILES%\Git   - the standard Git for Windows install
rem   %PROGRAMFILES(X86)%  - 32-bit Git for Windows
rem   %LOCALAPPDATA%       - Git for Windows installed per-user, which is the default for a
rem                          non-administrator install and is therefore common
rem   where bash           - last resort, filtered to exclude System32 (WSL)
rem
rem FAIL OPEN. If no usable bash is found this exits 0 with no output, which Codex reads as a hook
rem that had nothing to say. A customer with a broken install gets a session with no memories, not
rem a session that will not start.

set "MMRY_HANDLER=%~1"
if "%MMRY_HANDLER%"=="" exit /b 0

set "MMRY_SELF_DIR=%~dp0"

set "MMRY_BASH_EXE="

if defined MMRY_BASH (
    if exist "%MMRY_BASH%" set "MMRY_BASH_EXE=%MMRY_BASH%"
)

if not defined MMRY_BASH_EXE (
    if exist "%PROGRAMFILES%\Git\bin\bash.exe" set "MMRY_BASH_EXE=%PROGRAMFILES%\Git\bin\bash.exe"
)
if not defined MMRY_BASH_EXE (
    if exist "%PROGRAMFILES%\Git\usr\bin\bash.exe" set "MMRY_BASH_EXE=%PROGRAMFILES%\Git\usr\bin\bash.exe"
)
if not defined MMRY_BASH_EXE (
    if exist "%PROGRAMFILES(X86)%\Git\bin\bash.exe" set "MMRY_BASH_EXE=%PROGRAMFILES(X86)%\Git\bin\bash.exe"
)
if not defined MMRY_BASH_EXE (
    if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "MMRY_BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
)

rem Last resort: whatever PATH offers, minus the WSL launcher in System32. findstr /v /i on the
rem literal substring is enough here; every WSL bash lives under a System32 path and no Git Bash
rem does.
if not defined MMRY_BASH_EXE (
    for /f "delims=" %%B in ('where bash 2^>nul ^| findstr /v /i "\\System32\\"') do (
        if not defined MMRY_BASH_EXE set "MMRY_BASH_EXE=%%B"
    )
)

if not defined MMRY_BASH_EXE exit /b 0

"%MMRY_BASH_EXE%" "%MMRY_SELF_DIR%codex-hook.sh" %*
exit /b %ERRORLEVEL%
