---
name: memory-system
description: The MMRY AI persistent memory system for Codex. Memories load automatically at session start and are saved back as the work happens, so context survives between sessions, machines and teammates. Use this skill whenever the user asks to remember, recall, search, forget or share something, or wants to coordinate with another assistant session. Saving, searching, correcting, retiring and reloading memories, and starting, joining, messaging, assigning work in, reporting progress in, reading the roster and the close-out record of, closing out, removing a member from and leaving a formation, are calls to the mmry_plugin tools, never scripts.
---

# MMRY AI memory system (Codex)

You have a persistent memory store reached over the MMRY AI REST API. It is how context survives
between sessions.

## Call MMRY's tools. Do not run a script for anything a tool does.

The everyday operations are tools from the `mmry_plugin` server this plugin starts. Codex runs them
outside its sandbox, so they reach MMRY AI with no Internet access approval. **Call the tool
directly, as your first action. Do not run a script first to see whether it works**: a script you
run yourself is inside the sandbox, has no network, and fails with `HTTP 000` until the customer
approves Internet access for the conversation, which is the prompt these tools exist to remove.

| To | Call | With |
|---|---|---|
| Save a memory, or correct a wrong one | `memory_save` | `content`; optional `supersedes`, `visibility`, `permission_group_id`, `working_dir` |
| Search memories (prints each match's id) | `memory_search` | `query`; optional `scope` |
| Retire (deactivate) a memory | `memory_retire` | `id` |
| Reload memories now | `memory_load` | optional `working_dir` |
| Join a formation, as this conversation | `formation_join` | `formation_id`; optional `working_dir` |
| Message the formation, or one member | `formation_say` | `message`; optional `to_member_id` |
| Report Accepted, Done, Blocked or Abandoned | `formation_progress` | `state`; optional `note` |
| See the members, their ids, and the lead | `formation_roster` | nothing |
| Start a formation, with this conversation as lead | `formation_start` | `objective`; optional `task_id`, `working_dir` |
| As the lead, give one member work or a role | `formation_assign` | `member_id`; `assignment`, `role`, or both |
| Read the close-out record | `formation_report` | optional `formation_id` |
| As the lead, close the formation out | `formation_debrief` | `summary` |
| As the lead or an administrator, remove a member whose session has dropped | `formation_remove` | `member_id`; optional `formation_id` |
| Leave the formation | `formation_leave` | nothing |

Each tool describes its own arguments and returns what MMRY printed. Codex tells each tool which
conversation called it, so a formation joined with `formation_join` is this conversation's alone,
and its messages arrive here on their own.

`memory_retire`, `formation_debrief` and `formation_remove` are the three tools Codex asks about:
retiring takes a memory out of recall, a debrief ends the formation for every member, and removing a
member takes that member out of the formation. Tell the customer they can choose to always allow
each one, and they will not be asked again.

**If the mmry_plugin tools are not offered at all,** MMRY's tool server is not running for this
conversation. Tell the customer, and find out why with the missing-tools check under "If the MMRY
tools are missing" below: it is one command, needs no network and changes nothing. The recovery
keeps this conversation's place in a Formation: quit Codex completely, then reopen THIS SAME
conversation. Never recover by starting a new conversation, by leaving and rejoining the Formation,
or by using the `mmry_formation_*` connector tools: each of those joins as someone else. A
Formation message that arrives while the tools are missing says so itself; tell the customer when
you see it. Do not substitute a script for one of these operations.

## What happens without you doing anything

| Moment | What MMRY does |
|---|---|
| Session start | Loads your memories (Foundation, universals, and any matching this directory) and writes them to a file you are told to read |
| Every prompt you receive | Re-states the account's Foundation memories so they stay in effect |
| After a tool call | Delivers any new coordination-group messages |
| The next prompt, when work is unsaved | Prompts you to save what is new since the last save, and stays silent when nothing is |

## What is different on Codex, and what to do instead

This platform does not give plugins typed slash commands. On Claude Code a customer types
`/mmry:save`; here they ask in plain words and you use this skill. Four specific consequences:

1. **There is nothing to type.** If a customer asks "what commands do I have", tell them there are
   none to type on Codex and that asking in plain words is the whole interface: "remember this",
   "what do you know about X", "make that private", "start a formation".
2. **There is no prompt before context is trimmed.** Codex hooks have no channel to you at the
   compaction moment, so the save prompt arrives with the customer's NEXT message instead, and
   only when something is still unsaved. Treat every one of those prompts as the last chance to
   record what has happened since the last save, because it may be.
3. **Idle delivery does not happen here.** Coordination messages reach you when a tool runs, when a
   prompt is submitted, and at session start. A Codex session that is sitting doing nothing is not
   woken by a message; it sees it on the next thing that happens. For a lead that matters most:
   see "Leading a formation on Codex" below.
4. **There is no plan-accepted prompt.** Claude Code tells MMRY when a plan is accepted; Codex has
   no equivalent, so nothing saves an agreed plan automatically. When the customer accepts a plan,
   or says "remember this plan", save it as a Decision memory yourself.

State these plainly if asked. Do not imply a capability this platform does not have.

## Saving a memory

Call `memory_save` with the memory as `content`, and `working_dir` set to the project directory.
MMRY classifies it (tier, category, scope, topic). The tool returns one line saying MMRY AI received
it. It does not return the new memory's id, so do not tell the customer one.

Each memory records the name of the agent that created it: the customer's `MMRY_AGENT_NAME`
setting is sent automatically when it is set. Never write the agent's name into the memory text to
label it.

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

Call `memory_search` with keywords as `query`, and optionally a `scope` such as `backend`. Each
match is printed with its id, tier, scope and topic, then its content.

Search finds memories that were not loaded at session start.

## Reloading memories mid-session

Memories are loaded at session start, and the account's Foundation memories are re-stated from a
local cache that refreshes on a daily cycle. Call `memory_load` (with `working_dir` when the
directory matters) to do both again now. It returns where the loaded memories were written; read
that file.

Reach for it when an administrator has just added or changed a Foundation memory and the customer
wants it in effect immediately rather than on the next daily refresh, when the customer has moved
to a different project directory mid-session and wants the memories that match it, or when MMRY
has reported that Foundation directives could not be applied to a turn. It does what the
session-start hook does; calling it by hand is not a workaround.

## Tiers

| Tier | For |
|---|---|
| Foundation | Core values, identity and orientation |
| Strategic | Organisation and communication standards |
| Operational | Active working knowledge |
| Tactical | This week's work |
| Momentary | Right now |

Foundation is sacred: only core values and `Initialization` category memories belong there.

Categories: `Initialization`, `Decision`, `Fact`, `Convention`, `Issue`.
Scopes: consistent lowercase names, e.g. `global`, `frontend`, `backend`, `infrastructure`.

## Correcting a memory

When the customer says a remembered fact is wrong, or a decision has changed, call `memory_save`
with the corrected version as `content` and `supersedes` set to the id of the wrong one, for
example `supersedes 42`. MMRY AI saves it and retires the old memory, so only the new one is
recalled from then on. Correct a memory this way rather than retiring it and saving a new one.

Read the result, because it says whether the replacement happened:

| Result | Meaning | What to tell the customer |
|---|---|---|
| Not an error | Saved, and memory 42 is retired | The correction is saved and replaces the old memory. |
| An error | Nothing saved | The message says why: memory 42 does not exist, is already retired or is not one this customer can see; it is a Foundation memory; a different visibility was asked for; or MMRY AI could not save it at all. Say the correction was NOT saved, and act on the reason. |
| Ends "Saved, but the memory it was meant to replace may still be active" | Saved, but memory 42 may still be active | Both may be live. Say so plainly; do not claim the old one was replaced. |

The replacement keeps the old memory's tier, visibility and group: a private memory stays private,
a group memory stays with its group, and so does its correction. So do not pass `visibility` or
`permission_group_id` with `supersedes`, unless it is the one the old memory already has; a
different one is refused. A Foundation memory cannot be replaced by a save at all; the account owner
changes those in the MMRY AI portal.

**Where the id comes from.** Call `memory_search` for the memory being corrected; each match is
printed as `id 42 | tier | scope | topic`. Use the id of the match that says the wrong thing. Never
guess one. The memories loaded at session start are the Foundation set, which a save cannot
replace. If no match is clearly the wrong memory, save the correction without `supersedes` and tell
the customer the earlier memory is still active alongside it. Do not show ids to the customer
unless they ask.

## Retiring a memory

Call `memory_retire` with the memory's id. Deactivate; never delete. The historical record is the
point.

## Coordination groups (formations)

> **Use this plugin's `formation_join` and `formation_leave` tools (server `mmry_plugin`),
> not the `mmry_formation_*` connector tools, for anything that JOINS or LEAVES a group.**
>
> Both look like they work. They do not do the same thing. The connector tools reach MMRY directly
> and enrol you under their own identity; this plugin's tools enrol the identity this
> conversation's hooks use. Join with the connector and you will appear on the roster, your status
> will say you are a member, and **no message anyone sends you will ever arrive**. Nothing errors.
> Nothing warns. You simply never hear from your teammates.
>
> Measured on a real machine, twice, on 2026-09-21: a session that joined with the connector tools
> received nothing from two directed messages, while a session that joined through this plugin
> received the next one within seconds of its next command.
>
> The connector tools are fine for reading. `mmry_formation_list` and `mmry_formation_status`
> answer questions without changing anything. It is joining and leaving that must go through this
> plugin's tools.

A formation carries messages between assistant sessions that cannot otherwise see each other, so
two people's assistants can work the same job without colliding.

Join with `formation_join` and the formation's id. The other members see this conversation under
its thread name, or under `name` if you give one. Message the whole formation with
`formation_say`, or one member by adding `to_member_id`. `formation_roster` lists the members, the
id to address each by, each member's name beside its id, and which one is the lead.
`formation_status` shows the same members, plus which member this conversation is. Rename a member
with `formation_assign` and `name`; with no `member_id` it renames this conversation's own member,
which any member may do. Report how your assigned work is going with
`formation_progress` (`Accepted`, `Done`, `Blocked` or `Abandoned`, and an optional `note`). Leave
with `formation_leave`.

Member ids come from the roster, never from a session id. Assigning work is the lead's to do.

Start a formation with `formation_start` and an `objective` that says what the job is; this
conversation becomes its lead, and the reply gives the id to share with the other sessions. As the
lead, give a member work with `formation_assign` (`member_id` from the roster, and an
`assignment`); only that member is told. `formation_report` prints the close-out record: every
member, the work it was given and the state it ended in. Close the formation out with
`formation_debrief` and a `summary` of what was accomplished, decided and learned; the summary and
the record become lasting memories, and the formation stops carrying messages.

A member can leave only from its own session. When that session has dropped, the lead, the person
who started the formation, or an account administrator can take it off with `formation_remove` and
its `member_id` from the roster; add `formation_id` to act on a formation this conversation is not
in. MMRY AI decides who may, and says so when it refuses. The member receives nothing further and a
message directed at it is refused, so remove a member only when its session has really gone. The
same person's other windows in the formation stay on.

### Leading a formation on Codex

Codex cannot wake an idle conversation. A lead on Codex therefore hears its members only on its
next action: their messages and reports arrive with this conversation's next tool call or the
customer's next message, never while it sits idle. A lead has to be listening all the time, or the
customer has to keep prompting it.

So when a customer asks to start a formation here, start it, give them the id, and tell them
plainly what `formation_start` says: Codex is fine for joining a formation, but we recommend it does
not lead one; a Claude Code session hears its members while idle, so start the formation from Claude
Code and join it from Codex. If they lead from here anyway, check in while the work runs: call
`formation_roster`, which shows each member's state and delivers anything waiting, and tell the
customer to send a message to this conversation whenever they want an update. Never tell a customer
a member's message will reach an idle Codex lead on its own.

**Relay the next-action line to the customer, in your own reply, after every `formation_start` and
every `formation_assign`.** Both results include a line that begins "Tell the customer this in
your reply". It is for the customer, not for you: never leave it out, even when the rest of your
reply is a one-line confirmation. After `formation_assign`, tell the customer that the member's
report arrives when they next send a message here, not on its own, and to check in then. For
example: "Member 7 has the checkout tests. Their report reaches me only when you next send a
message here, so check in with me once they have had time to work." After `formation_start`, give
the id, say the same of every member, and give the recommendation above.

Messages from the formation arrive on their own, marked `MMRY AI Formation Transmission`. Each
line names its sender by name and member id, for example `[Checkout tests (12)]`, or by role and
member id, `[Wingman 14]`, when the sender has no name. A line marked
`DIRECTED TO YOU` was sent to this session and nobody else: act on it. A line marked `[MMRY]` came
from the memory system rather than from a colleague.

Joining prints two standing rules, and every assignment repeats them. Follow them for as long as
this session is in the formation; they are the same on every platform:

> Report to the lead at every stopping point, with a message directed to the lead: when you finish, when you are blocked, when you are waiting, and when you stop with work still running, saying what is still running. Never hold finished work back for a slow check; report it and say the check is still running.
>
> When you receive an assignment, a brief or a question, acknowledge it before you start, with substance: what you understood, anything you cannot do, and when to expect the result. If the job is short, fold that into your first update. Findings and status updates need no acknowledgement.

Each member is also given one rule for its own role:

> As the lead, delegate and check in: when a member is idle or reports Done, give it the next piece of work or tell it there is none, and do not do work yourself that an idle member could take. Keep for yourself the coordinating, the deciding and the reviewing.
>
> As a member, never go idle silently: when you finish, report Done to the lead and end the report by asking whether there is anything else you can do, then keep listening for the answer.

**The lead hears who is free.** A member with no active work for 15 minutes is named to the lead, up to three times, 30 minutes apart, and the roster marks it. A member's own Done asks the lead: Is there anything else I can do? A lead on Codex or a connected assistant sees this on its next action, not while idle.

Send the report with `formation_say`, with `to_member_id` set to the lead's id; the roster shows
which member is the lead.

When `formation_leave` or `formation_progress` with `Done` or `Abandoned` for your own work ends with a prompt to save what you did, act on it with `memory_save` (#32682).

Listing formations and claiming an area have no tool and are scripts, and neither has been
tested from Codex yet; see the next section.

## Operations with no tool: MMRY's scripts

**Everything in this section has no mmry_plugin tool, so it is a bash script. Nothing above is.**
Use a script only for the operations listed here.

The scripts live in the MMRY directory inside the customer's Codex home, which the SessionStart
hook populates at the start of every session.

**WRITE THE PATH AS `"${CODEX_HOME:-$HOME/.codex}/mmry/<folder>/<script>"`.** Every command
below does, and it matters: Codex reads `CODEX_HOME` to find its own configuration, and a customer
who has moved their Codex home has no `~/.codex` directory at all. That form resolves correctly in
both cases, needs nothing set up beforehand, and is safe to paste into any shell you reach for -
unlike a variable you set in one Bash call, which is gone by the next one.

The examples below spell it out in full for that reason. `~/.codex/mmry/...` is the same path on a
default install, and is fine to SAY to a customer, but do not RUN it: on a relocated home it names
a directory that does not exist, and the failure is a confusing "No such file or directory" rather
than anything that names the real problem.

### On Windows: run every script through Git Bash

On Windows, Codex runs your commands in PowerShell, and there a bare `bash` is the Windows
Subsystem for Linux's: it cannot see the user's Windows files and fails with
`execvpe(/bin/bash) failed`. Never type `bash` at the PowerShell prompt.

Instead, put the command exactly as it is written in this skill between the `@'` line and the `'@`
line below, and run the whole block as one command:

```powershell
$c = @'
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/list-groups.sh"
'@; $f = Join-Path $env:TEMP "mmry-$PID.sh"; [IO.File]::WriteAllText($f, $c.Replace("`r", "")); & (Join-Path (Split-Path (Split-Path (Split-Path (git --exec-path)))) 'bin\bash.exe') $f; Remove-Item $f
```

Why it is shaped like that, so you do not "simplify" it:

- The command travels to Git Bash in a file, not as an argument. Windows PowerShell 5.1 strips the
  double quotes out of arguments it hands to another program, so `bash -c "..."` arrives broken
  there, and memory text full of quotes would be mangled.
- `@'` ... `'@` is a literal block: nothing inside it is changed by PowerShell, so `$`, quotes and
  backslashes reach bash as written. `'@` must start its own line.
- Git Bash is found from `git --exec-path`, which points into the Git install whichever `git.exe`
  is on PATH. Splitting the path of `git.exe` itself gives the wrong folder when Git's `mingw64\bin`
  is on PATH.

On macOS and Linux, run the commands as written.

### Who can see a memory

Memories default to Global, meaning everyone on the account. The alternatives are Private (only the
person who saved it) and Group (only members of one permission group). A single save can set its
own with `memory_save`'s `visibility` and `permission_group_id`; the default and re-scoping are
scripts:

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

### The formation operations with no tool

Listing the active formations and claiming an area have no tool, and neither has been tested
from Codex yet. If a customer asks for one, run it and tell them it has not been tested on Codex:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-list.sh"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-claim.sh" "src/Billing"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/formation-claim.sh" --list
```

They were left undocumented here until #31245 QA round 6 because the instructions they printed
named typed slash commands. Those messages are derived from the host now, and where one names an
operation a tool covers, it names the tool.

### Your AI database

MMRY AI markets this as **your AI database**: a database the assistant builds and fills in while
the customer talks. One thing the customer tracks (expenses, sales leads, a migraine log) is **a
database**, each item saved in it is **an entry**, and its named values are **fields**. Say those
words to the customer. The scripts and flags below keep older names (`create-format.sh`,
`--format-id`, `save-record.sh`, `--record-id`) because installed copies call them so; they are
code, not words to repeat.

Most saves are ordinary memories. Set up a database only when the customer is accumulating
examples of a recurring shape they will want to count, filter or compare later, and never for a
single fact. List what they have first and reuse it:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/list-formats.sh"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/list-formats.sh" --id 42
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/create-format.sh" --name "Expenses" \
  --fields '[{"key":"amount","label":"Amount","type":"number"},{"key":"category","label":"Category","type":"text"}]' \
  --mode append --match-hints "expense, spent, paid"
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/save-record.sh" --format-id 42 \
  --content "the customer's own words" --fields '{"amount":25,"category":"travel"}'
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/query-records.sh" --format-id 42 --filter category=travel
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/record-history.sh" --format-id 42 --record-id 9137
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/revise-format.sh" --id 42 --retire
```

`--format-id` is the database's id and `--record-id` an entry's id. Name the fields from the
customer's own words. `--mode keyed --identity-field <key>` is for a list of named things that
each change on their own (leads, tasks); `append` is a log where every entry is new. Report the
outcome `save-record.sh` prints: `structured.created` is a new entry, `structured.updated` changed
one, and `text.degraded` means the words were kept but the fields were not. An update changes only
the fields you send. `query-records.sh` answers how many, which ones and in what order from the
values; `record-history.sh` lists what an entry used to hold, oldest first. Retiring stops a
database collecting and deletes nothing. The same databases and entries are in Claude Code,
through the MMRY connector and at mmryai.com/records. These scripts have not been tried from a
live Codex session yet: if you run one, say so.

### Setting up

If memories are not loading, the account may not be authenticated on this machine:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/setup/mmry-setup.sh"
```

It opens a browser for the customer to sign in at mmryai.com and writes the credential. After it
finishes, the customer restarts Codex.

### If the MMRY tools are missing

When this conversation is offered no mmry_plugin tools, find out why in one step:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/tools-check.sh"
```

It needs no network and changes nothing, so it runs in the sandbox without asking for access. Its
first line is `MMRY tools: running` or `MMRY tools: not started`; the `Why:` line names the reason,
and the rest says how to get the tools back. Tell the customer what it says, in plain words.

The recovery is always the same shape: fix what the check names, quit Codex completely, then reopen
THIS SAME conversation (in the desktop app, from the conversation list; in a terminal,
`codex resume` with the id the check prints). Reopening the same conversation keeps its place in a
Formation and its member id. Never recover by starting a new conversation, by leaving and rejoining
the Formation, or by using the `mmry_formation_*` connector tools: each of those joins as someone
else, so the other members see a new member and this conversation's messages stop arriving.

If the check says MMRY's launcher is not marked executable, the customer runs the same command with
`--recover` added, in a terminal; that is the one thing it repairs, and it never touches a Formation
membership. If the tools are still missing after the recovery, report a problem (below), and paste
the check's output into it.

### Reporting a problem

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/submit-feedback.sh" --type bug --title "..." --description "..."
```

### If one of these scripts cannot reach MMRY AI: ask for access, once per conversation

This is about the scripts in this section only. If the operation has a tool, you should not have
run a script for it: call the tool instead of asking.

In Codex's default sandbox, a command you run has no network access and cannot write under the
Codex home, so MMRY's scripts fail there. The hooks are not affected; only what you run yourself.
You will see one of:

- `Error (HTTP 000): curl failed`, followed by a request_permissions line
- `Error: could not reach MMRY AI at https://mmryai.com ...` from setup

When that happens, do not retry the same command blindly and do not tell the customer it worked.
Call the `request_permissions` tool for network access and write access to the MMRY folder in the
Codex home, and ask the customer to approve it **for this conversation**. The error output prints
the exact request with this machine's paths; use it. It has this shape:

```json
{
  "reason": "MMRY AI needs to reach mmryai.com and keep its files in your Codex home for this conversation.",
  "permissions": {
    "network": { "enabled": true },
    "file_system": { "write": ["<absolute path of the Codex home>/mmry"] }
  }
}
```

Setup also writes the credential file beside that folder, so for setup add
`<absolute path of the Codex home>/mmry-config.json` to `write`. The paths must be absolute; the
request does not expand `${CODEX_HOME:-$HOME/.codex}`.

Once it is approved, run the same MMRY command again. An approval for the conversation covers
every MMRY command after it, so ask once, not before each command. If the customer declines, or
the tool is not offered, say so plainly and give them the two alternatives: run the command
themselves in a terminal, or allow it permanently in their Codex settings (see docs/codex.md,
"What MMRY's commands need from Codex").

### In the Codex desktop app

If a customer asks whether MMRY works in the Codex desktop app, this is what has been tested:

- On a Mac and on Windows, MMRY's hooks run in the desktop app: memories load when a conversation
  starts, and saving, searching and retiring memories and formation messages work. On a Mac,
  Foundation memories are also re-stated on each later turn.
- On Windows, MMRY's scripts do not start inside the desktop app's sandbox, so in the desktop app on
  Windows MMRY works through its own tools. For anything that still runs as a script, such as
  changing who can see a memory, tell the customer to use the Codex CLI.
- Trust MMRY's hooks in the Codex CLI review (choose "Trust all and continue" when the Codex CLI
  starts). In our testing, hooks trusted in the Codex CLI review also ran in the desktop app.
- The desktop app's hook settings page for MMRY AI can stay on "Loading hooks..." or show "No hooks
  found". That does not stop MMRY working. If memories loaded at the start of this conversation,
  MMRY's hooks are running.

## Removing MMRY from Codex

If the customer asks how to uninstall, do NOT point them at uninstall.sh or uninstall.bat. Both of
those remove the CLAUDE CODE installation and both refuse to run from a Codex directory. The Codex
removal is three steps, and the first one is theirs to do in the Codex interface:

1. They remove the plugin through Codex, the same way they added it:
   ```bash
   codex plugin remove mmry@mmry-plugin
   ```
2. Delete the MMRY directory:
   ```bash
   rm -rf "${CODEX_HOME:-$HOME/.codex}/mmry"
   ```
3. Delete the credential, which is what disconnects the machine from the account:
   ```bash
   rm -f "${CODEX_HOME:-$HOME/.codex}/mmry-config.json"
   ```

Tell them their memories are stored on the account and none of this deletes any of them, and that
a Claude Code installation on the same machine is untouched.

## What is not available here, stated plainly

If a customer asks what MMRY can do on Codex, or seems to expect something that is not here, point
them at the full statement rather than improvising:
https://github.com/MMRY-AI/mmry-plugin/blob/master/docs/codex.md

The four things that are genuinely unavailable on this platform are: typed slash commands, the
prompt before context is trimmed, waking an idle session with a formation message, and the
plan-accepted prompt. Never imply any of them works here.

The formation operations tested on Codex are: start, join, say (to the formation or to one member),
assign, progress, roster, report, debrief and leave, all as tools. Do not tell a customer any of
them is unavailable. Removing a member (`formation_remove`) is a tool here too, but it has not been
tested live from Codex yet: never tell a customer it is proven here. Listing the formations and
claiming an area have not been tested from Codex yet: never tell a customer they are proven here,
and if you run one of their scripts, say it has not been tested on Codex. Do tell a customer who
leads from Codex that a lead here hears its members only on its next action, and that we recommend a
Claude Code session lead (see "Leading a formation on Codex").
