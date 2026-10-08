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

## Live test: idle longer than three hook windows, still receives (requirement 1)

See `live/` once run. Recorded below.

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
