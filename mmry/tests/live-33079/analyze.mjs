// analyze.mjs - compares what a prompt was handed (Foundation parts) with the account's Foundation set.
// usage: node analyze.mjs <delivered.json> <service-snapshot.json> [label]
//   delivered.json: array of strings, the additionalContext / developer messages of ONE prompt
//   service-snapshot.json: GET /api/memories/startup response taken just before the prompt
import fs from 'node:fs';
const [,, dpath, spath, label = ''] = process.argv;
const delivered = JSON.parse(fs.readFileSync(dpath, 'utf8'));
const snap = JSON.parse(fs.readFileSync(spath, 'utf8')).filter(m => m.memoryTier === 'Foundation');
const expLines = snap.map(m => `- ${m.topic}: ${m.content}`);
const expected = expLines.join('\n');
const out = [];
const say = s => { out.push(s); console.log(s); };
say(`== ${label} ${dpath}`);
say(`service Foundation entries: ${snap.length}, expected set text: ${expected.length} chars`);
const parts = [];
for (const t of delivered) {
  const m = /This is PART (\d+) OF (\d+) of the set, version (\d+)/.exec(t);
  if (!m) { say(`  (message without part label, ${t.length} chars, starts: ${JSON.stringify(t.slice(0, 80))})`); continue; }
  const i = t.indexOf('\n\n', m.index);
  parts.push({ k: +m[1], n: +m[2], ver: m[3], len: t.length, payload: t.slice(i + 2) });
}
parts.sort((a, b) => a.k - b.k);
say(`parts delivered: ${parts.map(p => `${p.k}/${p.n}(${p.len} chars, v${p.ver})`).join(' ')}`);
let ok = true; const fail = s => { ok = false; say('  FAIL: ' + s); };
if (!parts.length) fail('no Foundation part delivered');
else {
  const n = parts[0].n;
  if (parts.length !== n) fail(`${parts.length} parts delivered, label says ${n}`);
  if (parts.some(p => p.n !== n)) fail('parts disagree on the total');
  if (new Set(parts.map(p => p.ver)).size !== 1) fail('parts carry different versions');
  parts.forEach((p, idx) => { if (p.k !== idx + 1) fail(`part sequence broken at ${idx + 1}`); });
  if (n < 3) fail(`only ${n} parts: the set was not long enough to be served in parts of 3 or more`);
}
const joined = parts.map(p => p.payload).join('');
const norm = s => s.replace(/\r/g, '').replace(/\n+$/, '');
const got = norm(joined);
say(`restated text: ${got.length} chars; exact match to service set: ${got === expected}`);
if (got !== expected) {
  // locate first divergence; the framing/trailer of the last part is reported, not guessed at
  let d = 0; while (d < got.length && d < expected.length && got[d] === expected[d]) d++;
  say(`  first difference at char ${d}: got ${JSON.stringify(got.slice(d, d + 80))} expected ${JSON.stringify(expected.slice(d, d + 80))}`);
  ok = false;
}
let pos = -1, inOrder = true, present = 0;
snap.forEach((m, idx) => {
  const line = `- ${m.topic}: ${m.content}`;
  const at = joined.indexOf(line);
  const endMark = /END-J016-\d+-[\d-]+/.exec(m.content);
  const tailOk = endMark ? joined.includes(endMark[0]) : true;
  if (at >= 0 && tailOk) present++; else fail(`entry ${idx + 1} (id ${m.id}) missing or truncated`);
  if (at < pos) inOrder = false; pos = Math.max(pos, at);
});
say(`entries present whole: ${present}/${snap.length}; in service order: ${inOrder}`);
if (!inOrder) ok = false;
say(`VERDICT ${label}: ${ok ? 'MET' : 'NOT MET'}`);
fs.writeFileSync(dpath.replace(/\.json$/, '') + '.analysis.txt', out.join('\n') + '\n');
process.exit(ok ? 0 : 1);
