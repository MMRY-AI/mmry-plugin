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

This skill covers everything else: how to store memories, query mid-session, search, correct, and manage the memory system.

## How to Execute Memory Operations

### Pre-Built Scripts (preferred)

The plugin includes pre-built bash scripts for common memory operations. Each is a single command:

| Script | Operation |
|--------|-----------|
| `save-memory.sh` | Store a new memory |
| `deactivate-memory.sh` | Deactivate a memory |
| `search-memories.sh` | Search memories by keyword |
| `list-groups.sh` | List your permission groups |
| `list-databases.sh` | List the user's databases (their AI database) |
| `create-database.sh` | Set up a new database |
| `revise-database.sh` | Add a field to a database, rename it, retire it |
| `rename-database.sh` | Rename a database, or change its description or the words that help choose it |
| `retire-database.sh` | Retire a database (it stops collecting; nothing is deleted) |
| `reinstate-database.sh` | Start a retired database collecting again |
| `save-entry.sh` | Save an entry in a database, or update one |
| `query-entries.sh` | Read entries, filtered on their FIELDS |
| `entry-history.sh` | What an entry used to hold, oldest change first |
| `database.sh` | What `/mmry:database` runs: one subcommand, handed to the script above that does it |

All scripts are in `${CLAUDE_PLUGIN_ROOT}/hooks-handlers/`. See the relevant sections below for usage examples.

**Run in background** when you don't need the result immediately: memory saves and deactivations rarely need to block the conversation. Use `run_in_background: true` on the Bash tool call so the script executes without blocking.

### Custom Queries (source the client library)

For operations that need custom handling, source `mmry-client.sh` and call API wrapper functions directly:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"

# Call any API function
mmry_search_memories "authentication" "backend"
echo "$MMRY_RESPONSE"

# Get active sessions
mmry_get_active_sessions
echo "$MMRY_RESPONSE"
```

Available functions: `mmry_create_memory`, `mmry_get_memories`, `mmry_get_startup_memories`, `mmry_get_memory_by_id`, `mmry_search_memories`, `mmry_deactivate_memory`, `mmry_register_session`, `mmry_get_active_sessions`, `mmry_get_my_groups`, `mmry_health`, and for the AI database `mmry_list_databases`, `mmry_get_database`, `mmry_create_database`, `mmry_revise_database`, `mmry_rename_database`, `mmry_retire_database`, `mmry_reinstate_database`, `mmry_save_entry`, `mmry_get_entries`, `mmry_get_entry_history`.

After each call, check `$MMRY_HTTP_CODE` and `$MMRY_RESPONSE` for the result.

## Your AI Database

**What to call it.** MMRY AI markets this as **your AI database**: a database your assistant
builds and fills in while the user talks. One thing the user tracks (their migraine log, their
expenses, their sales leads) is **a database**; each item saved in it is **an entry**; its named
values are **fields**. Say those words to the user. The scripts, flags and tools keep older names
(`create-database.sh`, `--database-id`, `save-entry.sh`, `--entry-id`, `mmry_entry_save`) because
installed copies and connected assistants call them by those names; they are code, not words to
repeat to the user.

### What it is, and when it is the right answer

Almost everything the user saves is an ordinary memory, and the ordinary `save-memory.sh` call is
the right tool for it. But when they are accumulating **examples of a recurring shape**: every
migraine and what preceded it, every expense, every job application, every recipe, a **database**
stores the same words with **named fields** alongside them. "How many of these had X" then
becomes an answer rather than a guess.

An entry is an ordinary memory that additionally carries fields. Everything else about it is
unchanged: it appears in recall, in search and in the user's export, it is deactivated like any
other, and **the user's own words are always kept verbatim**. Removing one is a deactivation.

**Do not set up a database for a single fact, a one-off note, or anything you would not expect a
second example of.** Left unchecked a model sets up one per conversation and leaves the account
full of databases holding one entry each. Run `list-databases.sh` first and reuse what is already
there.

### Seeing what the user has

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/list-databases.sh"
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/list-databases.sh" --id 42   # one database in full
```

### Setting one up

Design the fields from what the user actually said, using **their** words as the labels. Rough is
fine: an unrecognised field type is stored as text rather than refused.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/create-database.sh" \
  --name "Migraine log" \
  --description "Every migraine and what preceded it" \
  --fields '[{"key":"severity","label":"Severity","type":"number"},
             {"key":"triggers","label":"Triggers","type":"list","of":"text"},
             {"key":"duration","label":"Duration","type":"text"}]' \
  --mode append \
  --match-hints "migraine, headache, aura"
```

`--match-hints` are the words the user would actually write about one of these ("migraine,
headache, aura"). They are shown by `list-databases.sh` so that **you** recognise, in a later
conversation, that what the user just said is another example for this database.

**When a save becomes an entry.** A save becomes an entry when MMRY can tell which database it
belongs to **and** has values for that database's fields. The database is the one the save names,
or the one whose hint words appear in it as whole words (the database with the most hint words
wins, a tie chooses none, and a database with no hint words is never chosen this way). The values
are the fields the save supplies, or labelled lines such as `Amount: 25`. Without both, the save
stays an ordinary memory: naming a database with no values stays ordinary, and so do hint words
with no supplied fields and no labelled lines.
Naming the database and giving its fields is the reliable way, so when the user tells you
something in their own words and it fits one of their databases, **you** read the values out of
their words and save it as an entry naming the database (see the next section).
Run `list-databases.sh` whenever what they say looks like a recurring shape, so you know which
databases they have.

`--mode` decides what makes two entries the same one:

| Mode | Use it when | Also needs |
|------|-------------|-----------|
| `append` | every entry is new and nothing is ever revised: a log, such as symptoms or expenses | |
| `keyed` | entries are named things that each change on their own: a list of tasks, contacts, recipes | `--identity-field` |
| `singleton` | there is only ever one: "my spouse", "this laptop" | |

### Saving an entry

Two ways, and the difference matters:

**As part of an ordinary save.** The user asked you to remember something, and the entry is a
decoration on that. Name the database and hand over the values you read out of their words:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier Operational --category Fact --scope health \
  --topic "Migraine on Tuesday" \
  --content "Woke up with a migraine this afternoon, lasted until the evening." \
  --database-name "Migraine log" \
  --entry-fields '{"severity":7,"triggers":["red wine","poor sleep"],"duration":"about five hours"}'
```

`--database-name` takes the database's name and `--entry-fields` its field values.

**A save naming a database is classified by you, not by the server.** The ordinary save hands
your context to the server's AI layer, which picks tier, category and scope and may extract
several memories from one context, and a set of fields has no single memory to belong to there.
So this one writes **one** memory directly, and `--tier`, `--category`, `--scope`, `--topic` and
`--content` are all required. The script says which are missing rather than letting the server
refuse.

**A save that names a database the server cannot use keeps the words.** A database that does not
exist, a field it does not declare, a value too long for its column: all of them cost the fields
and keep the words. The script prints `SavedInDatabase:` (the database the entry went into, or none) so
you can tell which happened. **Report what actually happened**: saying "saved in your migraine
log" when it was stored as ordinary text is worse than saying nothing.

**A refused entry save saves nothing.** If `--entry-fields` is not one valid JSON object, the
server refuses the whole request and the script exits 1. It prints the server's reason, which
looks like this:

```
Error (HTTP 400): {"error":"Request body is required.","detail":null}
Nothing was saved. Check that --entry-fields is one valid JSON object, then run the save again.
```

There is no `NewMemoryID` and no `SavedInDatabase`, and the user's words are NOT stored. Fix the
fields and run the same save again, and tell the user it did not go through until it has.

**As the request itself**, when saving the entry *is* what the user asked for. This one
**refuses** rather than falling back, so a mistyped field name comes back as an error naming the
field:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-entry.sh" \
  --database-id 42 \
  --content "That task is finished now." \
  --fields '{"title":"Rewire the settings page","status":"done"}'
```

`--database-id` is the database's id, from `list-databases.sh`. Read the outcome and report it:
`structured.created` is a new entry, `structured.updated` changed an existing one, and
`text.degraded` means the words were saved and the fields were not.
An update changes **only** the fields you send; anything you leave out keeps its current value,
and sending a field as `null` clears it.

### Changing a database that already exists

The shape of what somebody is collecting is **never right the first time**. When they want a
field the database does not have, do not set up a second database for the same thing: revise the
one they have.

```bash
# add a field: send the WHOLE field list, not just the new one
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/revise-database.sh" --id 42 \
  --fields '[{"key":"severity","type":"number"},{"key":"triggers","type":"list","of":"text"}]'

# change what it is called, what it is for, or the words that help you choose it
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/revise-database.sh" --id 42 --rename "Headache log"
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/revise-database.sh" --id 42 --match-hints "migraine, headache, aura"

# stop it collecting, or start again. Neither deletes anything.
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/revise-database.sh" --id 42 --retire
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/revise-database.sh" --id 42 --reinstate
```

**`--fields` replaces the whole list rather than appending to it.** Read the database first with
`list-databases.sh --id 42`, take the fields it reports, add yours, and send the lot. A field you
leave out is not deleted (the entries carrying it keep it and stay readable) but the new version
stops collecting it, which is rarely what the user meant.

**Revising publishes a new version and destroys nothing.** Every entry already stored stays where
it is and stays readable; entries from before the change simply have no value for a field that
did not exist yet. Filters and sorts span every version, so older entries still come back.

**Retiring is not deleting**, and it is worth saying so in those words: it sounds destructive and
is not. A retired database keeps every entry it holds, they stay searchable and stay in the
user's export, and it simply stops collecting new ones. There is no way to delete a database, by
design.

### Asking questions of it

This is what the whole thing is for. Use it when the question depends on the **values** rather
than on the wording: how many, which ones, since when, sorted by what:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/query-entries.sh" --database-id 42 --filter status=open
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/query-entries.sh" --database-id 42 \
  --filter severity=7 --order "createdDate desc" --page-size 20
```

Filters are ANDed and they span **every version** of the database, so improving its shape later
does not strand what was saved under the old one. Every entry comes back with every field the
database declares, blank where nothing was saved.

Leave `--page-size` out unless you need a particular size: the page is then sized to fit in one
reply, so a wide database gives fewer entries per page. The output's `Page` line says how many per
page and the total, and `Next page:` gives the exact `--page` and `--page-size` to ask for next. Use
those numbers as given, so the next page starts where this one stopped. Every page, even one you
sized, is held to what your shell tool shows in full, and says so when it was shortened.

**On a database with many fields, ask only for the fields the question needs.** `--fields` takes
their keys, comma separated, and each entry then carries only those (plus its id, entry name and
dates); `--no-note` leaves out the words each entry was saved from when the values answer the
question. A narrower read gets more entries per page, so a count or a comparison needs fewer pages.
Filters and `--order` may still use fields you did not name. A key the database does not declare
comes back as an error listing the keys it does declare; it is never silently dropped. Who can see
each entry is the same as for a full read.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/query-entries.sh" --database-id 42 \
  --fields status,applied --no-note --filter status=open
```

`--order` takes a field key the database declares, or `createdDate`, each optionally followed by
` asc` or ` desc`. `recent` and `oldest` are aliases for `createdDate desc` and `createdDate asc`.
**A field key on its own sorts ascending; leaving `--order` out sorts newest first.** A `number`
field sorts numerically, so 7 comes before 10; a `date` field sorts chronologically; an entry with
no value for the field sorts last in both directions. Ordering by a `list` field, or by a key the
database does not declare, comes back as an error naming the key rather than being ignored.

### Correcting an entry

An entry saved anywhere, here, through the connector, in the account area or over the REST API,
is corrected from here the same way: find its id with `query-entries.sh`, then send only what
changes with `save-entry.sh --entry-id` (the entry's id). The words can be corrected too, with
`--content`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/query-entries.sh" --database-id 42 --filter title="Rewire the settings page"
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-entry.sh" --database-id 42 --entry-id 9137 \
  --content "Rewire the settings page. Done." --fields '{"status":"done"}'
```

The outcome must read `structured.updated`. Anything else, report what it says.

### What an entry used to hold

Every change to an entry is kept as it happens, including the values it was first saved with.
Reach for this **before** telling the user a value has "always" been anything, and whenever they
ask how something got to where it is: when a task moved to done, what a dose was before it was
raised, whether they have already corrected this once.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/entry-history.sh" --database-id 42 --entry-id 9137
```

Changes come back **oldest first**, each naming the field, what it was, what it became, when, and
who changed it. EIGHT names in the list are not fields but reserved keys, and each one arrives
with a plain-English label you should use when you tell the customer what happened, rather than
reading them the raw sentinel: the memory's own words, its topic, who can see it, its category,
how long it lasts, its entry name, the retired entry it replaces, and the moment it was retired.
The first two the customer can correct directly; the other six note things that happened to the
entry. `~content~` is the memory's own words and
`~topic~` is its topic, both of which the user can also correct.

**An entry on another account and an entry that does not exist answer identically.** Do not
report "it exists but you cannot see it" on a not-found: you do not know that, and saying it
would be the disclosure the sameness exists to prevent.

### One database, every surface

The same databases and the same entries are reached from the MMRY connector (ChatGPT, Cursor,
Claude Desktop and the user's other connected tools) through the `mmry_database_*`, `mmry_entry_save` and `mmry_entry_history` tools,
and over the REST API. **A customer can also correct an entry themselves**, without asking anyone,
at `mmryai.com/databases` in their account area. A database set up here is visible there, an entry
saved there is readable here, and a correction made in any of them is immediately true in all of
them: there is one entry and one update path, not a copy per client. Say so if the user asks:
this is one account, not one client's private feature.

The user can also start any of this with `/mmry:database` (create, list, add, find, correct,
history, retire, restore). It is not needed: asking in plain words, as in the examples above,
does the same.

## Mid-Session Loading

Memories are auto-loaded at session start (Foundation + universals + directory-matched). To reload mid-session, use the `/mmry:load-memories` command, or source the client library:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/mmry-client.sh"
mmry_get_memories "$PWD" "" "" "" ""
echo "$MMRY_RESPONSE"
```

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

Optional parameters (`--task-id`, `--project-id`, `--visibility`, `--permission-group-id`, `--supersedes`, `--agent-name`) can be omitted — they default to empty/NULL. **Always include `--session-id "$CLAUDE_SESSION_ID"`.** `--working-dir` is optional — if omitted, it defaults to the session launch directory (persisted at session start). It prints a short confirmation from MMRY AI. It does not print the new memory's id, so do not tell the user one.

**Which agent saved it.** Each memory records the name of the agent that created it. You do not
need to do anything for this: when the session was started as a named agent (`claude --agent
<name>`), MMRY AI picks the name up at session start and sends it with every save, and a name the
user set in `MMRY_AGENT_NAME` is used otherwise. Pass `--agent-name "<name>"` only to name a
different agent, for example when you are a subagent saving on your own behalf. Never write the
agent's name into the memory text to label it.

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

## Correcting a Memory

When a fact or decision changes, save the new memory with `--supersedes <old id>`. MMRY AI saves
it and retires the old memory, so only the new one is recalled from then on:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --context "DECISION: Use UPC as primary. SKU as fallback. EAN for EU markets." \
  --supersedes 42 --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"
```

Read the exit status, because it says whether the replacement happened:

| Exit | Meaning | What to tell the user |
|------|---------|-----------------------|
| 0 | Saved, and memory 42 is retired | The correction is saved and replaces the old memory. |
| 1 | Nothing saved | The message says why: memory 42 does not exist, is already retired or is not one this user can see; it is a Foundation memory; a different visibility was asked for; or MMRY AI could not save it at all. Say the correction was NOT saved, and act on the reason. |
| 3 | Saved, but memory 42 may still be active | Both may be live. Say so plainly; do not claim the old one was replaced. |

The replacement keeps the old memory's tier, visibility and group: a private memory stays private,
a group memory stays with its group, and so does its correction. So do not pass `--visibility` or
`--permission-group-id` with `--supersedes`, unless it is the one the old memory already has; a
different one is refused. A Foundation memory cannot be replaced by a save at all; the account owner
changes those in the MMRY AI portal.

**Where the id comes from.** Search for the memory being corrected with `--ids`, which prints each
match's id (`id 42 | tier | scope | topic`):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/search-memories.sh" --ids "primary product id"
```
Use the id of the match that says the wrong thing. Never guess one. The memories loaded at session
start are the Foundation set, which a save cannot replace. If no match is clearly the wrong memory,
save the correction without `--supersedes` and tell the user the earlier memory is still active
alongside it. Do not show ids to the user unless they ask; `/mmry:search` results stay as they are.

**Corrections.** When the user says a remembered fact is wrong, or you find one that is out of date,
this is how to fix it: save the corrected version with `--supersedes <id of the wrong one>`, so only
the correction is recalled from then on.

## Search

Search finds memories by keyword across their topic and content, including memories that were not loaded at session start.

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
- When you need context that was not loaded at session start

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

| Tier | Use For |
|------|---------|
| Foundation | Core values and Initialization (identity & orientation) |
| Strategic | Organization & communication standards |
| Operational | Active working knowledge |
| Tactical | This week's work |
| Momentary | Right now |

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

When multiple Claude sessions may work on the same project, use the session registration API to register your presence.

**Your session list shows your own sessions only.** Other people's sessions on the same account are not visible to you, and yours are not visible to them — a session belongs to the person who registered it. An account administrator additionally sees that another person's session exists and who owns it, but the identifier that binds it is withheld on every row but their own; being an administrator does not lift that, it only widens which sessions they can see listed.

So registration is a record of your own presence, not a way to discover who else is working. **If you need to coordinate with another person's assistant, use a formation** — `/mmry:formation` — which is built for exactly that, and carries messages between sessions that cannot see each other's registrations.

Sessions are automatically registered at session start. The 8-hour auto-expiry handles stale registrations naturally.

## Categories
- **Initialization** — boot-sequence identity and orientation (Foundation tier only, sorted first)
- **Decision** — a choice that was made
- **Fact** — something that is true
- **Convention** — a standard or pattern to follow
- **Issue** — a known problem or limitation

## Scopes
Use consistent, lowercase scope names for your organization's platforms and projects. Examples: `global`, `frontend`, `backend`, `infrastructure`, `marketing`

## Task References
The memory store is for **institutional knowledge** — decisions, patterns, lessons learned. The task management system is the source of truth for **what work is being done**.

When a memory originates from a specific task, include the `--task-id` parameter to record which task it came from. This is optional and should be omitted for memories that aren't tied to a specific task.

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
# From a task: lesson learned during specific work
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/save-memory.sh" \
  --tier "Operational" --category "Issue" --scope "backend" \
  --topic "Missing Transaction IDs" \
  --content "ISSUE: Platform occasionally fails to save transaction IDs on orders. IMPACT: Blocks automatic refunds. WORKAROUND: Refund via API directly." \
  --source "joel" --task-id "TSK-4521" \
  --working-dir "$PWD" --session-id "$CLAUDE_SESSION_ID"

# Not from a task: general convention (omit --task-id)
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

It shows the IDs and names of the groups you belong to.

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

### Setting a Default Visibility

A user can set a sticky default so every later save follows it without repeating a scope:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/visibility.sh"                # show current default
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/visibility.sh" private        # default to Private
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/visibility.sh" group          # list their groups
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/visibility.sh" group "Sales"  # default to a group
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/visibility.sh" global         # back to the default
```

An explicit scope on a single save still wins over the default. Groups are created and their
membership managed by an account administrator in the portal; this only selects among groups
the user already belongs to, so when a user has no groups, tell them to ask an administrator rather than
trying to create one.

### Restricting a Memory After Saving

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/make-private.sh"          # the last one saved
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/make-private.sh" 1234     # a specific memory
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/make-private.sh" 1234 group 7
```

Changing a memory's scope is creator-only: only the person who saved a memory can change it,
and the server returns 403 otherwise (an administrator cannot re-scope someone else's memory
either). Content is preserved.

### Sensitive-Content Nudge

Because memories are shared by default, when a save is clearly personal or sensitive
(health, pay, a personnel matter, a private opinion), add one short passive line after the
save noting that it went out shared and that they can say "make it private." Never ask a
question, never wait, and never change visibility on your own; the user decides. Do not
nudge on ordinary work content, and skip it when the user already chose a scope.

## How to Deactivate a Memory
When something is no longer true:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/deactivate-memory.sh" 42
```
Do NOT delete memories. Deactivate them so there's a historical record.
