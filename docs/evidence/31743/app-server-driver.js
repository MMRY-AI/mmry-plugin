// app-server-driver.js - drive the REAL Codex (codex app-server, the process the Codex desktop app
// runs) against the installed MMRY plugin, with no model and no OpenAI key (#31743).
//
// It starts N threads (conversations), lists the MCP servers each one sees with their tools, and
// calls MMRY's tools through mcpServer/tool/call. That route proves what the server does inside
// Codex: that Codex starts it from the plugin, that it reaches MMRY AI from outside the sandbox, and
// which conversation each call is attributed to. It does NOT exercise the model's approval policy
// (a direct call from the app is not reviewed by it); that is read from Codex's source and is part
// of the live procedure on Mac and Windows.
//
// Usage: node app-server-driver.js <plan.json>
//   plan: { "cwd": "...", "threads": 2, "threadsOut": "<file>", "steps": [
//     {"t": 0, "tool": "memory_search", "args": {...},
//      "capture": {"id1": "id (\\d+)"}, "until": "<regex>", "retries": 10, "retryDelay": 5000},
//     {"list": 0}, {"sleep": 3000} ] }
//   "${name}" as a whole argument value is replaced by a value captured earlier.
// The environment (CODEX_HOME, HOME, TMPDIR, the credential) is the caller's; make it isolated.
//
// #31789 added two steps, and nothing about the ones above changed:
//   {"watch": 60000, "t": 0}   wait that long and report every notification the app-server sent
//                              about thread t meanwhile, and how many turns started on it. An idle
//                              thread that something woke would show turn/started here.
//   {"exec": ["script", "arg", "${t1}"], "label": "x"}
//                              run a bash script (BASH_BIN, else bash) mid-plan and log its output
//                              under the label; ${t0}, ${t1}... are the thread ids and ${name} a
//                              captured value. Used to run the plugin's own delivery hook for one
//                              conversation at the moment the plan needs it.
'use strict';
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');

const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const codex = process.env.CODEX_BIN || 'codex';
const child = spawn(codex, ['app-server'], { stdio: ['pipe', 'pipe', 'pipe'], shell: process.platform === 'win32' });
let buf = '';
let nextId = 1;
const pending = new Map();
const vars = {};
const notes = [];
const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);

child.stderr.on('data', () => {});
child.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id !== undefined && !msg.method && pending.has(msg.id)) {
      const { resolve } = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    } else if (msg.method === 'mcpServer/startupStatus/updated') {
      log('startup', JSON.stringify(msg.params));
    } else if (msg.id === undefined && msg.method) {
      // #31789: every other notification is kept, with the thread it names, for "watch".
      const p = msg.params || {};
      notes.push({ at: Date.now(), method: msg.method, threadId: p.threadId || (p.thread && p.thread.id) || (p.turn && p.turn.threadId) || null });
    } else if (msg.id !== undefined && msg.method) {
      log('SERVER REQUEST (approval or elicitation):', JSON.stringify(msg).slice(0, 400));
    }
  }
});

function request(method, params, timeoutMs = 180000) {
  const id = nextId++;
  child.stdin.write(JSON.stringify({ method, id, params }) + '\n');
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve });
    setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${method}`)); }
    }, timeoutMs);
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function substitute(args) {
  const out = {};
  for (const [k, v] of Object.entries(args || {})) {
    const m = typeof v === 'string' && /^\$\{(\w+)\}$/.exec(v);
    if (m && m[1] in vars) out[k] = /^\d+$/.test(vars[m[1]]) ? Number(vars[m[1]]) : vars[m[1]];
    else out[k] = v;
  }
  return out;
}

(async () => {
  const init = await request('initialize', { clientInfo: { name: 'mmry-31743-driver', title: null, version: '1' } });
  log('initialize', init.error ? JSON.stringify(init.error) : 'ok');
  child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
  const threads = [];
  for (let n = 0; n < (plan.threads || 1); n++) {
    const r = await request('thread/start', { cwd: plan.cwd });
    if (r.error) { log('thread/start error', JSON.stringify(r.error)); process.exit(2); }
    threads.push(r.result.thread.id);
    log(`thread ${n} = ${r.result.thread.id}`);
  }
  if (plan.threadsOut) fs.writeFileSync(plan.threadsOut, threads.join('\n') + '\n');
  for (const step of plan.steps) {
    if (step.sleep) { await sleep(step.sleep); continue; }
    if (step.list !== undefined) {
      const r = await request('mcpServerStatus/list', { threadId: threads[step.list] });
      if (r.error) { log('list error', JSON.stringify(r.error)); continue; }
      for (const s of r.result.data || []) {
        const tools = Object.values(s.tools || {});
        log(`list t${step.list}: server ${s.name} runtimeStatus=${JSON.stringify(s.runtimeStatus)} plugin=${s.pluginId} tools=${tools.length}${s.toolsError ? ' toolsError=' + s.toolsError : ''}`);
        for (const t of tools) log(`    ${t.name} ${JSON.stringify(t.annotations || {})}`);
      }
      continue;
    }
    if (step.watch) {
      // #31789: what did the app-server do about thread t while nobody spoke to it?
      const tid = threads[step.t || 0];
      const from = Date.now();
      await sleep(step.watch);
      const seen = notes.filter((n) => n.at >= from && n.threadId === tid);
      const turns = seen.filter((n) => n.method === 'turn/started').length;
      const methods = [...new Set(seen.map((n) => n.method))].join(',') || 'none';
      log(`watch t${step.t || 0} ${step.watch}ms: turn/started=${turns} notifications=${seen.length} methods=${methods}`);
      continue;
    }
    if (step.exec) {
      // #31789: run a script mid-plan, with thread ids and captured values substituted.
      const sub = (a) => a.replace(/\$\{(\w+)\}/g, (m, k) => (/^t\d+$/.test(k) ? threads[Number(k.slice(1))] : (k in vars ? vars[k] : m)));
      const argv = step.exec.map(sub);
      const r = spawnSync(process.env.BASH_BIN || 'bash', argv, { encoding: 'utf8', timeout: 120000 });
      log(`exec ${step.label || argv[0]} exit=${r.status}\n${(r.stdout || '') + (r.stderr || '')}\nend exec ${step.label || argv[0]}`);
      continue;
    }
    const args = substitute(step.args);
    let r;
    let text;
    let tries = 0;
    for (;;) {
      r = await request('mcpServer/tool/call', { threadId: threads[step.t], server: step.server || 'mmry_plugin', tool: step.tool, arguments: args });
      text = r.result ? (r.result.content || []).map((c) => c.text).join('\n') : JSON.stringify(r.error);
      if (!step.until || new RegExp(step.until).test(text) || ++tries > (step.retries || 0)) break;
      log(`call t${step.t} ${step.tool}: not there yet (try ${tries}), retrying`);
      await sleep(step.retryDelay || 5000);
    }
    log(`call t${step.t} ${step.tool} ${JSON.stringify(args)} isError=${r.result ? !!r.result.isError : 'rpc-error'}\n${text}`);
    for (const [k, re] of Object.entries(step.capture || {})) {
      const m = new RegExp(re).exec(text);
      if (m) { vars[k] = m[1]; log(`captured ${k}=${m[1]}`); } else log(`capture ${k} FAILED`);
    }
  }
  child.kill();
  process.exit(0);
})().catch((e) => { log('FAILED', e.message); child.kill(); process.exit(1); });
