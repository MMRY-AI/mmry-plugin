Search your MMRY AI memories by keyword, on demand, during a session.

Usage: `/mmry:search <keywords> [scope]`

## What This Does

Runs a live keyword search against your memories and shows the matches. Use it any
time you want to confirm what MMRY AI already knows about a topic before acting on it.

## How to Search

1. Take the user's input from `$ARGUMENTS` and split it into two parts:
   - **keywords** - the words to search for (may be more than one word).
   - **scope** - an optional single trailing token that narrows results to one area of
     work (for example a project or directory name). If the user did not clearly ask to
     narrow to a scope, leave scope empty and treat the entire input as keywords.

   If `$ARGUMENTS` is empty, do not run a blank search. Ask the user what they want to
   search for and stop.

2. Run the existing search hook with the Bash tool, passing keywords as the first
   argument and scope as the second (omit or pass an empty string when there is no
   scope). Prefer the plugin path; fall back to the installed runtime copy:

   ```bash
   HOOK="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/hooks-handlers/search-memories.sh}"
   [ -f "$HOOK" ] || HOOK="${HOME}/.claude/mmry/hooks-handlers/search-memories.sh"
   bash "$HOOK" "KEYWORDS" "SCOPE"
   ```

3. Present the results the hook returns. Each match is formatted as
   `tier | scope | topic` followed by its content. Show them as a readable list and lead
   with the count line the hook prints (for example, "Found 3 memories").

## Result Handling

- **Matches found:** show the count and the formatted list. Do not invent, reorder, or
  add memory IDs; present what the hook returned.
- **No matches:** the hook prints "Found 0 memories". Relay that as a friendly note that
  nothing matched, and suggest broadening the keywords or dropping the scope.
- **Empty keywords:** the hook exits with "Keywords required". Do not surface a raw
  error; ask the user what they would like to search for.
- **Errors:** if the hook reports an error (for example a connection or auth problem),
  tell the user plainly that the search could not be completed and suggest trying again.

## Guidelines

- Keep keywords tight. One to three meaningful words search better than a full sentence.
- Only pass a scope when the user clearly wants to narrow to one area; otherwise search
  everything.
- This is a read-only lookup. It never changes or saves memories.
