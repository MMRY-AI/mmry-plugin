// steps.js - turn one tracer.bash log into per-step timings (#31976).
// Usage: node steps.js TRACEFILE HANDLER_FILE [threshold_ms]
//
// Each xtrace line is stamped as a shell is about to run that command, so the time from one line to
// the next (in time order, across every shell in the chain) is what that command cost, including any
// process it started. A fork for $(...) shows as time on the line just before the forked command,
// which is in the same function, so grouping by function stays honest.
//
// Steps come from the bash function stack (FUNCNAME). Top-level lines of formation-check.sh are
// placed by section markers found in HANDLER_FILE (the handler the trace was taken from), so the
// grouping survives edits that move lines. Lines from a sourced library at top level belong to the
// section that sourced them.
const fs = require("fs");
const [file, handler, thr = "300"] = process.argv.slice(2);
const src = fs.readFileSync(handler, "utf8").split(/\r?\n/);
const find = (re, from = 0) => { for (let i = from; i < src.length; i++) if (re.test(src[i])) return i + 1; return 1e9; };
const M = {};
M.hookread = find(/^source "\$\{HANDLER_DIR\}\/lib-hookread\.sh"/);
M.member = find(/^# ---- 1\. Are we in a formation/);
M.deliver = find(/^# ---- 3\. Deliver/);
const sp = find(/^    start\|prompt\)/);
M.out0 = find(/_poll_once \|\| exit 0/, sp);
M.out1 = find(/_mark_shown/, M.out0);
let t0 = null; const ev = [];
for (const l of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    let m = l.match(/^T0 (\d+)/); if (m) { t0 = +m[1]; continue; }
    m = l.match(/^\++ (\d+\.\d+) (\d+) (\S*):(\d+) \[([^\]]*)\] (.*)$/);
    if (m) ev.push({t: +m[1] * 1000, src: m[3], line: +m[4], fn: m[5].split(" ").filter(Boolean), cmd: m[6]});
}
ev.sort((a, b) => a.t - b.t);
const end = ev[ev.length - 1].t;
ev.forEach((e, i) => e.cost = (i + 1 < ev.length ? ev[i + 1].t : end) - e.t);
const S = {
    host: "00 the host's bash starts (before any MMRY code)",
    guard: "01 sh membership gate, hook-guard.sh, start formation-check.sh",
    jq: "02 credential check, resolve jq",
    payload: "03 read stdin, parse the payload (jq)",
    client: "04 membership record, load the client, read config (jq)",
    mutex: "05 take the delivery mutex (mkdir), read the record",
    enc: "06 url-encode session id and since",
    req: "07 request (auth header, mktemp, curl, read, rm)",
    render: "08 parse and render the response (jq)",
    out: "09 write additionalContext (jq)",
    mark: "10 mark seen, release the mutex",
    other: "11 other",
};
let reached = false, section = S.jq;
function top(L) {
    if (L < M.hookread) return S.jq;
    if (L < M.member) return S.payload;
    if (L < M.deliver) return S.client;
    if (L > M.out0 && L < M.out1) return S.out;
    return S.other;
}
function step(e) {
    if (e.src === "formation-check.sh") reached = true;
    if (!reached) return S.guard;
    const has = n => e.fn.includes(n);
    if (has("_mark_shown")) return S.mark;
    if (has("mmry_resolve_jq") || has("mmry_jq_candidate") || has("_fc_resolve_jq")) return S.jq;
    if (has("mmry_load_config")) return S.client;
    if (has("_mmry_urlencode") || has("_mmry_urlencode_v")) return S.enc;
    if (has("_mmry_request")) return S.req;
    if (has("_poll_once")) {
        if (has("_acquire") || has("mmry_formation_state_read") || has("mmry_formation_state_refresh") || has("mmry_formation_state_seen")) return S.mutex;
        if (has("mmry_get_formation_transmissions")) return S.enc;
        return e.line >= find(/MMRY_HTTP_CODE:-\}" =~ \^2/) ? S.render : S.mutex;
    }
    if (e.src === "formation-check.sh" && e.fn.filter(f => f !== "source" && f !== "main").length === 0) {
        section = top(e.line); return section;
    }
    return section;
}
const per = {};
for (const e of ev) { const k = step(e); per[k] = (per[k] || 0) + e.cost; }
per[S.host] = t0 != null ? ev[0].t - t0 : 0;
console.log("total, launch to last traced line: " + (end - t0).toFixed(0) + " ms");
for (const k of Object.keys(per).sort()) console.log("  " + per[k].toFixed(0).padStart(6) + " ms  " + k);
console.log("commands over " + thr + " ms:");
for (const e of ev) if (e.cost > +thr) console.log("  " + e.cost.toFixed(0).padStart(6) + " ms  " + e.src + ":" + e.line + " [" + e.fn.join(" ") + "] " + e.cmd.slice(0, 80));
