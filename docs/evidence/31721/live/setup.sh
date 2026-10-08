#!/usr/bin/env bash
# setup.sh - prepare a working folder for live.js (#31721).
#
#   bash setup.sh <work-dir> [plugin-checkout]
#
# Creates <work-dir>/R and <work-dir>/S, each a project folder for one Claude Code session, and a
# wrap.sh that runs the CHECKOUT's formation-check.sh and logs every watch to <work-dir>/watch.log.
# R gets the Stop registration exactly as the checkout's hooks/hooks.json ships it (asyncRewake and
# its timeout), and nothing else; S gets no hooks at all - it only sends.
set -euo pipefail
WORK="${1:?usage: setup.sh <work-dir> [plugin-checkout]}"
PLUGIN="${2:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
mkdir -p "$WORK/R/.claude" "$WORK/S/.claude" "$WORK/tmp"
WORK="$(cd "$WORK" && pwd)"
TIMEOUT="$(node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log((d.hooks.Stop||[]).flatMap(g=>g.hooks).find(h=>h.command.includes("formation-check")).timeout)' "$PLUGIN/mmry/hooks/hooks.json")"
cat > "$WORK/wrap.sh" <<WRAP
#!/usr/bin/env bash
LOG="$WORK/watch.log"
p="\$(cat)"
echo "\$(date -u +%FT%TZ) start pid=\$\$" >> "\$LOG"
e="\$(mktemp)"
printf '%s' "\$p" | bash "$PLUGIN/mmry/hooks-handlers/formation-check.sh" 2>"\$e"
rc=\$?
echo "\$(date -u +%FT%TZ) end pid=\$\$ rc=\$rc said=\$(head -c 90 "\$e" | tr '\n' ' ')" >> "\$LOG"
cat "\$e" >&2; rm -f "\$e"
exit \$rc
WRAP
chmod +x "$WORK/wrap.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"MMRY_CONFIG_FILE=\\"%s/live-config.json\\" TMPDIR=\\"%s/tmp\\" bash \\"%s/wrap.sh\\"","asyncRewake":true,"rewakeSummary":"MMRY formation","timeout":%s}]}]}}\n' \
    "$WORK" "$WORK" "$WORK" "$TIMEOUT" > "$WORK/R/.claude/settings.json"
echo '{}' > "$WORK/S/.claude/settings.json"
echo "Prepared $WORK with the Stop registration timeout $TIMEOUT s from $PLUGIN"
