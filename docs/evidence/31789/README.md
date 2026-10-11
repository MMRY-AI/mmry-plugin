# #31789 evidence: a Codex customer starts and leads a formation

Branch `31789/codex-formation-lead`, stacked on #31743 (`31743/codex-tools-no-prompt`, PR #88).
Codex read and run: codex-cli **0.160.0** (openai/codex `rust-v0.160.0`).

## Requirement 0: can an idle Codex lead hear its members? No.

Eric Barone, 2026-10-07: "a lead has to be listening all the time, or it needs constant
babysitting." The question was whether anything can deliver a member's message to a Codex lead
conversation that is sitting idle, without anyone typing. It was settled from Codex's source at
`rust-v0.160.0` and from the real `codex app-server`, not from belief.

### From the source

Every route by which something reaches the model, or starts a turn, was followed:

| Route | What it does | Where |
|---|---|---|
| A hook's output (synchronous) | Reaches the model only inside a turn that is already running: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop. No hook event fires on an idle thread. | `codex-rs/hooks/src/events/*.rs`; `core/src/hook_runtime.rs` |
| An async hook (`"async": true`, new since Claude Code's `asyncRewake` was ruled out) | Its context is queued and drained only at a turn boundary: before the next user prompt, or after a sampling step of a running turn. It never starts a turn. | `core/src/hook_runtime.rs` `drain_async_hook_results`; called from `core/src/session/turn.rs` lines 175 and 553 |
| A Stop hook that blocks | Continues the CURRENT turn with its reason as a new prompt, with no cap and no timeout ceiling (`normalize_command_hook` defaults to 600 s and caps only SessionEnd and Interrupt). So a Stop hook that waits for a member's message holds the turn open; it does not wake an idle one. While it waits the conversation is busy and the customer's own message waits behind it. | `core/src/session/turn.rs` 655-690; `hooks/src/engine/discovery.rs` `normalize_command_hook` |
| A notification from an MCP server (MMRY's tool server) | Logged, nothing else: progress, logging, resource and list-changed notifications go to the log. | `rmcp-client/src/logging_client_handler.rs` |
| An MCP event stream (`events/stream`) | Refused for any server but Codex's own hosted apps ("MCP event subscriptions are only supported for hosted apps"), and forwarded to the client, not to a turn. | `app-server/src/request_processors/mcp_event_stream.rs` |
| Mail between agents, durable sleep | These DO start a turn on an idle thread (`maybe_start_turn_for_pending_work`), but both are internal to one Codex process: mail between Codex's own agents, and a sleep an extension records. Neither is reachable from a plugin or from another process. | `core/src/session/handlers.rs` `inter_agent_communication`; `core/src/tasks/mod.rs` `has_outstanding_durable_sleep` |
| The `clock.sleep` tool | A model tool (feature `sleep_tool`, listed by `codex features list` as `stable true` on this machine) that pauses INSIDE a running turn and ends early on new input for that turn. It keeps a turn running; it does not wake an idle one. | `core/src/tools/handlers/sleep.rs`; `core/src/tools/spec_plan.rs` 1234 |
| Starting a turn from outside | `turn/start` belongs to the client that owns the thread (the CLI or the desktop app). A plugin has no channel to it. | `app-server-protocol` methods |

So a Codex lead hears its members only on its next action: its next tool call (PostToolUse fires
for MCP tools, `core/src/tools/handlers/mcp.rs` 478), the customer's next message
(UserPromptSubmit), or the next session start.

The only way to keep a Codex lead "listening" is to keep its turn running (a Stop hook that waits
and blocks, or a model looping on `clock.sleep` and a tool call). That is continuous listening, which
the ticket puts in #31721, and it has costs this ticket does not take on: the conversation is
busy the whole time, every wake is a model call, and the customer's own messages wait behind it.
Not built here.

### From the real codex app-server

`live-integration.sh` leaves the lead conversation idle for 60 seconds after the member has
reported Done and sent the lead a message, and records every notification the app-server sends
about that conversation. Result: see "Runs kept here" below (`turn/started=0`). The member's
message was waiting, and was delivered by the lead's next prompt (the UserPromptSubmit hook run
straight after the watch).

### What follows (the R0 test case, second branch)

The product and the docs say plainly that Codex can join a formation but should not lead one, and
steer the lead role to Claude Code:

- `formation_start` on Codex replies with the id, then: "Tell the customer this in your reply when
  you give them the id. Codex cannot wake an idle conversation, so a lead on Codex hears its members only on its
  next action ... we recommend it does not lead one: start the formation from a Claude Code session,
  which hears its members while idle, and join it from here. If this conversation does lead, check
  in while the work runs ..." (`lib-host.sh` `mmry_host_lead_notice`; asserted in
  `mmry/tests/handlers/codex-formation-lead.bats` and live below).
- `formation_assign` on Codex adds, straight after the confirmation: "Tell the customer this in
  your reply, every time you assign work, in words like these: "Their report reaches me only when
  you next send a message here, not while this conversation sits idle, so check in with me once they
  have had time to work." Members' replies and reports reach you only on your next action; to check
  in yourself, call the mmry_plugin formation_roster tool."
- QA round 2 (TC2, Mac and Windows): the lead's reply after `formation_assign` dropped the old,
  unlabelled next-action line. Both lines now open "Tell the customer this in your reply", the assign
  line comes before the line about the member rather than last, and the Codex skill's "Leading a
  formation on Codex" section tells the model to relay the line after every start and every assign.
- docs/codex.md, gap 3: "This is why we recommend you lead a formation from Claude Code." The Codex
  skill has a "Leading a formation on Codex" section; the README's idle row recommends it too
  (`mmry/tests/structural/codex-formation-lead-docs.bats`).

Claude Code output is unchanged, byte for byte (the same BATS files pin it).

## What is proven here, and how

| Claim | How | Where |
|---|---|---|
| Codex lists and runs the lead's tools from the plugin's server | real `codex app-server`, plugin installed with `codex plugin marketplace add` / `codex plugin add` into a throwaway Codex home | `live-*.txt`, `setup` lines |
| TC1: a lead starts a formation and is given its id; a second conversation joins by it | same run, Integration, throwaway `*@test.mnemo` subscriber | `TC1` lines |
| TC2: the lead assigns work; the member sees it, marked as directed at it | same run; the member's delivery hook run as Codex runs it | `TC2` lines |
| R0: nothing starts a turn on an idle lead in 60 s after a member's report | same run, `watch` step | `R0` lines |
| TC3: the member reports Done, messages the lead, and messages the whole formation; the lead sees both messages on its next prompt (the broadcast unmarked, because it went to everyone), and its roster shows Done | same run; the lead's UserPromptSubmit delivery hook | `TC3` lines |
| TC4: the lead reads the record, debriefs; the formation closes; the record is read back after the close; the member leaves | same run | `TC4` lines |
| R3: the start and assign replies carry the next-action wording | same run, and BATS on Codex with a Claude Code control | `R0/R3`, `R3` lines; `codex-formation-lead.bats` |
| Each lead tool's request and response, refusals, quoting, identity, annotations by Codex's rule | BATS | `mmry/tests/handlers/mcp-server.bats` |
| TC5 / R4: the Codex page, the Codex skill and both READMEs claim only operations test cases 1 to 4 prove, and state listing and claiming as not yet tested | BATS | `mmry/tests/structural/codex-formation-lead-docs.bats` |
| Nothing a Codex model reads names a script for an operation a tool covers, now including start, assign, report and debrief | BATS (#31743's pins, extended) and the live run | `codex-tools-first.bats`, `codex-tools-first-output.bats`, `tools-first` line |
| Each guard bites: 27 mutations, 27 refused. Round 1 (20): 19 refused, and access-hint-lead SURVIVED, because nothing pinned the lead tools in the sandbox-access hint; a pin was added. Round 2: that one and a sharper one (the tool names dropped) both refused. Round 3: six against the skill and README pins, one restoring the skill passage QA round 1 failed, all refused | mutation runner | `mmry/tests/mutation/run-31789-mutations.sh`; `mutations-round1.txt`, `mutations-round2.txt`, `mutations-round3.txt` |

What the app-server run does NOT prove: anything the MODEL does. A call through
`mcpServer/tool/call` is not put through the approval policy and runs no hooks, so the harness runs
the delivery hooks itself, exactly as Codex runs them. That a model in Codex picks these tools from a
plain-words request, with no Internet access prompt, and that the customer reads the lead notice,
is the live procedure below.

## Re-running the automated live check

```bash
cd docs/evidence/31789 && bash live-integration.sh
```

Needs `codex` (0.160 or later), `node` and `curl`. Throwaway home, temp folder, Codex home and
Integration subscriber; the key stays in the environment. Runs on Windows (Git Bash) and macOS.
Expect `fails=0`. Do not edit the script while it runs: bash reads it as it goes.

## The live procedure for the Codex members (Mac and Windows)

Test cases 1 to 4 need a real model in a real Codex. Run them on **macOS** and on **Windows**, in
the **Codex CLI** (the surface MMRY is documented for; add the desktop app if you can, and record
it as its own column). Default policy: start Codex with no sandbox or approval flags.

### Setup (once per machine)

1. Clone the branch: `git clone -b 31789/codex-formation-lead https://github.com/MMRY-AI/mmry-plugin.git`
2. Install it: `codex plugin marketplace add <path of that clone>` then
   `codex plugin add mmry@mmry-plugin`. If an earlier MMRY is installed, first
   `codex plugin remove mmry@mmry-plugin`. Restart Codex; trust MMRY's hooks when asked.
3. Confirm the server and the lead's tools: `codex mcp list` shows `mmry_plugin`; in a conversation,
   ask "which mmry_plugin tools do you have?" and check `formation_start`, `formation_assign`,
   `formation_report` and `formation_debrief` are among them.
4. Sign in to Integration with a throwaway `@test.mnemo` account:
   `bash <clone>/mmry/setup/mmry-setup.sh --api-url https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net --host codex`
   (Windows: from Git Bash).

Open **two Codex conversations side by side** (two terminal windows running `codex` in the same
project folder). Call them LEAD and MEMBER. Record, for every prompt below, the FIRST action the
assistant takes and whether any **Internet access** prompt appears.

### TC1: start in plain words, share the id, join by it

1. LEAD: "Start a formation for the checkout tests."
   Pass: the first action is the `mmry_plugin` `formation_start` tool; the reply shows the formation
   id (call it N); no Internet access prompt; and the assistant tells you, in its own words, that a
   Codex lead hears its members only on its next action, that we recommend a Claude Code session
   lead, and how to check in. (R0 and R3. Whether it reads plainly is your judgement; write one line
   on it.)
2. MEMBER: "Join formation N."
   Pass: `formation_join` with N; "Joined formation N".

### TC2: assign, and the member sees it

1. LEAD: "Show me the roster." Note the member's id M.
2. LEAD: "Assign member M to write the checkout tests."
   Pass: `formation_assign`; "Member M in formation N is now Wingman, working on: ..."; and the
   assistant's own reply to you says the member's report arrives when you next send a message
   there, not on its own, and to check in then. A reply that only confirms the assignment fails.
3. MEMBER: send any prompt, for example "Anything for me?"
   Pass: the assignment appears, marked `MMRY AI Formation Transmission` and `DIRECTED TO YOU`.

### TC3: Done, and the lead sees it on its next prompt (and not before)

1. MEMBER: "Report my progress as Done: the tests are written, and tell the lead."
   Pass: `formation_progress` with Done, and `formation_say` directed to the lead.
2. MEMBER: "Tell the whole formation the checkout tests are in."
   Pass: `formation_say` with no recipient; "Sent to formation N. The other members will see it
   after their next tool call."
3. Leave LEAD alone for **two minutes**. Do not type in it. Pass (R0): nothing appears in LEAD on its
   own. This is the limit the product now states.
4. LEAD: "Any news from the formation?"
   Pass: both of the member's messages arrive with this prompt, the one to the lead marked
   `DIRECTED TO YOU` and the one to the formation not; "Show me the roster" shows the member as
   Done.

### TC4: close out

1. LEAD: "Show me the formation's close-out record." Pass: `formation_report`; it names the member,
   the assignment and Done.
2. LEAD: "Close out the formation: the checkout tests are written and passing, nothing went wrong."
   Pass: `formation_debrief`. Codex asks once to approve it (it ends the formation for everyone);
   choose the option to always allow it. The reply prints the record and "Formation N closed out".
3. LEAD: "Show me the close-out record of formation N." Pass: the record is still readable.
4. MEMBER: "Leave the formation." Pass: `formation_leave`.

Fail anywhere: an Internet access prompt; any `.sh` command run for start, join, assign, roster,
report, debrief, say, progress or leave, even one followed by the tool; a tool error; or a lead
reply that does not mention the next-action limit.

### What to send back

For each column (Mac CLI, Windows CLI, and desktop app if run) and each TC: pass or fail, the Codex
version, the plugin commit (`git -C <clone> rev-parse HEAD`), and a transcript or screenshots
showing the tool calls, the absence of an Internet access prompt, and the lead's start reply.

## Runs kept here

- `live-windows-run4.txt`: plugin 2b3221a, Windows 11, codex-cli 0.160.0, Integration revision 1de4775.
  **25 of 25 PASS**, `fails=0`. Formation 8934. Adds the broadcast step to TC3: the member messages
  the whole formation, and the lead's next prompt shows it unmarked, beside the directed report.
  Idle watch: `turn/started=0` for 60 s. Runs 1 to 3 predate that step and have 23 checks.
- `live-windows-run3.txt`: plugin 260e42c, Windows 11, codex-cli 0.160.0, Integration. **23 of 23 PASS**,
  `fails=0`. Formation 8932. The throwaway account's password is now made per run and never shown.
  Idle watch: `turn/started=0` for 60 s.
- `live-windows-run2.txt`: plugin ed5d6d3, Windows 11, codex-cli 0.160.0, Integration. **23 of 23 PASS**,
  `fails=0`. Formation 8931. The idle watch: `turn/started=0 notifications=0` for 60 s after the
  member's Done report and message; the lead's next prompt then delivered both.
- `live-windows-run1.txt`: plugin 71fd92e, the same flow. 22 of 23: every product check passed, and
  the one FAIL was the harness matching compact JSON where the hook prints it indented (fixed in the
  harness, not the product). Formation 8930; the same idle result.

(Commit ed5d6d3's and 4c16234's messages counted these runs as 24 and 23 of 24. The runs have 23
checks; the counts above are the ones in the files.)
