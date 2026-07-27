# MMRY AI Help

MMRY AI is your memory. It remembers your decisions, conventions, preferences, and context across every session — so you never have to repeat yourself.

## How It Works

You don't need to do anything special. MMRY AI runs quietly in the background:

- **When a session starts**, your memories load automatically. Claude already knows your context.
- **On every message**, your Foundation memories - your identity, values, and standards - are kept front and center, so Claude follows them consistently through a long session, not just at the start.
- **When a session ends**, Claude is prompted to save anything important before closing.
- **When context gets compressed**, Claude saves a continuity note so nothing is lost.
- **When a plan is accepted**, Claude saves it as a decision record.

## Things You Can Say

You can talk to Claude naturally about your memories:

- **"Remember this: we always use kebab-case for file names."** — Claude saves it as a memory.
- **"Save a Foundation memory about our tech stack."** — Foundation memories never expire. Use them for things that define who you are.
- **"What do you remember about our deployment process?"** — Claude searches your memories.
- **`/mmry:search <keywords> [scope]`** runs a search on demand and lists the matches, optionally narrowed to one area of your work.
- **"Forget the memory about the old API endpoint."** — Claude deactivates it.
- **"Load my memories."** — Reloads your memories mid-session (same as `/mmry:load-memories`).

## Memory Types

Not all memories are equal. Use the right type for the right purpose:

| Type | Lasts | Good For |
|------|-------|----------|
| **Foundation** | Forever | Who you are, your values, your stack, your conventions |
| **Strategic** | 1 year | Architecture decisions, communication patterns, long-term plans |
| **Operational** | 3 months | Active project knowledge, current workflows |
| **Tactical** | 7 days | This week's tasks, current sprint context |
| **Momentary** | 8 hours | Right now — what you're working on this session |

Memories that get accessed regularly stay alive longer. Memories that stop being relevant fade naturally.

## Tips

- **You don't need to memorize this.** Just talk to Claude. Say "remember this" or "save this as a decision" and Claude handles the rest.
- **Foundation memories are your identity.** Take a few minutes early on to tell Claude about your team, your tools, and your values. Everything builds on that. Because they steer every response, keep the set small and deliberate.
- **Foundation changes reach the whole team.** Foundation memories refresh automatically each day, so when an admin adds or updates one, everyone picks it up. Need it sooner? Say "load my memories" or restart Claude Code to refresh right away.
- **Don't over-save.** Only save things you'd want to know next week or next month. Claude's own context handles the rest within a session.
- **Memories are private to your organization.** Your team shares memories. Other organizations can't see them.
