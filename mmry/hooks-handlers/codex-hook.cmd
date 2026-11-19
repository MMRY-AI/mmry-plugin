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

setlocal enableextensions disabledelayedexpansion
rem Delayed expansion off for the whole file, whatever the machine's registry default (#33967 QA round
rem 2): a ! in PATH, in the answer :from_path carries back, or in an argument is then a character.
rem THE SESSION START'S CLOCK STARTS HERE (#33062). Codex cuts the SessionStart hook off at 30 s
rem counted from when it starts this file, and on a loaded machine finding and starting Git's bash
rem took 4 to 7 s of that. codex-hook.sh counts its budget from this time when it can read it. A
rem builtin `set`: it starts no process.
rem EVERY HANDLER'S CLOCK, NOT ONLY THE SESSION START'S (#33967). The per-message checks have limits
rem too (the Foundation parts 20 s, stop-check 10 s), and in the 33452 TC5 proof the launch took most
rem of them: codex-hook.sh hands the seconds since this stamp to those handlers, which take them off
rem their own deadlines.
set "MMRY_CODEX_HOOK_STARTED=%TIME%"
rem STOP-CHECK'S QUIET MESSAGE ENDS HERE, IN CMD (#33967 round 4). In the 33967 live proof (Codex
rem 0.169.0 on Windows, a load of about 1.5 s per process start) stop-check failed at its 10 s limit on
rem a message sent mid-turn, a message on which it had nothing to say. With nine hooks starting at
rem once, Codex's own PowerShell and this cmd took about 8 s of the 10, and Git's bash took the rest.
rem On most messages stop-check is inside its 15-minute quiet time, so :stop_check_quiet answers that
rem from the record stop-check leaves beside its marker, with builtins only, and the hook ends here
rem having started no process at all. Anything it cannot be sure of goes on to stop-check as before.
if /i "%~1"=="stop-check" call :stop_check_quiet
if /i "%~1"=="stop-check" if defined MMRY_SQ_QUIET exit /b 0
rem THE LATE-MEMORIES GATE (#33062 fix round 1; moved by #33231, DD-182). codex-first-prompt runs on
rem every prompt and has work only when a session start ran out of time and left a
rem .mmry-codex-late.<key>.<session> marker, so with none it exits here, before where.exe, reg.exe or
rem bash. THE MARKER LIVES IN THE USER'S OWN FOLDER, <Codex home>\mmry-handoff, never the temp folder
rem (#33231): the Codex home is %CODEX_HOME%, else <home>\.codex, and <home> is %HOME% when Git's bash
rem would see one, else %USERPROFILE%, the same rule hooks-handlers/lib-codex-key.sh applies. Every
rem spelling that is defined is looked in, because a stray extra match only costs a check that would
rem have run anyway, and a missed one loses the memories. Builtins only: set, if and for start no
rem process.
if /i not "%~1"=="codex-first-prompt" goto :after_late_gate
set "MMRY_LATE="
if defined CODEX_HOME for %%F in ("%CODEX_HOME%\mmry-handoff\.mmry-codex-late.*") do set "MMRY_LATE=1"
if defined HOME for %%F in ("%HOME%\.codex\mmry-handoff\.mmry-codex-late.*") do set "MMRY_LATE=1"
if defined USERPROFILE for %%F in ("%USERPROFILE%\.codex\mmry-handoff\.mmry-codex-late.*") do set "MMRY_LATE=1"
if not defined MMRY_LATE exit /b 0
:after_late_gate
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
rem THE APPROVAL HOOK GOES THROUGH THE SAME GATE (#33903). formation-waiting, the Codex PermissionRequest
rem hook, has work only for a Formation member, and it runs on every approval prompt for every person.
rem Without this a person in no Formation paid where.exe, reg.exe, bash and the library, 0.9 to 1.6 s
rem measured, on each prompt before formation-waiting.sh found nothing to do. The sh form in
rem hooks/codex-hooks.json carries the identical gate the formation-check entries carry. Only the
rem raise, formation-waiting with no second argument; any other formation-waiting entry keeps its own
rem gate.
if /i "%~1"=="formation-waiting" if "%~2"=="" goto :formation_gate
if /i not "%~1"=="formation-check" goto :after_formation_gate
:formation_gate
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

rem 1. THE git.exe ON PATH, FOUND WITHOUT A PROCESS (#33967). This was `for /f` over
rem    `where.exe $PATH:git.exe`, which is two processes on every hook (the cmd that `for /f` starts and
rem    where.exe), and on a loaded machine each is about a second of a hook's limit. The same search in
rem    builtins: each PATH entry in order, the first holding git.exe with Git's bin\bash.exe one or two
rem    levels up. ONLY ABSOLUTE ENTRIES (X:\ or \\server), which is what $PATH: gave where.exe: an
rem    entry such as "." or "tools" would name a folder in the customer's project, and a git.exe planted
rem    there must never choose the bash (security, #31245 QA round 10).
rem    PATH IS READ AS WRITTEN (#33967 QA round 1): the walk is in :from_path, at the end of this file.
if defined PATH call :from_path

if not defined MMRY_GIT_BASH call :from_registry HKLM
if not defined MMRY_GIT_BASH call :from_registry HKCU

if not defined MMRY_GIT_BASH if exist "%ProgramW6432%\Git\bin\bash.exe" set "MMRY_GIT_BASH=%ProgramW6432%\Git\bin\bash.exe"
if not defined MMRY_GIT_BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "MMRY_GIT_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined MMRY_GIT_BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "MMRY_GIT_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined MMRY_GIT_BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "MMRY_GIT_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if not defined MMRY_GIT_BASH goto :no_git

"%MMRY_GIT_BASH%" "%~dp0codex-hook.sh" %*
exit /b %ERRORLEVEL%

rem THE PATH WALK, READING PATH AS WRITTEN (#33967 QA round 1). Round 1 split PATH with a percent
rem substitution, which cmd expands BEFORE it parses the line, and handed each entry to a `call`, which
rem parses it a second time. So a quote in PATH, legal and common ("C:\Program Files\Git\cmd";...), broke
rem the line: a quoted Git entry made every hook exit 255 with `=1" was unexpected at this time.`, and a
rem quoted or unbalanced entry before Git's made every hook exit 0 without running. A percent sign or a
rem caret in an entry was changed by the second parse, so that entry was never looked in. where.exe read
rem all of these. (No percent sign is written in these lines: cmd expands them even in a rem.)
rem   - Delayed expansion (!...!) puts a value in after cmd has parsed the line, so nothing in PATH is
rem     ever read as cmd syntax: not a quote, an ampersand, a bracket, a percent sign or a caret.
rem   - Quotes are taken out first. Windows' own search ignores them, and the walk then splits only on
rem     the semicolons. An entry quoted because it holds a semicolon splits in two; neither half holds
rem     git.exe, and the registry below is used, as for any PATH without Git.
rem   - Each entry is handled inside the loop, never handed to `call`, which would parse it again.
rem   - A ! IN AN ENTRY IS A CHARACTER (#33967 QA round 2). Round 2 copied each entry with delayed
rem     expansion on, so cmd expanded !NAME! inside it. That was wrong, and so was its comment, which
rem     said such an entry was not found and failed safe: !CD!\tools became the project's own tools
rem     folder, and a git.exe and bin\bash.exe planted there ran as the hook (likewise !__CD__!tools,
rem     the drive's current folder !=C:!, and !CD! alone); a lone ! was dropped, so C:\x\pl!ain\cmd was
rem     looked in as C:\x\plain\cmd. Now each entry is copied with delayed expansion OFF, so it is
rem     taken as written: !CD!\tools is not absolute and is skipped, and a Git installed under a
rem     folder holding ! is found where it is, as where.exe found it. Delayed expansion is turned on
rem     again only to test the copy, and a value read that way is never read a second time.
rem   - The answer leaves straight from the loop: endlocal back to the caller, whose delayed expansion
rem     is off, and the set on the same line, so a ! in the answer stays a !. Then exit /b, which
rem     ends the walk at the first match.
:from_path
setlocal enabledelayedexpansion
set "MMRY_PS=!PATH:"=!"
for %%P in ("!MMRY_PS:;=" "!") do (
    setlocal disabledelayedexpansion
    set "MMRY_PE=%%~P"
    setlocal enabledelayedexpansion
    set "MMRY_HIT="
    if defined MMRY_PE (
        set "MMRY_PE_ABS="
        if "!MMRY_PE:~1,2!"==":\" set "MMRY_PE_ABS=1"
        if "!MMRY_PE:~0,2!"=="\\" set "MMRY_PE_ABS=1"
        if defined MMRY_PE_ABS (
            if "!MMRY_PE:~-1!"=="\" set "MMRY_PE=!MMRY_PE:~0,-1!"
            if exist "!MMRY_PE!\git.exe" (
                if exist "!MMRY_PE!\..\bin\bash.exe" set "MMRY_HIT=!MMRY_PE!\..\bin\bash.exe"
                if not defined MMRY_HIT if exist "!MMRY_PE!\..\..\bin\bash.exe" set "MMRY_HIT=!MMRY_PE!\..\..\bin\bash.exe"
            )
        )
    )
    if defined MMRY_HIT for /f "delims=" %%H in ("!MMRY_HIT!") do endlocal & endlocal & endlocal & set "MMRY_GIT_BASH=%%H" & exit /b 0
    endlocal & endlocal
)
endlocal
exit /b 0

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
:stop_check_quiet
rem Sets MMRY_SQ_QUIET only when stop-check, run now, would certainly say nothing and change nothing:
rem   - its marker and the record beside it (.mmry-stop-checked.cmd, "SSSSS <date>", which stop-check
rem     writes when it stamps the marker, from the two values below that this launcher handed it) are
rem     both in the folder stop-check uses: TMPDIR, else TMP, else TEMP (Git's bash maps /tmp to the
rem     user's temp folder), and only when that is an absolute Windows path;
rem   - the record is from today by cmd's own %DATE%, and from 0 to 879 s before this launch. The quiet
rem     time in stop-check.sh is 900 s from its own stamp. 20 s are kept in hand because stop-check,
rem     had it run, would have run up to 10 s after this launch (Codex stops it at 10 s);
rem   - no Formation renewal-turn marker is waiting: stop-check spends those, so it must run.
rem It also hands stop-check this launch's seconds of the day and date (MMRY_CODEX_HOOK_SECS and
rem MMRY_CODEX_HOOK_DATE), so the record is written in exactly the form read here: no clock or date
rem arithmetic is shared between cmd and bash. A %TIME% that is not HH:MM:SS.cc in shape (a space for a
rem leading zero, any one-character separators) hands over neither, and stop-check then writes no
rem record. The record's text is compared with delayed expansion, so it is never parsed as commands.
rem Builtins only: set, set /a, set /p, if, for /f over a string, call.
set "MMRY_SQ_QUIET="
set "MMRY_CODEX_HOOK_SECS="
set "MMRY_CODEX_HOOK_DATE="
set "MMRY_SQ_T=%MMRY_CODEX_HOOK_STARTED: =0%"
if not "%MMRY_SQ_T:~11%"=="" exit /b 0
set "MMRY_SQ_D8=%MMRY_SQ_T:~0,2%%MMRY_SQ_T:~3,2%%MMRY_SQ_T:~6,2%%MMRY_SQ_T:~9,2%"
if "%MMRY_SQ_D8:~7,1%"=="" exit /b 0
for /f "delims=0123456789" %%X in ("%MMRY_SQ_D8%x") do if not "%%X"=="x" exit /b 0
for /f "delims=0123456789" %%X in ("a%MMRY_SQ_T:~2,1%") do if "%%X"=="a" exit /b 0
for /f "delims=0123456789" %%X in ("a%MMRY_SQ_T:~5,1%") do if "%%X"=="a" exit /b 0
for /f "delims=0123456789" %%X in ("a%MMRY_SQ_T:~8,1%") do if "%%X"=="a" exit /b 0
set /a "MMRY_SQ_H=1%MMRY_SQ_T:~0,2%-100, MMRY_SQ_M=1%MMRY_SQ_T:~3,2%-100, MMRY_SQ_S=1%MMRY_SQ_T:~6,2%-100"
if %MMRY_SQ_H% gtr 23 exit /b 0
if %MMRY_SQ_M% gtr 59 exit /b 0
if %MMRY_SQ_S% gtr 59 exit /b 0
if not defined DATE exit /b 0
set /a "MMRY_CODEX_HOOK_SECS=MMRY_SQ_H*3600+MMRY_SQ_M*60+MMRY_SQ_S"
set "MMRY_CODEX_HOOK_DATE=%DATE%"
set "MMRY_SQ_DIR=%TEMP%"
if defined TMP set "MMRY_SQ_DIR=%TMP%"
if defined TMPDIR set "MMRY_SQ_DIR=%TMPDIR%"
set "MMRY_SQ_ABS="
if "%MMRY_SQ_DIR:~1,2%"==":\" set "MMRY_SQ_ABS=1"
if "%MMRY_SQ_DIR:~0,2%"=="\\" set "MMRY_SQ_ABS=1"
if not defined MMRY_SQ_ABS exit /b 0
if "%MMRY_SQ_DIR:~-1%"=="\" set "MMRY_SQ_DIR=%MMRY_SQ_DIR:~0,-1%"
if exist "%MMRY_SQ_DIR%\.mmry-renewal-turn-*" exit /b 0
if not exist "%MMRY_SQ_DIR%\.mmry-stop-checked" exit /b 0
if not exist "%MMRY_SQ_DIR%\.mmry-stop-checked.cmd" exit /b 0
set "MMRY_SQ_REC="
set /p "MMRY_SQ_REC=" 0<"%MMRY_SQ_DIR%\.mmry-stop-checked.cmd"
if not defined MMRY_SQ_REC exit /b 0
setlocal enabledelayedexpansion
if not "!MMRY_SQ_REC:~5,1!"==" " goto :stop_check_loud
set "MMRY_SQ_RS=!MMRY_SQ_REC:~0,5!"
for /f "delims=0123456789" %%X in ("!MMRY_SQ_RS!x") do if not "%%X"=="x" goto :stop_check_loud
if not "!MMRY_SQ_REC:~6!"=="!MMRY_CODEX_HOOK_DATE!" goto :stop_check_loud
set /a "MMRY_SQ_AGE=MMRY_CODEX_HOOK_SECS-(1!MMRY_SQ_RS!-100000)"
if !MMRY_SQ_AGE! lss 0 goto :stop_check_loud
if !MMRY_SQ_AGE! geq 880 goto :stop_check_loud
endlocal & set "MMRY_SQ_QUIET=1"
exit /b 0
:stop_check_loud
endlocal
exit /b 0
