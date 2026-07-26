Manually reload memories from the MMRY AI API into your current context. This is equivalent to the automatic session-start load but can be run mid-session to refresh.

This also **immediately refreshes the Foundation re-injection cache**. Foundation memories are otherwise refreshed on a daily cycle, so if an administrator has just added or changed a Foundation memory and wants it to take effect right now, running this command (or restarting Claude Code) is the way to pick it up without waiting for the daily refresh.

**Steps:**
1. Run the plugin's session-start bash script directly:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/session-start.sh"
```

2. Review the returned memories and integrate them into your current context.

For broader queries that include universal memories not loaded at startup, source the client library and call API functions directly — see the memory-system skill for full details on mid-session loading, scope-filtered queries, and search.
