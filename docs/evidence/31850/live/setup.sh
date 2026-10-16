#!/usr/bin/env bash
# Prepares one variant of the #31850 live renewal-turn run.
#   bash setup.sh <run dir> <plugin mmry dir> <port>
# <run dir>/home is the HOME the hooks see (Claude Code itself keeps USERPROFILE on Windows), with
# the config pointing at the stub. <run dir>/project/.claude/settings.json registers EVERY hook in
# <plugin mmry dir>/hooks/hooks.json, verbatim except that ${CLAUDE_PLUGIN_ROOT} is written out as the
# plugin's path (Claude Code refuses that variable outside a plugin), plus one harness-only SessionStart hook that puts the
# session in formation 4242 (what /mmry:formation join records locally). The handlers are installed
# into the home by the plugin's own session-init.sh, as for a customer.
set -euo pipefail
RUN="$1"; PLUGIN="$2"; PORT="$3"
mkdir -p "$RUN/home/.claude" "$RUN/tmp" "$RUN/project/.claude"
printf '{"apiUrl":"http://127.0.0.1:%s","authMethod":"apikey","apiKey":"stub-key-not-a-credential"}\n' "$PORT" > "$RUN/home/.claude/mmry-config.json"
cat > "$RUN/join.sh" <<'J'
#!/usr/bin/env bash
p="$(cat)"; re='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
[[ "$p" =~ $re ]] || exit 0
bash "$CLAUDE_PLUGIN_ROOT/hooks-handlers/formation-state.sh" set 4242 "${BASH_REMATCH[1]}" >/dev/null 2>&1 || true
exit 0
J
node -e '
const fs=require("fs");const [hooksFile,out,join,root]=process.argv.slice(1);
const h=JSON.parse(fs.readFileSync(hooksFile,"utf8").split("${CLAUDE_PLUGIN_ROOT}").join(root));
h.hooks.SessionStart.unshift({hooks:[{type:"command",command:"bash \""+join+"\"",timeout:10}]});
fs.writeFileSync(out,JSON.stringify(h,null,1));' "$PLUGIN/hooks/hooks.json" "$RUN/project/.claude/settings.json" "$(cd "$RUN" && pwd -W)/join.sh" "$(cd "$PLUGIN" && pwd -W)"
