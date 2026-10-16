# #31850 evidence: the renewal turn, the hook ceiling on 2.1.292, and the listening limit

Measured 2026-10-15 on Windows 11 Pro, Git Bash, node 22, **Claude Code 2.1.292**
(`ceiling/version.txt`). Every Claude Code session here is headless (`claude -p`, stream-json, model
haiku) through `../31721/ceiling/driver.js`, loading only its own project settings
(`--setting-sources project`), so no installed plugin and no production service was involved.

## 1. A rewake fires UserPromptSubmit, with the renewal notice in the prompt (`ups/`)

A probe registered a synchronous Stop logger, an `asyncRewake` Stop hook that sleeps 8 s once and
exits 2 with a notice, and a UserPromptSubmit logger (`ups/settings.json`). `ups/hooks.txt`:

- 15:29:07 the rewake fires, and **UserPromptSubmit runs** with `"prompt":"<task-notification>...Stop
  hook blocking error from command \"Stop\": PROBE WATCH RENEWED. ... Reply with exactly: Still
  listening. ..."`.
- 15:29:09 the model has replied "Still listening." and **every Stop hook runs again**, with
  `"stop_hook_active":true` and `"last_assistant_message":"Still listening."`.

So a renewal turn runs the whole UserPromptSubmit and Stop sets. Before #31850 that meant: the
formation prompt check polled once and removed the renewal marker (so the next watch started at the
fast end of its schedule), and the save prompt fired, its 15-minute debounce being shorter than the
28-minute window. This is what requirement 2 fixes, and why the prompt check now recognises the
renewal's own prompt (`formation-check.sh`, prompt mode).

## 2. The 1800 s ceiling holds on 2.1.292 (`ceiling/`)

The #31721 measurement (2.1.285, live proof on 2.1.286) was repeated at MMRY's own registration:
`"asyncRewake": true, "timeout": 1800`, a hook that heart-beats every 10 s for 1740 s and then exits
2 (`ceiling/hb.sh`, `ceiling/p1800.settings.json`).

| Event (UTC) | |
|---|---|
| 22:34:18 | the model answers "READY"; the hook starts (`p1800.hook.txt`) |
| 23:03:24 | the hook exits 2 after 1740 s of sleep, 1746 s after it started |
| 23:03:26 | the model, with no input, answers "ACK" (`p1800.session.txt`) |

So the floor stated in `commands/formation.md` and on the help page, **Claude Code 2.1.285 or
newer**, is the earliest version measured; 2.1.286 and 2.1.292 were measured since. Versions 2.1.64
to 2.1.284 carry `asyncRewake` but were never measured for an 1800 s run, and the docs say so.

## 3. Live: a renewal turn with every plugin hook registered (`live/`)

`live/setup.sh` registers **every hook in `mmry/hooks/hooks.json`**, verbatim except that
`${CLAUDE_PLUGIN_ROOT}` is written out (Claude Code refuses that variable outside a plugin), plus one
harness hook that records the session in formation 4242. The plugin's own `session-init.sh`
installs the handlers into an isolated HOME. `live/stub.js` stands in for the service on a private
127.0.0.1 port, answers every route, confirms membership, and logs every request. `live/run.sh`
shortens the window to 30 s (`MMRY_IDLE_POLL_SECONDS`) and, because a 30 s window does not outlast
the save prompt's 15-minute debounce the way 28 minutes does, ages that debounce once per watch, 10 s
before it renews: the state every real renewal turn starts in. Nobody types after the first prompt.

    bash live/setup.sh <run dir> <plugin mmry dir> <port>
    bash live/run.sh   <run dir> <plugin mmry dir> <port> 140 30
    node live/analyze.js <run dir>

The same run, once with this branch's plugin and once with develop `0d5d967` (published v2.11.0):

| | branch `31850/listening-limit` | develop `0d5d967` |
|---|---|---|
| renewals completed in 140 s | 4, each one turn "Still listening." | 4, each one turn "Still listening." |
| requests during each renewal turn | **0** | 1 each (`GET .../transmissions`, the prompt check) |
| save prompt firings in the session (`.mmry-stop-count`) | **1** (the typed "READY" turn only) | 5 (that turn and every renewal) |
| checks by each following watch (30 s window) | 2 (slow end of the schedule) | 10 (fast end: the marker was cleared) |

Raw logs: `live/run-branch/` and `live/run-develop/` (`session.txt`, `requests.txt`,
`harness.txt`, `stop-count.txt`, `settings.json`, `summary.txt`).

**What this run does not show.** In headless stream-json mode Claude Code 2.1.292 did not turn the
save prompt's exit 2 into a visible extra model turn in either variant, so the save prompt is
measured by the hook's own firing count, not by an extra turn. In an interactive window that exit 2
is a second model turn (the behaviour #31850 was filed for); the Integration run in the QA statement
covers it. The stub is not the MMRY service, so credit use is reasoned from
`CreditMiddleware.cs` (no `/api/formations` exemption) and counted by
`tests/structural/formation-listen-limit.bats` ("cost:"), not read from a ledger.

## 4. The listening limit and the budget (offline)

`tests/structural/formation-listen-limit.bats` on a simulated clock: default 4 renewals and a quiet
stop at 7200 s; 60 minutes 2 renewals; off never renews; unlimited keeps renewing; 71 requests in the
first window and 170 over the default chain; worst-case watch 1728 s from hook start (+4 s before
it) of 1800, leaving 68 s against the documented 60; a lock held by a reused pid reclaimed once its
pid file is older than 1860 s.
