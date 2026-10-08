# #31847 evidence: a saved correction replaces the memory it corrects

| File | What it is |
|------|------------|
| `live-integration.sh` | Drives the plugin's own `save-memory.sh` against a live API with a throwaway subscriber. Claude Code layout (TC1), Codex install layout under `${CODEX_HOME}/mmry` (TC2, script leg), private and group corrections plus the refusal of a wider visibility (TC3). |
| `live-integration.txt` | That run on Integration (revision 32caee0) with this branch: 0 failures. |
| `codex-cli-run.txt` | Codex CLI 0.160.0, plugin installed from this branch into an isolated `CODEX_HOME` (`codex plugin marketplace add <worktree>`, `codex plugin add mmry@mmry-plugin`), Integration test account. Given a loaded memory (rendered in session-start's own format) and told it was wrong, Codex read the installed skill and ran `save-memory.sh ... --supersedes 31967`; exit 0; the API then returns 404 for 31967 and search returns only the correction. Hooks were not trusted (that needs the interactive review), so the memory file was rendered by hand rather than by the hook. |
| `control-before-port-a58acb6.txt` | The same run with plugin develop before the port (a58acb6): 10 failures. Every correction exits 0 while the earlier memory stays readable and search returns both; a private memory "corrected" with `--visibility global` gains a global copy. This is the behaviour of the plugin customers have today. |

Re-run: `bash docs/evidence/31847/live-integration.sh [API_BASE_URL]`; control:
`MMRY_PLUGIN_DIR=<checkout at a58acb6>/mmry bash docs/evidence/31847/live-integration.sh`.

Not covered here (pending, needs a clean machine): a Codex CLI session with MMRY's hooks trusted, so the
memory file comes from the hook; and the installed plugin cache after auto-update from the
marketplace. See the PR description.
