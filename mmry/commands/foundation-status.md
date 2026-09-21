Check whether your Foundation directives are actually reaching your assistant right now.

Usage: `/mmry:foundation-status`

## What This Does

Foundation memories are your standing directives, re-sent to the assistant on every prompt.
This reports, in plain words, whether that is really happening: whether re-injection is
switched on, whether the locally stored copy still matches the record MMRY wrote when it
last fetched your directives, how many directives and characters it holds, and how long ago
it was last sent.

It is a LOCAL integrity check and makes no network call. That is worth being precise about,
because the two questions are different. It can tell you your copy is intact and is being
delivered to the assistant. It cannot tell you your copy agrees with what is in your account
right now, so if you have edited your directives in the portal since this session last
fetched them, run `/mmry:load-memories` rather than reading a healthy report here as
confirmation that the edit is in force.

It answers the question you would otherwise have no way to ask. A damaged local copy is
refused and reported by the hook itself, but a refusal only speaks when something is wrong.
This lets you confirm the healthy case too.

It is read-only. It never rebuilds, repairs, or changes anything.

## How to Run It

Run the hook with the Bash tool. Prefer the plugin path; fall back to the installed runtime
copy:

```bash
HOOK="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/hooks-handlers/foundation-status.sh}"
[ -f "$HOOK" ] || HOOK="${HOME}/.claude/mmry/hooks-handlers/foundation-status.sh"
bash "$HOOK"
```

Show the output to the user as-is. Do not summarise it away: the point of the command is the
specific numbers.

If it reports the stored copy as DAMAGED, MISSING or UNVERIFIABLE, tell the user to run
`/mmry:load-memories`, and say plainly that until they do, their directives are not being
applied.
