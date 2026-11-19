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
rem STOP-CHECK'S PROMPT IS SAID HERE TOO (#33967 round 5). In the round 4 live measurement (Codex 0.169.0,
rem a load of 496 ms per process start) the quiet message was at the floor, but on the first message
rem stop-check still failed at its 10 s limit, while formation-check, which ends here in cmd, took 9.5 s:
rem the prompt cost the floor plus Git's bash. So :stop_check_say, at the end of this file, says the prompt
rem itself, with builtins only, whenever it can be sure what stop-check would say, and leaves the files
rem stop-check leaves. Anything it cannot be sure of goes on to stop-check as before.
if /i "%~1"=="stop-check" call :stop_check_say
if /i "%~1"=="stop-check" if defined MMRY_SQ_SAID exit /b 0
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

rem EVERY HANDLER IS HANDED THIS LAUNCH'S SECONDS OF THE DAY AND DATE (#33967 round 5), not only
rem stop-check: codex-hook.sh leaves :stop_check_say its clock from them, and the session start and the
rem Foundation parts are the launches that reach it. stop-check's were set by :stop_check_quiet.
if /i not "%MMRY_HANDLER%"=="stop-check" call :launch_clock
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
call :launch_clock
if not defined MMRY_CODEX_HOOK_SECS exit /b 0
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
:launch_clock
rem Sets MMRY_CODEX_HOOK_SECS, this launch's seconds of the day, and MMRY_CODEX_HOOK_DATE, cmd's date, from
rem the stamp taken as this file's first step, or leaves both unset when the stamp is not HH:MM:SS.cc in
rem shape (a space for a leading zero, any one-character separators). Split out of :stop_check_quiet,
rem unchanged, by round 5, so every handler is handed them. Builtins only.
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
exit /b 0
:stop_check_say
rem Says stop-check's prompt, or its "a save already landed" silence, from cmd (#33967 round 5), and sets
rem MMRY_SQ_SAID when it has answered for stop-check. It answers only when it can be sure what
rem stop-check.sh would say on Codex, and then leaves the files stop-check leaves; anything else leaves
rem MMRY_SQ_SAID unset, having written nothing, and stop-check runs as before. It answers when:
rem   - the folder is stop-check's (TMPDIR, else TMP, else TEMP), an absolute Windows path, and no Formation
rem     renewal-turn marker is waiting (stop-check spends those);
rem   - THE CLOCK. cmd cannot read the time in seconds since 1970, which stop-check's files hold, so
rem     codex-hook.sh leaves it .mmry-codex-clock.cmd on every launch the launcher handed its seconds and
rem     date (the session start's included): "SSSSS EEEEEEEEEE <date>", bash's seconds of the day and its
rem     epoch read at one instant, with this launcher's date. It is used only when its date is today's and
rem     its seconds are not after this launch's; now is its epoch plus the seconds since. On the night a
rem     clock change falls between the clock and now this is an hour out, which can only move one prompt;
rem   - stop-check's marker is absent (the first message of a fresh home), or it is 900 s or more old by
rem     the time stop-check keeps beside it (.mmry-stop-checked.at), with the launcher's record beside it
rem     well formed (so the last stamp was a launcher's, whose time is consistent). Under 900 s it is
rem     stop-check's to decide: :stop_check_quiet answers the clear cases from the record;
rem   - each file it reads is one line of digits as stop-check would read it (spaces dropped), epochs
rem     of 10 digits no larger than 2147483647, a count of up to 8 digits with no leading zero.
rem What it then does is stop-check.sh's Codex path, step for step: a save at or after the marker's time
rem means silence, a stamp and a count of 0; otherwise a stamp (time, marker, record), the count plus
rem one, and the directive, with the last save's minutes, the escalation from 3 firings and the
rem compaction clause, printed as one JSON line with no newline. A marker that cannot be written ends it
rem silently, as stop-check's set -e does. tests/structural/codex-per-message-in-time.bats runs both on
rem the same state and requires the same words and files. Builtins only: set, set /a, set /p, if, call,
rem for over a list, type nul, echo and redirection.
set "MMRY_SQ_SAID="
if not defined MMRY_CODEX_HOOK_SECS exit /b 0
if not defined MMRY_CODEX_HOOK_DATE exit /b 0
set "MMRY_SS_DIR=%TEMP%"
if defined TMP set "MMRY_SS_DIR=%TMP%"
if defined TMPDIR set "MMRY_SS_DIR=%TMPDIR%"
set "MMRY_SS_ABS="
if "%MMRY_SS_DIR:~1,2%"==":\" set "MMRY_SS_ABS=1"
if "%MMRY_SS_DIR:~0,2%"=="\\" set "MMRY_SS_ABS=1"
if not defined MMRY_SS_ABS exit /b 0
if "%MMRY_SS_DIR:~-1%"=="\" set "MMRY_SS_DIR=%MMRY_SS_DIR:~0,-1%"
if exist "%MMRY_SS_DIR%\.mmry-renewal-turn-*" exit /b 0
setlocal enabledelayedexpansion
set "MMRY_SS_MK=!MMRY_SS_DIR!\.mmry-stop-checked"
rem The clock, read whole: its date holds spaces.
set "MMRY_SS_C="
if exist "!MMRY_SS_DIR!\.mmry-codex-clock.cmd" set /p "MMRY_SS_C=" 2>nul 0<"!MMRY_SS_DIR!\.mmry-codex-clock.cmd"
if not defined MMRY_SS_C goto :ss_run
if not "!MMRY_SS_C:~5,1!"==" " goto :ss_run
if not "!MMRY_SS_C:~16,1!"==" " goto :ss_run
if not "!MMRY_SS_C:~17!"=="!MMRY_CODEX_HOOK_DATE!" goto :ss_run
set "MMRY_SS_V=!MMRY_SS_C:~0,5!"
call :ss_digits
if not defined MMRY_SS_OK goto :ss_run
set /a "MMRY_SS_CS=1!MMRY_SS_V!-100000"
set "MMRY_SS_V=!MMRY_SS_C:~6,10!"
call :ss_epoch
if not defined MMRY_SS_OK goto :ss_run
set /a "MMRY_SS_SINCE=MMRY_CODEX_HOOK_SECS-MMRY_SS_CS"
if !MMRY_SS_SINCE! lss 0 goto :ss_run
set /a "MMRY_SS_NOW=!MMRY_SS_V!+MMRY_SS_SINCE"
rem The marker: absent, or 900 s or more old by the time beside it.
set "MMRY_SS_AT="
if not exist "!MMRY_SS_MK!" goto :ss_marker_done
set "MMRY_SS_R="
if exist "!MMRY_SS_MK!.cmd" set /p "MMRY_SS_R=" 2>nul 0<"!MMRY_SS_MK!.cmd"
if not defined MMRY_SS_R goto :ss_run
if not "!MMRY_SS_R:~5,1!"==" " goto :ss_run
set "MMRY_SS_V=!MMRY_SS_R:~0,5!"
call :ss_digits
if not defined MMRY_SS_OK goto :ss_run
set "MMRY_SS_F=!MMRY_SS_MK!.at"
call :ss_read
call :ss_epoch
if not defined MMRY_SS_OK goto :ss_run
set "MMRY_SS_AT=!MMRY_SS_V!"
set /a "MMRY_SS_AGE=MMRY_SS_NOW-MMRY_SS_AT"
if !MMRY_SS_AGE! lss 900 goto :ss_run
:ss_marker_done
rem The last save, if any.
set "MMRY_SS_SV="
if not exist "!MMRY_SS_DIR!\.mmry-last-save" goto :ss_save_done
set "MMRY_SS_F=!MMRY_SS_DIR!\.mmry-last-save"
call :ss_read
call :ss_epoch
if not defined MMRY_SS_OK goto :ss_run
set "MMRY_SS_SV=!MMRY_SS_V!"
:ss_save_done
rem The firings since the last save.
set "MMRY_SS_N=0"
if not exist "!MMRY_SS_DIR!\.mmry-stop-count" goto :ss_count_done
set "MMRY_SS_F=!MMRY_SS_DIR!\.mmry-stop-count"
call :ss_read
if not defined MMRY_SS_V goto :ss_count_done
call :ss_digits
if not defined MMRY_SS_OK goto :ss_run
if not "!MMRY_SS_V:~8!"=="" goto :ss_run
if "!MMRY_SS_V:~0,1!"=="0" if not "!MMRY_SS_V!"=="0" goto :ss_run
set /a "MMRY_SS_N=!MMRY_SS_V!"
:ss_count_done
rem Sure now. The stamp, in stop-check's order: its time, the marker, the launcher's record.
set "MMRY_SS_P=0000!MMRY_CODEX_HOOK_SECS!"
set "MMRY_SS_P=!MMRY_SS_P:~-5!"
>"!MMRY_SS_MK!.at" 2>nul echo !MMRY_SS_NOW!
type nul >"!MMRY_SS_MK!" 2>nul
if not exist "!MMRY_SS_MK!" goto :ss_silent
<nul >"!MMRY_SS_MK!.cmd" 2>nul set /p "=!MMRY_SS_P! !MMRY_CODEX_HOOK_DATE!"
rem A save at or after the marker's time: nothing is outstanding, so silence and a count of 0.
if not defined MMRY_SS_AT goto :ss_prompt
if not defined MMRY_SS_SV goto :ss_prompt
if !MMRY_SS_SV! lss !MMRY_SS_AT! goto :ss_prompt
>"!MMRY_SS_DIR!\.mmry-stop-count" 2>nul echo 0
goto :ss_silent
:ss_prompt
set /a "MMRY_SS_N+=1"
>"!MMRY_SS_DIR!\.mmry-stop-count" 2>nul echo !MMRY_SS_N!
set "MMRY_SS_TX=Save what is new since the last memory: identify decisions, findings, and corrections from this segment of the session, then call the mmry_plugin memory_save tool for each, with the memory as its content. If nothing new is worth keeping, skip and proceed."
if not defined MMRY_SS_SV goto :ss_said_save
set /a "MMRY_SS_MIN=(MMRY_SS_NOW-MMRY_SS_SV)/60"
if !MMRY_SS_MIN! lss 1 set "MMRY_SS_TX=!MMRY_SS_TX! Your last save was under a minute ago; save only what is genuinely new since then, or skip."
if !MMRY_SS_MIN! geq 1 set "MMRY_SS_TX=!MMRY_SS_TX! Your last save was !MMRY_SS_MIN! minute(s) ago; save only what is new since then."
:ss_said_save
if !MMRY_SS_N! geq 3 set "MMRY_SS_TX=!MMRY_SS_TX! You have skipped !MMRY_SS_N! Stop firings without saving. Either save now or briefly state in your reply why this segment has nothing worth keeping."
set "MMRY_SS_TX=!MMRY_SS_TX! Codex gives MMRY no moment at compaction and no channel at session end, so this periodic prompt is the only warning you get: anything not saved can be lost when the conversation is trimmed."
<nul set /p "={"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"!MMRY_SS_TX!"}}"
:ss_silent
endlocal & set "MMRY_SQ_SAID=1"
exit /b 0
:ss_run
endlocal
exit /b 0

rem :stop_check_say's reader: the file MMRY_SS_F's first line into MMRY_SS_V, as stop-check reads it, spaces
rem dropped as stop-check drops whitespace. set /p stops at CRLF and drops a final LF, but reads on past an
rem LF inside: that LF is not a digit, so every caller then lets stop-check run (measured, round 5).
:ss_read
set "MMRY_SS_V="
set /p "MMRY_SS_V=" 2>nul 0<"!MMRY_SS_F!"
if not defined MMRY_SS_V exit /b 0
set "MMRY_SS_V=!MMRY_SS_V: =!"
exit /b 0

rem MMRY_SS_OK when MMRY_SS_V is one or more digits and nothing else: every digit is taken out, and nothing
rem may be left. (A for /f with digits for delimiters would pass 12x3.)
:ss_digits
set "MMRY_SS_OK="
if not defined MMRY_SS_V exit /b 0
set "MMRY_SS_W=!MMRY_SS_V!"
for %%D in (0 1 2 3 4 5 6 7 8 9) do if defined MMRY_SS_W set "MMRY_SS_W=!MMRY_SS_W:%%D=!"
if not defined MMRY_SS_W set "MMRY_SS_OK=1"
exit /b 0

rem MMRY_SS_OK when MMRY_SS_V is an epoch cmd can do sums with: 10 digits, no leading zero, no larger than
rem 2147483647 (set /a is 32-bit; compared as text, which is exact for two 10-digit numbers).
:ss_epoch
call :ss_digits
if not defined MMRY_SS_OK exit /b 0
set "MMRY_SS_OK="
if "!MMRY_SS_V:~9,1!"=="" exit /b 0
if not "!MMRY_SS_V:~10!"=="" exit /b 0
if "!MMRY_SS_V:~0,1!"=="0" exit /b 0
if "!MMRY_SS_V!" gtr "2147483647" exit /b 0
set "MMRY_SS_OK=1"
exit /b 0
