# #31976 evidence: the message check before each prompt, on a loaded Windows machine

Test cases 1 and 2: twenty consecutive timed runs through the hook guard on a Windows machine
loaded with at least two agents running test suites, all under 12 seconds; and a per-step timing
log of one loaded run, before and after the change.

## Machine and load

Windows 11 Pro 10.0.26300, Git Bash 5.2.37 (x86_64-pc-msys), jq 1.8.2 on PATH (WinGet), bundled
jq 1.7.1, node 22.14.0. Measured 2026-10-10.

The load was other work, not a synthetic CPU spinner:

- **Two simulated agents running test suites**: two loops, each running this plugin's BATS
  structural suite (`tests/run-tests.sh structural`, HOME and TMPDIR isolated) from its own copy,
  for the whole session.
- **A third suite** for the final interleaved runs: the BATS run for this change, on the same
  machine at the same time.
- **The owner's other agents** throughout (ambient): the process counts below include them.

Recorded with every run (columns `node_procs bash_procs`, from `tasklist`): 29 to 33 `node.exe`
and 50 to 79 `bash.exe`. CPU (Win32_Processor.LoadPercentage) read 12 to 36% and free memory 4.9 GB.
The cost on this machine is process creation, not CPU: starting any process took 0.33 to 1.6 s,
including the host's own bash before any MMRY code runs (see the traces).

## Method

`run.sh` times **the UserPromptSubmit formation-check registration, verbatim from
`hooks/hooks.json`**, under `bash -c` as Claude Code runs it: the `sh -c` membership gate, then
`hook-guard.sh`, then `formation-check.sh`. Each run has a fresh isolated HOME (handlers copied to
`HOME/.claude/mmry/hooks-handlers`) and TMPDIR, `CLAUDE_CODE_SESSION_ID` set, a UserPromptSubmit
payload on stdin, a membership record that already carries a last-seen time, and a config naming
`stub.js`, a local service that answers at once with one message and logs when it was asked.

- **total**: launch to exit, timed outside the command with `EPOCHREALTIME`.
- **prep**: launch to the moment the stub was asked. Everything the check does before it asks.
- **delivered**: the message was in the hook's output.

With more than one handler set, each round runs every set in turn, so they share the moment's load.
`NOSYSJQ_PLUGIN` drops every PATH directory holding a jq and sets `CLAUDE_PLUGIN_ROOT`, as Claude
Code does for plugin hooks: the machine most Windows customers have, which uses the bundled jq.

Per-step: `tracer.bash` is loaded through `BASH_ENV` by every bash in the chain and writes an xtrace
line per command stamped with `EPOCHREALTIME` (no process added). `steps.js` turns one trace into
steps by the bash function stack and by section markers it finds in the handler the trace came from.
The time from one command to the next is that command's cost, so the cost of a fork can land on the
neighbouring line; the steps are close at their edges, not exact.

`before` is `origin/develop` at 1b8b575 (plugin 2.10.2, which carries #31746). `after` is this
branch at 932a5ec.

## Where the time went (before)

Nothing in the check does much work. Its time goes on starting processes: about 15 per delivering
prompt check, each 0.33 to 1.6 s on this machine under load. Where a run spends its time is where
the stalls happened to land. Per-step, from a loaded run (`traces/before-1.trace`, total 7.7 s):

| step | before-1 | after-1 |
|---|---|---|
| 00 the host's bash starts (before any MMRY code) | 0.09 s | 1.72 s |
| 01 sh membership gate, hook-guard.sh, start formation-check.sh | 0.40 s | 0.06 s |
| 02 credential check, resolve jq | 0.39 s | 0.01 s |
| 03 read stdin, parse the payload (jq) | 1.08 s | 0.07 s |
| 04 membership record, load the client, read config (jq) | 0.99 s | 0.40 s |
| 05 take the delivery mutex (mkdir), read the record | 0.05 s | 0.03 s |
| 06 url-encode session id and since | 0.46 s | 0.00 s |
| 07 request (auth header, mktemp, curl, read, rm) | 0.85 s | 0.76 s |
| 08 parse and render the response (jq) | 0.35 s | 0.02 s |
| 09 write additionalContext (jq) | 1.04 s | 1.06 s |
| 10 mark seen, release the mutex | 1.98 s | 0.05 s |
| 11 other | 0.04 s | 0.37 s |
| **total** | **7.72 s** | **4.53 s** |

Step 00 is the host's bash starting, before any line of the plugin. It was 0.09 s in one run and
1.72 s in the next, which is the scale of the noise every step here is subject to. All six traces
are in `traces/`; `node steps.js traces/after-1.trace <handler>/formation-check.sh` reproduces a row.

## What changed (the processes removed)

| before | after | processes saved |
|---|---|---|
| `hook-guard.sh` starts a second bash for `formation-check.sh` | sources it in the same shell, only when it sits beside the guard; every other handler still `exec bash` | 1 |
| `jq --version` before the first jq use | the payload parse is the proof; a jq that does not answer falls back to `mmry_resolve_jq` as before | 1 |
| with no system jq: `$(_mmry_jq_bundle_name)`, two `uname`, `$(_mmry_jq_vendor_dir)` | `mmry_jq_candidate`, from `OSTYPE` and `HOSTTYPE` | 4 |
| `$(printf \| jq)` for the payload | `jq <<< "$payload"` | 1 |
| `_mmry_urlencode`: `$(printf \| sed)`, twice | parameter expansion into `_MMRY_URLENC` | 4 to 6 |
| `$(_mmry_get_auth_header)` | `_mmry_auth_header_v`, no command substitution | 1 |
| `$(cat "$tmp_resp")` | `read -r -d ''` | 1 |
| `printf \| jq -Rs` to write the answer | `jq -Rs ... <<< "$FORMATION_BLOCK"` | 1 |
| `rm -f pid; rmdir` to release a lock | `rm -rf` | 1 |

Unchanged: the order (printed first, marked seen after, under the delivery mutex), the deadline
and request limits from #31746, the registration in `hooks.json`, and the Codex launcher.

## Test case 1: twenty consecutive runs through the hook guard

Interleaved, 20 rounds, both versions each round, three suites plus ambient agents
(`interleaved-20.txt`):

| | total median (min to max) | prep median (max) | under 12 s | delivered |
|---|---|---|---|---|
| before | 6.56 s (3.41 to 12.03) | 4.58 s (8.87) | 19/20 | 20/20 |
| **after** | **4.49 s (2.89 to 7.02)** | **2.68 s (4.73)** | **20/20** | **20/20** |

Load: node 29, bash 59 to 79.

Sequential, 20 runs each, two suites plus ambient agents (`seq-before-20.txt` on develop,
`seq-after-20.txt` at 77458eb, the first commit; the jq candidate came after):

| | total median (min to max) | under 12 s |
|---|---|---|
| before | 7.61 s (5.08 to 13.42) | 19/20 |
| after | 3.90 s (2.22 to 5.79) | 20/20 |

No system jq, the bundled jq, interleaved 10 rounds (`interleaved-nosysjq-10.txt`):

| | total median (min to max) | under 12 s |
|---|---|---|
| before | 7.51 s (5.30 to 9.11) | 10/10 |
| after | 4.60 s (2.75 to 4.78) | 10/10 |

Margin: the slowest after-run was 7.02 s against the 15 s limit, about 8 s of margin; against the
ticket's 12 s bar, about 5 s.

## Test case 2: the per-step log

The table above is one loaded run of each. All six are in `traces/` (`before-1..3`, `after-1..3`,
taken interleaved, `traced-3.txt` holds their totals). Tracing adds a little time per command.

## To repeat

    # load: two loops of `tests/run-tests.sh structural`, each from its own copy of the plugin
    ./run.sh 20 out.txt -- before=<develop>/hooks-handlers,<develop>/hooks.json after=<branch>/hooks-handlers,<branch>/hooks.json
    node summarize.js out.txt 12000
    ./run.sh 3 tr.txt trace -- before=...,... after=...,...
    node steps.js tr.txt.trace.after.1 <branch>/hooks-handlers/formation-check.sh
