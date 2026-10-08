// Drive one headless Claude Code session over stream-json; keep stdin open HOLD seconds; log events.
const { spawn } = require('child_process');
const fs = require('fs');
const [cwd, holdSec, outFile, prompt] = process.argv.slice(2);
const out = fs.createWriteStream(outFile, { flags: 'a' });
const log = (s) => out.write(new Date().toISOString() + ' ' + s + '\n');
const args = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
  '--model', 'haiku', '--setting-sources', 'project', '--permission-mode', 'default'];
const cp = spawn('claude', args, { cwd, shell: true, stdio: ['pipe', 'pipe', 'pipe'] });
log('spawned pid=' + cp.pid);
let buf = '';
cp.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1);
  try { const j = JSON.parse(line); let s = j.type + (j.subtype ? '/' + j.subtype : '');
    if (j.type === 'assistant') s += ' TEXT=' + JSON.stringify((j.message.content || []).map(c => c.text || c.type).join('|')).slice(0, 300);
    if (j.type === 'user') s += ' ' + JSON.stringify(j.message.content).slice(0, 400);
    if (j.type === 'result') s += ' result=' + JSON.stringify(j.result).slice(0, 200);
    if (j.type === 'system' && j.subtype !== 'init') s += ' ' + JSON.stringify(j).slice(0, 600);
    log('OUT ' + s); } catch (e) { log('RAW ' + line.slice(0, 300)); } } });
cp.stderr.on('data', (d) => log('ERR ' + String(d).slice(0, 500)));
cp.on('exit', (c) => { log('exit ' + c); out.end(); process.exit(0); });
cp.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: prompt } }) + '\n');
setTimeout(() => { log('closing stdin'); cp.stdin.end(); setTimeout(() => cp.kill(), 30000); }, Number(holdSec) * 1000);
