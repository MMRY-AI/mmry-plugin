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
rem THE FORMATION GATE, FIRST, BEFORE ANYTHING ELSE RUNS (#31746, Eric Barone 2026-10-07).
rem
rem The formation message check is registered on every prompt, tool call and session start, and
rem nearly every session is in no formation. Such a session must pay one file lookup and nothing
rem else: no where.exe, no reg.exe, no bash, no library, no payload read. So for the formation-check
rem handler the first thing this file does is look for a membership file, .mmry-formation-<session>,
rem and exit 0 with no output when there is none. hooks/hooks.json and the `command` form in
rem hooks/codex-hooks.json open with the same check written for sh; this is that check in cmd,
rem because commandWindows is run by PowerShell or cmd and cannot carry an sh line.
rem
rem SAME FOLDER AS formation-state.sh, which writes the file to ${TMPDIR:-/tmp}:
rem   - TMPDIR set: Git Bash receives it as the same folder (Cygwin converts it in both directions,
rem     measured), so it is checked as it stands. If it is not a drive or UNC path cmd can read, the
rem     gate stands aside and the check runs as before: a gate that guesses must never drop a message.
rem   - TMPDIR not set: Git Bash's /tmp is the "usertemp" mount, the user's Windows temp folder. TEMP,
rem     TMP and %LOCALAPPDATA%\Temp are all looked in, because a stray extra match only costs a check
rem     that would have run anyway, and a missed one loses a message.
rem `for` with a wildcard matches FILES only, so the delivery locks (.mmry-formation-cs-*, -poll-*),
rem which are directories, do not open the gate. Builtins only: set, if and for start no process.
rem MEMBERSHIP FILES ONLY (#31844). The locks and markers that share the prefix are sometimes FILES
rem (a crashed holder, an older version), and every one of them opened this gate. Each match is
rem handed to :gate_consider, at the end of this file, which ignores those names. `call` to a label
rem starts no process either.
if /i not "%~1"=="formation-check" goto :after_formation_gate
set "MMRY_MEMBER="
if not defined TMPDIR goto :gate_usertemp
set "MMRY_GATE_DIR=%TMPDIR%"
set "MMRY_GATE_ABS="
if "%MMRY_GATE_DIR:~1,1%"==":" set "MMRY_GATE_ABS=1"
if "%MMRY_GATE_DIR:~0,2%"=="\\" set "MMRY_GATE_ABS=1"
if not defined MMRY_GATE_ABS goto :after_formation_gate
for %%F in ("%MMRY_GATE_DIR%\.mmry-formation-*") do call :gate_consider "%%~nxF"
goto :gate_decide
:gate_usertemp
if defined TEMP for %%F in ("%TEMP%\.mmry-formation-*") do call :gate_consider "%%~nxF"
if defined TMP for %%F in ("%TMP%\.mmry-formation-*") do call :gate_consider "%%~nxF"
if defined LOCALAPPDATA for %%F in ("%LOCALAPPDATA%\Temp\.mmry-formation-*") do call :gate_consider "%%~nxF"
:gate_decide
if not defined MMRY_MEMBER exit /b 0
:after_formation_gate

rem NEVER RUN A PROGRAM FROM THE CUSTOMER'S PROJECT FOLDER (#31245 QA rounds 9 and 10, security).
rem Codex runs this hook with the customer's project as the current folder, and cmd.exe looks
rem in the current folder BEFORE PATH. Three safeguards, each closing something the others leave
rem open:
rem   1. NoDefaultCurrentDirectoryInExePath=1, below, turns cmd's current-folder lookup off for
rem      this script and every child it starts, so a where.bat, reg.bat or findstr.bat committed
rem      to a repository cannot stand in for the real tool.
rem   2. Those three tools are also called by their full System32 path, so the first safeguard
rem      is not the only thing between a planted tool and the hook.
rem   3. where.exe is asked for $PATH:git.exe, not git.exe. Neither safeguard above covers this:
rem      where.exe searches the current folder for the FILE it is looking for whatever that
rem      variable says, so a git.exe planted in a repository subfolder would be listed first and
rem      the bash.exe beside it, inside the repository, would run as the hook.
rem The Claude Code harness sets the variable itself, which is why tests launched from it could
rem not see these holes; the tests that plant the fixtures unset it first.
set "NoDefaultCurrentDirectoryInExePath=1"
rem Unquoted inside the for /f commands below on purpose: a for /f command that begins with a
rem quote has its outer quotes stripped by cmd /c. SystemRoot contains no spaces.
set "MMRY_SYS32=%SystemRoot%\System32"
set "MMRY_HANDLER=%~1"
if "%MMRY_HANDLER%"=="" exit /b 0
set "MMRY_GIT_BASH="

for /f "delims=" %%G in ('%MMRY_SYS32%\where.exe $PATH:git.exe 2^>nul') do (
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
for /f "tokens=2,*" %%A in ('%MMRY_SYS32%\reg.exe query "%~1\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| %MMRY_SYS32%\findstr.exe /i "InstallPath"') do (
    if exist "%%B\bin\bash.exe" set "MMRY_GIT_BASH=%%B\bin\bash.exe"
)
exit /b 0

:no_git
if /i "%MMRY_HANDLER%"=="session-init" echo MMRY AI could not start on this Windows machine: Git for Windows was not found. Tell the user, in these words: MMRY needs Git for Windows. Install it from https://gitforwindows.org with its default options, then start a new session.
exit /b 0

rem The formation gate's filter (#31844): %1 is the name of one file matching .mmry-formation-*.
rem It counts as membership unless it is one of formation-check.sh's locks or markers, the same list
rem formation-state.sh (mmry_formation_is_membership_name) and both hooks files carry.
:gate_consider
set "MMRY_GATE_NAME=%~1"
if /i "%MMRY_GATE_NAME:~0,19%"==".mmry-formation-cs-" exit /b 0
if /i "%MMRY_GATE_NAME:~0,21%"==".mmry-formation-poll-" exit /b 0
if /i "%MMRY_GATE_NAME:~0,25%"==".mmry-formation-handover-" exit /b 0
if /i "%MMRY_GATE_NAME:~0,24%"==".mmry-formation-renewed-" exit /b 0
set "MMRY_MEMBER=1"
exit /b 0
