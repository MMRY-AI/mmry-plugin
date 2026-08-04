Save a memory to MMRY AI. If the user provided a description after the command, save that. If not, save the most important takeaway from the recent conversation.

## How to Save

1. Determine what to save:
   - If the user wrote something after `/mmry:save`, save that specific thing.
   - If they just typed `/mmry:save` with nothing else, review the recent conversation and identify the most important decision, convention, fact, or insight worth persisting.

2. Run the save script. Use the Bash tool. Pass the substantive content as `--context`. MMRY AI's server processes the context and decides how to file it. **Important:** Use the heredoc pattern shown below to prevent bash from expanding `$`, backticks, or other special characters in the content:

   ```
   _mmry_context=$(cat <<'MMRY_CONTEXT'
   CONTEXT
   MMRY_CONTEXT
   )
   bash "${HOME}/.claude/mmry/hooks-handlers/save-memory.sh" \
     --context "$_mmry_context" \
     --session-id "$CLAUDE_SESSION_ID"
   ```

   The server resolves the working directory from the registered session — no need to pass `--working-dir` explicitly. Pass it only when overriding the session-recorded value.

   Replace `CONTEXT` with the substantive content you want to save. Be specific and actionable, not vague. Include enough surrounding context that the server can file it correctly (e.g., what project or topic it relates to, why it matters).

3. Confirm to the user that the memory was sent for processing. Keep it brief — one sentence. Do **not** announce internal classification details (the server decides those).

4. **Sensitive-content nudge.** Memories are shared with the organization by default. If what
   was just saved reads as personal or sensitive (health, pay or finances, a performance or
   personnel matter, a private opinion about someone, anything clearly meant for the person
   alone), add ONE short line after the confirmation pointing out that it saved as shared and
   how to restrict it. For example:

   > Saved. This looks personal, and memories are shared with your organization by default —
   > say "make it private" if you would rather keep it to yourself.

   Rules for this nudge, which matter more than the wording:
   - **Never ask a question and never wait.** The save already happened; this is a passive note.
   - **Never change visibility yourself.** Only the user decides, by asking.
   - **Do not nudge on ordinary work content.** Reserve it for genuinely personal material, or
     it becomes noise people ignore.
   - Skip it entirely when the user already chose a scope (they saved privately or to a group).

## Guidelines

- Keep the context dense and specific. Aim for under 500 characters of substantive content unless the situation genuinely needs more.
- If the user pushes back on what was saved, ask them what they'd like changed and save a follow-up memory with the correction. Do not try to override the server's decision from the client.
- Do not ask the user to confirm before saving. Just save it.
