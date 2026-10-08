# #31746 evidence: the formation check's time before a prompt, on a loaded Windows machine

Requirement 1 asks for the check's time before a prompt to be measured on a loaded Windows machine,
recorded with the method and the machine load, and shown to stay within the budget with margin.

## Machine

Windows 11 Pro 10.0.26200, 13th Gen Intel Core i7-13700 (24 logical CPUs), 31.7 GB RAM.
Git Bash 5.2.37 (x86_64-pc-msys), jq 1.8.2 (system, on PATH), curl 8.18.0, node 22.14.0.
Measured 2026-10-07. The machine was also running the owner's other Claude Code sessions throughout
("ambient" below), so the load is the generated load plus whatever those sessions were doing.

## Method (`measure.sh`)

Each run times **the command Claude Code registers**, verbatim from `hooks/hooks.json`:

    bash -c "[ -f ~/.claude/mmry/hooks-handlers/formation-check.sh ] || exit 0; bash ~/.claude/mmry/hooks-handlers/hook-guard.sh formation-check"

with a real `UserPromptSubmit` payload on stdin, in a fresh isolated `HOME` and `TMPDIR` holding a
config and a formation state, so every run delivers one message. The Codex variants time the
`commandWindows` form from `hooks/codex-hooks.json`:

    cmd /d /c "<plugin>\hooks-handlers\codex-hook.cmd" formation-check

- **total** is launch to exit, measured outside the command.
- **prep** is launch to the moment a local stub service received the request (the stub logs its
  arrival in ms): everything the check does before it asks anything, launch chain included.
- The stub answers at once, so these are each version's best case for the request itself. Under
  a slow service develop could wait 25 s more; this branch at most 6 s (prompt).
- `old` is `origin/develop` at e99286c; `new` is this branch. They alternate run by run so both see
  the same moment's load. 10 rounds per load level, 4 variants per round.

Load was generated with `load2.sh`: busy-loop bash workers (one CPU each) plus idle bash workers that
wake and fork once per interval, on top of the ambient load. The load was recorded with `ps`
(MSYS bash processes), `Win32_Processor.LoadPercentage` sampled once a second, free RAM, and
`bash -c true` timed five times. The ticket's recorded load was 62 bash processes, CPU 34%, 4.0 GB
free, `bash -c true` 101 ms, and develop spending about 6 s before its first request.

## Results

Budget: 15 s for this branch (all three synchronous registrations, both hosts). Develop's prompt
budget was 10 s.

### Load matched to the ticket: 8 spinners + 50 idle (3 s), `load-mid.txt`

73 MSYS bash processes, CPU 38-53%, 5.3 GB free, `bash -c true` 105-126 ms.

| variant | total median (min-max) | prep median (max) | inside budget |
|---|---|---|---|
| develop, Claude Code | 5.20 s (3.95-30.46) | 2.94 s (19.09) | 9/10 within 10 s |
| **this branch, Claude Code** | **2.95 s (1.52-3.86)** | **1.90 s (2.83)** | **10/10 within 15 s** |
| develop, Codex | 7.19 s (4.13-10.64) | 4.34 s (7.67) | 9/10 within 10 s |
| **this branch, Codex** | **2.58 s (1.74-18.53)** | **1.61 s (9.03)** | **9/10 within 15 s** |

Margin on the prompt route: the worst Claude Code run spent 2.83 s before asking. With the request
limited to 6 s that is at most about 8.8 s plus writing out, against 15 s: about 6 s of margin.

The one Codex run over 15 s (round 5, 18.5 s) sits next to develop's 30.5 s in round 6, the same
window: the whole machine stalled for several seconds. It is reported, not dropped.

### Lighter: 6 spinners + 50 idle (10 s), `load-light.txt`

66 MSYS bash processes, CPU 48-73%, 3.4 GB free, `bash -c true` 157-200 ms.

| variant | total median (min-max) | prep median (max) | inside budget |
|---|---|---|---|
| develop, Claude Code | 3.17 s (2.34-4.36) | 1.95 s (2.69) | 10/10 within 10 s |
| this branch, Claude Code | 1.06 s (0.90-1.69) | 0.68 s (1.13) | 10/10 within 15 s |
| develop, Codex | 3.61 s (2.97-8.60) | 2.59 s (4.43) | 10/10 within 10 s |
| this branch, Codex | 1.57 s (1.09-3.00) | 0.86 s (1.92) | 10/10 within 15 s |

### Stress, several times the ticket: 8 spinners + 50 idle (2 s), `load-heavy.txt`

113 MSYS bash processes, CPU 35-43% (40-50% at the end), 4.6 GB free, `bash -c true` 147-900 ms.
Develop needed 15.7 s median just to get ready here, against the ticket's 6 s.

| variant | total median (min-max) | prep median (max) | inside budget | shown |
|---|---|---|---|---|
| develop, Claude Code | 28.04 s (9.30-80.73) | 15.65 s (67.09) | 1/10 within 10 s | 10/10 |
| this branch, Claude Code | 7.77 s (4.15-16.19) | 4.78 s (12.30) | 9/10 within 15 s | 10/10 |
| develop, Codex | 24.15 s (14.32-31.92) | 16.05 s (22.36) | 0/10 within 10 s | 10/10 |
| this branch, Codex | 11.04 s (3.45-30.14) | 7.30 s (20.96) | 7/10 within 15 s | 7/10 |

At this level the launch chain alone - before the handler's own clock starts - can take longer than
the 4 s the deadline reserves for it, most of all on Codex (`cmd`, `where`, Git's `bash.exe`,
`codex-hook.sh`, then the handler). The three Codex runs that did not show anything were past the
deadline and printed and marked nothing, so their message stays pending for the next check; under
Codex they would also have shown the timeout notice. This is the limit named in DD-100.

## Raw files

- `measure.sh`, `load2.sh`, `summarize.js`: the harness, the load generator, the summary.
- `timing-mid.txt`, `timing-light.txt`, `timing-heavy.txt`: one row per run
  (`impl run total_ms prep_ms delivered`).
- `load-mid.txt`, `load-light.txt`, `load-heavy.txt`: the load as recorded before (and for mid and
  heavy, after) each run.

To repeat: `bash measure.sh <develop hooks-handlers> <branch hooks-handlers> 10 out.txt` with
`load2.sh SPIN IDLE STOPFILE NAP` running, then `node summarize.js out.txt 15000`.

## Round 2: the membership gate (requirement added 2026-10-07)

Every registered formation-check command now opens with a check for any `.mmry-formation-*`
regular file in `${TMPDIR:-/tmp}`, and exits 0 with no output when there is none.

| Host form | The gate |
|---|---|
| Claude Code, `hooks/hooks.json` (4 registrations) | `sh -c 'for f in "${TMPDIR:-/tmp}"/.mmry-formation-*; do if [ -f "$f" ]; then ...; fi; done; exit 0'` |
| Codex `command`, `hooks/codex-hooks.json` (3) | the same opening and close, launching `codex-hook.sh` on a match |
| Codex `commandWindows` (3) | first step of `codex-hook.cmd`: cmd `for` over `%TMPDIR%`, or `%TEMP%`, `%TMP%`, `%LOCALAPPDATA%\Temp` when TMPDIR is unset |

Measured on Windows, 2026-10-07, no membership file, real handlers installed:

- Processes the OS created per firing (Windows job object, `tests/helpers/count-processes.ps1`,
  3 runs each): the old registration 13, the gate 3. The 3 are the host's bash and the gate's `sh`,
  which Cygwin starts as a fork plus an exec; a host bash starting one no-op `sh` is also 3.
- The Codex Windows launcher with no membership file: 1 process, the same as `cmd /d /c exit 0`.
- Wall time, 10 runs each on a machine other work was loading: old median about 1,280 ms
  (674 to 3,385), gate median about 514 ms (126 to 1,280). Both include the host bash's own start.

`tests/structural/formation-gate.bats` is the proof for each test case, and seven breaks of the
gate in `tests/structural/run-codex-mutations.sh` (label `31746 gate`) are each refused.
