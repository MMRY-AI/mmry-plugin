// Live test for #31721 requirement 1 (and requirement 2 end to end):
// a real Claude Code session R, idle for longer than three hook windows, still receives a directed
// message sent by a second real Claude Code session S, with nobody typing into R.
//
// R runs the branch's formation-check.sh on Stop with the shipped registration (asyncRewake, 1800 s).
// S sends with the branch's formation-say.sh through its own Bash tool. Both talk to LIVE_API.
const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// LIVE_DIR is the working folder setup.sh prepared (R/, S/, tmp/, wrap.sh, the logs).
// LIVE_API is the service to test against; LIVE_PLUGIN the plugin checkout whose handlers run.
const L = process.env.LIVE_DIR || __dirname;
const API = process.env.LIVE_API || 'http://localhost:5291';
const W = (process.env.LIVE_PLUGIN || path.resolve(__dirname, '../../../..')).split(path.sep).join('/');
const H = `${W}/mmry/hooks-handlers`;
const TMP = `${L.replace(/\\/g, '/')}/tmp`;
const CFG = `${L.replace(/\\/g, '/')}/live-config.json`;
const RENEWALS_NEEDED = Number(process.env.RENEWALS_NEEDED || 3);
const LOG = path.join(L, 'live.log');
const log = (s) => fs.appendFileSync(LOG, new Date().toISOString() + ' ' + s + '\n');
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function rest(method, p, { token, key, body } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (key) headers['X-Api-Key'] = key;
  const res = await fetch(API + p, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let data; try { data = JSON.parse(text); } catch { data = text; }
  return { status: res.status, data };
}

function session(name, cwd, extraEnv, allowedTools) {
  const args = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
    '--model', 'haiku', '--setting-sources', 'project'];
  if (allowedTools) args.push('--allowedTools', allowedTools);
  const cp = spawn('claude', args, { cwd, shell: true, env: { ...process.env, ...extraEnv }, stdio: ['pipe', 'pipe', 'pipe'] });
  const s = { name, cp, sid: null, texts: [], results: 0 };
  let buf = '';
  cp.stdout.on('data', (d) => {
    buf += d; let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      try {
        const j = JSON.parse(line);
        if (j.session_id && !s.sid) s.sid = j.session_id;
        if (j.type === 'assistant') {
          const t = (j.message.content || []).map(c => c.text || (c.type === 'tool_use' ? `[tool_use ${JSON.stringify(c.input).slice(0, 200)}]` : '')).join('').trim();
          if (t) { s.texts.push(t); log(`${name} ASSISTANT ${JSON.stringify(t).slice(0, 400)}`); }
        } else if (j.type === 'user') {
          log(`${name} USER/TOOL ${JSON.stringify(j.message.content).slice(0, 400)}`);
        } else if (j.type === 'result') {
          s.results++; log(`${name} RESULT #${s.results} ${JSON.stringify(j.result || '').slice(0, 200)}`);
        } else if (j.type === 'system' && j.subtype === 'init') {
          log(`${name} INIT session=${j.session_id}`);
        }
      } catch { /* not json */ }
    }
  });
  cp.stderr.on('data', (d) => log(`${name} STDERR ${String(d).slice(0, 300)}`));
  cp.on('exit', (c) => log(`${name} EXIT ${c}`));
  s.say = (text) => { log(`${name} <= ${JSON.stringify(text).slice(0, 300)}`); cp.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: text } }) + '\n'); };
  return s;
}

async function waitFor(pred, ms, what) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (pred()) return true; await sleep(1000); }
  throw new Error(`timed out waiting for ${what}`);
}

function renewals() {
  const p = path.join(L, 'watch.log');
  if (!fs.existsSync(p)) return 0;
  return fs.readFileSync(p, 'utf8').split('\n').filter(l => l.includes('rc=2') && l.includes('WATCH RENEWED')).length;
}

(async () => {
  const ts = Date.now();
  log(`---- live #31721 run ${ts}, claude ${execFileSync('claude', ['--version'], { shell: true }).toString().trim()}`);

  // ---- an account, an API key for the plugin, and a formation with a REST lead -----------------
  const email = `live31721-${ts}@test.mnemo`;
  const reg = await rest('POST', '/api/auth/register', { body: { subscriberName: `Live31721_${ts}`, firstName: 'Live', lastName: 'Test', email, password: 'TestPassword123!' } });
  if (reg.status >= 300) throw new Error('register ' + JSON.stringify(reg));
  const token = reg.data.token;
  const keyRes = await rest('POST', '/api/auth/apikey', { token, body: { label: 'live-31721' } });
  const key = keyRes.data.apiKey;
  fs.writeFileSync(CFG, JSON.stringify({ apiUrl: API, authMethod: 'apikey', apiKey: key }));
  const lead = `live-lead-${ts}`;
  await rest('POST', '/api/sessions', { token, body: { sessionId: lead, clientName: 'live-lead' } });
  const f = await rest('POST', '/api/formations', { token, body: { objective: `Live #31721 ${ts}`, sessionId: lead } });
  const fid = f.data.id;
  log(`formation ${fid} created`);

  // ---- two real Claude Code sessions -------------------------------------------------------------
  // SMOKE_WINDOW shortens the window for a harness smoke run ONLY; the real run leaves it unset.
  const env = { MMRY_CONFIG_FILE: CFG, TMPDIR: TMP, ...(process.env.SMOKE_WINDOW ? { MMRY_IDLE_POLL_SECONDS: process.env.SMOKE_WINDOW } : {}) };
  const R = session('R', path.join(L, 'R'), env, null);
  const S = session('S', path.join(L, 'S'), env, 'Bash');
  R.say('Reply with exactly the word READY.');
  S.say('Reply with exactly the word READY.');
  await waitFor(() => R.sid && S.sid && R.results >= 1 && S.results >= 1, 180000, 'both sessions to start');

  // Join both on the service and record membership locally, exactly as formation-join.sh does.
  const members = {};
  for (const s of [R, S]) {
    await rest('POST', '/api/sessions', { token, body: { sessionId: s.sid, clientName: `live-${s.name}` } });
    const j = await rest('POST', `/api/formations/${fid}/join`, { token, body: { sessionId: s.sid } });
    if (j.status >= 300) throw new Error(`join ${s.name} ` + JSON.stringify(j));
    execFileSync('bash', [`${H}/formation-state.sh`, 'set', String(fid), s.sid], { env: { ...process.env, TMPDIR: TMP } });
  }
  const roster = await rest('GET', `/api/formations/${fid}`, { token });
  for (const m of roster.data.members) members[m.sessionId] = m.id;
  const rMember = members[R.sid];
  log(`R=${R.sid} member ${rMember}; S=${S.sid} member ${members[S.sid]}`);

  // R's turn ends after this, and from here NOTHING is typed into R again.
  R.say('You are now a member of a coordination group. If MMRY shows you a FORMATION TRANSMISSION, reply with the exact text of the line marked DIRECTED TO YOU. If MMRY says it is renewing its watch, end your turn by replying with the single word OK. For now, reply with exactly the word JOINED.');
  await waitFor(() => R.results >= 2, 180000, 'R to finish its last typed turn');
  const idleFrom = Date.now();
  log(`R idle from now; waiting for ${RENEWALS_NEEDED} renewals`);

  await waitFor(() => renewals() >= RENEWALS_NEEDED, (RENEWALS_NEEDED * 1700 + 900) * 1000, `${RENEWALS_NEEDED} renewals`);
  const idleSec = Math.round((Date.now() - idleFrom) / 1000);
  log(`${RENEWALS_NEEDED} renewals seen after R had been idle ${idleSec} s; waiting 90 s into the next watch`);
  await sleep(90000);

  const code = `LIVE-31721-${ts}`;
  const before = R.texts.length;
  S.say(`Run exactly this shell command with your Bash tool, then reply with its output: CLAUDE_SESSION_ID=${S.sid} MMRY_CONFIG_FILE="${CFG}" TMPDIR="${TMP}" bash "${H}/formation-say.sh" "${code} take the validator" ${rMember}`);
  const sentAt = Date.now();
  await waitFor(() => R.texts.slice(before).some(t => t.includes(code)), 600000, 'R to repeat the directed message');
  const deliveredSec = Math.round((Date.now() - sentAt) / 1000);
  log(`PASS R repeated ${code} ${deliveredSec} s after S was asked to send it; R had been idle ${Math.round((sentAt - idleFrom) / 1000)} s with nobody typing`);

  // Requirement 2, end to end: S's view says it was read once R's next watch has reported it.
  let read = null;
  for (let i = 0; i < 24 && !(read && read.read); i++) {
    await sleep(5000);
    const v = await rest('GET', `/api/formations/${fid}/transmissions/sent?sessionId=${encodeURIComponent(S.sid)}`, { key });
    read = (v.data.messages || []).find(m => (m.preview || '').includes(code));
  }
  log(`sender view: ${JSON.stringify(read)}`);

  R.cp.stdin.end(); S.cp.stdin.end();
  await sleep(15000); try { R.cp.kill(); S.cp.kill(); } catch { }
  log('---- done');
  process.exit(0);
})().catch(e => { log('FAIL ' + (e.stack || e)); process.exit(1); });
