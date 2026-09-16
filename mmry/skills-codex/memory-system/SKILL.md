---
name: memory-system
description: The MMRY AI persistent memory system for Codex. Memories load automatically at session start and are saved back as the work happens, so context survives between sessions, machines and teammates. Use this skill whenever the user asks to remember, recall, search, forget or share something, or wants to coordinate with another assistant session.
---

# MMRY AI memory system (Codex)

You have a persistent memory store reached over the MMRY AI REST API. It is how context survives
between sessions.

**All operations are bash scripts.** They live in the MMRY directory inside the customer's Codex
home, which the SessionStart hook populates at the start of every session.

**WRITE THE PATH AS `"${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/<script>"`.** Every command
below does, and it matters: Codex reads `CODEX_HOME` to find its own configuration, and a customer
who has moved their Codex home has no `~/.codex` directory at all. That form resolves correctly in
both cases, needs nothing set up beforehand, and is safe to paste into any shell you reach for -
unlike a variable you set in one Bash call, which is gone by the next one.

The examples below spell it out in full for that reason. `~/.codex/mmry/...` is the same path on a
default install, and is fine to SAY to a customer, but do not RUN it: on a relocated home it names
a directory that does not exist, and the failure is a confusing "No such file or directory" rather
than anything that names the real problem.

## What happens without you doing anything

| Moment | What MMRY does |
|---|---|
| Session start | Loads your memories (Foundation, universals, and any matching this directory) and writes them to a file you are told to read |
| Every prompt you receive | Re-states the account's Foundation memories so they stay in effect |
| After a tool call | Delivers any new coordination-group messages |
| End of a turn | Prompts you to save what is new since the last save |

## What is different on Codex, and what to do instead

This platform does not give plugins typed slash commands. On Claude Code a customer types
`/mmry:save`; here they ask in plain words and you use this skill. Three specific consequences:

1. **There is nothing to type.** If a customer asks "what commands do I have", tell them there are
   none to type on Codex and that asking in plain words is the whole interface: "remember this",
   "what do you know about X", "make that private", "start a formation".
2. **There is no prompt before context is trimmed.** Codex hooks have no channel to you at the
   compaction moment, so the save prompt arrives at the end of a turn instead. Treat every
   end-of-turn prompt as the last chance to record something, because it may be.
3. **Idle delivery does not happen here.** Coordination messages reach you when a tool runs, when a
   prompt is submitted, and at session start. A Codex session that is sitting doing nothing is not
   woken by a message; it sees it on the next thing that happens.

State these plainly if asked. Do not imply a capability this platform does not have.

## Saving a memory

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/save-memory.sh" \
  --tier "Operational" \
  --category "Decision" \
  --scope "backend" \
  --topic "Refund Handling" \
  --content "DECISION: Refund through the API directly when the platform fails to save a transaction id." \
  --source "codex" \
  --working-dir "$PWD"
```

Optional: `--task-id`, `--project-id`, `--visibility`, `--permission-group-id`, `--supersedes`.
Returns the new memory id.

### When to save

- A decision is made about architecture, process or approach
- A bug is resolved: record the root cause and the fix
- A convention or pattern is established
- Someone says "remember this", "note this", "going forward", "don't forget", "the standard is"
- Something did not work and should be avoided next time

### How to write it

Short declarative statements, as though briefing a new team member.

Good: `DECISION: V2 uses UPC as the primary product identifier. SKU is fallback only. REASON: sync
failures against the distributor catalog when keyed on SKU.`

Bad: `We had a long discussion about identifiers and decided UPC was best for various reasons.`

## Recalling and searching

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/search-memories.sh" "UPC"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/search-memories.sh" "refund" "backend"
```

Search ignores age, which is the point: it is how a memory that has aged out of normal loading is
recovered. When a search result genuinely guides the work, reinforce it so it comes back on its own
next time:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/reinforce-memory.sh" 42
```

## Tiers

| Tier | For | Expires | Reinforceable |
|---|---|---|---|
| Foundation | Core values, identity and orientation | Never | No |
| Strategic | Organisation and communication standards | 1 year from creation | No |
| Operational | Active working knowledge | 3 months from last access | Yes |
| Tactical | This week's work | 7 days from last access | Yes |
| Momentary | Right now | 8 hours from last access | Yes |

Foundation is sacred: only core values and `Initialization` category memories belong there.

Categories: `Initialization`, `Decision`, `Fact`, `Convention`, `Issue`.
Scopes: consistent lowercase names, e.g. `global`, `frontend`, `backend`, `infrastructure`.

## Who can see a memory

Memories default to Global, meaning everyone on the account. The alternatives are Private (only the
person who saved it) and Group (only members of one permission group).

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/list-groups.sh"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/visibility.sh"                # show the current default
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/visibility.sh" private        # default new saves to Private
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/visibility.sh" group "Sales"  # default to one group
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/make-private.sh"              # restrict the last one saved
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/make-private.sh" 1234 group 7
```

Re-scoping is creator-only and the server enforces it; an administrator cannot re-scope someone
else's memory either.

**Sensitive-content nudge.** Because memories are shared by default, when a save is clearly personal
or sensitive (health, pay, a personnel matter, a private opinion), add one short passive line after
the save noting that it went out shared and that they can say "make it private". Never ask a
question, never wait, and never change visibility on your own.

## Linking

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/link-memories.sh" 42 87 "related"
```

Types: `related` and `contradicts` (symmetric), `supersedes` and `elaborates` (directional). When a
decision changes, save the new one with `--supersedes <old-id>` rather than deleting anything.

## Retiring a memory

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/deactivate-memory.sh" 42
```

Deactivate; never delete. The historical record is the point.

## Coordination groups (formations)

A formation carries messages between assistant sessions that cannot otherwise see each other, so
two people's assistants can work the same job without colliding.

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-list.sh"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-start.sh" "Ship the v2 checkout"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-join.sh" <formation-id>
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-say.sh" "Heads up: I am editing the payment module"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-roster.sh"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-leave.sh"
```

Messages from the formation arrive on their own, marked `FORMATION TRANSMISSION`. A line marked
`DIRECTED TO YOU` was sent to this session and nobody else: act on it. A line marked `[MMRY]` came
from the memory system rather than from a colleague.

## Setting up

If memories are not loading, the account may not be authenticated on this machine:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/setup/mmry-setup.sh"
```

It opens a browser for the customer to sign in at mmryai.com and writes the credential. After it
finishes, the customer restarts Codex.

## What is not available here, stated plainly

If a customer asks what MMRY can do on Codex, or seems to expect something that is not here, point
them at the full statement rather than improvising:
https://github.com/MMRY-AI/mmry-plugin/blob/master/docs/codex.md

The four things that are genuinely unavailable on this platform are: typed slash commands, the
prompt before context is trimmed, waking an idle session with a formation message, and the
plan-accepted prompt. Never imply any of them works here.

## Reporting a problem

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/submit-feedback.sh" --type bug --title "..." --description "..."
```
