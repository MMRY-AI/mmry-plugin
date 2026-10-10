// steps.js - turn one tracer.bash log into per-step timings (#31976).
// Usage: node steps.js TRACEFILE [threshold_ms]
//
// Each xtrace line is stamped as the shell is about to run that command, so the time from one line
// to the next (in time order, across every shell in the chain) is what that command cost, including
// any process it started. A fork for $(...) shows as time on the line BEFORE the forked command's
// first line, which is still inside the same function, so grouping by function stays honest.
// Steps are assigned from the bash function stack (FUNCNAME) and, for top-level code, the file.
const fs = require("fs");
const [file, thr = "150"] = process.argv.slice(2);
let t0 = null; const ev = [];
for (const l of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    let m = l.match(/^T0 (\d+)/); if (m) { t0 = +m[1]; continue; }
    m = l.match(/^\++ (\d+\.\d+) (\d+) (\S*):(\d+) \[([^\]]*)\] (.*)$/);
    if (m) ev.push({t: +m[1] * 1000, src: m[3], line: +m[4], fn: m[5].split(" ").filter(Boolean), cmd: m[6]});
}
ev.sort((a, b) => a.t - b.t);
const end = ev[ev.length - 1].t;
ev.forEach((e, i) => e.cost = (i + 1 < ev.length ? ev[i + 1].t : end) - e.t);
let reachedFC = false, after = false;
function step(e) {
    const f = e.fn;
    if (e.src === "formation-check.sh" || f.length > 0 && reachedFC) reachedFC = true;
    if (!reachedFC) return "01 launch: sh gate, hook-guard.sh, start formation-check.sh";
    const has = n => f.includes(n);
    if (has("_mark_shown")) return "11 mark seen + release the mutex";
    if (has("mmry_resolve_jq")) return "03 resolve jq (jq --version)";
    if (has("mmry_load_config")) return "05 load the client + read config (jq)";
    if (has("_mmry_urlencode")) return "07 url-encode session id and since";
    if (has("_mmry_request")) return "08 request (auth header, mktemp, curl, read, rm)";
    if (has("_acquire")) return "06 take the delivery mutex (mkdir)";
    if (has("_poll_once")) {
        if (after || e.line >= 548) { after = true; return "09 parse + render the response (jq)"; }
        return "06 take the delivery mutex, read and refresh the record";
    }
    if (e.src === "formation-check.sh") {
        if (e.line < 168) return "02 start formation-check.sh";
        if (e.line < 207) return "03 resolve jq (jq --version)";
        if (e.line < 297) return "04 read stdin + parse the payload (jq)";
        if (e.line < 317) return "05 load the client + read config (jq)";
        if (e.line < 782) return "05 load the client + read config (jq)";
        if (e.line >= 846 && e.line <= 849) return "10 write additionalContext (jq)";
        return "12 other";
    }
    return "05 load the client + read config (jq)"; // sourcing libraries at top level
}
const per = {};
for (const e of ev) { const k = step(e); per[k] = (per[k] || 0) + e.cost; e.step = k; }
// The launch step starts at T0, not at the first traced line.
const lead = t0 != null ? ev[0].t - t0 : 0;
per["01 launch: sh gate, hook-guard.sh, start formation-check.sh"] = (per["01 launch: sh gate, hook-guard.sh, start formation-check.sh"] || 0) + lead;
console.log("total, launch to last traced line: " + (end - t0).toFixed(0) + " ms");
console.log("steps:");
for (const k of Object.keys(per).sort()) console.log("  " + per[k].toFixed(0).padStart(6) + " ms  " + k);
console.log("commands over " + thr + " ms:");
for (const e of ev) if (e.cost > +thr) console.log("  " + e.cost.toFixed(0).padStart(6) + " ms  " + e.src + ":" + e.line + " [" + e.fn.join(" ") + "] " + e.cmd.slice(0, 90));
