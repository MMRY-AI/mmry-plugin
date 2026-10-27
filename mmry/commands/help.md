Output the text below the line verbatim, exactly as written, and nothing else. Do not summarize it, shorten it, add to it or comment on it.

---

# MMRY AI Help

MMRY AI is your memory. It remembers your decisions, conventions, preferences, and context across every session, so you never have to repeat yourself.

## How It Works

You don't need to do anything special. MMRY AI runs quietly in the background:

- **When a session starts**, your memories load automatically. Claude already knows your context.
- **On every message**, your Foundation memories - your identity, values, and standards - are kept front and center, so Claude follows them consistently through a long session, not just at the start.
- **When a session ends**, Claude is prompted to save anything important before closing.
- **When context gets compressed**, Claude saves a continuity note so nothing is lost.
- **When a plan is accepted**, Claude saves it as a decision record.

## Commands

- `/mmry:help` shows this page.
- `/mmry:save [what to remember]` saves a memory, either what you describe or the most important takeaway from the conversation.
- `/mmry:search <keywords> [scope]` searches your memories and lists the matches.
- `/mmry:load-memories` reloads your memories into this session.
- `/mmry:foundation-status` reports whether your Foundation directives are reaching this assistant right now.
- `/mmry:visibility [global | private | group ["NAME"]]` sets who can see the memories you save: your organization, only you, or one of your groups.
- `/mmry:feedback` sends a bug report or feature request to the MMRY AI team.
- `/mmry:setup` sets up MMRY AI, or reconfigures it for a different account.
- `/mmry:uninstall` removes MMRY AI from this computer.
- `/mmry:formation <subcommand>` coordinates several assistants on one job, as a Formation. The subcommands:
  - `/mmry:formation start "objective"` begins a Formation with this session as its lead.
  - `/mmry:formation join <id>` puts this session in a Formation.
  - Each member is given a rule for its role, and the lead is told which members have had no work for 15 minutes.
  - `/mmry:formation roster` lists the members and the ids to address them by.
  - `/mmry:formation say "message" [--to <memberId>]` sends a message to the other members, or to one member.
  - `/mmry:formation assign <memberId> "work"` gives one member its work (the lead).
  - `/mmry:formation progress <state> "note"` tells the lead how your assigned work is going.
  - `/mmry:formation report` shows what each member was asked to do and how it ended.
  - `/mmry:formation claim "<path>"` declares the area this session is about to work, so nobody collides with it.
  - `/mmry:formation debrief "summary"` closes the job out with a record that lasts (the lead).
  - `/mmry:formation leave` takes this session out of the Formation.
  - `/mmry:formation remove <memberId>` takes a member whose session has dropped off the Formation (the lead or an administrator).
  - `/mmry:formation status` shows which Formation this session is in.
- `/mmry:database <subcommand>` starts and uses a database in your AI database. Asking in plain words does the same. The subcommands:
  - `/mmry:database create "what to keep track of"` sets up a database, with fields named in your words.
  - `/mmry:database list` lists your databases, or one database in full with its fields.
  - `/mmry:database add <database> "the entry"` saves a new entry.
  - `/mmry:database find <database> [field=value]` finds entries by the values in their fields.
  - `/mmry:database correct <database> <entry> "what changes"` corrects an entry already saved.
  - `/mmry:database history <database> <entry>` shows what an entry held before, and when it changed.
  - `/mmry:database retire <database>` stops a database collecting new entries. Nothing is deleted.
  - `/mmry:database restore <database>` starts a retired database collecting again.
  - You can also see your databases and correct any entry yourself at https://mmryai.com/databases.

## Your AI database

Claude can keep a database for anything you track again and again, such as your expenses, your migraines or your job applications. Each item in a database is an entry. Ask in plain words or use `/mmry:database`; both do the same. A new database is private unless you ask Claude to share it with everyone on your account. `/mmry:database list` shows each database's id.

- **Start a database:** "Keep track of my expenses for me: how much each one was, what it was for, and the date." Claude sets up an Expenses database with the fields Amount, What it was for and Date. Or: `/mmry:database create "job applications: the company, the role, the date I applied and where it stands"`.
- **Add an entry:** "I spent $42 on lunch with a client today." Claude saves it as an entry and tells you what it saved. Or: `/mmry:database add <database> "Applied to Globex for Senior Analyst on Monday"`.
- **Ask about your entries:** "Which of my expenses were over $20?" Claude answers from the values in your entries. Or: `/mmry:database find <database> status=interviewing`.
- **Correct an entry:** "That lunch was actually $48, not $42." Claude changes that entry, and the values you do not mention stay as they are. Or: `/mmry:database correct <database> <entry> "Globex invited me to interview"`.
- **See an entry's history:** "Show me the history of the lunch entry." Claude lists every change, oldest first, with when it was made. Or: `/mmry:database history <database> <entry>`.
- **Stop a database:** "Stop keeping my expenses for now." Nothing is deleted: every entry stays readable and in your export. Or: `/mmry:database retire <database>`.
- **Start it again:** "Start keeping my expenses again." Or: `/mmry:database restore <database>`.
- **See your databases:** `/mmry:database list` lists them, and you can see every entry and correct it yourself at https://mmryai.com/databases.

## Things You Can Say

You can talk to Claude naturally about your memories:

- **"Remember this: we always use kebab-case for file names."** Claude saves it as a memory.
- **"Save a Foundation memory about our tech stack."**: Foundation memories are your standing guidance. Use them for things that define who you are.
- **"What do you remember about our deployment process?"** Claude searches your memories.
- **`/mmry:search <keywords> [scope]`** runs a search on demand and lists the matches, optionally narrowed to one area of your work.
- **`/mmry:formation start "objective"`** begins a formation with this session as its lead. **`join <id>`** puts this session in a formation, a group of assistants coordinating on one job, so their messages are surfaced here automatically. **`say "message"`** sends one to the others, and **`say "message" --to <memberId>`** sends it to that one member and nobody else, which is what an instruction meant for one person wants. **`roster`** lists the members and the ids to address them by. **`debrief "summary"`** closes the job out with a record that lasts. **`remove <memberId>`** lets the lead or an administrator take off a member whose session has dropped; that member's other windows stay on. Also `leave` and `status`. Every member is told when it joins, and again with every assignment, to report to the lead at each stopping point (finished, blocked, waiting, or stopping with work still running) and to acknowledge an assignment, a brief or a question with what it understood, anything it cannot do and when to expect the result; `/mmry:formation` has the exact wording. Members receive a message on their next tool call, or within a minute while idle, by default for 24 hours of quiet after their last turn, or when that session next starts. Idle listening renews about every half hour, and each renewal is a model turn that re-reads the whole conversation (measured at about 30,000 tokens in a new session and 570,000 to 880,000 in a long one) and counts toward Claude Code usage, while each check for messages uses one MMRY credit (about 1,580 over a full day at the default 24 hours). Set `formationListenMinutes` in `~/.claude/mmry-config.json` to a number of minutes, `"off"` or `"unlimited"` (no limit) to change it; renewal needs Claude Code 2.1.285 or newer. A session that is closed or asleep may not receive until then, so if something has to be acted on now, ask that session to run `/mmry:formation status`. `roster` also shows whether each message you sent with `--to` has been read. Delivery while a session is idle needs Claude Code 2.1.64 or newer, and MMRY plugin 2.9.1 or newer. On an older client, or on a Mac running MMRY 2.9.0 or earlier, nothing breaks and nothing is lost, but a message waits for that member's next tool call, next prompt or next session start instead of arriving while they sit idle. On a Mac the plugin version is the more likely of the two, so check both before concluding a message was not sent.
- **`/mmry:foundation-status`** reports whether your Foundation directives are actually reaching this assistant right now: whether re-injection is on, whether the locally stored copy still matches the record MMRY wrote when it last fetched your directives, how many directives and bytes it holds, whether the most recent prompt received them in full, in part or by reference, and how long ago they were last sent. It is a local check and makes no network call. Read-only.
- **"Forget the memory about the old API endpoint."** Claude deactivates it.
- **"Load my memories."** Reloads your memories mid-session (same as `/mmry:load-memories`).
- **"Keep track of our bug reports, then save one."** Claude sets up a database for them with fields named in your words, saves each bug report as an entry, and can answer questions about the values or show an entry's history.

## Tips

- **You don't need to memorize this.** Just talk to Claude. Say "remember this" or "save this as a decision" and Claude handles the rest.
- **Foundation memories are your identity.** Take a few minutes early on to tell Claude about your team, your tools, and your values. Everything builds on that. Because they steer every response, keep the set small and deliberate.
- **Foundation changes reach the whole team.** Foundation memories refresh automatically each day, so when an admin adds or updates one, everyone picks it up. Need it sooner? Say "load my memories" or restart Claude Code to refresh right away.
- **Don't over-save.** Only save things you'd want to know next week or next month. Claude's own context handles the rest within a session.
- **Memories are private to your organization.** Your team shares memories. Other organizations can't see them.
