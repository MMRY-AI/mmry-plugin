# #31743 evidence: MMRY's tools on Codex without an Internet access prompt

Branch `31743/codex-tools-no-prompt`. Codex read and run: codex-cli **0.160.0** (openai/codex
`rust-v0.160.0`).

## What is proven here, and how

| Claim | How | Where |
|---|---|---|
| Codex starts the plugin's MCP server from the plugin, on Windows, through `mcp/mmry-mcp.cmd` | real `codex app-server`, plugin installed with `codex plugin marketplace add` / `codex plugin add` into a throwaway Codex home | `live-windows-run3.txt` |
| The server reaches MMRY AI from inside Codex: save, search, reinforce, link, retire, reload | same run, live Integration, throwaway `*@test.mnemo` subscriber | `live-windows-run3.txt` (R1 lines) |
| Join, say, progress through the tools | same run | R2 lines |
| Two conversations at once, each in a different formation, each receiving only its own messages | two threads in one `codex app-server`; each formation's lead sends a marked message; the plugin's own delivery hook run per conversation with the payload Codex gives it | R3 lines |
| Each tool's request and response; annotations judged by Codex's rule; identity per call | BATS | `mmry/tests/handlers/mcp-server.bats` |
| Registration, launchers, Claude Code untouched | BATS | `mmry/tests/structural/codex-mcp.bats` |
| Nothing a Codex model reads names a script for an operation a tool covers: the skill, docs/codex.md, the Codex-only files, the tool server's own words (fix round 1) | BATS | `mmry/tests/structural/codex-tools-first.bats` |
| The same for everything MMRY prints on Codex: session start, the memory_load answer, the save prompt, every formation remedy, the roster footer, the sandbox-access hint; each with a Claude Code control (fix round 1) | BATS | `mmry/tests/handlers/codex-tools-first-output.bats` |
| The same, live: a fresh Integration account's session start and every tool answer in the run (fix round 1) | real `codex app-server`, `TC1-cause` lines | `live-integration.sh` |

What the app-server run does NOT prove: that the MODEL's call is free of prompts. A call the app
makes through `mcpServer/tool/call` is not put through the approval policy. That rests on Codex's
source (below) until the live checks in the next section are run.

### From Codex's source (rust-v0.160.0)

- `codex-rs/rmcp-client/src/stdio_server_launcher.rs`: a local stdio server is a plain child
  process; no sandbox is applied.
- `codex-rs/core/src/mcp_tool_call.rs`, `requires_mcp_tool_approval`: in the default `auto` mode a
  tool runs without a prompt when `readOnlyHint` is true, or when `destructiveHint` and
  `openWorldHint` are both false; otherwise the customer is prompted, and for a plugin's server
  (not a thread-selected one) the prompt offers a persistent approval.
- Same file, `with_mcp_tool_call_ids_meta`: every model tool call carries `_meta.sessionId` and
  `_meta.threadId`. `core/src/hook_runtime.rs`: hooks receive `session_id` = the same session id.

## Re-running the automated live check

```bash
cd docs/evidence/31743 && bash live-integration.sh
```

Needs `codex` (0.160 or later), `node` and `curl`. It makes its own throwaway home, temp folder and
Codex home, and a throwaway Integration subscriber whose key stays in the environment. Runs on
Windows (Git Bash) and macOS. Expect `fails=0`.

## The live checks still to run (Codex members, Mac and Windows)

These are the parts only a real model in a real Codex can show: that no **Internet access** prompt
appears. Run each in the **Codex CLI** and in the **Codex desktop app**, on **macOS** and on
**Windows**: four columns. Use the default policy: start Codex with no sandbox or approval flags.

### Setup (once per machine)

1. Clone the branch: `git clone -b 31743/codex-tools-no-prompt https://github.com/MMRY-AI/mmry-plugin.git`
2. Install it: `codex plugin marketplace add <path of that clone>` then
   `codex plugin add mmry@mmry-plugin`. Restart Codex; trust MMRY's hooks when asked (CLI: "Trust
   all and continue").
3. Confirm the server: `codex mcp list` shows `mmry_plugin` with command `./mcp/mmry-mcp`.
4. Sign in to Integration with a throwaway account (register one at the Integration site with an
   `@test.mnemo` address):
   `bash <clone>/mmry/setup/mmry-setup.sh --api-url https://mnemo-integration-d8h6bzh2bxgrc3e4.westus3-01.azurewebsites.net --host codex`
   (Windows: from Git Bash.)

### TC1: memory tools, no Internet access prompt

In a **fresh conversation**, ask in plain words, one at a time:

1. "Remember this: 31743-LIVE-<date>-A is a marked test memory."
2. "Remember this: 31743-LIVE-<date>-B is a second marked test memory."
3. "Search my memories for 31743-LIVE." (wait a few seconds after saving; saves are processed)
4. "Reinforce the A memory." / "Link A and B as related."
5. "Retire the B memory."

Pass: each step shows an `mmry_plugin` tool call (`memory_save`, `memory_search`,
`memory_reinforce`, `memory_link`, `memory_retire`), each succeeds, and **no "Internet access"
prompt appears at any point**. The only prompt allowed is the retire approval: choose the option to
always allow it. Then open a **second fresh conversation** and retire A: **no prompt at all**.
Fail: any Internet access prompt; the assistant running `save-memory.sh` or another script instead
of the tool; any tool error.

**Watch the FIRST action after each prompt.** The tool call must be the first thing the assistant
does. A shell command naming any `.sh` before it, even one that fails and is followed by the tool,
is a FAIL: that is exactly round 1's failure.

#### TC1 round 1 (Mac, Codex CLI 0.162.1, plugin 03ceb6c): FAIL, 2 of 2

Prompt "Remember this: 31743-LIVE-20261010-A is a marked test memory." In both fresh conversations
the assistant read the skill, ran `save-memory.sh` first (exit 1, HTTP 000, the sandbox has no
network), then found `mmry_plugin` `memory_save`, which succeeded with no prompt. TC2 and TC3 passed
in the CLI. The desktop app was not run.

#### What fix round 1 changed (plugin head after 03ceb6c, see the PR)

Every Codex-facing text that named a script for an operation a tool covers now names the tool:

- the skill: each of save, search, reinforce, reload, link, correct, retire, join, say, progress,
  roster and leave is a tool call; the tool table's "Instead of" column of script names is gone;
  scripts appear only under "Operations with no tool"; when the tools are missing it says to
  restart Codex rather than run a script; its description says the same;
- the hooks: the per-turn save prompt (`stop-check.sh`) and the empty-account session-start welcome
  (also what `memory_load` returns on an empty account) name `memory_save`, not `save-memory.sh`;
- every derived remedy (formation join, say, roster, leave, own progress; reload) names the tool,
  including the roster footer and the Foundation notices;
- the sandbox-access hint, the message after a script fails with HTTP 000, says to call the tool
  instead of asking for access, before it shows the access request;
- the tool server's refusal no longer offers "the skill's bash script";
- docs/codex.md: the reload, nothing-saves, Foundation-notice and rejoin rows name the tools.

Claude Code is unchanged byte for byte: its skill, hooks and commands still name the scripts.

#### Re-running TC1 after fix round 1

1. Update the clone to the branch head and reinstall, so Codex does not keep the old skill:
   `git -C <clone> pull`, then `codex plugin remove mmry@mmry-plugin` and
   `codex plugin add mmry@mmry-plugin`. Restart Codex and trust the hooks again if asked.
2. Check the skill Codex will read is the new one. This must print nothing:
   `grep -rl --include=SKILL.md 'save-memory.sh' "${CODEX_HOME:-$HOME/.codex}"`
3. Run the five TC1 prompts above, each in a **fresh conversation for prompt 1**, twice, as round 1
   did. Use a **fresh throwaway account** for at least one of the two runs: an empty account gets
   the first-session welcome, which was one of the texts naming `save-memory.sh`.
4. Record for each prompt the first action the assistant took. Pass needs `memory_save` (and the
   others) as the first action, no `.sh` command anywhere, and no Internet access prompt.

### TC2: formation tools, no Internet access prompt

1. In a terminal, make a stand-in lead session id, a UUID (macOS: `LEAD=$(uuidgen)`; Windows Git
   Bash: `LEAD=$(cat /proc/sys/kernel/random/uuid)`), and start a formation as its lead:
   `CODEX_SESSION_ID=$LEAD MMRY_HOST=codex bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-start.sh" "31743 live TC2"`
   and note the formation id N.
2. In a **fresh conversation**: "Join formation N." then "Tell the formation hello from TC2." then
   "Report my progress as Accepted."
3. In the terminal, as the lead:
   `CODEX_SESSION_ID=$LEAD MMRY_HOST=codex bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-say.sh" "TC2-REPLY from the lead"`
4. In the conversation, ask anything that makes the assistant run a tool (or just send a prompt).

Pass: `formation_join`, `formation_say` and `formation_progress` tool calls succeed with **no
Internet access prompt**, and "TC2-REPLY from the lead" arrives in the conversation marked
`MMRY AI Formation Transmission`. Desktop app: delivery needs MMRY's hooks trusted, and trusting
them in the desktop app could not be confirmed in an earlier release; if the reply never arrives in
the app, record whether the hooks ran (the session-start memory load is the tell) rather than
failing the tools.

### TC3: two conversations at once, each its own formation

1. Start two formations as two leads, F1 and F2, with two different stand-in UUIDs (LEAD1, LEAD2),
   exactly as in TC2 step 1.
2. Open **two conversations at the same time** (two `codex` windows, or two threads in the app).
   Conversation 1: "Join formation F1." Conversation 2: "Join formation F2."
3. Lead 1 says "FOR-F1-ONLY"; lead 2 says "FOR-F2-ONLY".
4. Make each conversation run a tool.

Pass: conversation 1 shows FOR-F1-ONLY and never FOR-F2-ONLY; conversation 2 the reverse; asking
each "show the roster" lists only its own formation.

### What to send back

For each of the four columns (CLI/app x Mac/Windows) and each TC: pass or fail, the Codex version,
and a screenshot or transcript showing the tool calls and the absence of an Internet access prompt.
Clean up: "leave the formation" in each conversation, then retire the test memories.

## Runs kept here

- `live-windows-run3.txt`: plugin de68916 (the bash 3.2 stdin fix), Windows 11, codex-cli 0.160.0, Integration. 16 of 16 PASS.
- `live-windows-run2.txt`: plugin 90ac8e4, Windows 11, codex-cli 0.160.0, Integration. 16 of 16 PASS.
- `live-windows-run1.txt`: plugin 4a58d58, the same checks before the server was renamed from
  `mmry` to `mmry_plugin`. 16 of 16 PASS. (Its commit message said 18; the run has 16 checks.)
