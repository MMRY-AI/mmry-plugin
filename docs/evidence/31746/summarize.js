// summarize.js FILE [BUDGET_MS] - per-variant figures from measure.sh output.
const fs = require("fs");
const file = process.argv[2], budget = Number(process.argv[3] || 15000);
const rows = fs.readFileSync(file, "utf8").trim().split(/\r?\n/).slice(1).map(l => l.trim().split(/\s+/))
  .filter(r => r.length >= 5).map(([impl, run, total, prep, d]) => ({ impl, total: +total, prep: prep === "NA" ? NaN : +prep, d }));
const med = a => { const s = [...a].sort((x, y) => x - y); const n = s.length; return n ? (n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2) : NaN; };
const order = ["old", "new", "old-codex", "new-codex"];
console.log("variant      runs  total median / min / max (ms)    prep median / max (ms)   within " + budget / 1000 + " s   delivered");
for (const v of order) {
  const r = rows.filter(x => x.impl === v); if (!r.length) continue;
  const t = r.map(x => x.total), p = r.map(x => x.prep).filter(x => !isNaN(x));
  const within = r.filter(x => x.total < budget).length, del = r.filter(x => x.d === "yes").length;
  console.log(`${v.padEnd(12)} ${String(r.length).padStart(4)}  ${String(med(t)).padStart(7)} / ${String(Math.min(...t)).padStart(6)} / ${String(Math.max(...t)).padStart(6)}       ${String(med(p)).padStart(7)} / ${String(Math.max(...p)).padStart(6)}        ${within}/${r.length}        ${del}/${r.length}`);
}
