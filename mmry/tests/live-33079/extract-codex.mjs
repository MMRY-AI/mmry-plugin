// extract-codex.mjs <rollout.jsonl> <outdir> - per turn (task_started .. next task_started): the developer
// messages that carry Foundation parts, written to <outdir>/pN-delivered.json; prints a per-turn summary.
import fs from 'node:fs';
const [,, rp, od] = process.argv;
const turns = []; let cur = null;
for (const l of fs.readFileSync(rp, 'utf8').split('\n')) {
  if (!l.trim()) continue;
  const e = JSON.parse(l);
  if (e.type === 'event_msg' && e.payload?.type === 'task_started') { cur = { dev: [], user: [] }; turns.push(cur); continue; }
  if (!cur || e.type !== 'response_item' || e.payload?.type !== 'message') continue;
  const texts = (e.payload.content || []).map(c => c.text || '');
  (e.payload.role === 'developer' ? cur.dev : e.payload.role === 'user' ? cur.user : []).push(...texts);
}
turns.forEach((t, i) => {
  const f = t.dev.filter(x => /This is PART \d+ OF \d+ of the set/.test(x));
  fs.writeFileSync(`${od}/p${i + 1}-delivered.json`, JSON.stringify(f));
  console.log(`turn ${i + 1}: developer messages ${t.dev.length} (${t.dev.map(x => x.length).join(',')}), Foundation parts ${f.length}, MMRY messages: ${t.dev.filter(x => /MMRY AI/.test(x) && !/PART \d+ OF/.test(x)).map(x => JSON.stringify(x.slice(0, 70))).join(' | ')}`);
});
