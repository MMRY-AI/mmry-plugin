# #31847 evidence: a saved correction replaces the memory it corrects

| File | What it is |
|------|------------|
| `live-integration.sh` | Drives the plugin's own `search-memories.sh --ids` and `save-memory.sh` against a live API with a throwaway subscriber. Claude Code layout (TC1), Codex install layout under `${CODEX_HOME}/mmry` (TC2, script leg), private and group corrections plus the refusal of a wider visibility (TC3). |
| `live-integration.txt` | That run on Integration (revision 32caee0) with this branch: 20 checks, 0 failures. |
| `codex-cli-run.txt` | Codex CLI 0.160.0, this branch installed from a local marketplace into an isolated `CODEX_HOME`, Integration test account, one memory seeded. Codex was told only that what MMRY remembered was wrong. It read the installed skill, ran `search-memories.sh --ids`, then `save-memory.sh ... --supersedes 31987`; exit 0; the API then returns 404 for 31987 and search returns only the correction (31988). Hooks were not trusted (that needs the interactive review), so no session-start hook ran; the correction path does not depend on it. |
| `control-before-port-a58acb6.txt` | The same live script with plugin develop before the port (a58acb6): 14 failures. Every correction exits 0 while the earlier memory stays readable and search returns both; search has no `--ids`; a private memory "corrected" with `--visibility global` gains a global copy. This is the behaviour of the plugin customers have today. |

Re-run: `bash docs/evidence/31847/live-integration.sh [API_BASE_URL]`; control:
`MMRY_PLUGIN_DIR=<checkout at a58acb6>/mmry bash docs/evidence/31847/live-integration.sh`.

Not covered here (pending, needs a clean machine): a Claude Code session on a clean install with
this plugin version, the same correction asked in conversation; a Codex CLI session with MMRY's
hooks trusted; and the installed plugin cache after auto-update from the marketplace. See the PR.
