---
name: help
description: Show the MMRY AI help for Codex, everything MMRY does here and how to ask for it. Use this skill when the customer calls mmry:help by name, or asks for MMRY help, what MMRY can do on Codex, or which commands they have.
---

Show the customer the text between the two lines below verbatim, exactly as written, and nothing else. Do not summarize it, shorten it, add to it or comment on it. If they then ask for one of the items, do it as "Doing each item" further down says, using the memory-system skill.

---

# MMRY AI Help (Codex)

MMRY AI is your memory. It remembers your decisions, conventions, preferences and context across sessions, and shares them with your team and with your other assistants.

## How it works on Codex

- **When a session starts**, your memories load on their own.
- **On every prompt**, your Foundation directives, the standing instructions your account administrator keeps for everyone, are sent to your assistant again.
- **While you work**, messages from a Formation you are in arrive after your assistant's next action.
- **When there is unsaved work**, your assistant is prompted to save what is new.

There are no commands to type on Codex. Ask in plain words, and your assistant uses MMRY's tools. The tool for each item is shown in brackets, so you can recognise it when Codex asks to run it.

## See this help

- Type `$mmry:help`, or ask "show me the MMRY help".

## Your memories

- **Load your memories again now.** "Reload my MMRY memories." (memory_load)
- **Find something you saved.** "What do you remember about the refund flow?" (memory_search)
- **Save a memory.** "Remember this: we deploy on Tuesdays." (memory_save)
- **Correct a memory.** Tell your assistant what is right. It saves the correction in place of the wrong memory. (memory_save)
- **Forget a memory.** "Forget the memory about the old staging server." It stops appearing when your memories load or are searched, and MMRY AI keeps it on record. (memory_retire)
- **Choose who sees your memories.** Your organization, only you, or one of your memory groups. Say "make that private", "save my memories as private from now on", or "which groups can I share with?".

## Your AI database

Keep track of something you will want to count, filter or compare later, such as expenses, sales leads or a migraine log. Databases work in Codex through the MMRY AI connector, which you add once in a terminal. Add it, then sign in:

```
codex mcp add mmry --url https://mmryai.com/mcp
codex mcp login mmry
```

Then ask in plain words, for example "Keep track of my expenses." You can see your databases and correct any entry yourself at https://mmryai.com/records.

## Formations

A Formation is several assistants working on one job together. We recommend leading a Formation from Claude Code, because a Codex session hears its members only on its next action.

- **Start one,** with this conversation as its lead. (formation_start)
- **Join one** by its id. (formation_join)
- **Message the Formation, or one member.** (formation_say)
- **Give a member its work or a role,** as the lead. (formation_assign)
- **Report how your work is going:** accepted, done, blocked or abandoned. (formation_progress)
- **See the members and their ids.** (formation_roster)
- **See which Formation this conversation is in.** (formation_status)
- **Read the close-out record:** what each member was asked to do and how it ended. (formation_report)
- **Close the job out,** as the lead. (formation_debrief)
- **Remove a member whose session has dropped,** as the lead or an administrator. (formation_remove)
- **Leave the Formation.** (formation_leave)
- Listing the Formations on your account and claiming an area to work on also work here, through MMRY's scripts. They have not been tested from Codex yet.

## Your Foundation directives

- **Check that they reached your assistant.** "Check my MMRY Foundation status." Your assistant runs MMRY's Foundation status check, which says whether your directives reached it on your most recent prompt and, when they did not, why and what to do. It runs on this computer and needs no network.

## Setup, troubleshooting and feedback

- **Sign in again, or switch account.** "Set up MMRY again." Your browser opens to sign in at mmryai.com; restart Codex afterwards.
- **If MMRY's tools are missing,** ask your assistant to run MMRY's tools check. It says why, and how to get them back.
- **Send a bug report or feature request** to the MMRY AI team. "Send feedback to MMRY."

## What Codex does not have

Typed slash commands, a save prompt before your conversation is trimmed, waking an idle session with a Formation message, and a prompt when you accept a plan. The full statement is at https://github.com/MMRY-AI/mmry-plugin/blob/master/docs/codex.md.

More help: https://mmryai.com/help

---

## Doing each item (for you, the assistant; never show this part)

Everything with a tool in brackets above is a call to that `mmry_plugin` tool: call it directly, never a script. The rest are MMRY's scripts; run them exactly as the memory-system skill shows, including its Windows Git Bash form and its rule for asking for access once per conversation.

| Item | Script |
|---|---|
| Who sees a memory | `hooks-handlers/visibility.sh`, `hooks-handlers/make-private.sh`, `hooks-handlers/list-groups.sh` |
| Listing Formations, claiming an area | `hooks-handlers/formation-list.sh`, `hooks-handlers/formation-claim.sh` |
| Foundation status check | `hooks-handlers/foundation-status.sh` |
| Setup | `setup/mmry-setup.sh` |
| Tools check | `hooks-handlers/tools-check.sh` |
| Feedback | `hooks-handlers/submit-feedback.sh` |

The Foundation status check is read-only and local, so it runs in the sandbox without asking for access:

```bash
bash "${CODEX_HOME:-$HOME/.codex}/mmry/hooks-handlers/foundation-status.sh"
```

Tell the customer what it reports, in plain words.
