#!/usr/bin/env bash
# setup.sh - prepare a working folder for live.js, driving the watch through the SHIPPED hook
# registration (#31721 TC1b).
#
#   bash setup.sh <work-dir> [plugin-checkout]
#
# What differs from ../live/setup.sh, which wrapped formation-check.sh directly:
#
#   * R's .claude/settings.json holds every hooks.json entry whose command names formation-check,
#     copied VERBATIM from the checkout's mmry/hooks/hooks.json under the same events. So what runs
#     on Stop is the shipped gate (`sh -c 'for f in "${TMPDIR:-/tmp}"/.mmry-formation-*; ...'`), then
#     the shipped `~/.claude/mmry/hooks-handlers/hook-guard.sh formation-check`, with the shipped
#     asyncRewake and timeout. Nothing in the command line is rewritten.
#   * `~` in that command is <work-dir>/home: live.js starts R with HOME pointing there, and
#     <work-dir>/home/.claude/mmry/hooks-handlers is a copy of the checkout's handlers, which is what
#     session-init.sh installs on a real machine. The developer's own ~/.claude is never touched.
#     (Claude Code on Windows takes its own config from USERPROFILE, so it stays signed in.)
#   * There is no logging wrapper, because there is nothing to wrap without changing the command.
#     live.js watches the lock directories the handler itself creates in TMPDIR instead.
set -euo pipefail
WORK="${1:?usage: setup.sh <work-dir> [plugin-checkout]}"
PLUGIN="${2:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
mkdir -p "$WORK/R/.claude" "$WORK/S/.claude" "$WORK/tmp" "$WORK/home/.claude/mmry/hooks-handlers"
WORK="$(cd "$WORK" && pwd)"
cp -R "$PLUGIN/mmry/hooks-handlers/." "$WORK/home/.claude/mmry/hooks-handlers/"
node -e '
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const out = { hooks: {} };
for (const [ev, groups] of Object.entries(d.hooks)) {
  const keep = groups.filter(g => (g.hooks || []).some(h => (h.command || "").includes("formation-check")));
  if (keep.length) out.hooks[ev] = keep;
}
fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 2) + "\n");
console.log("formation-check entries copied for: " + Object.keys(out.hooks).join(", "));
' "$PLUGIN/mmry/hooks/hooks.json" "$WORK/R/.claude/settings.json"
echo '{}' > "$WORK/S/.claude/settings.json"
( cd "$PLUGIN" && git rev-parse HEAD ) > "$WORK/plugin-head.txt"
echo "Prepared $WORK from $PLUGIN at $(cat "$WORK/plugin-head.txt")"
