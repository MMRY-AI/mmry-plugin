#!/usr/bin/env bash
# Probe: do the writer's entry count and the fixture helpers' entry count diverge, and
# does that divergence make the handler REFUSE a healthy cache?
set -uo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../../mmry" && pwd)"
export PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
WORK="$(mktemp -d)"
export TMPDIR="$WORK" MMRY_TMPDIR="$WORK" HOME="$WORK"
export MMRY_API_KEY="unused" MMRY_AUTH_METHOD="apikey" MMRY_API_URL="http://127.0.0.1:1"
# jq shim, same approach as the test helper
if ! command -v jq >/dev/null 2>&1; then
  B="$PLUGIN_ROOT/vendor/jq/jq-windows-amd64.exe"
  mkdir -p "$WORK/bin"; printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$B" > "$WORK/bin/jq"; chmod +x "$WORK/bin/jq"
  export PATH="$WORK/bin:$PATH"
fi
source "$PLUGIN_ROOT/hooks-handlers/mmry-client.sh" >/dev/null 2>&1
CACHE="$WORK/mmry-foundation.md"

# A realistic set: 12 Foundation memories, one of which is a bulleted list in its CONTENT,
# exactly the shape of the real account (12 memories, 15 lines beginning "- ").
RESP='['
for i in $(seq 1 11); do
  RESP+='{"memoryTier":"Foundation","topic":"Directive '"$i"'","content":"Standing directive number '"$i"' with enough text to be realistic."},'
done
RESP+='{"memoryTier":"Foundation","topic":"Values","content":"Our values:\n- Justice\n- Joy\n- Service"}]'

mmry_write_foundation_cache "$RESP" "$CACHE" || { echo "WRITER FAILED"; exit 1; }

echo "=== written by the real writer ==="
echo "manifest: $(cat "$CACHE.manifest")"
echo "bytes on disk: $(wc -c < "$CACHE")"
echo "writer entry count (jq, from response): $(sed -n 's/.*entries=\([0-9]*\).*/\1/p' "$CACHE.manifest")"
echo "fixture-helper entry count (grep -c '^- '): $(grep -c '^- ' "$CACHE")"

echo
echo "=== A: handler against the WRITER's manifest ==="
out="$(bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh")"; rc=$?
echo "exit=$rc"
case "$out" in *'could not verify'*) echo "VERDICT: REFUSED";; *'Directive 1'*) echo "VERDICT: INJECTED";; *) echo "VERDICT: SILENT/OTHER";; esac
echo "status file: $(cat "$WORK/mmry-foundation.status" 2>/dev/null)"

echo
echo "=== B: same bytes, manifest written by the _manifest_for / manifest_now formula ==="
read -r s b < <(cksum < "$CACHE")
n="$(grep -c '^- ' "$CACHE")"
printf 'mmry-foundation v1 entries=%s bytes=%s cksum=%s\n' "$n" "$b" "$s" > "$CACHE.manifest"
echo "manifest: $(cat "$CACHE.manifest")"
rm -f "$WORK/mmry-foundation.status"
out="$(bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh")"; rc=$?
echo "exit=$rc"
case "$out" in *'could not verify'*) echo "VERDICT: REFUSED";; *'Directive 1'*) echo "VERDICT: INJECTED";; *) echo "VERDICT: SILENT/OTHER";; esac
echo "status file: $(cat "$WORK/mmry-foundation.status" 2>/dev/null)"

echo
echo "=== C: entries=0 beside a full cache. BEFORE the fix: SILENT (withheld, nobody told). NOW: REFUSED ==="
printf 'mmry-foundation v1 entries=0 bytes=%s cksum=%s\n' "$b" "$s" > "$CACHE.manifest"
rm -f "$WORK/mmry-foundation.status"
out="$(bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh")"; rc=$?
echo "exit=$rc  output-bytes=${#out}"
case "$out" in *'could not verify'*) echo "VERDICT: REFUSED";; *'Directive 1'*) echo "VERDICT: INJECTED";; '') echo "VERDICT: SILENT (directives withheld, nothing said) - THE PRE-FIX BEHAVIOUR, a regression if seen";; *) echo "VERDICT: OTHER";; esac
echo "status file: $(cat "$WORK/mmry-foundation.status" 2>/dev/null)"

echo
echo "=== D: byte count off by ONE in the manifest ==="
printf 'mmry-foundation v1 entries=12 bytes=%s cksum=%s\n' "$((b+1))" "$s" > "$CACHE.manifest"
out="$(bash "$PLUGIN_ROOT/hooks-handlers/userpromptsubmit-foundation.sh")"; rc=$?
echo "exit=$rc"
case "$out" in *'could not verify'*) echo "VERDICT: REFUSED";; *'Directive 1'*) echo "VERDICT: INJECTED";; *) echo "VERDICT: SILENT/OTHER";; esac
rm -rf "$WORK"
