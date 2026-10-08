# #31847 evidence: a saved correction replaces the memory it corrects

| File | What it is |
|------|------------|
| `live-integration.sh` | Drives the plugin's own `save-memory.sh` against a live API with a throwaway subscriber. Claude Code layout (TC1), Codex install layout under `${CODEX_HOME}/mmry` (TC2, script leg), private and group corrections plus the refusal of a wider visibility (TC3). |
| `live-integration.txt` | That run on Integration (revision 32caee0) with this branch: 0 failures. |
| `control-before-port-a58acb6.txt` | The same run with plugin develop before the port (a58acb6): 10 failures. Every correction exits 0 while the earlier memory stays readable and search returns both; a private memory "corrected" with `--visibility global` gains a global copy. This is the behaviour of the plugin customers have today. |

Re-run: `bash docs/evidence/31847/live-integration.sh [API_BASE_URL]`; control:
`MMRY_PLUGIN_DIR=<checkout at a58acb6>/mmry bash docs/evidence/31847/live-integration.sh`.

Not covered here (pending, needs a clean machine): the Codex CLI itself choosing `--supersedes`
from the skill, and the installed plugin cache after auto-update. See the PR description.
