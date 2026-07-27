---
name: memory-system
description: The MMRY AI memory system skill has been loaded. I now have access to the persistent memory store for maintaining context across sessions, computers, and teams. Important decisions, conventions, and context are saved automatically. Say "remember this" to save something anytime, or /mmry:help for a quick reference.
---

# Claude Memory System

## Overview
You have access to a persistent memory store via the MMRY AI REST API. Use it to maintain context across sessions.

**Do NOT use PowerShell — all operations use bash.** The plugin includes pre-built bash scripts for all memory operations. For custom queries, source `mmry-client.sh` directly.

**Automated lifecycle:** The MMRY AI plugin handles these events automatically via hooks:
- **Session start** — Memories are loaded automatically (Foundation + universals + directory-matched)
- **Session end** — You'll be prompted to save any decisions, issues, or notes before exiting
- **Context compression** — You'll be prompted to save a Momentary "Session Continuity" memory before compression
- **Plan accepted** — You'll be prompted to save accepted plans as Decision memories

This skill covers everything else: how to store memories, query mid-session, search, link, and manage the memory system.

## How to Execute Memory Operations

### Pre-Built Scripts (preferred)

The plugin includes pre-built bash scripts for common memory operations. Each is a single command:

| Script | Operation |
|--------|-----------|
| `save-memory.sh` | Store a new memory |
| `reinforce-memory.sh` | Reinforce (reset expiration) |
| `deactivate-memory.sh` | Deactivate a memory |
| `link-memories.sh` | Link two memories |
| `search-memories.sh` | Search memories by keyword |
| `list-groups.sh` | List your permission groups |

All scripts are in `${CLAUDE_PLUGIN_ROOT}/hooks-handlers/`. See the relevant sections below for usage examples.

**Run in background** when you don't need the result immediately — memory saves, reinforcements, deactivations, and links rarely need to block the conversation. Use `run_in_background: true` on the Bash tool call so the script executes without blocking.

### Custom Queries (source the client library)

For operations that need custom handling, source `mmry-client.sh` and call API wrapper functions directly:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# Call any API function
mmry_search_memories "authentication" "backend"
echo "$MMRY_RESPONSE"

# Get related memories
mmry_get_related 42
echo "$MMRY_RESPONSE"

# Get active sessions
mmry_get_active_sessions
echo "$MMRY_RESPONSE"
```

Available functions: `mmry_create_memory`, `mmry_get_memories`, `mmry_get_startup_memories`, `mmry_get_memory_by_id`, `mmry_search_memories`, `mmry_deactivate_memory`, `mmry_reinforce_memory`, `mmry_create_link`, `mmry_delete_link`, `mmry_get_related`, `mmry_register_session`, `mmry_get_active_sessions`, `mmry_get_my_groups`, `mmry_health`.

After each call, check `$MMRY_HTTP_CODE` and `$MMRY_RESPONSE` for the result.

## API Endpoints

All operations go through the MMRY AI REST API:

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/memories` | Store a memory (409 on duplicate topic+scope) |
| GET | `/api/memories` | Retrieve memories (auto-reinforces) |
| GET | `/api/memories/search?q=` | Keyword search |
| GET | `/api/memories/startup` | Get startup memories (Foundation + dir-matched) |
| GET | `/api/memories/{id}` | Get single memory by ID |
| DELETE | `/api/memories/{id}` | Deactivate a memory |
| POST | `/api/memories/{id}/reinforce` | Reinforce (reset expiration) |
| POST | `/api/memories/{id}/links` | Create memory link |
| DELETE | `/api/memories/{id}/links/{targetId}` | Delete memory link |
| GET | `/api/memories/{id}/related` | Get related memories |
| POST | `/api/sessions` | Register/update session |
| GET | `/api/sessions/active` | List active sessions |
| GET | `/api/groups/mine` | List your permission groups |

## Mid-Session Loading

Memories are auto-loaded at session start (Foundation + universals + directory-matched). To reload mid-session, use the `/mmry:load-memories` command, or source the client library:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"
mmry_get_memories "$PWD" "" "" "" ""
echo "$MMRY_RESPONSE"
```

### Tier Expiration

The API automatically filters out stale memories based on tier:
- **Foundation** — always loaded (core facts, never expire)
- **Strategic** — loaded if less than 1 year old (priorities, direction)
- **Operational** — loaded if less than 3 months old (working knowledge)
- **Tactical** — loaded if less than 7 days old (current task context)
- **Momentary** — loaded if less than 8 hours old (immediate/in-progress items)

For Operational, Tactical, and Momentary tiers, the expiration clock resets each time a memory is reinforced (see Reinforcement below). A memory accessed yesterday has a fresh clock, regardless of when it was originally created.

## How to Store Memories

Use the pre-built `save-memory.sh` script:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" \
  --category "Decision" \
  --scope "backend" \
  --topic "Refund Handling" \
  --content "DECISION: Use API to refund directly when the platform fails to save transaction ID." \
  --source "claude" \
  --task-id "TSK-4521" \
  --working-dir "$PWD" \
  --session-id "$CLAUDE_SESSION_ID"
```

Optional parameters (`--task-id`, `--project-id`, `--visibility`, `--permission-group-id`, `--supersedes`) can be omitted — they default to empty/NULL. **Always include `--session-id "$CLAUDE_SESSION_ID"`.** `--working-dir` is optional — if omitted, it defaults to the session launch directory (persisted at session start). Returns `NewMemoryID` on success.

## When to Store a Memory
Store a memory when any of the following happen:
- A **decision** is made about architecture, process, or approach
- A **bug** is resolved — store root cause and fix
- A **new pattern or convention** is established
- A team member says "remember this", "note this", "going forward", "don't forget" or "the standard is"
- A **new integration, client, or project** is introduced
- Something **didn't work** and should be avoided in the future
- A **plan is accepted** — the PostToolUse hook will prompt you, but you can also store plans proactively

## How to Write Good Memory Content
Write short, declarative statements. Like briefing a new team member.

**Good:**
```
DECISION: App V2.0 uses UPC as primary product identifier. SKU is fallback only.
REASON: Sync failures with distributor catalog when using SKU.
```

**Bad:**
```
We had a long discussion about identifiers and after considering several options we decided UPC was the best choice for various reasons.
```

## Reinforcement

Memories in Operational, Tactical, and Momentary tiers are automatically reinforced when retrieved via the GET memories endpoint. Reinforcement increments the access count and resets the expiration clock — a reinforced memory persists as if it were just created.

**Automatic:** Every call to GET /api/memories reinforces the Operational, Tactical, and Momentary memories it returns. No manual action needed — memories that keep being loaded stay alive. Memories that stop being loaded (wrong directory, out of scope) naturally expire.

**Manual:** You can still reinforce a specific memory explicitly if needed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/reinforce-memory.sh" 42
```

Foundation and Strategic memories are excluded from reinforcement. Foundation never expires. Strategic should be consciously re-evaluated at year end, not silently extended.

## Associative Linking

Memories can be linked to each other to form associative networks. Links are separate from the memory data itself — they represent relationships between memories.

### Link Types

| Type | Directionality | Meaning |
|------|---------------|---------|
| `related` | Symmetric | Same topic area |
| `supersedes` | Directional | Source replaces target |
| `elaborates` | Directional | Source adds detail to target |
| `contradicts` | Symmetric | Conflict, flag for human review |

### Creating Links

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/link-memories.sh" 42 87 "related"
```

For symmetric types (`related`, `contradicts`), the API normalizes order automatically — you don't need to worry about which ID goes first.

### Retrieving Related Memories

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"
mmry_get_related 42
echo "$MMRY_RESPONSE"
```

Returns all linked memories in both directions (outgoing and incoming), with `linkType` and `linkDirection` fields. Only returns active memories.

This is a deliberate call — related memories are NOT automatically loaded at startup. Use it when you want to explore connections.

### Removing Links

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"
mmry_delete_link 42 87
```

### When to Link

- **Link at storage time** when the relationship is obvious (e.g., a new decision that supersedes an old one)
- **Link during discovery** when you realize two loaded memories are related
- **Do not bulk-link** retrospectively — links should reflect genuine associations, not retroactive organization

### Supersedes Pattern

When a decision changes, store the new memory and link it as `supersedes`:
```bash
# Store updated decision — returns NewMemoryID (e.g., 95)
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" --category "Decision" --scope "backend" \
  --topic "Primary Product ID" \
  --content "DECISION: Use UPC as primary. SKU as fallback. EAN for EU markets." \
  --source "eric" --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"

# Link to the old decision it replaces
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/link-memories.sh" 95 42 "supersedes"
```

Or use the `--supersedes` flag to do both in one step:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" --category "Decision" --scope "backend" \
  --topic "Primary Product ID" \
  --content "DECISION: Use UPC as primary. SKU as fallback. EAN for EU markets." \
  --source "eric" --supersedes 42 --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"
```

## Search

Search finds memories by keyword across Topic and Content fields, regardless of age. This is intentional — search is how you recover memories that have expired from normal loading.

Users can also trigger a search directly with the `/mmry:search <keywords> [scope]` command, which wraps the same `search-memories.sh` hook shown below. Reach for the command when the user explicitly asks to search; use the hook calls here when you are searching as part of your own reasoning.

```bash
# Search all scopes
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/search-memories.sh" "UPC"

# Search within a specific scope
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/search-memories.sh" "refund" "backend"
```

### When to Search

- When encountering an unexpected topic that feels familiar
- When doing cross-scope work and you suspect related knowledge exists
- When a keyword keeps coming up and you want to check if there's institutional knowledge about it
- When you need older context that may have aged out of normal loading

### Search + Reinforce Pattern

Search recovers expired memories. Reinforcement revives them. Together they mirror how the brain recalls from long-term storage through associative pathways:

```bash
# Search finds an expired Operational memory (ID 42, last accessed 4 months ago)
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/search-memories.sh" "UPC"

# You use the memory's content to guide your work → reinforce it
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/reinforce-memory.sh" 42
# Memory is now alive again in normal loading results (clock reset)
```

## Memory Tier Hierarchy

Memory tiers follow four considerations, in order of importance:

| Priority | Consideration | Tier | What Goes Here |
|----------|--------------|------|----------------|
| 1 | **Values & Identity** | Foundation | Core values AND identity & orientation. Initialization memories (team, key systems) load first as the boot sequence. |
| 2 | **Organization** | Strategic | How work is structured — conventions, lifecycle, processes |
| 3 | **Communication** | Strategic | How the team communicates — templates, formats, standards |
| 4 | **Skill** | Operational | Practice areas, tools, platforms, workflows, working knowledge |

**Foundation is sacred.** Only core values and Initialization memories (identity & orientation) belong at Foundation tier. Initialization memories use the `Initialization` category and are automatically sorted first in query results — they form the boot sequence that orients every new session.

### All Tiers

| Tier | Use For | Expiration | Reinforceable |
|------|---------|------------|---------------|
| Foundation | Core values and Initialization (identity & orientation) | Never | No |
| Strategic | Organization & communication standards | 1 year from creation | No |
| Operational | Active working knowledge | 3 months from last access | Yes |
| Tactical | This week's work | 7 days from last access | Yes |
| Momentary | Right now | 8 hours from last access | Yes |

### Balance Principle

Store enough that any Claude session can do a great job working with the team. Don't waste space, and don't under-share. Store decision-guiding knowledge and file pointers — not full document content that already exists on disk.

## Working Directory

`--working-dir` is optional. The working directory is recorded server-side on `dbo.Session` when `session-start.sh` registers the session, and the API resolves it back when a save call includes `--session-id` without an explicit `--working-dir`. When neither is supplied (e.g., scripts invoked outside a Claude Code session), the client falls back to `$PWD`. The previous `${TMPDIR:-/tmp}/mmry-session-dir*` file mechanism was removed in v1.8 (Bug #9) because concurrent Claude Code sessions on the same machine collided through the shared file.

The API records the working directory for directory-scoped loading and traceability. Universal memories (Foundation, Strategic, most Operational) load everywhere regardless of working directory — recording it simply tells future sessions where the memory was created.

**Examples:**
```bash
# Tactical memory — working dir used for scoped loading
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Tactical" --category "Fact" --scope "backend" \
  --topic "Session Progress" \
  --content "Next up: test refund flow on staging" \
  --source "claude" --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"

# Operational memory — working dir recorded for traceability, loads everywhere
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" --category "Decision" --scope "backend" \
  --topic "Primary Product ID" \
  --content "DECISION: Use UPC as primary product identifier. SKU is fallback only." \
  --source "eric" --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"
```

## Project ID

The `--project-id` parameter tags a memory with an Intervals Project ID (integer), identifying what project the work relates to. Unlike working directory, project ID groups work logically — multiple directories can belong to one project.

- **Omitted** (default) — not project-scoped, loads in every session
- **An integer value** — only loads when the caller passes matching project ID

**When to set --project-id:**
- Tactical and Momentary memories tied to a specific Intervals project

**Leave it omitted when:**
- The memory applies across projects (most memories)
- You don't know the Intervals Project ID

## Session ID

**Always pass `--session-id "$CLAUDE_SESSION_ID"` when saving memories.** This provides traceability from any memory back to the conversation that created it. The value is available in the `$CLAUDE_SESSION_ID` environment variable.

## Session Coordination

When multiple Claude sessions may work on the same project, use the session registration API to register your presence. Other sessions loading memories for the same project/directory will see your registration and can avoid collisions.

Sessions are automatically registered at session start. The 8-hour auto-expiry handles stale registrations naturally.

## Categories
- **Initialization** — boot-sequence identity and orientation (Foundation tier only, sorted first)
- **Decision** — a choice that was made
- **Fact** — something that is true
- **Convention** — a standard or pattern to follow
- **Issue** — a known problem or limitation

## Scopes
Use consistent, lowercase scope names for your organization's platforms and projects. Examples: `global`, `frontend`, `backend`, `infrastructure`, `marketing`

## Task Linkage
The memory store is for **institutional knowledge** — decisions, patterns, lessons learned. The task management system is the source of truth for **what work is being done**.

When a memory originates from a specific task, include the `--task-id` parameter to link back to it. This is optional and should be omitted for memories that aren't tied to a specific task.

**Use --task-id when:**
- A lesson was learned while working a specific task
- A decision was made in the context of a task
- An issue was discovered during task work

**Leave it omitted when:**
- The memory is a general convention or standard
- It's a Foundation-tier fact about the product or team
- It applies broadly and didn't come from a specific task

**Examples:**
```bash
# Linked to a task: lesson learned during specific work
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" --category "Issue" --scope "backend" \
  --topic "Missing Transaction IDs" \
  --content "ISSUE: Platform occasionally fails to save transaction IDs on orders. IMPACT: Blocks automatic refunds. WORKAROUND: Refund via API directly." \
  --source "joel" --task-id "TSK-4521" \
  --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"

# No task link: general convention (omit --task-id)
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Foundation" --category "Convention" --scope "global" \
  --topic "SQL Security Pattern" \
  --content "CONVENTION: Use ownership chaining with stored procedures. No direct table access for service accounts." \
  --source "eric" --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"
```

**Do not duplicate task details into memories.** The task system already tracks status, assignments, and timelines. Memories should capture the *knowledge gained* from doing the work, not the work itself.

## Group Visibility

Memories default to **Global** visibility (all users in the subscriber see them). You can also save **Private** (only the creator sees it) or **Group** (only members of a specific permission group see it).

### Listing Your Groups

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/list-groups.sh"
```

This calls `GET /api/groups/mine` and shows group IDs and names.

### Saving a Group-Scoped Memory

1. Run `list-groups.sh` to find the group ID
2. Save with `--visibility group --permission-group-id <ID>`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" --category "Decision" --scope "backend" \
  --topic "Team-Only Convention" \
  --content "CONVENTION: Use feature flags for all new endpoints." \
  --visibility "group" --permission-group-id 42 \
  --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"
```

The API validates that you are a member of the group. Non-members get a 403 error.

## How to Deactivate a Memory
When something is no longer true:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/deactivate-memory.sh" 42
```
Do NOT delete memories. Deactivate them so there's a historical record.
