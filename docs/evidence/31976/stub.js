// stub.js - a local stand-in for the MMRY service's transmissions route (#31976).
// Answers every request at once with one message and logs each arrival time in ms, so the time
// the check spends BEFORE it asks can be read off the arrival log.
const http = require("http"), fs = require("fs"), dir = process.argv[2];
const body = JSON.stringify([{transmissionID: 9001, senderRole: "lead", senderSessionID: "lead-1",
    senderUserID: 1, content: "MEASURE-MSG", sentDate: "2026-10-10T01:00:00"}]);
const srv = http.createServer((q, r) => {
    fs.appendFileSync(dir + "/arrivals", Date.now() + "\n");
    r.writeHead(200, {"Content-Type": "application/json"});
    r.end(body);
});
srv.listen(0, "127.0.0.1", () => fs.writeFileSync(dir + "/port", String(srv.address().port)));
