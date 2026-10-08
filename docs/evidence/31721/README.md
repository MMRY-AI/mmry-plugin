# #31721 evidence: how long Claude Code lets a background Stop hook run, and whether it can renew

The approach on #31721 required this to be measured before anything else was built: the longest time
Claude Code lets a background Stop hook run, and whether a watch that reaches that limit can hand
over to a fresh one without a person typing. If renewal were impossible, the work was to stop and
report. It is possible, so the work went ahead.

## Client and machine

- Claude Code **2.1.285** (`claude --version`, `~/.local/bin/claude.exe`, built 2026-09-30).
- Windows 11 Pro 10.0.26200, Git Bash, node 22.14.0.
- Measured 2026-10-08 between 00:12 and 01:19 UTC.

## Method

Each probe is a real Claude Code session, run headless with `driver.js`:

    claude -p --input-format stream-json --output-format stream-json --verbose \
           --model haiku --setting-sources project

`--setting-sources project` loads only the probe's own `.claude/settings.json`, so no installed
plugin's hooks run. stdin is held open after the first prompt, which keeps the session alive and
idle, and nothing more is written to it until the probe ends. Every assistant turn is logged with
a timestamp (`*.session.txt`).

The Stop hook is registered exactly as MMRY registers its idle watch: `"asyncRewake": true`, a
`"timeout"` in seconds. The hook (`probe-hb.sh`) logs its start, then a heartbeat every 10 s, then
sleeps out its time, prints a codeword on stderr and exits 2 (`*.hook.txt`). It traps TERM and HUP
so a polite stop would be logged. The registration of each probe is in `*.settings.json`.

## Results

| Probe | Registered timeout | Hook asked to run | Hook actually ran | Exit 2 woke the model with no input? | Next Stop re-armed a fresh hook? |
|---|---|---|---|---|---|
| `probe1` | 60 s | 15 s | 15 s, six times in a row | yes, every time ("ACK") | yes, five hand-overs |
| `pOver` | 20 s | 40 s | killed between 10 and 20 s; no TERM logged | **no**: the model was never woken | n/a |
| `p11m` | 900 s | 660 s of sleep | **674 s** (00:14:49 to 00:26:03) | yes ("ACK" at 00:26:04) | yes (00:26:05) |
| `p62m` | 7200 s | 3720 s of sleep | **3785 s** (00:14:48 to 01:17:53) | yes ("ACK" at 01:17:55) | yes (01:17:56) |

(Heartbeats drift about 0.2 s per 10 s sleep, which is why the actual run is longer than the sleep.)

## What that establishes

1. **The ceiling is the registration's own `timeout`, at least up to 63 minutes.** Nothing shorter
   applied: a hook registered for 900 s ran 674 s, and one registered for 7200 s ran 3785 s. The
   bundle shows the same in static form: the async timeout is taken as `timeout * 1000` with no
   clamp in the path that registers it (read from `claude.exe` 2.1.285; static reading only, the
   probes are the evidence). MMRY's previous 300 s was a choice, not a limit.
2. **A hook that reaches its timeout is killed outright, and wakes nobody.** `pOver` stopped
   heart-beating between 10 and 20 s, its TERM trap never ran, and the model was never woken. So a
   watch cannot be relied on to hand anything over once it is killed: it has to hand over **before**
   its timeout, by exiting 2 itself.
3. **A watch that exits 2 before its timeout hands over to a fresh one with nobody typing.** The
   exit wakes the model, the model's turn ends, and the Stop that follows starts a new hook. Seen
   five times in a row in `probe1` and once each in `p11m` and `p62m`.
4. **Closing the session kills its background hook** (the `p11m` and `p62m` re-armed hooks were gone
   once their sessions ended), so a watch never outlives the session it serves.

## The design that follows

- Stop registration `timeout` 1800 s (`hooks/hooks.json`), window `MMRY_IDLE_POLL_SECONDS` 1680 s.
  Both are well inside the measured ceiling. 120 s separate them for preparation, one last poll at
  the client's 25 s limit and the membership question.
- At the end of a window with nothing to say, the watch asks the service whether this session is
  still a member (`GET /api/formations/{id}/transmissions/sent`). Only an affirmative answer renews:
  exit 2 with a short notice, which wakes the session, which replies "Still listening.", and the
  next Stop starts a fresh watch. Anything else stops the watch quietly, as it always did.
- A turn that ends while a watch is live hands over: the new Stop asks the live watch to stand
  down, the old one exits within one 3 s slice of its sleep without renewing, and the new one starts
  a fresh window at the fast end. So a renewal wake only ever follows 28 genuinely idle minutes.

## Live test: idle longer than three hook windows, still receives (requirement 1)

Run 2026-10-08 01:41 to 03:08 UTC, Windows 11, Claude Code 2.1.285, against the local API built
from the API branch (`bf3ec72`) on mnemo_DEV with migration 063 applied. Harness `live/live.js`,
prepared by `live/setup.sh`; raw logs `live/run-2026-10-08.live.txt` and `.watch.txt`. The Stop
registration and window were the shipped ones (1800 s, 1680 s), with no overrides.

| Time (UTC) | What happened |
|---|---|
| 01:41:33 | R joins formation 4959 and goes idle. Nobody writes to R again |
| 02:09:38 | watch 1 renews (exit 2); R replies "Still listening."; watch 2 starts 02:09:41 |
| 02:37:53 | watch 2 renews; R replies "Still listening."; watch 3 starts 02:37:57 |
| 03:06:08 | watch 3 renews; watch 4 starts 03:06:09 |
| 03:07:55 | S, a second real session, sends a directed message to R with `formation-say.sh` |
| 03:08:22 | watch 4 delivers it (26 s after the send); R repeats it, 5165 s after it last had input |
| 03:08:28 | the service records it read; S's sender view shows `"read":true` |

Requirement 1 (idle longer than three windows, still receives) and requirement 2 end to end both
passed. Note: this run used the handler as of `c851aa7`, before the handover (DD-101 decision 4)
was added; the handover is covered by the structural suite on Windows, Linux and macOS.

## TC1b at the branch head, through the shipped hook registration

The run above used the handler as of `c851aa7`, and its harness called `formation-check.sh` through
a wrapper. This one was run at the head after the merge of the #31746 branch, and every watch went
through the registration `mmry/hooks/hooks.json` ships.

**What ran.** Plugin `639e40d` (branch `31721/formation-listening`); its hooks and handlers are
identical to `485a38f`, the merge, since `639e40d` only adds a harness log line. Claude Code
**2.1.286** (the stream's `claude_code_version`; the client updated itself from 2.1.285 between the
two attempts below). Windows 11 Pro 10.0.26200, Git Bash. API built from MMRY-AI/mmry
`31721/read-status` at `80fc5a4`, run locally against mnemo_DEV (migration 063 present) on
`http://localhost:5297`, a private port (see the first attempt). Harness `live-shipped/live.js`,
prepared by `live-shipped/setup.sh`. No window or timeout override: registration timeout 1800 s,
window 1680 s.

**How the watch was started.** R's `.claude/settings.json` (`run-2026-10-08-b/R-settings.json`) is the
four `formation-check` entries of `mmry/hooks/hooks.json`, copied verbatim by `setup.sh`: the Stop
entry is the shipped gate `sh -c 'for f in "${TMPDIR:-/tmp}"/.mmry-formation-*; ...'` followed by
`exec bash ~/.claude/mmry/hooks-handlers/hook-guard.sh formation-check`, with `asyncRewake` and
`timeout: 1800`. R ran with `HOME` set to a prepared home whose `~/.claude/mmry/hooks-handlers` is a
copy of the checkout's handlers (byte-identical, `diff -r`), and its config at that home's
`.claude/mmry-config.json`, where an installed client keeps it. Nothing called `formation-check.sh`
directly. The OS process table (`procs.txt`, sampled every 5 minutes) shows each running watch as
`bash /e/claude-31721/run2/home/.claude/mmry/hooks-handlers/formation-check.sh`, a path only
`hook-guard.sh` resolves: four different processes, one per window (pids 51244, 61292, 10108, 59260).

**What is not the same as a customer install.** The plugin's other hooks (session-init, the
foundation and stop checks) were not registered, because `--setting-sources project` loads only R's
own settings, and the handlers were copied by `setup.sh` rather than by `session-init.sh`. Claude
Code does not report Stop hooks in `stream-json`, so watches are timed from the lock the handler
itself holds in TMPDIR (`.mmry-formation-poll-<sid>`) and renewals from its
`.mmry-formation-renewed-<sid>` marker, sampled once a second (`watch.txt`), not from a hook log.

**Result (run b, 2026-10-08 UTC): passed.**

| Time (UTC) | What happened |
|---|---|
| 06:24:35.6 | R's last typed turn ends ("JOINED"). Nobody writes to R again |
| 06:24:36.9 | watch 1 takes its poll lock |
| 06:52:40.6 | watch 1 renews (28 min 4 s); R wakes and replies "Still listening." at 06:52:46.9 |
| 06:52:49.7 | watch 2 takes its poll lock |
| 07:20:52.8 | watch 2 renews (28 min 3 s); R replies "Still listening." at 07:20:56.5 |
| 07:20:58.8 | watch 3 takes its poll lock |
| 07:49:02.9 | watch 3 renews (28 min 4 s); R replies "Still listening." at 07:49:05.5 |
| 07:49:07.0 | watch 4 takes its poll lock |
| 07:50:48.9 | S, a second real session, sends a directed message to R with `formation-say.sh` (service `sentDate`) |
| 07:51:05.4 | watch 4 releases its lock having delivered (16.4 s after the send) |
| 07:51:06.0 | the service records the message read (`readDate`) |
| 07:51:07.6 | R repeats `LIVE-31721-1791440661518 take the validator`, 18.6 s after the send |
| 07:51:09.4 | a fresh watch starts after R's turn |
| 07:51:13.6 | S's sender view: `"read":true`, `"readDate":"2026-10-08T07:51:06.0122162"`, `"recipientHasLeft":false` |

R was idle 5,173 s (86 min 13 s) from the end of its last typed turn to the send, across three
complete watches, each of which ran its full 1680 s window and renewed, before watch 4 delivered.
That is longer than three 1680 s windows (5,040 s). It is not longer than three 1800 s registration
timeouts (5,400 s); no watch runs to that timeout, since each renews at the end of its window.
The API answered `200` with revision `80fc5a4` at every one of 87 minute-by-minute checks
(`api-health.txt`).

**The first attempt (run a) is recorded, not counted.** Same harness, plugin `485a38f`, Claude Code
2.1.285, API on the shared DEV port 5291. Watch 1 renewed at 05:23:44 and watch 2 at 05:52:22, both
through the shipped registration. Then the API process ended at about 05:53:35 (its log stops there;
the cause was not recorded), and at 06:10:39 another session's API, built from a different branch
(revision `99146f3`), took port 5291. Watch 3 reached the end of its window at 06:20:39 with no
answer from the service to "is this session still a member?", and stopped quietly without renewing,
as designed. Logs in `live-shipped/run-2026-10-08-a-aborted/`. Run b used a private port for that
reason.

## Human steps: the same live test on macOS, and in the interactive Claude Code window

The live test above was driven headless on Windows. Two legs remain for a person:

**A. macOS, headless, the same harness (about 95 minutes, unattended).**
Needs: a Mac with Claude Code signed in (`claude --version` recorded), node, git, jq; the #31721
API deployed to Integration with migration 063 applied (the PM does both); an Integration test
account email and password nobody else uses.

    git clone -b 31721/formation-listening https://github.com/MMRY-AI/mmry-plugin.git ~/mmry-31721
    cd ~/mmry-31721/docs/evidence/31721/live
    bash setup.sh ~/live31721
    LIVE_DIR=~/live31721 LIVE_API=https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net \
        RENEWALS_NEEDED=3 node live.js

`live.js` registers its own throwaway account on the target, so no credential is typed. Pass when
`~/live31721/live.log` ends with a `PASS R repeated LIVE-31721-...` line and a `sender view:` line
with `"read":true`, and `~/live31721/watch.log` shows at least three `rc=2 said=MMRY FORMATION
WATCH RENEWED` lines before the line that delivered. Send back both logs and `claude --version`.

**B. Interactive window (any platform, about 90 minutes, nobody types into window 1).**
1. Install the branch's handlers where the plugin runs them: back up `~/.claude/mmry/hooks-handlers`,
   then copy `mmry/hooks-handlers/*` from the branch over it. In the installed plugin's
   `hooks/hooks.json` (under `~/.claude/plugins/cache/mmry-plugin/mmry/<version>/`), set the Stop
   formation-check entry's `"timeout"` to 1800. Restart Claude Code.
2. Window 1: `/mmry:formation start "live 31721"`, note the id. Window 2: `/mmry:formation join <id>`,
   then `/mmry:formation roster` and note window 1's member id.
3. Leave window 1 alone. Expect, about every 28 minutes, a short turn in window 1 reading "Still
   listening." with nobody typing.
4. After the third such turn, in window 2: `/mmry:formation say "LIVE check, reply with the word
   BANANA" --to <window 1 member id>`.
5. Pass: within about a minute window 1 shows the message marked DIRECTED TO YOU and replies, with
   nobody touching it; then `/mmry:formation roster` in window 2 shows the message as `READ <time>`.
6. Restore the backed-up handlers and the original timeout.
