// A stand-in for the MMRY AI service on 127.0.0.1, for the #31850 live renewal-turn run. It answers
// every route the plugin calls with a plausible empty answer, says the session is a member of any
// formation it is asked about, and logs every request: "<ISO time> <METHOD> <path>".
const http = require('http');
const fs = require('fs');
const [port, logFile] = process.argv.slice(2);
const log = fs.createWriteStream(logFile, { flags: 'a' });
http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    const path = req.url.split('?')[0];
    log.write(new Date().toISOString() + ' ' + req.method + ' ' + req.url + '\n');
    let code = req.method === 'POST' ? 201 : 200;
    let out = req.method === 'POST' ? '{}' : '[]';
    if (/\/api\/formations\/\d+\/transmissions\/sent$/.test(path)) {
      out = JSON.stringify({ formationId: Number(path.split('/')[3]), member: true, messages: [] });
    } else if (/\/api\/health/.test(path)) {
      out = '{"status":"healthy"}';
    }
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(out);
  });
}).listen(Number(port), '127.0.0.1');
