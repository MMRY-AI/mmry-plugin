Choose who can see the memories you save: everyone in your organization, only you, or one of your groups.

Usage: `/mmry:visibility [global | private | group ["NAME"]]`

## What This Does

Sets your default memory visibility, which sticks until you change it. Memories are
**Global** by default (shared with your organization) so your team benefits from what you
learn. Switch to **Private** when what you are saving is personal, or to a **Group** when
it belongs to one team.

With no argument, it reports your current default.

## How to Run It

1. Read `$ARGUMENTS` and map it to one of: no argument (show current), `global`,
   `private`, or `group` with an optional quoted group name. Natural phrasing counts:
   "go private" is `private`, "back to global" or "share with everyone" is `global`,
   "use my Sales group" is `group "Sales"`.

2. Run the hook with the Bash tool. Prefer the plugin path; fall back to the installed
   runtime copy:

   ```bash
   HOOK="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/hooks-handlers/visibility.sh}"
   [ -f "$HOOK" ] || HOOK="${HOME}/.claude/mmry/hooks-handlers/visibility.sh"
   bash "$HOOK" MODE "GROUP NAME"
   ```

   Omit the group name unless the user named a group.

3. Relay what the hook prints. Do not invent group names or IDs.

## Result Handling

- **Group with no name:** the hook lists the groups the user belongs to. Show them and ask
  which one they want, then re-run with that name.
- **No groups:** the hook explains that an administrator creates groups and adds members.
  Relay that; do not attempt to create a group (there is no self-service group creation).
- **Unknown group name:** the hook says so and lists the valid ones. Ask the user to pick
  from that list.
- **Errors:** say plainly that the default could not be read or changed, and suggest
  trying again.

## Guidelines

- This sets a default for future saves. It does not change memories already saved. To
  change one already saved, the user asks for that specific memory to be made private or
  shared with a group.
- Never change someone's visibility on your own. Only run this when the user asks.
- Group creation and membership are administrator functions in the account portal; this
  command only selects among groups the user is already in.
