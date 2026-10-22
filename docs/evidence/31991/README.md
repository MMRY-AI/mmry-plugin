# #31991: what a dispatched agent's hook payload looks like

Measured 2026-10-21 on Claude Code 2.1.306 (Windows 11, Git Bash), to decide how formation-check.sh
tells a session's own hook calls apart from those of an agent it dispatched.

## Method

`probe.sh` (this folder) appends its stdin payload, plus the hook environment's
`CLAUDE_CODE_SESSION_ID` and `CLAUDE_CODE_AGENT`, to a JSONL file. It was registered on SessionStart,
UserPromptSubmit, PostToolUse, Stop and SubagentStop through `--settings`, in a nested headless run
that loaded no user settings and no plugins (`--setting-sources local`, `--strict-mcp-config`), with
a scratch TMPDIR. Each run had the main session run `echo` with Bash and then dispatch one
general-purpose agent that ran `echo` with Bash.

    claude -p --setting-sources local --settings probe-settings.json --strict-mcp-config \
      --allowedTools "Bash(echo:*)" "Agent" --model haiku "<prompt>"                          # run 1
    claude -p ... --agents '{"probelead":{...}}' --agent probelead ...                         # run 2

Prompts, tool output, assistant text and paths are removed from the committed files; nothing else
was changed.

## Result

| Run | Event | session_id | agent_id | agent_type |
|-----|-------|-----------|----------|------------|
| 1 plain | the session's own SessionStart, UserPromptSubmit, PostToolUse, Stop | S | absent | absent |
| 1 plain | dispatched agent's PostToolUse (`echo probe-sub`) | **S** | `add22966ec6f3f9bf` | `general-purpose` |
| 1 plain | dispatched agent's SubagentStop | **S** | `add22966ec6f3f9bf` | `general-purpose` |
| 2 `--agent probelead` | the session's own events, all five | S | **absent** | `probelead` |
| 2 `--agent probelead` | dispatched agent's PostToolUse, SubagentStop | **S** | `ad0298e37db92c11e` | `general-purpose` |

- The agent's events carry the PARENT's session_id, and the hook environment's
  `CLAUDE_CODE_SESSION_ID` is the parent's too. That is why the hooks.json gate and formation-check.sh
  both took the agent's tool call for the session's own.
- No SessionStart, UserPromptSubmit or Stop fired inside the agent; it fires PostToolUse and, at the
  end, SubagentStop.
- `agent_type` is present on a `--agent` session's OWN events, so it cannot be the test. `agent_id`
  is present only inside the dispatched agent. That is the field formation-check.sh reads.

## Codex

Not measured live (see the handback). From the source, openai/codex main at 6203846:
`codex-rs/core/src/hook_runtime.rs` builds PostToolUse and UserPromptSubmit requests with
`subagent: thread_spawn_subagent_hook_context(...)`, and `codex-rs/hooks/src/schema.rs` serialises
`agent_id`/`agent_type` with `skip_serializing_if = "Option::is_none"`, so they appear only inside a
thread-spawned subagent. The hooks documentation states "Subagent hooks use the parent session id",
and a subagent's Stop is converted to SubagentStop.
