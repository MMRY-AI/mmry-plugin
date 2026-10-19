// Summarises one live run: for each renewal, the model turns it made, the requests made DURING the
// renewal turn (from the membership answer to the turn's result), and the checks the following watch
// made before its own renewal. Reads session.txt and requests.txt from the run dir, plus
// tmp/.mmry-stop-count (how many times the save prompt fired in the whole session).
const fs = require('fs');
const dir = process.argv[2];
const t = (s) => Date.parse(s.slice(0, 24));
const sess = fs.readFileSync(dir + '/session.txt', 'utf8').split('\n');
const reqs = fs.readFileSync(dir + '/requests.txt', 'utf8').split('\n').filter(Boolean)
  .map((l) => ({ at: t(l), what: l.slice(25) }));
const results = sess.filter((l) => l.includes('OUT result/')).map((l) => ({ at: t(l), text: (l.match(/result="(.*)"/) || [])[1] }));
const sent = reqs.filter((r) => r.what.includes('/transmissions/sent'));
let count = 'absent';
try { count = fs.readFileSync(dir + '/tmp/.mmry-stop-count', 'utf8').trim(); } catch (e) {}
console.log(`${dir}: ${results.length} model turns (${results.map((r) => r.text).join(' | ')}); save prompt fired ${count} time(s) in the session`);
sent.forEach((s, i) => {
  const turn = results.find((r) => r.at > s.at);
  if (!turn) { console.log(`  renewal ${i + 1}: no turn before the run ended`); return; }
  const during = reqs.filter((r) => r.at > s.at && r.at <= turn.at);
  const next = sent[i + 1] ? sent[i + 1].at : Infinity;
  const watch = reqs.filter((r) => r.at > turn.at && r.at < next && r.what.includes('/transmissions?'));
  console.log(`  renewal ${i + 1}: turn "${turn.text}"; requests during the renewal turn: ${during.length}${during.length ? ' (' + during.map((r) => r.what.split('?')[0]).join(', ') + ')' : ''}; checks by the next watch before it renewed: ${sent[i + 1] ? watch.length : 'n/a'}`);
});
