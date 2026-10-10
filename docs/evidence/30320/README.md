# #30320 evidence: where the agent name comes from on Claude Code

The plugin sends the creating agent's name with every save. On Claude Code it learns the name from
the SessionStart hook payload and hands it to the Bash tool shell that runs `save-memory.sh`. Both
halves of that are properties of Claude Code rather than of this plugin, so they were measured
rather than taken from the documentation alone.

**Measured on 2026-10-08, Claude Code 2.1.286, Windows 11, Git Bash.** A throwaway project with no
plugin and no MMRY API: a project-level SessionStart hook (`probe-settings.json`, `probe-hook.sh`)
that writes its stdin to a file and appends one `export` line to `$CLAUDE_ENV_FILE`, and a project
agent (`probe-agent.md`). Run as:

```
claude -p --agent probe-agent --setting-sources project \
  --allowedTools "Bash(bash E:/mmry-wt/probe-agent/show.sh)" --max-turns 3 \
  'Run this exact bash command and print its output verbatim: bash E:/mmry-wt/probe-agent/show.sh'
```

| Claim | Evidence | Result |
|---|---|---|
| The SessionStart payload names the agent when the session is started with `--agent` | `sessionstart-payload.json` | `"agent_type":"probe-agent"` |
| SessionStart hooks receive `CLAUDE_ENV_FILE` | `envfile-path.txt` | a per-session file under `~/.claude/session-env/<session id>/` |
| A variable exported there is visible to the Bash tool shell the assistant runs commands in | `show.sh` printed it | `PROBE=[probe-agent]` |

The documentation says the same (code.claude.com/docs/en/hooks, read 2026-10-08): `agent_type` is a
common input field "present when the session uses `--agent` or the hook fires inside a subagent",
and SessionStart receives it "when you start Claude Code with `claude --agent <name>`";
`CLAUDE_ENV_FILE` is available to SessionStart hooks.

The plugin's handling of the payload, the env file and the request body is covered offline by
`mmry/tests/handlers/agent-name.bats`, including the whole chain: a SessionStart payload with
`agent_type`, the env file sourced into a fresh shell, `save-memory.sh` run as `/mmry:save` runs
it, and `agentName` in the request.

What this does not show, stated so it is not assumed: a SUBAGENT's own Bash commands source the
same session env file, so a subagent's save carries the session's `--agent` name, not the
subagent's type, unless the subagent passes `--agent-name`. Codex reports no agent; there the name
comes from the user's `MMRY_AGENT_NAME`.
