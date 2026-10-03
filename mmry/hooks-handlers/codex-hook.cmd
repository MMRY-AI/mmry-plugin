@echo off
rem codex-hook.cmd - how every MMRY hook starts on Windows Codex (#31245 QA round 8).
rem
rem WHY THIS FILE EXISTS. On Windows, Codex hands a hook's command line to cmd.exe, and a hook
rem declared as `sh "...codex-hook.sh"` needs an sh.exe on PATH. The Git for Windows installer's
rem default PATH option, the one it recommends, puts only Git\cmd on PATH, and Git\cmd holds git.exe
rem and no shell. So on a stock machine every MMRY hook failed with 9009 before any MMRY code ran,
rem and the published remedy (reinstall Git with a different PATH option) pointed the customer at the
rem option the installer itself flags as hazardous. hooks/codex-hooks.json names this file in
rem commandWindows, so Windows no longer depends on PATH holding a shell at all.
rem
rem HOW IT FINDS A SHELL. It looks for Git for Windows' bin\bash.exe, never a bare `bash`: Windows
rem ships a bash.exe in System32 when the Linux subsystem is installed, and that one cannot see the
rem customer's Windows files. bin\bash.exe, not usr\bin\bash.exe: bin\bash.exe sets up the PATH the
rem handlers need (tr, sed, curl), usr\bin\bash.exe does not. Measured with a stock PATH: the first
rem finds /usr/bin/tr and /mingw64/bin/curl, the second finds neither.
rem
rem   1. Beside the git.exe on PATH. A stock install always has Git\cmd\git.exe there, which is
rem      what the recommended PATH option is for, and from it the install root is one level up.
rem   2. The registry entry the Git for Windows installer writes, machine-wide then per-user.
rem   3. The standard install folders, for a Git that is installed but not on PATH at all.
rem
rem FAIL OPEN. If no Git bash is found this exits 0 having said nothing, which Codex reads as a hook
rem with nothing to say: a session without memories, never a session that will not start. The
rem session-start hook is the exception, because it is the one a customer will notice is missing:
rem it says in one line what is wrong and what to install.
rem
rem `@echo off` is load-bearing. With echo on, cmd.exe writes each command line to stdout, and
rem stdout is what Codex hands the model.

setlocal enableextensions
set "MMRY_HANDLER=%~1"
if "%MMRY_HANDLER%"=="" exit /b 0
set "MMRY_GIT_BASH="

for /f "delims=" %%G in ('where git.exe 2^>nul') do (
    if not defined MMRY_GIT_BASH if exist "%%~dpG..\bin\bash.exe" set "MMRY_GIT_BASH=%%~dpG..\bin\bash.exe"
    if not defined MMRY_GIT_BASH if exist "%%~dpG..\..\bin\bash.exe" set "MMRY_GIT_BASH=%%~dpG..\..\bin\bash.exe"
)

if not defined MMRY_GIT_BASH call :from_registry HKLM
if not defined MMRY_GIT_BASH call :from_registry HKCU

if not defined MMRY_GIT_BASH if exist "%ProgramW6432%\Git\bin\bash.exe" set "MMRY_GIT_BASH=%ProgramW6432%\Git\bin\bash.exe"
if not defined MMRY_GIT_BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "MMRY_GIT_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined MMRY_GIT_BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "MMRY_GIT_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined MMRY_GIT_BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "MMRY_GIT_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if not defined MMRY_GIT_BASH goto :no_git

"%MMRY_GIT_BASH%" "%~dp0codex-hook.sh" %*
exit /b %ERRORLEVEL%

:from_registry
for /f "tokens=2,*" %%A in ('reg query "%~1\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
    if exist "%%B\bin\bash.exe" set "MMRY_GIT_BASH=%%B\bin\bash.exe"
)
exit /b 0

:no_git
if /i "%MMRY_HANDLER%"=="session-init" echo MMRY AI could not start on this Windows machine: Git for Windows was not found. Install it from https://gitforwindows.org with its default options, then start a new session.
exit /b 0
