// summarize.js - per-label summary of run.sh output (#31976).
// Usage: node summarize.js OUTFILE [limit_ms]
const fs = require("fs");
const [file, lim = "12000"] = process.argv.slice(2);
const rows = fs.readFileSync(file, "utf8").trim().split(/\r?\n/).slice(1).map(l => l.trim().split(/\s+/));
const by = {};
for (const r of rows) {
    const hasLabel = isNaN(+r[0]);
    const [label, , total, prep, d, np, bp] = hasLabel ? r : ["after", ...r];
    (by[label] = by[label] || []).push({total: +total, prep: +prep, d, np: +np, bp: +bp});
}
const med = a => { const s = [...a].sort((x, y) => x - y), n = s.length; return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; };
for (const [label, rs] of Object.entries(by)) {
    const t = rs.map(r => r.total), p = rs.map(r => r.prep);
    console.log(`${label}: n=${rs.length} total median ${(med(t) / 1000).toFixed(2)} s (min ${(Math.min(...t) / 1000).toFixed(2)}, max ${(Math.max(...t) / 1000).toFixed(2)}); ` +
        `prep median ${(med(p) / 1000).toFixed(2)} s (max ${(Math.max(...p) / 1000).toFixed(2)}); under ${lim / 1000} s: ${t.filter(x => x < +lim).length}/${rs.length}; ` +
        `delivered ${rs.filter(r => r.d === "yes").length}/${rs.length}; node ${Math.min(...rs.map(r => r.np))}-${Math.max(...rs.map(r => r.np))}, bash ${Math.min(...rs.map(r => r.bp))}-${Math.max(...rs.map(r => r.bp))}`);
}
