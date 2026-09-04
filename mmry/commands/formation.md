Join a formation, hand out its work, declare what you are touching, speak to it, or leave: a group of assistants coordinating on one job at the same time.

Usage: `/mmry:formation start "objective"` | `/mmry:formation join <formationId>` | `/mmry:formation roster` | `/mmry:formation assign <memberId> "what they should work on"` | `/mmry:formation claim "src/Billing"` | `/mmry:formation say "message" [--to <memberId>]` | `/mmry:formation debrief "summary"` | `/mmry:formation leave` | `/mmry:formation status`

## What This Does

A formation is several assistants working one objective together, sending each other short
messages as they go. Once this session is in a formation, those messages are surfaced to you
automatically after each tool call. You do not have to ask for them.

**This command is what activates that.** Without it, this session does not know which formation
it belongs to and nothing is delivered, because the delivery hook reads the formation from local
session state and nothing else writes it.

## How to Run It

Take the user's input from `$ARGUMENTS`.

### start

The user gives the objective, for example `/mmry:formation start "migrate the billing schema"`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-start.sh" "<objective>" [taskId]
```

This creates the formation and makes this session its lead. Report the id it prints, because the
other sessions need it to join.

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
     This does NOT apply to your own formations: since #31122 a person needs no access group with
     themselves, so your own other windows can always join.
   - This session already belongs to another formation. Run `/mmry:formation leave` first, which
     since #31194 releases it on the service and frees it to join this one.

   **Every window joins for itself.** Membership is held per session, so starting a formation in
   one terminal does not enrol the others; each runs join with the id.

### roster

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-roster.sh" [formationId]
```

Who is in the formation, with the **member id** for each one. With no argument it shows this
session's own formation.

The member id is what `say --to` addresses. Report the list as the script prints it. Members who
have left are shown last and marked; a message cannot be directed at them, and the server refuses
it rather than sending it into a void.

### say

The user gives the message, for example `/mmry:formation say "I am refactoring FormationService, do not touch it"`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-say.sh" "<message>"
```

This is how anything gets into the channel the other members are listening to. The message is
recorded exactly as typed and delivered to every other member. There is no minimum length: "done",
"stop" and "files locked" are perfectly good transmissions, and until #31122 they were silently
discarded because the server interpreted messages instead of storing them.

#### say to one member (#31045)

When the message is an **instruction with exactly one intended recipient**, address it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-say.sh" "<message>" <memberId>
```

The user writes it as `/mmry:formation say "rewrite the validator" --to 12`. Pass the number
through as the second argument.

**Get the id from `/mmry:formation roster`, and do not guess one.** A wrong id is refused rather
than misdelivered, but it costs a round trip and the sender's attention. If the user names a person
rather than an id, run the roster, match them, and use the id you found.

**When to direct and when to broadcast.** Direct it when it is an order for one member: broadcasting
an instruction means every other member reads an order meant for somebody else, and any of them
might act on it. Broadcast findings, blockers and heads-ups, which are exactly the things everybody
needs.

**Report which one happened.** The script says "Sent to member N in formation X, and to nobody
else" or "Sent to formation X", and those are different facts. Never describe a directed message as
having gone to the formation, or the reverse.

**A refusal names its own cause and you pass it through.** The server refuses a member id that is
not in this formation, one belonging to another account, one who has left, and the sender's own.
Nothing is sent in any of those cases, and the message is not quietly broadcast instead.

Send one when it affects what somebody else is doing: you are about to change a file, you are
blocked, you have finished something they are waiting on. Do not narrate. Every member is
interrupted by it after their next tool call.

The script exits non-zero and explains itself when the message was not recorded. **Pass that
through. Never report a message as sent unless the script said so**, because a message nobody
received, reported as sent, is worse than an error.

A refusal usually means this window has not joined the formation, or the formation has been closed
out. The server does not distinguish those two, deliberately, so the script names both.

### assign

The lead gives one member its work, for example `/mmry:formation assign 12 "take the validator and its tests"`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-assign.sh" <memberId> "<assignment>" [role]
```

This is how the lead stops being a title. Until #31044 each member declared its own job when it
joined and nothing could change it afterwards, so the person running the work opened every window
themselves and briefed each one by hand.

**Get the member id from `/mmry:formation roster`, and do not guess one.** It is the same id
`say --to` uses.

**Only the flight lead, the person who started the formation, or an account administrator may do
this.** A wingman reassigning a colleague is refused, and the refusal comes from the server, which
decides it from the roster rather than from anything the request says.

**It reaches that member and nobody else.** The assigned session sees it after its next tool call,
marked as directed at it. The other members are not interrupted, because an instruction that
concerns one person and is read by five is the waste the formation exists to remove.

**An omitted field is left alone.** Give an assignment, a role, or both. Changing only the role
keeps the assignment. There is deliberately no way to blank an assignment back to empty.

To change only the role, pass an empty assignment:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-assign.sh" 12 "" Lead
```

**Report what the script reports.** On success it prints what the roster now holds, read back from
the server rather than echoed from the request. On a refusal it prints the server's own reason, and
that reason is worth passing through verbatim: no such member, a member who has left, a bad role
and nothing named to change all look the same otherwise.

### claim

Declare the area this session is about to work, so nobody collides with it unknowingly.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-claim.sh" "<path>" [repository]
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-claim.sh" --list
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-claim.sh" --release <claimId>
```

For example `/mmry:formation claim "src/Billing"` before starting on the billing code.

**Declare before you start, not after.** The point is to find out that somebody else is already
there while it still costs nothing.

**The repository is worked out from the git root.** Pass it as a second argument only when the
checkout is not named what the team calls the repository. Two members who spell it differently are
never warned about each other, and nothing detects that they have not been.

**If it overlaps somebody, both of you are told, privately, and nothing is blocked.** Two sessions
legitimately touch one file during a rebase, so a hard refusal would strand real work. Agree who
takes it, or carry on if you are not in fact in each other's way.

**An overlap means two declared paths overlap as text.** It does not mean you are editing the same
file. Do not tell the user it does.

**Leaving the formation releases every area this session declared,** so `--release` is only for
finishing one area and moving to another while staying in the formation. A session that has left,
or one that rejoins, holds nothing.

**Declaring the same area twice is not news.** The script says so, and says that nobody was told
the second time. Never describe a repeat as having warned anybody.

**What is compared is the repository and the path, never what anybody wrote in their assignment.**
If the user asks why two people working "the billing code" were not warned, that is the answer:
prose is not matched, on purpose, because a warning built on a guess is a warning that will be
wrong.

### debrief

The lead gives the closing summary, for example `/mmry:formation debrief "Schema migrated, the
import bug turned out to be the date format, follow-up filed as #12345"`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-debrief.sh" "<summary>"
```

This is how a formation ends properly. The summary is consolidated into lasting memories that
someone who was never in the formation can read later, and the running chatter stops being served.
Only the lead, the creator or an administrator may do it; the script translates a refusal.

If it reports that nothing was recorded, the formation is still active and retrying is safe. Do
not tell the user it was closed out unless the script said so.

### leave

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/formation-leave.sh"
```

This releases the session on the service as well as stopping delivery here (#31194), so the session can then join another formation. Nobody else in the formation is affected and the formation is not closed out.

**Report what the script reports, and nothing more.** It distinguishes four outcomes and the wording matters:

- It released the session. Say so, and that this session can now join another formation.
- The service holds no membership for this session. There was nothing to release; do not call that a failure.
- The service refused (it prints the status). Say the release was refused and that this session is still a member as far as the service is concerned, so joining another formation will be refused until that is resolved.
- The service could not be reached. Same warning, different cause.

Never tell the user the session left when the script did not say it did. Somebody who believes they left, and then cannot join anything, has nothing on screen to explain it.

A session that has lost track of which formation it was in can still run this: the service resolves the membership from the session itself, so no formation id is needed.

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
- **Do not report success unless the script says so.** The join and say scripts exit non-zero and
  explain themselves on failure; pass that explanation through rather than replacing it with a
  summary.
- **Do not transmit on the user's behalf without being asked.** Speaking interrupts every other
  session in the formation. Send when the user asks, or when you have something that genuinely
  affects another member's work.
