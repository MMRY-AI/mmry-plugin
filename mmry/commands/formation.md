Join or leave a formation: a group of assistants coordinating on one job at the same time.

Usage: `/mmry:formation join <formationId>` | `/mmry:formation leave` | `/mmry:formation status`

## What This Does

A formation is several assistants working one objective together, sending each other short
messages as they go. Once this session is in a formation, those messages are surfaced to you
automatically after each tool call. You do not have to ask for them.

**This command is what activates that.** Without it, this session does not know which formation
it belongs to and nothing is delivered, because the delivery hook reads the formation from local
session state and nothing else writes it.

## How to Run It

Take the user's input from `$ARGUMENTS`.

### join

The user gives a numeric formation id, for example `/mmry:formation join 42`.

1. If they gave no id, do not guess. List their active formations so they can pick one:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-list.sh"
   ```

   Show the objective and id of each, ask which one, and stop.

2. Join it, which both enrols this session server-side and records it locally:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-join.sh" <formationId>
   ```

3. Report the outcome in one line: the objective it joined, or the reason it could not.

   A refusal is usually one of two things, and both are worth saying plainly:
   - You share no access group with whoever created the formation. An administrator adds you.
   - This session already belongs to another formation. Leave that one first.

### leave

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-leave.sh"
```

This stops delivery to this session and tells the server the session has left. Confirm in one line.

### status

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-state.sh" get
```

Empty output means this session is in no formation. Otherwise it prints the formation id and the
timestamp of the last message already surfaced.

## What Not To Do

- **Do not invent a formation id.** If the user has not given one and has no active formations,
  say so. Guessing an id would either fail or, worse, join a formation that is nothing to do with
  the work in hand.
- **Do not report success unless the script says so.** The join script exits non-zero and explains
  itself on failure; pass that explanation through rather than replacing it with a summary.
